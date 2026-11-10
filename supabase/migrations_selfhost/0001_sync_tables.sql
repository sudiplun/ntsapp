-- =============================================================================
-- 0001_sync_tables.sql
-- Core sync tables: category, itemgroup, item.
--
-- These three tables are the *server-side* representation of the app's local
-- SQLite tables (lib/storage/storage_sqlite.dart, initTables()). The app is
-- local-first: the encrypted row data lives in SQLite; the Postgres rows only
-- carry the crypto envelope plus sync bookkeeping.
--
-- WRITERS (all service-role, i.e. RLS is bypassed):
--   push_changes (supabase/functions/push_changes/index.ts) upserts the ENTIRE
--   change payload under the conflict target "id":
--
--     supabaseClient.from(table).upsert(change, { onConflict: "id" })
--       .eq("id", id).eq("user_id", user_id).lt("updated_at", updated_at)
--
--   The `change` payload is built in lib/utils/utils_sync.dart,
--   encryptAndChange() (~line 340) and contains EXACTLY these columns:
--     id           "<userId>|<rowId>"
--     user_id      auth user uuid (string)
--     updated_at   epoch-ms INTEGER (last-writer-wins, see .lt() filter)
--     device_id    client device uuid
--     cipher_text  base64 libsodium cipher of the whole local row JSON
--     cipher_nonce base64
--     key_cipher   base64 (row key encrypted with the user master key)
--     key_nonce    base64
--
-- READERS:
--   * fetch_changes (supabase/functions/fetch_changes/index.ts, service-role):
--       .select("id,cipher_text,cipher_nonce,key_cipher,key_nonce")
--       .eq("user_id", userId)
--       .neq("device_id", deviceId)
--       .gt("server_at", lastAt)
--     `lastAt` is an ISO-8601 UTC string produced by nowUtcInISO()
--     (lib/utils/common.dart:213, "YYYY-MM-DD HH:MM:SS.sss+00"), so
--     server_at MUST be a timestamptz, not a bigint.
--   * No client (anon-key) code reads these tables directly — the app only
--     ever talks to them through the two Edge Functions above. The SELECT
--     policies below are granted to authenticated so the owner can inspect
--     their rows in Studio; they are not required for the app to work.
--
-- server_at maintenance:
--   push_changes never sends server_at, so it is set by DEFAULT on insert
--   and by a BEFORE UPDATE trigger on every row update. The upsert filter
--   (existing.updated_at < incoming.updated_at) guarantees an update only
--   happens for genuinely newer data, so "any update" == "new change".
-- =============================================================================

-- Shared trigger function: stamp server_at = now() on row update.
CREATE OR REPLACE FUNCTION public.touch_server_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.server_at := now();
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- category
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.category (
  id           TEXT PRIMARY KEY,             -- "<userId>|<categoryId>"
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id    TEXT,                         -- device uuid that last pushed it
  updated_at   BIGINT NOT NULL DEFAULT 0,    -- epoch ms, optimistic-concurrency key
  cipher_text  TEXT NOT NULL,                -- base64 libsodium ciphertext
  cipher_nonce TEXT NOT NULL,                -- base64
  key_cipher   TEXT NOT NULL,                -- base64 (row key, enc. w/ master key)
  key_nonce    TEXT NOT NULL,                -- base64
  server_at    TIMESTAMPTZ NOT NULL DEFAULT now()  -- last change time on server
);

-- fetch_changes: WHERE user_id = ? AND device_id <> ? AND server_at > ?
CREATE INDEX IF NOT EXISTS idx_category_user_server_at
  ON public.category (user_id, server_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.category TO service_role;
GRANT SELECT ON public.category TO authenticated;
-- NOTE: anon intentionally has no access (all client reads go via Edge Functions).

ALTER TABLE public.category ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "category_select_own" ON public.category;
CREATE POLICY "category_select_own"
  ON public.category FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Only the Edge Function (service-role) writes; bump server_at on every update.
DROP TRIGGER IF EXISTS category_touch_server_at ON public.category;
CREATE TRIGGER category_touch_server_at
  BEFORE UPDATE ON public.category
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_server_at();

-- -----------------------------------------------------------------------------
-- itemgroup
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.itemgroup (
  id           TEXT PRIMARY KEY,             -- "<userId>|<groupId>"
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id    TEXT,
  updated_at   BIGINT NOT NULL DEFAULT 0,
  cipher_text  TEXT NOT NULL,
  cipher_nonce TEXT NOT NULL,
  key_cipher   TEXT NOT NULL,
  key_nonce    TEXT NOT NULL,
  server_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_itemgroup_user_server_at
  ON public.itemgroup (user_id, server_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.itemgroup TO service_role;
GRANT SELECT ON public.itemgroup TO authenticated;

ALTER TABLE public.itemgroup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "itemgroup_select_own" ON public.itemgroup;
CREATE POLICY "itemgroup_select_own"
  ON public.itemgroup FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP TRIGGER IF EXISTS itemgroup_touch_server_at ON public.itemgroup;
CREATE TRIGGER itemgroup_touch_server_at
  BEFORE UPDATE ON public.itemgroup
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_server_at();

-- -----------------------------------------------------------------------------
-- item
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.item (
  id           TEXT PRIMARY KEY,             -- "<userId>|<itemId>"
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id    TEXT,
  updated_at   BIGINT NOT NULL DEFAULT 0,
  cipher_text  TEXT NOT NULL,
  cipher_nonce TEXT NOT NULL,
  key_cipher   TEXT NOT NULL,
  key_nonce    TEXT NOT NULL,
  server_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_item_user_server_at
  ON public.item (user_id, server_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.item TO service_role;
GRANT SELECT ON public.item TO authenticated;

ALTER TABLE public.item ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "item_select_own" ON public.item;
CREATE POLICY "item_select_own"
  ON public.item FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP TRIGGER IF EXISTS item_touch_server_at ON public.item;
CREATE TRIGGER item_touch_server_at
  BEFORE UPDATE ON public.item
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_server_at();

-- =============================================================================
-- ASSUMPTIONS / VERIFY:
-- 1. No FKs between category/itemgroup/item on purpose: the upsert payload is
--    the encrypted envelope only (category_id/group_id live INSIDE the
--    ciphertext), and a group may be pushed before its category. The local
--    SQLite schema (storage_sqlite.dart initTables) does enforce those FKs.
-- 2. server_at is TIMESTAMPTZ because fetch_changes compares it against an
--    ISO-8601 string (lib/utils/utils_sync.dart fetchMapChanges,
--    default "2011-11-11 11:11:11.111111+00" and nowUtcInISO() output).
--    If your production database actually stores it differently, verify with:
--      SELECT data_type FROM information_schema.columns
--      WHERE table_name IN ('category','itemgroup','item');
-- 3. cipher_* are NOT NULL because getEncryptedBytesMap (lib/utils/utils_crypto.dart:196)
--    always emits all four fields, and the decrypt path
--    (utils_crypto.dart getDecryptedBytesFromMap) dereferences them blindly.
-- 4. updated_at is epoch MILLISECONDS (lib/storage/storage_sqlite.dart seed
--    inserts use DateTime.now().toUtc().millisecondsSinceEpoch).
-- =============================================================================
