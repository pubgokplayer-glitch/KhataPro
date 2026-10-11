# Analyzer stubs for the Flutter-only layer

Five files in this project import a Flutter or plugin package, and this workspace has
no Flutter SDK (no APK builds, no `flutter pub get`, a 128 MB storage cap). Without
something to resolve those imports against, `dart analyze` reports a wall of
`uri_does_not_exist` and the *real* errors hide inside it — which is exactly what
happened: four shipped defects in `webrtc_lan_transport.dart` and `mdns_discovery.dart`
stayed invisible behind thirty lines of "package not found".

So each package gets a stub here: **signatures only, transcribed from the pinned
version's actual source**, never executed, never shipped. `build_plugin_config.py`
adds them to a copy of the harness's `package_config.json`, and

    ./dartx analyze --packages=plugin_stubs_config.json \
        /home/user/khata_pro/lib/platform /home/user/khata_pro/lib/sync

type-checks the real call sites against the real signatures.

What this proves: every type, argument and return value in the five Flutter-facing
files matches the API of the version in `pubspec.yaml`.

What it does **not** prove: anything about runtime behaviour. These stubs have no
bodies. A method that is called with the right types but the wrong order of
operations still fails on a device — which is why the defects found this way
(`setLocalDescription` being handed a minimised description, `getBufferedAmount()`
being awaited, TXT records typed as strings) were all fixed by reading the pinned
source, and why `docs/SYNC.md` §6 lists what still needs a phone to confirm.
