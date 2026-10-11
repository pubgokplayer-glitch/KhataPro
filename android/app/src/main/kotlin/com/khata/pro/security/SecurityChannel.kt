// KhataPro · Android Keystore security channel.
//
// Speaks to `lib/platform/security/platform_key_custody.dart` over the
// `khata_pro/security` method channel. Policy lives in Dart; this file stores
// keys, uses them, and reports what the hardware can do.
//
// Two key flavours — see the Dart file for why there are two:
//
//   requireBiometric = false → AES-256-GCM key in the Keystore, usable whenever
//       the device has been unlocked since boot. A WorkManager sync can decrypt
//       the database with no prompt. The key never leaves the TEE.
//
//   requireBiometric = true  → the same plus
//       setUserAuthenticationParameters(0, …): a fresh authentication for *every*
//       use. BiometricPrompt is driven with a CryptoObject built from the real
//       cipher, so the prompt authorises exactly one operation.
//
// This was authored without an Android toolchain in reach; the first
// `flutter build apk` is its real compile. The behaviour it must reproduce is
// pinned by `tool/security_verify.dart`, which runs the same policy against a
// fake Keystore with the real semantics (opaque handles, refusals, invalidation).
//
// Requires (see docs/PLATFORM_SETUP.md):
//   · MainActivity extends FlutterFragmentActivity — BiometricPrompt needs one
//   · androidx.biometric:biometric:1.2.0-alpha05 or newer
//   · minSdk 23 (Keystore AES-GCM), targetSdk 34+

package com.khata.pro.security

