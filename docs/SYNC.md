# Deliverable 3 — platform security, BYOC backup, LAN sync

Three things were asked for, in this order: (1) hardware key custody that lets a
background sync work **without a biometric prompt every time**, (2) bring-your-own-cloud
backup to Google Drive and iCloud that survives an interrupted network, (3) WebRTC
LAN sync with mDNS discovery, QR pairing, and chunking that does not drop frames.

All three are implemented and verified. The verification counts are real and
re-runnable; see §5 for the commands.

| what | where | evidence |
| --- | --- | --- |
| Hardware custody ladder + policy | `lib/platform/security/` | `tool/security_verify.dart` **54/54** |
| Android Keystore | `android/app/src/main/kotlin/com/khata/pro/security/SecurityChannel.kt` | compile-time (see §6) |
| iOS Secure Enclave | `ios/Runner/Security/SecurityChannel.swift` | compile-time (see §6) |
| KPB1 backup pack format | `lib/sync/backup/kpb1_format.dart` | `tool/sync_verify.dart` **133/133** |
| Resumable transfer engine | `lib/sync/backup/resumable_transfer.dart` | same |
| Google Drive store | `lib/platform/drive/drive_store.dart` | same, against a fake Drive |
| iCloud store | `lib/platform/icloud/icloud_store.dart` | same, against a temp-dir container |
| WebRTC transport | `lib/sync/transport/webrtc_lan_transport.dart` | compile-time + flow-control simulation |
| mDNS discovery | `lib/sync/transport/mdns_discovery.dart` | compile-time |
| QR pairing + session code | `lib/sync/transport/qr_pairing.dart` | `tool/sync_verify.dart` |
| Batch apply pipeline | `lib/sync/protocol/apply_pipeline.dart` | `tool/sync_verify.dart` |

---

## 1 · Hardware custody, and why sync never prompts

The requirement contains its own tension: *the key must be hardware-bound* and *a
background sync must open the database without a biometric prompt every time*.
Those are only in conflict if one key does both jobs. So there are two.

| alias | key | gate | used for |
| --- | --- | --- | --- |
| `khata/db/v1` | Keystore / Enclave key, **no** biometric flag | device unlocked at least once since boot (`AfterFirstUnlock`; Android `setUserAuthenticationRequired(false)`) | wrapping the **database DEK** — including from a WorkManager background pass |
| `khata/vault/v1` | Keystore / Enclave key, **biometric, per use** | a fresh fingerprint/face for every single operation; invalidated when enrolment changes | export, share, reveal-recovery-key — anything that carries the books *out* of the app |
| `khata/backup/v1` | no biometric flag | as `khata/db/v1` | wrapping a backup pack key, so a nightly Drive upload needs no prompt |

The shopkeeper is asked for a fingerprint when they *export*, not every time the app
syncs in the background. The ladder is
`hardwareBiometric → hardwareDevice → passphraseWrapped`, each step down announced
in the Security screen with the sentence a shopkeeper can read — `CustodyLevel`
carries `whereIsTheKey` and `protectsAgainst` verbatim for exactly that reason, and
`protectsAgainst` never overclaims.

Two consequences worth stating plainly:

