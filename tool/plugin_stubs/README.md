# Analyzer stubs for the Flutter-only layer

Every file in this project that imports a Flutter or plugin package needs something to
resolve against, and this workspace has no Flutter SDK (no APK builds, no
`flutter pub get`, a 128 MB storage cap). Without the stubs, `dart analyze` reports a wall
of `uri_does_not_exist` and the *real* errors hide inside it — which is exactly what
happened: four shipped defects in `webrtc_lan_transport.dart` and `mdns_discovery.dart`
stayed invisible behind thirty lines of "package not found".

## What is stubbed, and how faithfully

| package | stub | fidelity |
| --- | --- | --- |
| `flutter` | `painting.dart` (`dart:ui`: `Color`, `Canvas`, `Paint`, `CustomPainter`, `TextPainter`…), `ui_widgets.dart` (framework + material), `services.dart` (method channel, `rootBundle`), barrel-exported by `material.dart` | signatures transcribed from the 3.47 SDK for the members this project uses |
| `flutter_riverpod` | `flutter_riverpod.dart` declares only the Flutter half (`ProviderScope`, `Consumer`, `ConsumerWidget`, `ConsumerState`, `WidgetRef`) and **re-exports the real `package:riverpod`** | the Dart half is the pinned package itself, not a transcription: `AsyncValue`, `Provider`, `Notifier`, `ProviderSubscription` and the `select` extension are real declarations |
| `go_router` | `go_router.dart` | `GoRouter`, `GoRoute`, `RouteBase`, `GoRouterState`, the `context.go/push/pop` extension |
| `flutter_webrtc`, `nsd`, `icloud_storage`, `path_provider` | as before | signatures from the pinned sources |

`flutter_riverpod` re-exporting `riverpod` is deliberate: it means a widget's
`ref.watch(provider.select(...))` is checked against the *real* `ProviderListenableSelect`
extension that ships in 3.4.3, and a signature that changed between versions fails here
rather than on the user's machine.

So each package gets a stub here: **signatures only, transcribed from the pinned
version's actual source**, never executed, never shipped. `build_plugin_config.py`
adds them to a copy of the harness's `package_config.json`, and

    ./dartx analyze --packages=plugin_stubs_config.json /home/user/khata_pro/lib

type-checks the real call sites against the real signatures — the whole `lib/` tree,
widget layer included.

What this proves: every type, argument and return value in the five Flutter-facing
files matches the API of the version in `pubspec.yaml`.

What it does **not** prove: anything about runtime behaviour. These stubs have no
bodies. A method that is called with the right types but the wrong order of
operations still fails on a device — which is why the defects found this way
(`setLocalDescription` being handed a minimised description, `getBufferedAmount()`
being awaited, TXT records typed as strings) were all fixed by reading the pinned
source, and why `docs/SYNC.md` §6 lists what still needs a phone to confirm.
