#!/usr/bin/env bash
# KhataPro · workspace storage manager
#
# Keeps this workspace under its snapshot budget by deleting only *regenerable*
# caches. Nothing here touches source: lib/, test/, tool/, assets/, docs/ and the
# .git directory are never removed.
#
# Usage:
#   tool/cleanup_workspace.sh                 # clean only if usage > 100 MB
#   tool/cleanup_workspace.sh --force         # clean regardless
#   tool/cleanup_workspace.sh --dry-run       # say what would go, delete nothing
#   tool/cleanup_workspace.sh --threshold 80  # move the trigger to 80 MB
#   tool/cleanup_workspace.sh --keep-pub-cache  # keep dependency downloads
#   tool/cleanup_workspace.sh --all-caches      # also clean caches OUTSIDE the
#                                               # workspace (e.g. ~/.pub-cache)
#
# What each target costs you if it is deleted:
#   .dartServer/   analyzer/IDE index cache      → rebuilt on next analysis, free
#   .dart_tool/    build + package resolution    → `flutter pub get` restores it
#   build/         compiled bundle               → `flutter build` restores it
#   .pub-cache/    downloaded packages (~110 MB) → `flutter pub get` re-downloads
#
# The last one is the big win and the only one with a real cost: the next
# `pub get` needs network. Prefer `--keep-pub-cache` when you are about to build.
set -uo pipefail

THRESHOLD_MB=100
FORCE=0
DRY_RUN=0
KEEP_PUB_CACHE=0
ALL_CACHES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force)          FORCE=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    --keep-pub-cache) KEEP_PUB_CACHE=1 ;;
    --all-caches)     ALL_CACHES=1 ;;
    --threshold)      THRESHOLD_MB="${2:-100}"; shift ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$HERE")"
# The workspace root is the project's parent when the project is a subdirectory
# of it (the usual layout here); otherwise the project itself.
WORKSPACE="$(dirname "$PROJECT")"
[ -d "$WORKSPACE/.pub-cache" ] || [ -d "$WORKSPACE/.dartServer" ] || WORKSPACE="$PROJECT"

# ── sizes ────────────────────────────────────────────────────────────────────
size_mb() { # bytes → whole megabytes, portable across GNU/BSD du
  local target="$1"
  [ -e "$target" ] || { echo 0; return; }
  local kb
  kb="$(du -sk "$target" 2>/dev/null | awk '{print $1}')"
  echo $(( kb / 1024 ))
}

workspace_mb() { size_mb "$WORKSPACE"; }

total_before="$(workspace_mb)"

echo "KhataPro workspace cleanup"
echo "  workspace : $WORKSPACE"
echo "  project   : $PROJECT"
echo "  size      : ${total_before} MB (threshold ${THRESHOLD_MB} MB)"
echo

if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$total_before" -lt "$THRESHOLD_MB" ]; then
  echo "Under the threshold — nothing to do."
  echo "Run with --force to clean anyway."
  exit 0
fi

# ── the targets, biggest win first ───────────────────────────────────────────
TARGETS=()

# 1 · The dependency cache. Almost always the largest single item.
#
#     Only caches *inside* the workspace are touched by default: deleting a cache
#     that lives outside it (say ~/.pub-cache) frees nothing for the workspace and
#     just costs the user a re-download. `--all-caches` opts into that.
for candidate in "$WORKSPACE/.pub-cache" "${PUB_CACHE:-}"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  case "$candidate" in    # keep it inside the workspace unless asked otherwise
    "$WORKSPACE"/*) TARGETS+=("$candidate") ;;
    *) [ "$ALL_CACHES" -eq 1 ] && TARGETS+=("$candidate") ;;
  esac
done
if [ "$ALL_CACHES" -eq 1 ] && [ -d "$HOME/.pub-cache" ]; then
  TARGETS+=("$HOME/.pub-cache")
fi

# 2 · The analyzer server's index. Pure cache: deleting it costs one re-index.
[ -d "$WORKSPACE/.dartServer" ] && TARGETS+=("$WORKSPACE/.dartServer")

# 3 · Build output and package resolution inside the project.
for name in build .dart_tool; do
  [ -d "$PROJECT/$name" ] && TARGETS+=("$PROJECT/$name")
done

# stray compile artifacts anywhere in the project
while IFS= read -r dill; do
  [ -n "$dill" ] && TARGETS+=("$dill")
done < <(find "$PROJECT" -maxdepth 3 -name '*.dill' -not -path '*/.git/*' 2>/dev/null)

# De-duplicate: the same directory can be reachable by two routes (workspace
# relative and $PUB_CACHE), and a doubled target would double-count its size.
DEDUPED=()
for target in "${TARGETS[@]}"; do
  skip=0
  for seen in "${DEDUPED[@]:-}"; do
    [ "$seen" = "$target" ] && { skip=1; break; }
  done
  [ "$skip" -eq 0 ] && DEDUPED+=("$target")
done
TARGETS=("${DEDUPED[@]:-}")

removed_mb=0
for target in "${TARGETS[@]}"; do
  # Never delete the dependency cache when the caller asked to keep it.
  case "$target" in
    */.pub-cache) [ "$KEEP_PUB_CACHE" -eq 1 ] && { echo "  keep  $target"; continue; } ;;
  esac

  mb="$(size_mb "$target")"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would delete  %-52s %4s MB\n' "$target" "$mb"
  else
    printf '  deleting      %-52s %4s MB\n' "$target" "$mb"
    rm -rf "$target"
  fi
  removed_mb=$(( removed_mb + mb ))
done

# 4 · `flutter clean` / `dart pub cache clean`, when the tools are present.
#     These do the same work through the supported entry points, so they are run
#     *after* the direct deletions (and are harmless no-ops if nothing is left).
if command -v flutter >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would run     flutter clean (in $PROJECT)"
  else
    echo "  running       flutter clean"
    ( cd "$PROJECT" && flutter clean >/dev/null 2>&1 || true )
  fi
elif [ "$DRY_RUN" -eq 0 ]; then
  echo "  note          flutter not on PATH — skipped \`flutter clean\`"
fi

if [ "$KEEP_PUB_CACHE" -eq 0 ] && command -v dart >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would run     dart pub cache clean -f"
  else
    echo "  running       dart pub cache clean -f"
    dart pub cache clean -f >/dev/null 2>&1 || true
  fi
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: about ${removed_mb} MB would be freed (workspace stays at ${total_before} MB)."
  exit 0
fi

total_after="$(workspace_mb)"
echo "Freed ${removed_mb} MB: ${total_before} MB → ${total_after} MB (budget 128 MB)."
if [ "$total_after" -gt 115 ]; then
  echo "WARNING: still close to the 128 MB cap. Next: move the SDK and pub cache" >&2
  echo "         outside the workspace (PUB_CACHE, DART_SDK) rather than growing it." >&2
fi
echo
echo "Restore when you are ready to build:"
echo "  cd $PROJECT && flutter pub get"
