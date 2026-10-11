// KhataPro · iOS entry point.
//
// Registers the `khata_pro/security` method channel, which is the only native code
// this app has. Without it the Dart custody layer sees `MissingPluginException`,
// reads that as "no hardware keystore on this device", and steps down to passphrase
// custody — the app works, on the wrong rung of the ladder, and nothing tells anyone.
//
// The handler is stored in a property rather than a local. `FlutterMethodChannel`
// does retain a handler block, so the local version in docs/PLATFORM_SETUP.md would
// in fact survive — but relying on another framework's retain semantics for the
// lifetime of a security channel is not a bet worth making in silence.
//
// The `@main` attribute and the `FlutterAppDelegate` base class come from the Flutter
// template; keep whatever the template generated for the rest of this file.

import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    /// Retained, deliberately — see the comment above.
    private var security: SecurityChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            let handler = SecurityChannel()
            let channel = FlutterMethodChannel(
                name: SecurityChannel.channelName,
                binaryMessenger: controller.binaryMessenger
            )
            channel.setMethodCallHandler { call, result in
                handler.handle(call, result: result)
            }
            security = handler
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationWillResignActive(_ application: UIApplication) {
        // The app switcher photographs every app as it is backgrounded, and this one
        // is full of other people's balances. Attach a blur or an opaque cover view
        // here (the Android equivalent is FLAG_SECURE, set in MainActivity).
        super.applicationWillResignActive(application)
    }
}
