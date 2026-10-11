-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 003_crdt_sync.sql
--  CRDT plumbing: the op-log, peer bookkeeping, audit chain, backup state and
--  key custody.
--
--  THE MERGE MODEL (short version — full proof sketch in docs/ARCHITECTURE.md §3)
--  ─────────────────────────────────────────────────────────────────────────
--  Every replicated row carries (hlc, node_id, rev), with one deliberate
--  exception: `journal_lines` carries no hlc, because a line has no
--  independent existence — it is meaningless unless it sums to zero with its
--  siblings, so it always travels with its parent entry and inherits that
--  entry's stamp. hlc is a Hybrid Logical
--  Clock: "physical ms : logical counter : node id", fixed-width, so byte
--  comparison == causal comparison. Two rules are all we need:
--
--   · Ledger/append-only tables (journal_entries, journal_lines, stock_moves,
--     payment_allocations, fx_rates, balance_snapshots, audit_log):
--     merge = SET UNION, keyed by UUIDv7 pk. Idempotent, commutative,
--     associative ⇒ any interleaving of any two devices converges. Immutability
--     (enforced by triggers) is what makes this sound.
--
--   · Mutable tables (parties, items, accounts, documents-in-draft, settings,
--     reminders): merge = LWW-Element-Set with survival rule
--         winner = max_by( (hlc, node_id) )   over  {remote, local}
--     `node_id` in the key makes ties *deterministic*, not "whoever wrote last
--     to the local file" — so A→B→A re-syncs are byte-identical and never
--     flap. That is the CRDT guarantee: no arbiter, no divergence, no data
--     loss; the losing version is still preserved in conflict_log for the user
--     to inspect (a "merge receipt", not a silent overwrite).
--
--  Deletes are tombstones (deleted_at + an op='delete' row in the oplog), never
--  destructive SQL, so a delete cannot be resurrected by a stale peer copy.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- ───────────────────────────────────────────────────────────────────────────
--  oplog · LOCAL-ONLY. The change bus. Not itself replicated: each device
--  keeps its own journal of what it has to tell others.
--
--  Payload is NOT duplicated here. `row_id` + `table_name` let the transport
--  re-read the live row at send time (so a burst of edits coalesces to one
--  wire entry by keeping only the newest hlc per row — see the index below),
--  while `payload_json` is filled *only* for hard cases: tombstones whose row
--  is gone, and "audit" events with no row of their own.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS oplog (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name   TEXT NOT NULL CHECK (length(table_name) BETWEEN 1 AND 40),
  row_id       TEXT NOT NULL,
  op           INTEGER NOT NULL CHECK (op IN (1, 2, 3)),
                 -- 1 = upsert (row exists, send its current state)
                 -- 2 = delete (tombstone: row may be gone, payload_json has it)
                 -- 3 = append (immutable row: always send in full)
  hlc          TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id      TEXT NOT NULL CHECK (length(node_id) = 36),
  ledger_id    TEXT,
  rev          INTEGER NOT NULL DEFAULT 1,
  payload_json TEXT,
  byte_size    INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL,               -- epoch-ms, local wall clock
  dispatched_at INTEGER,                       -- NULL ⇒ still owed to somebody
  dispatch_count INTEGER NOT NULL DEFAULT 0 CHECK (dispatch_count >= 0)
) STRICT;

-- The delta cursor: "give me everything newer than the peer's HLC".
CREATE INDEX IF NOT EXISTS ix_oplog_hlc        ON oplog (hlc, seq);
CREATE INDEX IF NOT EXISTS ix_oplog_ledger_hlc ON oplog (ledger_id, hlc);
-- Undispatched backlog scan (drives the "N changes waiting to sync" badge).
CREATE INDEX IF NOT EXISTS ix_oplog_pending    ON oplog (created_at) WHERE dispatched_at IS NULL;
-- One logical entry per row for the *newest* change: the transport walks
-- (row_id) groups in reverse-seq order and keeps the first hit.
CREATE INDEX IF NOT EXISTS ix_oplog_row        ON oplog (table_name, row_id, seq DESC);

