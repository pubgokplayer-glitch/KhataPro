-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 006_search.sql
--  Full-text search that works offline, in Urdu, on a 4-year-old phone.
--
--  Design notes
--  ────────────
--  · One FTS5 table (unicode61 + remove_diacritics=2). That tokenizer folds
--    Urdu diacritics (zabar/zer/pesh) so a user typing "احمد" finds "اَحْمَد",
--    and it is folded at the byte level in C — no Dart-side normalisation pass
--    over 20 000 rows.
--  · `search_map` gives every indexed row a stable FTS rowid, so DELETE/UPDATE
--    of an index entry is an O(log n) rowid operation instead of a full scan
--    of the virtual table. Without this map, every party edit would re-scan the
--    whole FTS index — the classic reason "search feels slow" in these apps.
--  · The FTS index is DERIVED data: `ops/integrity_checks.sql` can rebuild it
--    from scratch (`INSERT INTO search_index(search_index) VALUES('rebuild')`
--    is only for external-content tables, so we rebuild from the source tables
--    instead — see ops/rebuild_search.sql).
--  · Only posted entries are indexed, so a user never searches for a number
--    that never made it into the books.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS search_map (
  doc_key     TEXT PRIMARY KEY,          -- 'party:<uuid>' — one key per indexed row
  kind        TEXT NOT NULL CHECK (kind IN ('party','item','document','entry','attachment')),
  row_id      TEXT NOT NULL,
  ledger_id   TEXT,
  fts_rowid   INTEGER,                   -- NULL ⇒ currently not in the index
  indexed_at  INTEGER NOT NULL,
  UNIQUE (kind, row_id)
) STRICT;

CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
  title,                                  -- the name / number — what the user types
  body,                                   -- urdu name, description, memo, OCR text
  meta,                                   -- phone, cnic, barcode, amount hints
  tokenize = 'unicode61 remove_diacritics 2'
);

-- Helper view: full context for a hit, so the UI needs one query, not four.
CREATE VIEW IF NOT EXISTS v_search_results AS
SELECT m.doc_key,
       m.kind,
       m.row_id,
       m.ledger_id,
       i.title,
       i.body,
       i.meta,
       m.fts_rowid,
       bm25(search_index, 10.0, 4.0, 2.0) AS rank_score
FROM search_index i
JOIN search_map   m ON m.fts_rowid = i.rowid;

-- ───────────────────────────────────────────────────────────────────────────
--  Shared macro-expansion: one pair of triggers per indexed table.
--  (SQLite has no trigger templates, so this is explicit on purpose — it is
--  also the only place where indexing rules can be reviewed.)
-- ───────────────────────────────────────────────────────────────────────────

-- ── parties ────────────────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS trg_fts_party_ai
AFTER INSERT ON parties
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'party:' || NEW.id);
  INSERT INTO search_index (title, body, meta)
  VALUES (NEW.name,
          COALESCE(NEW.name_ur, '') || ' ' || COALESCE(NEW.company, '') || ' ' ||
          COALESCE(NEW.address_line1, '') || ' ' || COALESCE(NEW.city, '') || ' ' || COALESCE(NEW.notes, ''),
          COALESCE(NEW.phone, '') || ' ' || COALESCE(NEW.alt_phone, '') || ' ' ||
          COALESCE(NEW.cnic, '') || ' ' || COALESCE(NEW.email, '') || ' ' || COALESCE(NEW.ntn, ''));
  INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
  VALUES ('party:' || NEW.id, 'party', NEW.id, NEW.ledger_id, last_insert_rowid(),
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(doc_key) DO UPDATE
    SET fts_rowid = excluded.fts_rowid, indexed_at = excluded.indexed_at, ledger_id = excluded.ledger_id;
END;

CREATE TRIGGER IF NOT EXISTS trg_fts_party_au
AFTER UPDATE ON parties
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'party:' || NEW.id);
  UPDATE search_map SET fts_rowid = NULL WHERE doc_key = 'party:' || NEW.id;
  INSERT INTO search_index (title, body, meta)
  SELECT NEW.name,
         COALESCE(NEW.name_ur, '') || ' ' || COALESCE(NEW.company, '') || ' ' ||
         COALESCE(NEW.address_line1, '') || ' ' || COALESCE(NEW.city, '') || ' ' || COALESCE(NEW.notes, ''),
         COALESCE(NEW.phone, '') || ' ' || COALESCE(NEW.alt_phone, '') || ' ' ||
         COALESCE(NEW.cnic, '') || ' ' || COALESCE(NEW.email, '') || ' ' || COALESCE(NEW.ntn, '')
  WHERE NEW.deleted_at IS NULL;
  UPDATE search_map
     SET fts_rowid = last_insert_rowid(), indexed_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE doc_key = 'party:' || NEW.id AND NEW.deleted_at IS NULL;
END;