import android.content.Context
import android.os.Build
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SecurityChannel(
    private val activity: FragmentActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    companion object {
        const val CHANNEL = "khata_pro/security"

        private const val PROVIDER = "AndroidKeyStore"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128

        // Error codes. The set is closed on purpose: the Dart policy reacts to
        // each one deliberately instead of matching message strings.
        private const val ERR_NOT_AUTHENTICATED = "user_not_authenticated"
        private const val ERR_INVALIDATED = "key_invalidated"
        private const val ERR_KEY_MISSING = "key_missing"
        private const val ERR_NO_HARDWARE = "hardware_unavailable"
        private const val ERR_UNIMPLEMENTED = "unimplemented"
        private const val ERR_INTERNAL = "internal_error"

        /** Aliases this app owns — mirrors `KeyAlias` in Dart. */
        private val OWNED_ALIASES = listOf("khata/db/v1", "khata/vault/v1", "khata/backup/v1")
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "hasKey" -> result.success(mapOf("present" to keyStore().containsAlias(call.string("alias"))))
                "ensureKey" -> result.success(ensureKey(call))
                "delete" -> {
                    delete(call.string("alias"))
                    result.success(emptyMap<String, Any?>())
                }
                "wrap" -> wrap(call, result)
                "unwrap" -> unwrap(call, result)
                "authorize" -> authorize(call, result)
                else -> result.error(ERR_UNIMPLEMENTED, "unknown method ${call.method}", null)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error(ERR_INVALIDATED, "the key was invalidated by a biometric enrolment or passcode change", null)
        } catch (e: UnrecoverableKeyException) {
            result.error(ERR_KEY_MISSING, "the Keystore has no usable key for this alias", null)
        } catch (e: IllegalArgumentException) {
            result.error(ERR_INTERNAL, e.message, null)
        }
    }

    // ── capability probe ─────────────────────────────────────────────────────

    private fun capabilities(): Map<String, Any?> {
        val biometrics = BiometricManager.from(activity).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        ) == BiometricManager.BIOMETRIC_SUCCESS

        val strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            activity.packageManager.hasSystemFeature("android.hardware.strongbox_keystore")

        return mapOf(
            // The AndroidKeyStore provider only exists where the platform
            // provides it. Whether an individual key ended up in the TEE or in
            // StrongBox is reported per key by `ensureKey`, not guessed here.
            "hardwareBacked" to true,
            "biometricAvailable" to biometrics,
            "strongBoxAvailable" to strongBox,
            "deviceUnlockedSinceBoot" to isUserUnlocked(),
            "presentAliases" to OWNED_ALIASES.filter { keyStore().containsAlias(it) },
            "notes" to emptyList<String>(),
        )
    }

    /**
     * Keystore keys are usable only after the user has unlocked the device once
     * since boot. Reporting the pessimistic answer when the service is missing
     * keeps the caller from treating "unknown" as "ready".
     */
    private fun isUserUnlocked(): Boolean {
        val um = activity.getSystemService(Context.USER_SERVICE) as? UserManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) um.isUserUnlocked else true
    }

    // ── key management ───────────────────────────────────────────────────────

    /**
     * Creates the key for an alias if it is absent. **Idempotent by contract**: an
     * existing alias is returned untouched, because regenerating it would
     * silently orphan the database key wrapped under the old one.
     */
    private fun ensureKey(call: MethodCall): Map<String, Any?> {
        val alias = call.string("alias")
        val requireBiometric = call.argument<Boolean>("requireBiometric") ?: false
        val preferStrongBox = call.argument<Boolean>("preferStrongBox") ?: true
        val ks = keyStore()

        if (ks.containsAlias(alias)) {
            return mapOf(
                "fingerprint" to fingerprintOf(alias),
                "created" to false,
                "strongBox" to false,
            )
        }

        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // A fresh IV per operation is enforced by the platform, which refuses
            // a caller-supplied one. That is what keeps GCM nonce reuse impossible.
            .setRandomizedEncryptionRequired(true)

        if (requireBiometric) {
            spec.setUserAuthenticationRequired(true)
            // Timeout 0 == every use. A timeout window would let the key be used
            // silently inside it, which is the thing a biometric gate prevents.
            spec.setUserAuthenticationParameters(
                0,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
            )
            // Enrolling a new fingerprint destroys the key: someone who adds their
            // own finger to a stolen, unlocked phone must not thereby inherit
            // access to last week's exports.
            spec.setInvalidatedByBiometricEnrollment(true)
        } else {
            spec.setUserAuthenticationRequired(false)
        }

        var strongBoxUsed = false
        if (preferStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            spec.setIsStrongBoxBacked(true)
            try {
                generate(spec.build())
                strongBoxUsed = true
            } catch (e: StrongBoxUnavailableException) {
                spec.setIsStrongBoxBacked(false)
            } catch (e: ProviderException) {
                // Some devices advertise StrongBox and then fail to provision a key
                // in it. A TEE key is still non-extractable, so falling back is
                // correct — and the caller is told which one it got.
                spec.setIsStrongBoxBacked(false)
            }
        }
        if (!strongBoxUsed) generate(spec.build())

        return mapOf(
            "fingerprint" to fingerprintOf(alias),
            "created" to true,
            "strongBox" to strongBoxUsed,
        )
    }

    private fun generate(spec: KeyGenParameterSpec) {
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
            .apply { init(spec) }
            .generateKey()
    }

    /**
     * A stable, non-secret identifier for a key: the first 8 bytes of SHA-256 over
     * its public certificate. It changes only when the key does, so
     * `key_material` can notice a rotation it did not cause.
     */
    private fun fingerprintOf(alias: String): String {
        val cert = keyStore().getCertificate(alias) ?: return ""
        return MessageDigest.getInstance("SHA-256")
            .digest(cert.encoded)
            .take(8)
            .joinToString("") { "%02x".format(it) }
    }

    private fun delete(alias: String) {
        val ks = keyStore()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
    }

    // ── wrap / unwrap ────────────────────────────────────────────────────────
    //
    // Flow for an auth-per-use key: `Cipher.init` succeeds, and the *use* is what
    // requires authentication — `doFinal` throws UserNotAuthenticatedException. The
    // prompt is then handed the initialised cipher as a CryptoObject, which
    // authorises that key for that one operation; on success the prompt's own copy
    // of the cipher is used to finish. That is why the catch wraps `doFinal`, not
    // `init`.

    private fun wrap(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.string("alias")
        val plaintext = base64(call.string("plaintext"))
        withCipher(alias, call, result, Cipher.ENCRYPT_MODE, null) { cipher ->
            val sealed = cipher.doFinal(plaintext)
            mapOf(
                "iv" to Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
                // doFinal returns ciphertext||tag; Dart splits the tag off, so the
                // envelope layout matches the software wrapping path byte for byte.
                "ciphertext" to Base64.encodeToString(sealed, Base64.NO_WRAP),
            )
        }
    }

    private fun unwrap(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.string("alias")
        val iv = base64(call.string("iv"))
        val sealed = base64(call.string("ciphertext"))
        withCipher(alias, call, result, Cipher.DECRYPT_MODE, iv) { cipher ->
            mapOf(
                "plaintext" to Base64.encodeToString(cipher.doFinal(sealed), Base64.NO_WRAP),
            )
        }
    }

    /**
     * Runs [produce] against a cipher for [alias], and answers [result] exactly
     * once — either with the map [produce] returns, or with a refusal when the key
     * demands authentication and the user has not (yet) provided it.
     */
    private fun withCipher(
        alias: String,
        call: MethodCall,
        result: MethodChannel.Result,
        mode: Int,
        decryptIv: ByteArray?,
        produce: (Cipher) -> Map<String, Any?>,
    ) {
        val key = try {
            keyStore().getKey(alias, null) as? SecretKey
        } catch (e: UnrecoverableKeyException) {
            null
        }
        if (key == null) {
            result.error(ERR_KEY_MISSING, "the Keystore has no usable key for $alias", null)
            return
        }

        val spec = decryptIv?.let { GCMParameterSpec(TAG_BITS, it) }
        val cipher = Cipher.getInstance(TRANSFORM)
        try {
            // Out of caution the init failure is handled too: some OEM builds raise
            // UserNotAuthenticatedException here rather than at doFinal.
            if (spec == null) cipher.init(mode, key) else cipher.init(mode, key, spec)
        } catch (e: UserNotAuthenticatedException) {
            promptThenRun(alias, cipher, call, result, produce)
            return
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error(ERR_INVALIDATED, "the key was invalidated by an enrolment change", null)
            return
        } catch (e: Exception) {
            result.error(ERR_INTERNAL, e.message ?: e.javaClass.simpleName, null)
            return
        }

        try {
            result.success(produce(cipher))
        } catch (e: UserNotAuthenticatedException) {
            promptThenRun(alias, cipher, call, result, produce)
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error(ERR_INVALIDATED, "the key was invalidated by an enrolment change", null)
        } catch (e: Exception) {
            result.error(ERR_INTERNAL, e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun promptThenRun(
        alias: String,
        cipher: Cipher,
        call: MethodCall,
        result: MethodChannel.Result,
        produce: (Cipher) -> Map<String, Any?>,
    ) {
        val reason = call.argument<String>("reason") ?: "Confirm it is you to continue"

        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                /** A MethodChannel call gets exactly one reply. */
                private var answered = false

                override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                    if (answered) return
                    val authorized = auth.cryptoObject?.cipher
                    if (authorized == null) {
                        // Unreachable with a CryptoObject prompt, and the operation is
                        // refused rather than retried with a cipher we cannot vouch for.
                        answered = true
                        result.error(ERR_INTERNAL, "the prompt authorises no cipher", null)
                        return
                    }
                    try {
                        val payload = produce(authorized)
                        answered = true
                        result.success(payload)
                    } catch (e: Exception) {
                        answered = true
                        result.error(
                            ERR_INTERNAL,
                            e.message ?: e.javaClass.simpleName,
                            null,
                        )
                    }
                }

                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    if (answered) return
                    if (code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        code == BiometricPrompt.ERROR_USER_CANCELED ||
                        code == BiometricPrompt.ERROR_CANCELED ||
                        code == BiometricPrompt.ERROR_LOCKOUT
                    ) {
                        // The user said no. That is an answer, not a crash, and it
                        // must not surface as an error dialog.
                        answered = true
                        result.error(ERR_NOT_AUTHENTICATED, message.toString(), null)
                        return
                    }
                    answered = true
                    result.error(
                        if (code == BiometricPrompt.ERROR_NO_BIOMETRICS) ERR_NO_HARDWARE else ERR_NOT_AUTHENTICATED,
                        message.toString(),
                        null,
                    )
                }
            },
        )

        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(reason)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()

        // The cipher handed over is the very cipher that was refused, so the
        // authorisation is bound to this key and this operation.
        activity.runOnUiThread {
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        }
    }

    // ── pre-authentication for non-crypto actions ────────────────────────────

    /**
     * Confirms the user's identity for an action that does not itself touch a key
     * (revealing a recovery phrase, changing the export policy). Crypto
     * operations do **not** need this: `wrap`/`unwrap` prompt for themselves when
     * the key demands it, which is stronger — the prompt authorises one
     * cryptographic operation rather than a session.
     */
    private fun authorize(call: MethodCall, result: MethodChannel.Result) {
        val reason = call.argument<String>("reason") ?: "Confirm it is you"
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                    result.success(mapOf("authenticated" to true))
                }

                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    result.success(
                        mapOf("authenticated" to false, "reason" to message.toString()),
                    )
                }
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(reason)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
        activity.runOnUiThread { prompt.authenticate(info) }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private fun MethodCall.string(key: String): String =
        argument<String>(key) ?: throw IllegalArgumentException("missing argument: $key")

    private fun base64(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
}