-- ───────────────────────────────────────────────────────────────────────────
--  sync_peers · LOCAL-ONLY (device-local trust + transport hints). Trust is
--  deliberately per-device: pairing is a physical act, and a silent cloud copy
--  of a trust list would be a security hole, not a convenience.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_peers (
  peer_node_id     TEXT PRIMARY KEY CHECK (length(peer_node_id) = 36),
  display_name     TEXT NOT NULL,
  platform         TEXT,
  transport        INTEGER NOT NULL DEFAULT 1 CHECK (transport BETWEEN 1 AND 4),
                     -- 1 lan_webrtc 2 qr_file_handoff 3 drive_relay 4 icloud_relay
  trust_state      INTEGER NOT NULL DEFAULT 0 CHECK (trust_state IN (0,1,2)),
                     -- 0 pending 1 trusted 2 revoked
  pinned_pubkey    TEXT,                   -- Ed25519 base64; TOFU pin, blocks MITM
  auto_sync        INTEGER NOT NULL DEFAULT 1 CHECK (auto_sync IN (0,1)),
  last_hint        TEXT,                   -- "192.168.1.34:52180" or Drive file id
  last_seen_at     INTEGER,
  last_sync_at     INTEGER,
  paired_at        INTEGER NOT NULL,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  CHECK (trust_state <> 1 OR pinned_pubkey IS NOT NULL)   -- trusted ⇒ pinned
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  sync_cursors · LOCAL-ONLY. Per-peer high-water marks in both directions.
--  Having both directions as HLC (not wall clock!) means a phone whose clock
--  is an hour fast cannot hide its neighbour's edits behind a bogus cursor.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_cursors (
  peer_node_id     TEXT PRIMARY KEY,
  last_sent_hlc    TEXT NOT NULL DEFAULT '000000000000000:0000:00000000-0000-0000-0000-000000000000',
  last_received_hlc TEXT NOT NULL DEFAULT '000000000000000:0000:00000000-0000-0000-0000-000000000000',
  ops_sent         INTEGER NOT NULL DEFAULT 0,
  ops_received     INTEGER NOT NULL DEFAULT 0,
  bytes_sent       INTEGER NOT NULL DEFAULT 0,
  bytes_received   INTEGER NOT NULL DEFAULT 0,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_error       TEXT,
  updated_at       INTEGER NOT NULL,
  FOREIGN KEY (peer_node_id) REFERENCES sync_peers(peer_node_id) ON DELETE CASCADE
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  sync_sessions · LOCAL-ONLY telemetry. Lets the Settings screen show an
--  honest "last sync: 2 h ago, 412 ops, 1.9 MB, 38 s" instead of a spinner.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_sessions (
  id             TEXT PRIMARY KEY CHECK (length(id) = 36),
  peer_node_id   TEXT,
  transport      INTEGER NOT NULL DEFAULT 1,
  direction      INTEGER NOT NULL DEFAULT 0 CHECK (direction IN (0,1,2)),
                   -- 0 bidirectional 1 push 2 pull
  status         INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0,1,2,3)),
                   -- 0 running 1 ok 2 partial 3 failed
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  ops_sent       INTEGER NOT NULL DEFAULT 0,
  ops_received   INTEGER NOT NULL DEFAULT 0,
  conflicts_lww  INTEGER NOT NULL DEFAULT 0,
  snapshot_hits  INTEGER NOT NULL DEFAULT 0,
  bytes_sent     INTEGER NOT NULL DEFAULT 0,
  bytes_received INTEGER NOT NULL DEFAULT 0,
  error          TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS ix_sync_sessions_time ON sync_sessions (started_at DESC);

