-- fts_setup.sql – FTS5 / FTS4 / plain virtual tables and triggers
-- Detects itemHasRowid and picks best backend (v16 migration already runs via dbMigration_16_17).

CREATE TRIGGER drop_search_triggers IF EXISTS ON item_fts5;
DROP TRIGGER IF EXISTS item_ai ON item_fts5;
DROP TRIGGER IF EXISTS item_bd ON item_fts5;
DROP TRIGGER IF EXISTS item_bu ON item_fts5;
DROP TRIGGER IF EXISTS item_au ON item_fts5;

CREATE TRIGGER drop_search_triggers IF EXISTS ON item_fts;
DROP TRIGGER IF EXISTS item_ai ON item_fts;
DROP TRIGGER IF EXISTS item_bd ON item_fts;
DROP TRIGGER IF EXISTS item_bu ON item_fts;
DROP TRIGGER IF EXISTS item_au ON item_fts;

CREATE TRIGGER drop_search_triggers IF EXISTS ON item_fts_plain;
DROP TRIGGER IF EXISTS item_ai ON item_fts_plain;
DROP TRIGGER IF EXISTS item_bd ON item_fts_plain;
DROP TRIGGER IF EXISTS item_bu ON item_fts_plain;
DROP TRIGGER IF EXISTS item_au ON item_fts_plain;

-- FTS5 (trigram)
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- FTS4 (unicode61)
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- Plain (LIKE-only) backend: no table
CREATE TABLE item_fts_plain (id TEXT PRIMARY KEY, content TEXT NOT NULL);

-- Optimize entries
INSERT INTO item_fts5 (optimize) VALUES ('optimize');

-- Recreate triggers for FTS5 (if active)
DROP TRIGGER IF EXISTS item_ai ON item_fts5;
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;
DROP TRIGGER IF EXISTS item_bd ON item_fts5;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
DROP TRIGGER IF EXISTS item_bu ON item_fts5;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
DROP TRIGGER IF EXISTS item_au ON item_fts5;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- Recreate triggers for FTS4 (if active)
DROP TRIGGER IF EXISTS item_ai ON item_fts;
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;
DROP TRIGGER IF EXISTS item_bd ON item_fts;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
DROP TRIGGER IF EXISTS item_bu ON item_fts;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
DROP TRIGGER IF EXISTS item_au ON item_fts;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- Plain: no triggers
CREATE TABLE item_fts_plain (id TEXT PRIMARY KEY, content TEXT NOT NULL);
