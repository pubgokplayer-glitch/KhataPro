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

cat <<EOF

Harness ready at $HARNESS

  cd $HARNESS                                  # \`dartx\` sets PUB_CACHE/TMPDIR for you
  ./dartx run bin/run_layer.dart --asset-root=$PROJECT
  ./dartx run ../../../home/user/khata_pro/tool/crdt_verify.dart
  KHATA_ASSET_ROOT=$PROJECT ./dartx test $PROJECT/test

  (or pass --sdk/--cache to keep the SDK and packages somewhere else)

Workspace stays small: the cache lives in $CACHE and is *not* part of the
workspace snapshot. Run tool/cleanup_workspace.sh if the workspace grows anyway.
EOF
