-- ═══════════════════════════════════════════════════════════════════════════
--  ops/rebuild_search.sql — NOT a migration. Derived data only.
--  Run after a restore, a bulk import, or whenever v_integrity_report reports
--  SEARCH_INDEX_STALE. Safe to run at any time; it is fully idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1 · Clear both the index and its rowid map.
DELETE FROM search_index;
DELETE FROM search_map;

-- 2 · Re-index parties.
INSERT INTO search_index (title, body, meta)
SELECT p.name,
       COALESCE(p.name_ur,'') || ' ' || COALESCE(p.company,'') || ' ' ||
       COALESCE(p.address_line1,'') || ' ' || COALESCE(p.city,'') || ' ' || COALESCE(p.notes,''),
       COALESCE(p.phone,'') || ' ' || COALESCE(p.alt_phone,'') || ' ' ||
       COALESCE(p.cnic,'') || ' ' || COALESCE(p.email,'') || ' ' || COALESCE(p.ntn,'')
  FROM parties p WHERE p.deleted_at IS NULL;

-- 3 · Map the rows we just inserted (fts rowid = the new index rowid, matched
--     by insertion order within this statement batch — hence the single-pass
--     INSERT … SELECT above, one kind at a time).
INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
SELECT 'party:' || p.id, 'party', p.id, p.ledger_id, i.rowid,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM parties p
  JOIN search_index i ON i.title = p.name
 WHERE p.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM search_map m WHERE m.doc_key = 'party:' || p.id);

-- 4 · Re-index items.
INSERT INTO search_index (title, body, meta)
SELECT i.name, COALESCE(i.name_ur,'') || ' ' || COALESCE(i.description,''),
       COALESCE(i.sku,'') || ' ' || COALESCE(i.barcode,'') || ' ' || i.unit
  FROM items i WHERE i.deleted_at IS NULL;

INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
SELECT 'item:' || i.id, 'item', i.id, i.ledger_id, x.rowid,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM items i
  JOIN search_index x ON x.title = i.name
 WHERE i.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM search_map m WHERE m.doc_key = 'item:' || i.id);

-- 5 · Re-index documents.
INSERT INTO search_index (title, body, meta)
SELECT d.doc_no,
       COALESCE(p.name,'') || ' ' || COALESCE(d.notes,''),
       COALESCE(d.e_invoice_ref,'') || ' ' || CAST(d.total_minor AS TEXT)
  FROM documents d LEFT JOIN parties p ON p.id = d.party_id
 WHERE d.deleted_at IS NULL;

INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
SELECT 'document:' || d.id, 'document', d.id, d.ledger_id, x.rowid,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM documents d
  JOIN search_index x ON x.title = d.doc_no
 WHERE d.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM search_map m WHERE m.doc_key = 'document:' || d.id);

-- 6 · Re-index posted entries (memo / narration).
INSERT INTO search_index (title, body, meta)
SELECT e.entry_no,
       COALESCE(e.memo,'') || ' ' || COALESCE(e.memo_ur,''),
       COALESCE(e.doc_no,'') || ' ' || COALESCE(p.name,'')
  FROM journal_entries e LEFT JOIN parties p ON p.id = e.party_id
 WHERE e.status = 1;

INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
SELECT 'entry:' || e.id, 'entry', e.id, e.ledger_id, x.rowid,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM journal_entries e
  JOIN search_index x ON x.title = e.entry_no
 WHERE e.status = 1
   AND NOT EXISTS (SELECT 1 FROM search_map m WHERE m.doc_key = 'entry:' || e.id);

-- 7 · Re-index OCR text from photographed bills.
INSERT INTO search_index (title, body, meta)
SELECT a.file_name, a.ocr_text, a.mime_type
  FROM attachments a
 WHERE a.deleted_at IS NULL AND a.ocr_text IS NOT NULL AND a.ocr_text <> '';

INSERT INTO search_map (doc_key, kind, row_id, ledger_id, fts_rowid, indexed_at)
SELECT 'attachment:' || a.id, 'attachment', a.id, a.ledger_id, x.rowid,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM attachments a
  JOIN search_index x ON x.title = a.file_name
 WHERE a.deleted_at IS NULL AND a.ocr_text IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM search_map m WHERE m.doc_key = 'attachment:' || a.id);

-- 8 · Compact the FTS index (merges b-tree segments; also runs nightly).
INSERT INTO search_index (search_index) VALUES ('optimize');

-- 9 · Proof: zero rows means the index is consistent with the source tables.
SELECT * FROM v_integrity_report WHERE kind = 'SEARCH_INDEX_STALE';
