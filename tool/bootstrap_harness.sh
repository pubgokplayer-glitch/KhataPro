#!/usr/bin/env bash
# KhataPro · rebuild the dependency-light verification harness in /tmp
#
# Why this exists: the workspace has a hard storage budget, so nothing that can
# be regenerated may live in it — no pub cache, no SDK, no build output. The Dart
# SDK and the pub cache live in /tmp (throwaway) and this script recreates the
# harness package that resolves `package:khata_pro` against the working tree.
#
# Usage:
#   tool/bootstrap_harness.sh [--sdk /path/to/dart-sdk] [--cache /tmp/pub-cache]
#
# Then:
#   cd /tmp/harness
#   $DART run bin/run_layer.dart --asset-root=/home/user/khata_pro    # 81 checks
#   $DART run ../../../home/user/khata_pro/tool/crdt_verify.dart     # 55 checks
#   $DART test /home/user/khata_pro/test                             # 16 tests
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$HERE")"
HARNESS=/tmp/harness
SDK="/tmp/dartsdk/dart-sdk"
CACHE=/tmp/pub-cache

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)   SDK="$2"; shift ;;
    --cache) CACHE="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

DART="$SDK/bin/dart"
[ -x "$DART" ] || { echo "no Dart SDK at $DART — pass --sdk, or download:" >&2;
  echo "  curl -o /tmp/dart.zip https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip" >&2;
  echo "  unzip -q /tmp/dart.zip -d /tmp/dartsdk && rm /tmp/dart.zip" >&2; exit 1; }

mkdir -p "$HARNESS/bin" "$CACHE"

# ── the host package ─────────────────────────────────────────────────────────
# `hooks: user_defines: sqlite3: source: system` links the system SQLite, so the
# harness needs no native build step. Everything else is ordinary pub deps.
cat > "$HARNESS/pubspec.yaml" <<'YAML'
name: harness
description: Verification host for the KhataPro repo — not part of the app.
publish_to: none
environment:
  sdk: ^3.10.0

dev_dependencies:
  test: ^1.25.15

dependencies:
  crypto: ^3.0.6
  drift: ^2.35.2
  http: ^1.6.0
  riverpod: ^3.4.3
  meta: ^1.19.0
  path: ^1.9.1
  sqlite3: ^3.7.0
  uuid: ^4.5.2

hooks:
  user_defines:
    sqlite3:
      source: system
YAML

# ── the wrapper that cannot get the environment wrong ───────────────────────
# Every Dart command in this harness must run with PUB_CACHE outside the
# workspace and TMPDIR outside it too. Forgetting either silently refills the
# workspace with ~110 MB of packages, which is exactly what this bootstrap exists
# to prevent — so the environment is baked into one executable entry point.
cat > "$HARNESS/dartx" <<WRAP
#!/usr/bin/env bash
# Run a Dart command with the workspace-safe environment. Usage: ./dartx <args...>
export PUB_CACHE="$CACHE"
export TMPDIR="\${TMPDIR_OUTSIDE:-/tmp/dart-tmp}"
mkdir -p "\$TMPDIR"
export DART="$DART"
exec "$DART" "\$@"
WRAP
chmod +x "$HARNESS/dartx"

# ── the mapping repair, as a tool ───────────────────────────────────────────
# `dart run` and `dart pub get` rewrite .dart_tool/package_config.json and drop the
# injected khata_pro mapping. This repairs it in one command; `run_tool.sh` calls it
# automatically so the trap costs nothing.
cat > "$HARNESS/fix_mapping.py" <<'PYEOF'
import json, os, pathlib, sys
harness = pathlib.Path(__file__).resolve().parent
project = os.environ.get("KHATA_PROJECT", "/home/user/khata_pro")
config = harness / ".dart_tool" / "package_config.json"
data = json.loads(config.read_text())
if not any(package["name"] == "khata_pro" for package in data["packages"]):
    data["packages"].append({
        "name": "khata_pro",
        "rootUri": "file://" + project,
        "packageUri": "lib/",
        "languageVersion": "3.13",
    })
    config.write_text(json.dumps(data, indent=2))
    print("khata_pro →", project)
PYEOF

# ── run the repo's own test suite ────────────────────────────────────────────
# The repo's tests import package:khata_pro/…, which only resolves inside a package
# whose config maps that name. `dart test /abs/path` resolves the *target's* package
# (the Flutter app) and rewrites this harness's config on the way, so the suite is
# copied in and run from here instead.
cat > "$HARNESS/run_tests.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${KHATA_PROJECT:-/home/user/khata_pro}"
rm -rf "$HARNESS/test"
cp -r "$PROJECT/test" "$HARNESS/test"
rm -rf "$HARNESS/test/.dart_tool"
python3 "$HARNESS/fix_mapping.py" >/dev/null
cd "$HARNESS"
KHATA_ASSET_ROOT="$PROJECT" exec ./dartx test test "$@"
SHEOF
chmod +x "$HARNESS/run_tests.sh"

