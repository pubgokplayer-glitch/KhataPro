#!/usr/bin/env bash
# KhataPro · a single-file, restorable copy of the whole repository
#
# `git bundle` packs every commit and every branch into one file that can be
# cloned from directly — no network, no remote, no credentials. This is the
# answer to "what if the workspace dies": keep the bundle in the workspace (it is
# a few hundred KB) and also copy it anywhere else you like.
#
# Usage:
#   tool/make_backup_bundle.sh                     # → ../khata_pro.bundle
#   tool/make_backup_bundle.sh /path/out.bundle    # → anywhere
#
# Restore later, on any machine with git:
#   git clone khata_pro.bundle khata_pro && cd khata_pro
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$HERE")"
OUT="${1:-$(dirname "$PROJECT")/khata_pro.bundle}"

cd "$PROJECT"
[ -d .git ] || { echo "not a git repository: $PROJECT" >&2; exit 1; }

# A bundle refuses to be overwritten, and it cannot contain the file it is being
# written to — so write to a temp name and move it into place.
TMP="$(mktemp -u "${OUT}.XXXXXX")"
git bundle create "$TMP" --all >/dev/null
mv "$TMP" "$OUT"

# Verify it before calling it a backup: an unverified backup is a rumour.
git bundle verify "$OUT" >/dev/null 2>&1 || { echo "bundle failed verification" >&2; exit 1; }

printf 'bundle: %s (%.0f KB, %s commits, revision %s)\n' \
  "$OUT" \
  "$(du -k "$OUT" | awk '{print $1}')" \
  "$(git rev-list --all --count)" \
  "$(git rev-parse --short HEAD)"
echo
echo "Restore with:  git clone '$OUT' khata_pro"
echo "Keep one of these *outside* this workspace — a backup that shares the"
echo "workspace's fate is not a backup."
