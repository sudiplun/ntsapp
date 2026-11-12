-- =============================================================================
-- 0001_core_tables.sql
-- Core sync tables: category, itemgroup, item.
--
-- These three tables are the *server-side* representation of the app's local
-- SQLite tables (lib/storage/storage_sqlite.dart, initTables()). They are
-- written EXCLUSIVELY by the `push_changes` Edge Function via the service-role
-- key (supabase/functions/push_changes/index.ts), which upserts the ENTIRE
-- encrypted local row under the conflict target `id`:
--
--   supabaseClient.from(table).upsert(change, { onConflict: "id" })
--     .eq("id", id).eq("user_id", user_id).lt("updated_at", updated_at)
--
-- The `change` payload sent from the app (lib/utils/utils_sync.dart,
-- encryptAndPushChange + Model*.toMap) contains, for every row:
--   id, user_id, device_id, updated_at
--   + cipher_text, cipher_nonce, key_cipher, key_nonce  (libsodium output)
--   + the full plaintext row fields:
--       category : id, profile_id, title, thumbnail(0|1), color, state,
--                  position, archived_at, at, updated_at, deleted
--       itemgroup: id, category_id, title, thumbnail, pinned, position,
--                  archived_at, color, state, data, at, updated_at, deleted
--       item     : id, group_id, text, thumbnail, starred, pinned,
--                  archived_at, type, state, data, at, updated_at, deleted
--
-- Note: the app stores timestamps as INTEGER epoch-ms and booleans as 0/1
-- (e.g. `starred` in lib/models/model_item.dart), so we use BIGINT / SMALLINT.
-- `text` is TEXT NOT NULL because push_changes upserts every item row and the
-- client always sends `text` (possibly NULL) - we keep it nullable to accept
-- any value the client sends, mirroring the local schema.
--
-- RLS strategy: rows are written by service-role (bypasses RLS). The client
-- (anon key) reads category/itemgroup/item ONLY inside `fetch_changes`
-- (service-role), so a per-user SELECT policy on its own rows is sufficient
-- for the app to work; it also lets the owner inspect rows in the SQL editor.
-- No INSERT/UPDATE/DELETE policy is granted to the client, because the app
-- never writes to these tables directly.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- category
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.category (
  id             TEXT PRIMARY KEY,
  user_id        UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id      TEXT,
  updated_at     BIGINT NOT NULL DEFAULT 0,
  profile_id     TEXT,
  title          TEXT NOT NULL,
  thumbnail      SMALLINT,                       -- 0 or 1 flag set by client
  color          TEXT,
  state          SMALLINT,
  position       INTEGER,
  archived_at    BIGINT,
  at             BIGINT,
  cipher_text    TEXT,
  cipher_nonce   TEXT,
  key_cipher     TEXT,
  key_nonce      TEXT
);

-- fetch_changes: .eq("user_id").neq("device_id").gt("server_at", lastAt)
CREATE INDEX IF NOT EXISTS idx_category_user_server_at
  ON public.category (user_id, updated_at);

ALTER TABLE public.category ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "category_select_own" ON public.category;
CREATE POLICY "category_select_own"
  ON public.category FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- itemgroup
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.itemgroup (
  id             TEXT PRIMARY KEY,
  user_id        UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id      TEXT,
  updated_at     BIGINT NOT NULL DEFAULT 0,
  category_id    TEXT NOT NULL,
  title          TEXT NOT NULL,
  thumbnail      SMALLINT,
  pinned         SMALLINT,
  position       INTEGER,
  archived_at    BIGINT,
  color          TEXT,
  state          SMALLINT,
  data           TEXT,
  at             BIGINT,
  cipher_text    TEXT,
  cipher_nonce   TEXT,
  key_cipher     TEXT,
  key_nonce      TEXT
);

CREATE INDEX IF NOT EXISTS idx_itemgroup_user_server_at
  ON public.itemgroup (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_itemgroup_category
  ON public.itemgroup (category_id);

ALTER TABLE public.itemgroup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "itemgroup_select_own" ON public.itemgroup;
CREATE POLICY "itemgroup_select_own"
  ON public.itemgroup FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- item
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.item (
  id             TEXT PRIMARY KEY,
  user_id        UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id      TEXT,
  updated_at     BIGINT NOT NULL DEFAULT 0,
  group_id       TEXT NOT NULL,
  text           TEXT,
  thumbnail      SMALLINT,
  starred        SMALLINT,
  pinned         SMALLINT,
  archived_at    BIGINT,
  type           SMALLINT,
  state          SMALLINT,
  data           TEXT,
  at             BIGINT,
  cipher_text    TEXT,
  cipher_nonce   TEXT,
  key_cipher     TEXT,
  key_nonce      TEXT
);

CREATE INDEX IF NOT EXISTS idx_item_user_server_at
  ON public.item (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_item_group
  ON public.item (group_id);

ALTER TABLE public.item ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "item_select_own" ON public.item;
CREATE POLICY "item_select_own"
  ON public.item FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());
