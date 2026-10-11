# Repository, storage budget, and getting this code off the workspace

Three things live here that are easy to get wrong: the workspace has a hard
storage budget, the repository has no remote until you add one, and none of it is
a backup until a copy exists somewhere else.

## 1 · The storage budget (128 MB, currently enforced by hand)

The workspace snapshot has a hard cap. Two directories dominate it and **neither
is part of the project**:

| directory | typical size | what it is |
| --- | --- | --- |
| `.pub-cache/` | ~110 MB | downloaded pub packages |
| `.dartServer/` | ~20 MB | the analyzer's index |

At one point this workspace sat at 132 MB — over the cap — purely because of
those two. Neither is in the snapshot exclusion list, so both count against the
budget.

**Run this whenever the workspace passes 100 MB:**

```bash
tool/cleanup_workspace.sh              # cleans only if > 100 MB
tool/cleanup_workspace.sh --dry-run    # show what would go, delete nothing
tool/cleanup_workspace.sh --force      # clean even when under the threshold
tool/cleanup_workspace.sh --keep-pub-cache
```

It deletes only regenerable things — `.dartServer/`, `.dart_tool/`, `build/`,
`*.dill`, and the `.pub-cache/` **that is inside the workspace**. Your source
(`lib/`, `test/`, `tool/`, `assets/`, `docs/`, `.git/`) is never touched. Caches
outside the workspace are left alone unless you pass `--all-caches`: deleting
`~/.pub-cache` frees nothing here and only costs you a re-download.

Then restore the build with `flutter pub get` (needs network).

**Keep the cache out of the workspace entirely.** Set `PUB_CACHE` to a directory
outside it:

```bash
export PUB_CACHE=/tmp/pub-cache          # or ~/pub-cache, anywhere but here
flutter pub get
```

Verification that runs in *this* environment uses `tool/bootstrap_harness.sh`,
which puts both the Dart SDK and the pub cache under `/tmp` and wraps every
command so the environment cannot be got wrong:

```bash
tool/bootstrap_harness.sh
cd /tmp/harness
./dartx run bin/run_layer.dart --asset-root=/home/user/khata_pro   # 81 checks
./dartx run ../../../home/user/khata_pro/tool/crdt_verify.dart    # 55 checks
KHATA_ASSET_ROOT=/home/user/khata_pro ./dartx test /home/user/khata_pro/test
```

Running a bare `dart` command without `PUB_CACHE` set will silently refill the
workspace with ~110 MB. That is precisely what `./dartx` exists to prevent.
Persisting the setting in your shell profile is the durable fix.

**If a test fails while *loading* — "No space left on device".** The harness's `/tmp`
is a small `tmpfs` (about 1 GB here) and it holds the Dart SDK (~640 MB), the pub cache
(~160 MB) and every test runner's kernel output. It can fill, and the symptom is not a
disk-full message at the top of the run: it is

```
Failed to load "test/core/crdt_merge_test.dart": Cannot copy file to
'/tmp/dart-tmp/…/kernel…/test.dart_2.dill' … (OS Error: No space left on device)
```

which reads like a broken test file and is not one. Check with `df -h /tmp`; the fix is
deleting scratch directories (`/tmp/pkg`, `/tmp/btest`, `/tmp/dart-tmp/*`) — never the
SDK or the pub cache. Measure to confirm:

```bash
df -h /tmp
du -sh /tmp/* | sort -rh | head
```

**No APK/IPA builds in this workspace.** Builds are hundreds of megabytes and the
deliverable is source. Build locally:

```bash
flutter pub get
flutter build apk --release --split-per-abi     # or: flutter build ipa
```

## 2 · Pushing to GitHub (or GitLab, or anything else)

The repository is already initialised and committed on `main` (115 files).
Adding a remote is the only step left, and it is deliberately *not* done for you:
credentials must never be written into a file this workspace shares.

```bash
cd /home/user/khata_pro

# GitHub, over SSH (recommended: no token in any file)
git remote add origin git@github.com:<your-user>/khata-pro.git

# …or over HTTPS with a fine-grained personal access token
#   create one at https://github.com/settings/tokens (scope: repo, contents:write)
#   and let a credential helper store it, not the repository:
git remote add origin https://github.com/<your-user>/khata-pro.git
git config --global credential.helper store     # writes to ~/.git-credentials

git push -u origin main
```

If the remote is empty, that is the whole job. For an existing repository:

```bash
git remote add origin <url>
git fetch origin
git rebase origin/main     # or: git merge --allow-unrelated-histories origin/main
git push -u origin main
```

### Two things worth knowing about this workspace

* **`.git/config` is excluded from workspace snapshots** (it is on the
  credential path list). So after this workspace is restored from a snapshot,
  the remote you added may be gone while every commit survives. Re-add it with
  one command: `git remote add origin <url>`. Nothing else needs redoing.
* **`.git/` itself does count** toward the 128 MB budget. Today it is 770 KB —
  negligible. If it ever grows (a large binary committed by accident), the fix is
  history surgery, not deletion of the directory: `git gc --aggressive` first.

### If you set up an empty repository and want the branch name to match

```bash
git branch -M main        # already the case here
git config --global init.defaultBranch main   # for future projects
```

## 3 · A backup that survives the workspace dying

A git repository with no remote is still a single copy. Two mechanisms, cheap
enough to use both:

**The bundle (offline, one file, verifiable):**

```bash
tool/make_backup_bundle.sh                # → /home/user/khata_pro.bundle (~690 KB)
tool/make_backup_bundle.sh /media/usb/khata_pro.bundle
```

A bundle contains every commit and branch and can be cloned from directly:

```bash
git clone /path/to/khata_pro.bundle khata_pro
```

**The remote** (step 2) is the primary backup; the bundle is the one that works
when there is no network at all, and it is what to keep on a USB stick. The
script verifies the bundle before declaring success — an unverified backup is a
rumour, and the failure mode of a corrupt one is discovering it years later.

## 4 · What must never be committed

`.gitignore` already refuses the usual suspects — keystores, provisioning
profiles, `key.properties`, `*.sqlite`, `*.khatapack`, `service_account*.json` —
because any one of them is either a secret or a user's actual books. Two notes:

* `pubspec.lock` is currently ignored. For an **application** (as opposed to a
  library) the Flutter guidance is to commit it, so every device builds the same
  dependency versions. If you want that — and for a ledger app you do — delete
  the line from `.gitignore` and commit the file.
* The verification vectors in `assets/testdata/` are *inputs*, not secrets:
  they contain published test vectors (FIPS-197, RFC 4231, RFC 5869). Commit
  them; the crypto suites are meaningless without them.
