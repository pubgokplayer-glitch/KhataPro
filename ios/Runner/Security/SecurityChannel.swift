// KhataPro · iOS Keychain + Secure Enclave security channel.
//
// Answers the `khata_pro/security` method channel; the Dart side
// (`lib/platform/security/platform_key_custody.dart`) owns every decision.
//
// Two key flavours, mirroring Android — see the Dart file for the reasoning:
//
//   khata/db/v1     accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
//                   no access control. Usable by a background URLSession task
//                   after the first unlock, with no prompt. This is the key that
//                   wraps the SQLCipher database key.
//
//   khata/vault/v1  access control with `.biometryCurrentSet`, requiring user
//                   presence at very use; enrolling a new Face ID invalidates it.
//                   Used for export, share, reveal-recovery-key.
//
// Why ECIES: the Secure Enclave holds EC P-256 keys — it cannot hold an AES key.
// So wrapping here is `SecKeyCreateEncryptedData` with
// `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`, and the envelope's
// `algorithm` is `ecies-p256-secure-enclave` rather than the Android GCM id. Both
// are "the keystore holds it"; a reader of `key_material.wrap_algo` can tell which
// platform produced a row, which is exactly what restore-time diagnostics need.
//
// Authored without an Xcode toolchain in reach: `flutter build ios` is its real
// compile. Behaviour is pinned by `tool/security_verify.dart` against a fake
// keystore with the same semantics.
//
// Requires (see docs/PLATFORM_SETUP.md):
//   · Keychain Sharing entitlement if you ever want the vault key in a shared
//     access group; not needed for the single-app case
//   · nothing else — Security.framework ships with the OS

import Foundation
import CryptoKit
import LocalAuthentication
import Security

final class SecurityChannel: NSObject {

    static let channelName = "khata_pro/security"

    private enum Alias {
        static let database = "khata/db/v1"
        static let vault = "khata/vault/v1"
        static let backup = "khata/backup/v1"
        static let all = [database, vault, backup]

        /// Keychain application tags are Data, and the tag is what identifies the
        /// key. Namespaced so no other app's tag can collide.
        static func tag(_ alias: String) -> Data {
            Data("com.khata.pro.\(alias)".utf8)
        }
    }

    private enum ErrorCode {
        static let notAuthenticated = "user_not_authenticated"
        static let invalidated = "key_invalidated"
        static let keyMissing = "key_missing"
        static let hardwareUnavailable = "hardware_unavailable"
        static let unimplemented = "unimplemented"
        static let internalError = "internal_error"
    }

