// KhataPro · Android entry point.
//
// Two things this class exists for, and both are load-bearing:
//
//   1. **It is a `FlutterFragmentActivity`, not a `FlutterActivity`.** AndroidX
//      `BiometricPrompt` shows its sheet through a `FragmentActivity`; passing a plain
//      `Activity` is a compile error inside `SecurityChannel`, which is the good kind
//      of failure. Without this, the vault key's biometric gate cannot exist at all.
//
//   2. **It registers the `khata_pro/security` channel.** With no registration the Dart
//      side gets `MissingPluginException`, and `SecurityPolicy.resolve()` — correctly —
//      reads that as "no hardware here" and steps down to passphrase custody. The app
//      works; the user is just asked for a passphrase instead of a fingerprint. Silent,
//      plausible, and exactly the sort of thing that ships. See docs/PLATFORM_SETUP.md.
//
// This file is part of the app module and needs no manifest change: the manifest
// already names `.MainActivity`, and the activity class is what changed.

package com.khata.pro

import com.khata.pro.security.SecurityChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    /**
     * Held so the channel has an owner for the life of the activity. The method
     * channel itself keeps the handler alive (the messenger owns it), but an explicit
     * field makes the lifetime visible to the next reader instead of relying on that
     * detail holding forever.
     */
    private var security: SecurityChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        security = SecurityChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        security = null
        super.onDestroy()
    }
}