# ── run any repo tool that uses package: imports ─────────────────────────────
# `dart run /abs/path.dart` resolves packages from the *target file's* package and
# therefore fails inside a Flutter app; `dart run` from here also drops the mapping.
# Copying the script into bin/ and executing it directly avoids both.
cat > "$HARNESS/run_tool.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:?usage: run_tool.sh <tool.dart|bin/name.dart> [args...]}"
shift
mkdir -p "$HARNESS/bin"
if [ -f "$SCRIPT" ]; then
  cp "$SCRIPT" "$HARNESS/bin/$(basename "$SCRIPT")"
  SCRIPT="bin/$(basename "$SCRIPT")"
fi
python3 "$HARNESS/fix_mapping.py" >/dev/null
cd "$HARNESS"
exec ./dartx "$SCRIPT" "$@"
SHEOF
chmod +x "$HARNESS/run_tool.sh"

cat > "$HARNESS/run_layer.dart" <<'DART'
// Entry point that drives the repo's own verification tool. Keeping the *script*
// in the harness (and the logic in the repo) is what makes `dart run` here apply
// the native-asset build hooks that a bare `dart run /absolute/path` skips.
import '../../../home/user/khata_pro/tool/data_layer_verify.dart' as layer;

Future<void> main(List<String> args) => layer.main(args);
DART

cd "$HARNESS"
echo "▶ pub get (cache: $CACHE)"
PUB_CACHE="$CACHE" "$DART" pub get >/dev/null

# ── make `package:khata_pro/...` resolve to the working tree ────────────────
# The repo's own pubspec depends on Flutter, so it cannot be a path dependency of
# a plain-Dart package. Injecting the mapping into this harness's package config
# gives the repo's tests and tools real package imports without dragging Flutter
# in — and without `flutter pub get` (which would fill the workspace).
python3 - "$HARNESS/.dart_tool/package_config.json" "$PROJECT" <<'PY'
import json, pathlib, sys
cfg_path, project = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = json.loads(cfg_path.read_text())
cfg['packages'] = [p for p in cfg['packages'] if p['name'] != 'khata_pro']
cfg['packages'].append({
    'name': 'khata_pro',
    'rootUri': f'file://{project}',
    'packageUri': 'lib/',
    'languageVersion': '3.10',
})
cfg_path.write_text(json.dumps(cfg, indent=2))
print(f'  mapped package:khata_pro → {project}/lib')
PY

# ── shims for the tools that import the repo's lib/ by relative path ─────────
# `crypto_verify.dart` and `aes_verify.dart` import `../lib/...`, which resolves
# against the *tool file's* location. Copying them into bin/ therefore breaks them
# (there is no lib/ next to bin/), and the resulting wall of "undefined name" errors
# looks exactly like a broken crypto implementation. Importing the tool by path keeps
# its relative imports pointing at the real working tree.
for tool in crypto aes; do
  cat > "$HARNESS/${tool}_run.dart" <<DART
import '../../../home/user/khata_pro/tool/${tool}_verify.dart' as tool;
void main(List<String> args) => tool.main(args);
DART
done

# ── the analyzer's view of the Flutter-only layer ────────────────────────────
# The five files that import Flutter or a plugin cannot be *run* here, but they can be
# type-checked against stubs transcribed from the pinned versions. Generated from the
# repo's own tool/plugin_stubs/, so the stubs travel with the source.
python3 "$PROJECT/tool/plugin_stubs/build_plugin_config.py" --config "$HARNESS/.dart_tool/package_config.json" --out "$HARNESS/plugin_stubs_config.json" || true

cat <<EOF

Harness ready at $HARNESS

  cd $HARNESS                                  # \`dartx\` sets PUB_CACHE/TMPDIR for you
  ./dartx run bin/run_layer.dart --asset-root=$PROJECT      # 81 checks
  ./run_tool.sh $PROJECT/tool/security_verify.dart          # 54 checks
  ./run_tests.sh                                            # 16 repo tests + smoke

  Any tool that imports \`package:khata_pro/...\` must go through ./run_tool.sh —
  \`dart run <abs path>\` resolves packages from the target's own package and
  fails inside a Flutter app, and a bare \`dart run\` here drops the khata_pro
  mapping that ./run_tool.sh reinstates.

  Tools that import \`../lib/...\` relatively (crypto_verify, aes_verify) run as
    ./dartx crypto_run.dart $PROJECT/assets/testdata/crypto_vectors.json
    ./dartx aes_run.dart    $PROJECT/assets/testdata/aes_vectors.json

  The Flutter-only files cannot be run or tested here, but they can be type-checked
  against the pinned package APIs transcribed into $PROJECT/tool/plugin_stubs:
    ./dartx analyze --packages=plugin_stubs_config.json $PROJECT/lib

  (or pass --sdk/--cache to keep the SDK and packages somewhere else)

Workspace stays small: the cache lives in $CACHE and is *not* part of the
workspace snapshot. Run tool/cleanup_workspace.sh if the workspace grows anyway.
EOF