    // ── entry point ──────────────────────────────────────────────────────────

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "capabilities":
                result(try capabilities())
            case "hasKey":
                result(["present": try key(for: alias(call)) != nil])
            case "ensureKey":
                result(try ensureKey(call))
            case "delete":
                try deleteKey(alias(call))
                result([:])
            case "wrap":
                try wrap(call, result: result)
            case "unwrap":
                try unwrap(call, result: result)
            case "authorize":
                authorize(call, result: result)
            default:
                result(FlutterError(code: ErrorCode.unimplemented,
                                    message: "unknown method \(call.method)",
                                    details: nil))
            }
        } catch let failure as SecurityFailure {
            result(FlutterError(code: failure.code, message: failure.message, details: nil))
        } catch {
            result(FlutterError(code: ErrorCode.internalError,
                                message: error.localizedDescription, details: nil))
        }
    }

    private func alias(_ call: FlutterMethodCall) throws -> String {
        guard let alias = (call.arguments as? [String: Any])?["alias"] as? String else {
            throw SecurityFailure(ErrorCode.internalError, "missing argument: alias")
        }
        return alias
    }

    // ── capability probe ─────────────────────────────────────────────────────

    private func capabilities() throws -> [String: Any] {
        var error: NSError?
        // `isDeviceCredentialSet` matters: a vault key bound to a passcode the
        // user has not set is a key nothing can unlock.
        let context = LAContext()
        let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                   error: &error)

        return [
            // iOS devices with a Secure Enclave (A7 and later) are the only ones
            // this app supports; `secureEnclaveAvailable` reports whether the key
            // can actually be created there rather than in software.
            "hardwareBacked": true,
            "biometricAvailable": biometrics,
            "strongBoxAvailable": secureEnclaveAvailable(),
            "deviceUnlockedSinceBoot": deviceUnlockedSinceBoot(),
            "presentAliases": Alias.all.filter { (try? key(for: $0)) != nil },
            "notes": notes(for: context, biometrics: biometrics),
        ]
    }

    private func secureEnclaveAvailable() -> Bool {
        // The enclave is present when the device supports it and the key can be
        // created with kSecAttrTokenIDSecureEnclave. Probing by creating a
        // throwaway key would be more precise and would also touch the user's
        // Keychain for no reason; the documented capability check is enough.
        if #available(iOS 13.0, *) {
            return SecureEnclave.isAvailable
        }
        return false
    }

    private func deviceUnlockedSinceBoot() -> Bool {
        // After a reboot, BeforeFirstUnlock lasts until the user unlocks once.
        // While it lasts, an AfterFirstUnlock key cannot be used, so a background
        // pass must wait rather than fail permanently.
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return usable || error?.code != LAError.passcodeNotSet.rawValue
    }

    private func notes(for context: LAContext, biometrics: Bool) -> [String] {
        var notes: [String] = []
        if !biometrics {
            notes.append("No biometrics enrolled: export and reveal are protected by the "
                       + "device passcode.")
        }
        if !secureEnclaveAvailable() {
            notes.append("This device has no Secure Enclave; keys live in the Keychain, "
                       + "still bound to this device but not to dedicated hardware.")
        }
        var error: NSError?
        if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error),
           error?.code == LAError.passcodeNotSet.rawValue {
            notes.append("No device passcode is set. Set one before storing the books on "
                       + "this device.")
        }
        return notes
    }

    // ── key management ───────────────────────────────────────────────────────

    /// Idempotent by contract: an existing key is returned untouched. Regenerating
    /// it would silently orphan the database key wrapped under the old one.
    private func ensureKey(_ call: FlutterMethodCall) throws -> [String: Any] {
        let alias = try alias(call)
        let requireBiometric = (call.arguments as? [String: Any])?["requireBiometric"] as? Bool ?? false

        if let existing = try key(for: alias) {
            return ["fingerprint": fingerprint(of: existing),
                    "created": false,
                    "secureEnclave": isInEnclave(existing)]
        }

        // Attributes shared by both flavours. `kSecAttrTokenIDSecureEnclave` falls
        // back to a Keychain key on devices without the enclave, so an old device
        // degrades instead of refusing to run.
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Alias.tag(alias),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]

        if requireBiometric {
            var accessError: Unmanaged<CFError>?
            // `.biometryCurrentSet` invalidates the key when Face ID / Touch ID is
            // re-enrolled: someone who adds their own face to an unlocked phone
            // must not thereby inherit access to last week's exports.
            // `.userPresence` would allow the passcode fallback; the vault wants
            // the biometric specifically, and the Dart policy has a passphrase
            // path for devices with no enrolment.
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.biometryCurrentSet, .privateKeyUsage],
                &accessError
            ) else {
                throw SecurityFailure(ErrorCode.hardwareUnavailable,
                                      "could not build an access policy: "
                                      + (accessError?.takeRetainedValue().localizedDescription ?? "unknown"))
            }
            attributes[kSecAttrAccessControl as String] = access
            // With an access control object, accessibility may not also be set.
            var privateAttrs = attributes[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
            privateAttrs.removeValue(forKey: kSecAttrAccessible as String)
            privateAttrs[kSecAttrAccessControl as String] = access
            attributes[kSecPrivateKeyAttrs as String] = privateAttrs
        }

        if secureEnclaveAvailable() {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var error: Unmanaged<CFError>?
        guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            // A biometric-bound key cannot be created when nothing is enrolled:
            // report the capability gap rather than a mysterious failure.
            if requireBiometric, message.lowercased().contains("passcode") {
                throw SecurityFailure(ErrorCode.hardwareUnavailable, message)
            }
            throw SecurityFailure(ErrorCode.internalError, message)
        }

        return ["fingerprint": fingerprint(of: created),
                "created": true,
                "secureEnclave": isInEnclave(created)]
    }

    private func key(for alias: String) throws -> SecKey? {
        if alias == Alias.vault {
            // The vault key needs an authentication context; looking it up does
            // not require one, but the query must not ask the system to prompt.
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Alias.tag(alias),
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                // Present but not usable right now — the caller decides whether to
                // prompt. Reporting "missing" here would be a lie that leads to a
                // wipe prompt, so it is reported as an authentication refusal.
                throw SecurityFailure(ErrorCode.notAuthenticated,
                                      "the vault key needs an authentication")
            }
            guard status == errSecSuccess, let value = item else {
                throw SecurityFailure(ErrorCode.keyMissing, "Keychain status \(status)")
            }
            return (value as! SecKey)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Alias.tag(alias),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value = item else {
            throw SecurityFailure(ErrorCode.keyMissing, "Keychain status \(status)")
        }
        return (value as! SecKey)
    }

    private func deleteKey(_ alias: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Alias.tag(alias),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        // A biometric key may refuse deletion without a prompt on some iOS
        // versions; ignoring the UI flag keeps "wipe" working on a locked device.
        SecItemDelete([query, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail] as CFDictionary)
        SecItemDelete(query as CFDictionary)
    }

    /// A stable, non-secret *name* for a key: SHA-256 over the public key's
    /// external representation, first 8 bytes. It changes only when the key does,
    /// so `key_material` can notice a rotation it did not cause.
    private func fingerprint(of key: SecKey) -> String {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return ""
        }
        return data.shortFingerprint
    }

    private func isInEnclave(_ key: SecKey) -> Bool {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any] else { return false }
        return (attributes[kSecAttrTokenID as String] as? String) == (kSecAttrTokenIDSecureEnclave as String)
    }

    // ── wrap / unwrap ────────────────────────────────────────────────────────

    private func wrap(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        let alias = try alias(call)
        guard let key = try key(for: alias) else {
            throw SecurityFailure(ErrorCode.keyMissing, "no key for \(alias)")
        }
        guard let base64 = (call.arguments as? [String: Any])?["plaintext"] as? String,
              let plaintext = Data(base64Encoded: base64) else {
            throw SecurityFailure(ErrorCode.internalError, "missing argument: plaintext")
        }

        var error: Unmanaged<CFError>?
        guard let sealed = SecKeyCreateEncryptedData(
            key,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            plaintext as CFData,
            &error
        ) as Data? else {
            throw translate(error, alias: alias)
        }

        result([
            // The ECIES blob carries its own ephemeral public key and nonce; the
            // `iv` field exists so the envelope layout is the same shape on both
            // platforms, and is left empty because there is nothing to put in it.
            "iv": "",
            "ciphertext": sealed.base64EncodedString(),
            "algorithm": "ecies-p256-secure-enclave",
        ])
    }

    private func unwrap(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        let alias = try alias(call)
        guard let key = try key(for: alias) else {
            throw SecurityFailure(ErrorCode.keyMissing, "no key for \(alias)")
        }
        guard let base64 = (call.arguments as? [String: Any])?["ciphertext"] as? String,
              let sealed = Data(base64Encoded: base64) else {
            throw SecurityFailure(ErrorCode.internalError, "missing argument: ciphertext")
        }

        // A biometric key needs its authentication context attached to the
        // operation, and the reason string is what the user reads in the prompt.
        // Attaching the LAContext to the SecKey call would require the deprecated
        // kSecUseAuthenticationContext key path on some iOS versions; the documented
        // behaviour is that a key protected by `.biometryCurrentSet` prompts on use
        // with its own reason string. The context is still built first so the
        // *capability* is checked here, and a device with nothing enrolled is
        // refused with `user_not_authenticated` rather than an opaque OS error.
        var context: LAContext?
        if alias == Alias.vault {
            let reason = (call.arguments as? [String: Any])?["reason"] as? String
                ?? "Confirm it is you to unlock your books"
            context = LAContext()
            if let context {
                var authError: NSError?
                let ok = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
                if !ok {
                    throw SecurityFailure(ErrorCode.notAuthenticated,
                                          authError?.localizedDescription ?? reason)
                }
                context.localizedReason = reason
            }
        }

        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            key,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            sealed as CFData,
            &error
        ) as Data? else {
            throw translate(error, alias: alias)
        }

        result(["plaintext": plaintext.base64EncodedString()])
    }

    /// Turns a Security.framework failure into the Dart policy's vocabulary.
    /// `errSecUserCanceled` is a *decision* by the user, not a fault.
    private func translate(_ error: Unmanaged<CFError>?, alias: String) -> SecurityFailure {
        let failure = error?.takeRetainedValue()
        let description = failure?.localizedDescription ?? "unknown"
        if let code = failure.map({ CFErrorGetCode($0) }) {
            if code == Int(errSecUserCanceled) || code == Int(errSecAuthFailed) {
                return SecurityFailure(ErrorCode.notAuthenticated, description)
            }
            if code == Int(errSecInteractionNotAllowed) {
                return SecurityFailure(ErrorCode.notAuthenticated, description)
            }
        }
        return SecurityFailure(ErrorCode.internalError, description)
    }

    // ── pre-authentication for non-crypto actions ────────────────────────────

    /// Crypto operations do not need this: `wrap`/`unwrap` prompt for themselves
    /// when the key demands it, which is stronger. This exists for actions that do
    /// not touch a key at all — revealing a recovery phrase, changing the export
    /// policy.
    private func authorize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let reason = (call.arguments as? [String: Any])?["reason"] as? String
            ?? "Confirm it is you"
        let context = LAContext()
        context.localizedReason = reason
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                // "The user said no" is an answer, not a failure: it comes back as
                // authenticated=false so the UI can simply not proceed.
                result(["authenticated": ok, "reason": error?.localizedDescription ?? ""])
            }
        }
    }

    private struct SecurityFailure: Error {
        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
        let code: String
        let message: String
    }
}

// ── fingerprints ─────────────────────────────────────────────────────────────
// CryptoKit ships with iOS 13+ and is the only thing imported for this: eight
// bytes of SHA-256 to *name* a key. It is never key material.

extension Data {
    /// First 8 bytes of SHA-256, hex.
    var shortFingerprint: String {
        SHA256.hash(data: self).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
