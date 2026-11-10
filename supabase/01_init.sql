-- init_schema.sql – primary tables created by initTables() in lib/storage/storage_sqlite.dart
-- Supabase project "ntsapp", schema "public", port 54322, major_version 15

CREATE TABLE profile (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  username TEXT,
  thumbnail TEXT,
  url TEXT,
  type INTEGER,
  updated_at INTEGER,
  at INTEGER
);

CREATE TABLE category (
  id TEXT PRIMARY KEY,
  profile_id TEXT,
  title TEXT NOT NULL,
  color TEXT,
  position INTEGER,
  archived_at INTEGER,
  at INTEGER,
  updated_at INTEGER,
  thumbnail TEXT,
  state INTEGER
);

CREATE TABLE itemgroup (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL,
  title TEXT NOT NULL,
  pinned INTEGER,
  position INTEGER,
  archived_at INTEGER,
  color TEXT,
  at INTEGER,
  updated_at INTEGER,
  thumbnail TEXT,
  data TEXT,
  state INTEGER,
  FOREIGN KEY (category_id) REFERENCES category(id) ON DELETE CASCADE
);

CREATE TABLE item (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL,
  text TEXT,
  starred INTEGER,
  pinned INTEGER,
  archived_at INTEGER,
  type INTEGER,
  data TEXT,
  at INTEGER,
  updated_at INTEGER,
  thumbnail TEXT,
  state INTEGER,
  FOREIGN KEY (group_id) REFERENCES itemgroup(id) ON DELETE CASCADE
);

CREATE TABLE itemfile (
  id TEXT PRIMARY KEY,
  hash TEXT NOT NULL,
  FOREIGN KEY (id) REFERENCES item(id) ON DELETE CASCADE
);

CREATE TABLE change (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  data TEXT NOT NULL,
  type INTEGER NOT NULL,
  thumbnail TEXT,
  map TEXT
);

CREATE TABLE files (
  id TEXT PRIMARY KEY,
  change_id TEXT NOT NULL,
  path TEXT NOT NULL,
  size INTEGER NOT NULL,
  parts INTEGER NOT NULL,
  parts_uploaded INTEGER NOT NULL,
  key_cipher TEXT NOT NULL,
  key_nonce TEXT NOT NULL,
  uploaded_at INTEGER NOT NULL,
  b2_id TEXT,
  FOREIGN KEY (change_id) REFERENCES change(id) ON DELETE CASCADE
);

CREATE TABLE parts (
  id TEXT PRIMARY KEY,
  file_id TEXT NOT NULL,
  part_number INTEGER NOT NULL,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
);

CREATE TABLE setting (
  id TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  at INTEGER
);

CREATE TABLE logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  log TEXT
);

CREATE TABLE preferences (
  id TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE change_log (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  data TEXT NOT NULL,
  type INTEGER NOT NULL,
  thumbnail TEXT,
  map TEXT
);

CREATE TABLE profiles (
  id TEXT PRIMARY KEY,
  email TEXT,
  username TEXT,
  thumbnail TEXT,
  url TEXT,
  type INTEGER,
  updated_at INTEGER,
  at INTEGER
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  title TEXT,
  last_at INTEGER,
  fcm_id TEXT,
  status INTEGER
);

CREATE TABLE keys (
  id TEXT PRIMARY KEY,
  server_keys TEXT,
  server_token TEXT,
  user_token TEXT,
  created_at INTEGER
);

CREATE TABLE plans (
  id TEXT PRIMARY KEY,
  b2_limit INTEGER,
  expires_at INTEGER,
  devices INTEGER
);

CREATE TABLE user (
  id TEXT PRIMARY KEY,
  email TEXT,
  username TEXT,
  fcm_id TEXT,
  device_id TEXT,
  plan_id TEXT,
  created_at INTEGER
);

CREATE TABLE server (
  key TEXT,
  value TEXT,
  state INTEGER
);

CREATE TABLE thmbs (
  id TEXT PRIMARY KEY,
  file_id TEXT,
  cipher_nonce TEXT,
  key_cipher TEXT,
  key_nonce TEXT,
  path TEXT,
  user_file_id TEXT,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
);

CREATE TABLE item_fts5 (
  id TEXT PRIMARY KEY,  -- rowid treated as id, UNINDEXED, text, tokenize
  text TEXT NOT NULL,
  id TEXT NOT NULL,
  FOREIGN KEY (id) REFERENCES item(id) ON DELETE RESTRICT
) USING fts5(content="item", id UNINDEXED, text, tokenize=trigram);

CREATE TABLE item_fts (
  id TEXT PRIMARY KEY,
  text TEXT NOT NULL,
  item_id TEXT NOT NULL,
  FOREIGN KEY (item_id) REFERENCES item(id) ON DELETE RESTRICT
) USING fts4(content="item", id, text, tokenize=unicode61);

CREATE TABLE item_fts_plain (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  FOREIGN KEY (item_id) REFERENCES item(id) ON DELETE RESTRICT
);

CREATE INDEX idx_item_fts5_text ON item_fts5(text);
CREATE INDEX idx_item_fts_text ON item_fts(text);
CREATE INDEX idx_item_fts5_id ON item_fts5(id);
CREATE INDEX idx_item_fts_text_id ON item_fts(text, id);
CREATE INDEX idx_item_fts_plain_id ON item_fts_plain(id);

-- Maintenance triggers for FTS5 (item_fts5)
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- Maintenance triggers for FTS4 (item_fts)
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
CREATE TRIGGER item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text BEGIN DELETE FROM item_fts WHERE docid = old.rowid; END;
CREATE TRIGGER item_au AFTER UPDATE ON item WHEN old.text IS NOT new.text BEGIN INSERT INTO item_fts(docid, id, text) VALUES (new.rowid, new.id, new.text); END;

-- Plain/no search table for LIKE-only backend
CREATE TABLE item_fts_plain (id TEXT PRIMARY KEY, content TEXT NOT NULL);

DROP TABLE IF EXISTS item_fts5;
DROP TABLE IF EXISTS item_fts;
DROP TABLE IF EXISTS item_fts_plain;

-- FTS5 backend (trigram)
INSERT INTO item_fts5(rowid, id, text) SELECT rowid, id, text FROM item WHERE text IS NOT NULL;

-- FTS4 backend (unicode61)
INSERT INTO item_fts(docid, id, text) SELECT rowid, id, text FROM item WHERE text IS NOT NULL;

-- Optimize entries
INSERT INTO item_fts5 (optimize) VALUES ('optimize');

-- Triggers repointed to item_fts5
DROP TRIGGER IF EXISTS item_ai AFTER INSERT ON item;
CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;
DROP TRIGGER IF EXISTS item_bd BEFORE DELETE ON item;
CREATE TRIGGER item_bd BEFORE DELETE ON item BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
DROP TRIGGER IF EXISTS item_bu BEFORE UPDATE ON item WHEN old.text IS NOT new.text;
CREATE TRIGGER item_bu BEFORE UPDATE ON item BEGIN INSERT INTO item_fts5(docid, id, text) VALUES (old.rowid, old.id, old.text); END;
DROP TRIGGER IF EXISTS item_au AFTER UPDATE ON item;
CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN INSERT INTO item_fts5(rowid, id, text) VALUES (new.rowid, new.id, new.text); END;

DROP TRIGGER IF EXISTS item_ad AFTER INSERT ON item; -- no-op
-- plain backend: no search table

-- Search index for plain backend (no table)
CREATE TABLE item_fts_plain (id TEXT PRIMARY KEY, content TEXT NOT NULL);