-- ───────────────────────────────────────────────────────────────────────────
--  conflict_log · LOCAL-ONLY. The "merge receipt".
--  LWW loses a value on purpose; hiding that fact is how users stop trusting an
--  app. Every overwritten field lands here with both versions, is surfaced as a
--  dismissible review card, and is prunable. Losing side only, never the winner.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS conflict_log (
  id           TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id    TEXT,
  table_name   TEXT NOT NULL,
  row_id       TEXT NOT NULL,
  field_name   TEXT,
  kind         INTEGER NOT NULL DEFAULT 1 CHECK (kind IN (1,2,3)),
                 -- 1 lww_overwrite 2 duplicate_document 3 orphan_repaired
  local_hlc    TEXT,
  remote_hlc   TEXT,
  local_node   TEXT,
  remote_node  TEXT,
  local_json   TEXT,
  remote_json  TEXT,
  resolution   TEXT NOT NULL,          -- 'remote_won' | 'local_won' | 'union' | 'merged'
  reviewed_at  INTEGER,
  detected_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS ix_conflict_unreviewed ON conflict_log (detected_at DESC) WHERE reviewed_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_conflict_row        ON conflict_log (table_name, row_id);

-- ───────────────────────────────────────────────────────────────────────────
--  audit_log · replicated, APPEND-ONLY, HASH-CHAINED.
--  hash_self = SHA-256( hash_prev ‖ canonical_json(event) ) — computed in Dart,
--  verified by SQL on read (a trigger checks that hash_prev equals the previous
--  row's hash_self for this ledger, catching insertion, reordering or deletion
--  from anywhere, including a hostile peer).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id            TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id     TEXT NOT NULL,
  seq           INTEGER NOT NULL,
  actor_node_id TEXT NOT NULL,
  actor_name    TEXT,
  action        TEXT NOT NULL,        -- 'entry.posted', 'party.deleted', 'backup.restored'…
  entity_type   TEXT NOT NULL,
  entity_id     TEXT,
  before_json   TEXT,
  after_json    TEXT,
  hash_prev     TEXT NOT NULL CHECK (length(hash_prev) = 64),
  hash_self     TEXT NOT NULL CHECK (length(hash_self) = 64),
  hlc           TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id       TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at    INTEGER NOT NULL,
  UNIQUE (ledger_id, seq)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_audit_entity ON audit_log (ledger_id, entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_time   ON audit_log (ledger_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_hlc    ON audit_log (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  backup_state · replicated. BYOC configuration travels with the *book*, so
--  reinstalling on a new phone restores settings from a tiny bootstrap pack.
--  It never contains credentials: the OAuth/CloudKit identity lives in the OS
--  keychain and is re-established by the user on the new device.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS backup_state (
  id                  TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id           TEXT NOT NULL,
  target              INTEGER NOT NULL CHECK (target IN (0,1,2)),
                        -- 0 google_drive 1 icloud 2 local_file (SD card / SAF)
  is_enabled          INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0,1)),
  remote_folder_ref   TEXT,               -- Drive folder id / iCloud container path
  account_hint        TEXT,               -- "ali@gmail.com" — display only
  last_pack_id        TEXT,
  last_success_at     INTEGER,
  last_attempt_at     INTEGER,
  last_error          TEXT,
  chain_seq           INTEGER NOT NULL DEFAULT 0,
  checkpoint_days     INTEGER NOT NULL DEFAULT 7 CHECK (checkpoint_days BETWEEN 1 AND 90),
  keep_copies         INTEGER NOT NULL DEFAULT 12 CHECK (keep_copies BETWEEN 1 AND 365),
  upload_over_wifi_only INTEGER NOT NULL DEFAULT 1 CHECK (upload_over_wifi_only IN (0,1)),
  include_attachments INTEGER NOT NULL DEFAULT 0 CHECK (include_attachments IN (0,1)),
  bytes_total         INTEGER NOT NULL DEFAULT 0,
  hlc                 TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id             TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                 INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at          INTEGER,
  created_at          INTEGER NOT NULL,
  updated_at          INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  UNIQUE (ledger_id, target),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE CASCADE
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  key_material · LOCAL-ONLY. Custody of the random Data Encryption Key.
--  The DEK itself is never stored in the clear: it is sealed with a key held by
--  the OS (Android Keystore via EncryptedSharedPreferences / iOS Keychain with
--  kSecAttrAccessibleWhenUnlockedThisDeviceOnly). If the user opts into a
--  recovery phrase, the SAME DEK is wrapped a second time with an Argon2id key
--  (64 MiB, t=3, p=1) derived from 24 BIP-39 words. Losing the phone then does
--  not lose the books; forgetting the phrase loses nothing on this device.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS key_material (
  key_id        TEXT PRIMARY KEY,
  purpose       TEXT NOT NULL CHECK (purpose IN ('db_dek','vault_dek','backup_kek','device_signing')),
  wrapped_key   BLOB NOT NULL,            -- ciphertext only, ever
  wrap_algo     TEXT NOT NULL,            -- 'aes-256-gcm+keystore' | 'argon2id-aes-256-gcm'
  wrap_iv       BLOB NOT NULL,
  wrap_salt     BLOB,
  kdf_params    TEXT,                     -- {"m":67108864,"t":3,"p":1,"version":19}
  device_node_id TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  rotated_at    INTEGER,
  retired_at    INTEGER
) STRICT;

CREATE INDEX IF NOT EXISTS ix_key_material_purpose ON key_material (purpose) WHERE retired_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
--  recovery_guard · LOCAL-ONLY single row. Guard against the worst UI bug in
--  this class of app: "forgot PIN" that wipes a database it cannot re-key.
--  Wipe is allowed only when a verified backup exists (or the user types the
--  recovery phrase / holds the explicit double-confirm acknowledgement).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS recovery_guard (
  id                     INTEGER PRIMARY KEY CHECK (id = 1),
  last_verified_backup_at INTEGER,
  last_verified_pack_id  TEXT,
  recovery_phrase_set    INTEGER NOT NULL DEFAULT 0 CHECK (recovery_phrase_set IN (0,1)),
  wipe_acknowledged_at   INTEGER,
  failed_unlock_count    INTEGER NOT NULL DEFAULT 0,
  last_failed_unlock_at  INTEGER
) STRICT;

INSERT OR IGNORE INTO recovery_guard (id, recovery_phrase_set) VALUES (1, 0);

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('sync_protocol_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  ('hlc_format', 'physical15:counter4:node36', CAST(unixepoch('subsec') * 1000 AS INTEGER));