* **A reboot delays sync; it does not break it.** Before the first unlock, the
  keystore refuses with `device_locked`, and the app says so ("sync waits for your
  first unlock"). After the unlock, the same operation succeeds with no user
  involvement.
* **Enrolling a new fingerprint destroys the vault key and spares the books.** That
  is the whole point of two keys: someone who adds their own fingerprint to a stolen,
  unlocked phone gains nothing, and the owner does not lose their ledger.

The platform channel is deliberately **one-way about key material**: the only
operations are `wrap` and `unwrap`. There is no method that returns a key, so a
compromised Dart context can ask the hardware to *use* a key but never to reveal one.
`CustodyRules.neverExportable` (Deliverable 2) still holds.

### The authentication window

One user action can touch the vault twice (read the export key, sign the manifest).
`AuthenticationSession` holds one successful authentication for a short, stamped
window so the prompt appears **once** per export — and it is not a session flag: it
expires (`SecurityTuning.exportGrace`, 30 s), it is scoped to one action, it is never
persisted, and it is revoked on lock, logout or screen-off. The harness asserts all
of that, including that a *different* action cannot inherit another's grant.

### Testing security policy without a phone

`fake_security_transport.dart` is not a stub: it refuses, invalidates and locks in
the situations the real Keystore does — opaque handles, idempotent `ensureKey`,
`device_locked` before first unlock, per-use authentication that is *consumed* by one
operation, `key_invalidated` after an enrolment change, and both platform envelope
flavours (Android `AES-GCM` with `iv`; iOS ECIES with an empty `iv`). The policy is
run against it 54 times before it ever meets a device.

That fake earned its keep immediately: the first run caught two shipped bugs.

## 2 · BYOC backup

### The pack format (KPB1)

```
magic "KPB1"  version(2)  headerLen(4)  header(canonical JSON)  headerMac(32)
then per chunk:  length(4)  nonce(16)  ciphertext  mac(32)
```

* **Per-chunk MACs, plus a merkle root in the header.** One MAC over the whole file
  would make a drop at 90 % cost the entire upload. Per-chunk MACs make progress
  resumable; the merkle root commits to all of it, so a manifest in the cloud cannot
  be edited to describe different contents.
* **Deterministic chunk nonces** (pack nonce with the trailing 8 bytes replaced by a
  big-endian counter) so a resume re-derives exactly the same keystream, and no two
  chunks ever share a counter block.
* **The header is authenticated including its length field**, so JSON cannot be
  smuggled in past the MAC.
* The pack key is wrapped by the device keystore (`khata/backup/v1`), which is why a
  nightly upload is unattended. A pack written on one device cannot be opened by
  another — the failure is typed and explained, not a decryption error.

### Resumable, verified transfers

`ResumableUploader` drives any `BlobStore`:

* a **journal** records progress after every committed chunk; the store's reported
  offset is treated as authoritative over the journal, because a chunk can land whose
  acknowledgement never arrives;
* a checkpoint records the **pack's merkle root**, so a resume can never splice two
  different packs together (the harness asserts this specifically);
* failures are **classified**: transient (retry with jittered exponential backoff),
  **quota** (do not retry — tell the user their Drive is full), auth (do not retry —
  ask them to sign in), corrupt (do not retry — the data is wrong);
* a resumed upload starts at the byte the store actually holds. The harness drops a
  connection at 60 % and asserts the first request afterwards is well past the drop.

### Google Drive

`drive.file` + `appDataFolder`, and nothing else. That scope means the app can touch
only files it created; the consent screen is a sentence a shopkeeper can agree with,
the token is useless for anything else, and no Google verification review is needed —
which is why a zero-cost app can ship it.

Resumable sessions are implemented directly (`POST …uploadType=resumable` → session
URI; `PUT` with `Content-Range`; `308` carries the range the server holds; an empty
`PUT` with `bytes */TOTAL` is the resume probe). The HTTP layer is behind a small
seam (`http_transport.dart`), so the protocol is tested against a fake Drive that
drops sockets, answers `308` with partial ranges and returns
`403 storageQuotaExceeded` — none of which you can ask the real service for on demand.

### iCloud

A ubiquity container, no OAuth, no session URIs — so resumption is done with a
`.part` file that is appended to and renamed on completion. Two properties fall out
of that, and both are asserted: **a half-written pack is invisible to `list()`** (it
can never be offered for restore), and abandoned partials are swept after six hours
so debris does not quietly consume the user's iCloud quota. `availableBytes()`
returns null on iOS because iOS does not expose iCloud quota to apps — the doc
comment says so rather than inventing a number.

## 3 · LAN sync over WebRTC

### No servers, and no leaks

`RTCConfiguration(iceServers: [])`: host candidates only. No STUN, no TURN, no
public-IP leak into a QR code, nothing to pay for. On the same Wi-Fi it connects;
across networks it fails honestly instead of silently relaying a user's books.

mDNS advertises `_khata-sync._tcp.local` with TXT records carrying a node id, a
protocol version, a truncated ledger fingerprint and a display name — **never the
business name, the balance or the file name**, because anyone on the café Wi-Fi can
read those records.

### Pairing, and the six digits

Discovery is not trust. Pairing is: an offer QR (expiring in two minutes), an answer,
and then **both screens show the same six digits**, derived from both peers' ephemeral
public keys and the ticket nonce. Two people standing next to each other glance at
two phones. A man-in-the-middle cannot make the digits agree without both private
keys — the harness asserts that a third device's key produces *different* digits. This
is the one step no cleverness replaces, and it is why the flow has two humans in it.

The ticket is compact (JSON → run-length encoded → base64url, with the SDP reduced to
the lines a data-channel-only connection needs), which keeps the QR at a density that
scans first try under shop lighting. A ticket from a different app version is refused
with a sentence, not a parse error.

### Not dropping frames while 52 MB crosses the room

`FlowControl` is pure arithmetic, so the frame-rate behaviour is tested rather than
hoped for. The simulator pushes a full 52 MB initial sync through it and asserts:

* the in-flight buffer **never** exceeds its 256 KiB budget;
* the pump **yields** to the isolate regularly (a yield is what lets the invoice list
  keep animating);
* pacing holds the transfer near its 4 MiB/s target — enough for a phone on 2.4 GHz
  Wi-Fi to render at 60–120 fps while syncing;
* frame size adapts (16 KiB → 64 KiB) on a healthy link and halves on loss.

The harness caught a genuine defect here too: the pacing window counted a *running
byte total* instead of a per-second window, which silently disables pacing after the
first second.

## 4 · Applying what arrives

`apply_pipeline.dart` turns received bytes into a decision, and it has three rules:

1. **All of a batch, or none.** Received changes go in through one transaction, and
   the Deliverable 2 gate runs inside it. An unbalanced entry from a peer rolls the
   *whole batch* back — a half-merged ledger would disagree with itself, which is the
   exact state the gate exists to prevent.
2. **Nothing unsigned.** A batch carries a MAC under a key derived from the pairing
   secret, and its id is a hash over its content in canonical order. A replay is
   therefore free (same id → duplicate → no-op), and an unpaired device on the Wi-Fi
   cannot inject anything: the receiver refuses before parsing.
3. **Nothing from another business.** A batch whose ledger id differs is refused
   outright, which matters because a shared family Drive is a realistic accident.

The per-table write path (`OpApplier`) is the one piece deliberately left as an
interface: it is per-table SQL and belongs next to the DAOs, where the schema's own
triggers and generated columns are visible. The *contract* — atomic, ordered by HLC,
idempotent by batch id, gated — is implemented and tested now, so the SQL can grow
table by table without reopening the design. See §6.

## 5 · Verification

```bash
# from the project root, with a plain Dart SDK (no Flutter needed):
dart tool/crdt_verify.dart            # 55
dart tool/crypto_verify.dart          # 72   (run from a directory containing lib/,
dart tool/aes_verify.dart             # 27    or via the harness shims below)
python3 tool/sql_contract_test.py     # 35/35
bash tool/verify_schema.sh            # 0 critical findings

# the harness carries the security + sync suites (it holds the package mapping):
bash tool/bootstrap_harness.sh
cd /tmp/harness
./run_tool.sh /home/user/khata_pro/tool/security_verify.dart   # 54
./run_tool.sh /home/user/khata_pro/tool/sync_verify.dart       # 133
./dartx run bin/run_layer.dart --asset-root=/home/user/khata_pro   # 81
./run_tests.sh                                                 # 16

# the two tools that import the repo's lib/ by relative path, and the analyzer's
# view of the Flutter-only layer (see §5.1 — both are easy to get wrong):
./dartx crypto_run.dart /home/user/khata_pro/assets/testdata/crypto_vectors.json
./dartx aes_run.dart    /home/user/khata_pro/assets/testdata/aes_vectors.json
./dartx analyze --packages=plugin_stubs_config.json /home/user/khata_pro/lib
```

### 5.1 · Type-checking the files that need a phone

Five files import Flutter or a plugin, and this workspace has no Flutter SDK. Until
this session that meant the entire Flutter-facing layer was **never analyzed at all**:
`dart analyze` reported thirty-odd `uri_does_not_exist` errors and the real ones hid
inside the noise. `tool/plugin_stubs/` fixes that — signatures for `flutter`,
`flutter_webrtc`, `nsd`, `icloud_storage` and `path_provider`, transcribed from the
pinned versions' actual source, never executed, and wired into a package config by
`tool/plugin_stubs/build_plugin_config.py`. With them, analyzing all of `lib/` reports
**no issues**.

The same session turned up a second, quieter verification bug: `crypto_verify.dart`
and `aes_verify.dart` import `../lib/...` relatively, so *copying* them into the
harness's `bin/` compiles them against a `lib/` that is not there (or, worse, is stale).
They must be imported by path (`/tmp/harness/crypto_run.dart`, generated by the
bootstrap), which keeps their relative imports pointing at the working tree.

### 5.2 · The defects the suites caught (each would have shipped)

| # | defect | why it mattered |
| --- | --- | --- |
| 1 | An empty `iv` was rejected as malformed | Would have broken **every unwrap on iOS**, where ECIES carries its own nonce and the field is legitimately empty |
| 2 | `passphraseOnly` created a keystore key before honouring the user's refusal | Stored a key the user explicitly declined to have stored |
| 3 | The uploader counted *chunks sent* as *attempts* | Any backup larger than 6 × chunkBytes failed on a correct, healthy upload |
| 4 | The pacing window used a running byte total | Pacing silently stopped after the first second, so the UI would stutter |
| 5 | `Hlc.encode()` accepted a node id that `parse()` rejects | Would have written unreadable HLCs into `hlc` columns, breaking causal ordering on merge |
| 6 | The QR codec **inflated** a realistic ticket 2.55× — 2838 characters against a version-40 QR's absolute limit of 2953 | Pairing would have failed to draw a code as soon as one phone gathered one more ICE candidate. Nothing would have reported an error; the screen would just never show a QR. Deflate instead of run-length: 788 characters, with the budget (`PairingCodec.scannableBudget = 1200`) now asserted |

Defect 5 was found by the apply-pipeline test, which is a good argument for testing a
format at both ends: the encoder and the decoder each looked right on their own.
Defect 6 was found by *measuring* rather than reasoning — the compression scheme had a
plausible story ("candidate lists have long runs") and the story was false.

### 5.3 · The defects the pinned plugin sources caught

Found by transcribing each pinned version's real API into the stubs in §5.1 and
analyzing the call sites against it. None of these could have been found by any test in
this environment: they are all in files that need a device to run.

| # | defect | why it mattered |
| --- | --- | --- |
| 7 | `setLocalDescription` returns `Future<void>`, and was being handed a *minimised* description | A compile error, and — had it compiled — libwebrtc would have been given text it did not produce, which is a negotiation that succeeds and then never connects |
| 8 | Candidates never reached the far side: gathering finished *after* the ticket was built, the answer read candidates out of a stale description, and the receiver ignored `PairingTicket.candidates` entirely | Two phones would pair, show matching six digits, and then transfer nothing |
| 9 | The SDP minimiser dropped `a=sctp-port` and the `v=`/`o=`/`s=`/`t=` session lines | The description scans, negotiates, and the data channel never opens. Now the surgery lives in a pure-Dart file (`sdp_tools.dart`) that **refuses** to return a description that cannot carry a data channel |
| 10 | `PumpState.copyWith(sentThisWindow:)` named a field that does not exist (it is `sentThisSecond`), and `drainDelay` could divide by zero on a zero-size frame | A compile error at the first real caller; a crash on a degenerate frame size |
| 11 | mDNS TXT values are `Uint8List?`, not `String` | Writing them as strings does not compile; **reading** them and comparing to a `String` compiles, runs, and matches no peer ever. Discovery would have found nothing, silently, on both platforms |
| 12 | `requiresPairing: version == protocolVersion` | Inverted a safety flag — it claimed "no pairing required" for exactly the peers whose protocol this build does not understand |
| 13 | The `nsd.Discovery` `ChangeNotifier` listener was never removed on `stop()` | Leaks the discovery object, its stream and an `NsdManager` registration every time the user opens the sync screen |
| 14 | `icloud_storage`'s `gather()` returns `List<ICloudFile>` and was assigned to a `String?` "container path"; the whole iCloud store was built around a container path the plugin does not expose, and `upload()` returns *before* the file reaches iCloud | The iOS backup path could not have run at all. The interface was rebuilt around what the plugin actually does — **staging locally, committing whole files, and reporting `isUploaded` separately from "exists on this phone"** — and `UbiqContainer` now says exactly that |

The lesson worth keeping: eleven of these lived in ~900 lines of code that had never
been type-checked, and every one of them was invisible to the suites that pass. The
suites test the *logic* (which is pure Dart and stays that way on purpose); the stubs
test the *seam*; a phone is still the only thing that tests the plugin.

## 6 · What is not done, stated plainly

* **The Kotlin, Swift and Flutter-plugin files have not been compiled or run here** —
  this environment has neither an Android SDK, Xcode, nor the Flutter SDK. They are now
  **type-checked** against stubs transcribed from the pinned versions (§5.1), which is
  what caught the eleven defects in §5.3, but no stub has a body: the first
  `flutter build apk` / `build ipa` is their real compile, and the first pair of phones
  is their first thing resembling a test. That is also why the workspace holds no
  APK/IPA. What specifically still needs a device:
  * whether `IcloudPluginContainer`'s `Documents/` prefix assumption holds on a real
    container (macOS containers differ from iOS ones);
  * whether `nsd` returns `addresses` on both platforms with `IpLookupType.any`
    (iOS is the uncertain one);
  * whether the minimised description actually connects (the failure mode of getting
    SDP surgery wrong is silence);
  * whether the 30-second `AuthenticationSession` grace period is long enough for a
    background `URLSession` upload on a real phone with a locked screen.
* **`OpApplier` has no per-table implementation yet.** The pipeline, its
  transaction/gate/idempotence contract and its tests exist; the SQL that writes
  `parties`, `journal_entries`, `journal_lines` … from a `SyncOp` is next, and it
  belongs with the DAOs.
* **The chaos suite** (`integration_test/sync_chaos_test.dart` from the original
  plan) is not written: it needs a device or two.
* **Device identity pinning** is not implemented. The original plan mentioned Ed25519
  pinning at pairing; what exists is ephemeral keys plus a session code, which
  authenticates *this transfer* rather than *that device forever*. Pinning a device
  key on first pairing is a small addition and is the natural next step.
* **`/tmp` is not persisted.** The harness (Dart SDK, pub cache, package mapping) is
  rebuilt by `tool/bootstrap_harness.sh` in a few seconds; nothing about it lives in
  the repository.