-- ── items ──────────────────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS trg_fts_item_ai
AFTER INSERT ON items
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'item:' || NEW.id);
  INSERT INTO search_index (title, body, meta)
  VALUES (NEW.name, COALESCE(NEW.name_ur, '') || ' ' || COALESCE(NEW.description, ''),
          COALESCE(NEW.sku, '') || ' ' || COALESCE(NEW.barcode, '') || ' ' || NEW.unit);
  INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
  VALUES ('item:' || NEW.id, 'item', NEW.id, NEW.ledger_id, last_insert_rowid(),
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(doc_key) DO UPDATE
    SET fts_rowid = excluded.fts_rowid, indexed_at = excluded.indexed_at;
END;

CREATE TRIGGER IF NOT EXISTS trg_fts_item_au
AFTER UPDATE ON items
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'item:' || NEW.id);
  UPDATE search_map SET fts_rowid = NULL WHERE doc_key = 'item:' || NEW.id;
  INSERT INTO search_index (title, body, meta)
  SELECT NEW.name, COALESCE(NEW.name_ur, '') || ' ' || COALESCE(NEW.description, ''),
         COALESCE(NEW.sku, '') || ' ' || COALESCE(NEW.barcode, '') || ' ' || NEW.unit
   WHERE NEW.deleted_at IS NULL;
  UPDATE search_map SET fts_rowid = last_insert_rowid(),
         indexed_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE doc_key = 'item:' || NEW.id AND NEW.deleted_at IS NULL;
END;

-- ── documents ──────────────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS trg_fts_doc_ai
AFTER INSERT ON documents
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'document:' || NEW.id);
  INSERT INTO search_index (title, body, meta)
  VALUES (NEW.doc_no,
          COALESCE((SELECT name FROM parties WHERE id = NEW.party_id), '') || ' ' || COALESCE(NEW.notes, ''),
          COALESCE(NEW.e_invoice_ref, '') || ' ' || CAST(NEW.total_minor AS TEXT));
  INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
  VALUES ('document:' || NEW.id, 'document', NEW.id, NEW.ledger_id, last_insert_rowid(),
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(doc_key) DO UPDATE SET fts_rowid = excluded.fts_rowid, indexed_at = excluded.indexed_at;
END;

-- ── journal entries (memo / narration search — the "kis din kya hua" query) ─
CREATE TRIGGER IF NOT EXISTS trg_fts_entry_ai
AFTER INSERT ON journal_entries
FOR EACH ROW
WHEN NEW.status = 1
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'entry:' || NEW.id);
  INSERT INTO search_index (title, body, meta)
  VALUES (NEW.entry_no, COALESCE(NEW.memo, '') || ' ' || COALESCE(NEW.memo_ur, ''),
          COALESCE(NEW.doc_no, '') || ' ' ||
          COALESCE((SELECT name FROM parties WHERE id = NEW.party_id), ''));
  INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
  VALUES ('entry:' || NEW.id, 'entry', NEW.id, NEW.ledger_id, last_insert_rowid(),
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(doc_key) DO UPDATE SET fts_rowid = excluded.fts_rowid, indexed_at = excluded.indexed_at;
END;

CREATE TRIGGER IF NOT EXISTS trg_fts_entry_au
AFTER UPDATE OF status, memo, memo_ur ON journal_entries
FOR EACH ROW
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'entry:' || NEW.id);
  UPDATE search_map SET fts_rowid = NULL WHERE doc_key = 'entry:' || NEW.id;
  INSERT INTO search_index (title, body, meta)
  SELECT NEW.entry_no, COALESCE(NEW.memo, '') || ' ' || COALESCE(NEW.memo_ur, ''),
         COALESCE(NEW.doc_no, '') || ' ' ||
         COALESCE((SELECT name FROM parties WHERE id = NEW.party_id), '')
   WHERE NEW.status = 1;
  UPDATE search_map SET fts_rowid = last_insert_rowid(),
         indexed_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE doc_key = 'entry:' || NEW.id AND NEW.status = 1;
END;

-- ── attachments (OCR text of photographed bills) ───────────────────────────
CREATE TRIGGER IF NOT EXISTS trg_fts_attach_au
AFTER UPDATE OF ocr_text ON attachments
FOR EACH ROW
WHEN NEW.ocr_text IS NOT NULL AND NEW.ocr_text <> ''
BEGIN
  DELETE FROM search_index WHERE rowid = (SELECT fts_rowid FROM search_map WHERE doc_key = 'attachment:' || NEW.id);
  INSERT INTO search_index (title, body, meta) VALUES (NEW.file_name, NEW.ocr_text, NEW.mime_type);
  INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
  VALUES ('attachment:' || NEW.id, 'attachment', NEW.id, NEW.ledger_id, last_insert_rowid(),
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(doc_key) DO UPDATE SET fts_rowid = excluded.fts_rowid, indexed_at = excluded.indexed_at;
END;

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('search_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER));
