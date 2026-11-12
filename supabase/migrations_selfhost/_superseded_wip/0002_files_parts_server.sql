-- =============================================================================
-- 0002_files_parts_server.sql
-- Media-file bookkeeping + per-user B2 usage + service token cache.
--
-- `files` is written by:
--   * start_parts_upload / _shared setFileEntry (service-role INSERT,
--     columns: id, user_id, key_cipher, key_nonce, parts, size)
--   * finish_parts_upload / _shared setFileUploaded (UPDATE parts_uploaded,
--     uploaded_at)
--   * _shared setB2FileId (UPDATE b2_id WHERE b2_id IS NULL)
--   * _shared setDownloadToken (UPDATE token, expires)
--   * delete_file / _shared deleteFileEntry (DELETE)
-- and READ/WRITE from the client with the anon key (lib/utils/utils_sync.dart):
--   .from("files").select().eq("id", ...)                       (checkPushFile/pushFile)
--   .from("files").update({"uploaded_at","parts_uploaded","b2_id"})
--       .eq("id").lt("uploaded_at", uploadedAt)                  (pushFiles)
--   .from("files").update({"parts_uploaded"}).eq("id").lt("parts_uploaded", n)
--   .from("files").update({"b2_id"}).eq("id").is("b2_id", null)
--
-- `storage` is a per-user usage meter (one row per user, id = user uuid):
--   * client READ (anon key): lib/ui/pages/page_plan_status.dart
--       .from("storage").select("b2_size").eq("id", userId).single()
--       and _shared/getUserPlanStatus (service-role) reads the same.
--   * NOTE: no code in this repository writes b2_size. It must be maintained
--     by your B2 webhook pipeline (webhook_b2 currently only logs the payload
--     and returns 200). See ASSUMPTIONS below.
--
-- `server` is a key/value service cache used by authenticateB2
-- (supabase/functions/_shared/backblaze.ts) to store the shared Backblaze
-- account auth token. It is only ever accessed with the service-role key, so
-- it should have NO policies for anon/authenticated. It MUST contain the
-- seed row (key='b2_account_token', state=0) for the token refresh logic to
-- work.
--
-- `parts` exists only in the local SQLite DB (lib/storage/storage_sqlite.dart)
-- and is never queried from Postgres by either the app or the Edge Functions
-- (ModelPart.shasForFileId reads the local DB). It is created here for
-- completeness/parity; you may drop it if you want a minimal schema.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- files
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id             TEXT PRIMARY KEY,          -- "<userId>|<fileName>"
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  key_cipher     TEXT NOT NULL,             -- file key encrypted with master key
  key_nonce      TEXT NOT NULL,
  parts          INTEGER NOT NULL,
  size           BIGINT NOT NULL,
  parts_uploaded INTEGER NOT NULL DEFAULT 0,
  uploaded_at    BIGINT NOT NULL DEFAULT 0, -- 0 => not fully uploaded yet
  b2_id          TEXT,
  token          TEXT,                      -- B2 download authorization token
  expires        BIGINT                     -- download token expiry (ms)
);

CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

-- The client only ever targets its own rows (id always begins with "<userId>|").
DROP POLICY IF EXISTS "files_select_own" ON public.files;
CREATE POLICY "files_select_own"
  ON public.files FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "files_insert_own" ON public.files;
CREATE POLICY "files_insert_own"
  ON public.files FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "files_update_own" ON public.files;
CREATE POLICY "files_update_own"
  ON public.files FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "files_delete_own" ON public.files;
CREATE POLICY "files_delete_own"
  ON public.files FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- parts (local-only parity table; optional)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.parts (
  id          TEXT PRIMARY KEY,             -- sha1 of the part
  file_id     TEXT NOT NULL REFERENCES public.files(id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL
);

ALTER TABLE public.parts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "parts_select_own" ON public.parts;
CREATE POLICY "parts_select_own"
  ON public.parts FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.files f
                 WHERE f.id = parts.file_id AND f.user_id = auth.uid()));

-- -----------------------------------------------------------------------------
-- storage (per-user B2 usage meter)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.storage (
  id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  b2_size BIGINT NOT NULL DEFAULT 0         -- bytes currently stored in B2
);

ALTER TABLE public.storage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "storage_select_own" ON public.storage;
CREATE POLICY "storage_select_own"
  ON public.storage FOR SELECT
  TO authenticated
  USING (id = auth.uid());
-- INSERT/UPDATE are done by service-role (see assumptions about maintenance).

-- -----------------------------------------------------------------------------
-- server (service-role key/value cache; holds the B2 account token)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server (
  key   TEXT PRIMARY KEY,
  value TEXT,
  state INTEGER NOT NULL DEFAULT 0          -- 1 => token refresh in progress
);

ALTER TABLE public.server ENABLE ROW LEVEL SECURITY;
-- No policies: only service-role may touch this table.
-- (Enabling RLS with zero policies denies anon/authenticated access,
-- which is exactly what we want.)

INSERT INTO public.server (key, value, state)
VALUES ('b2_account_token', NULL, 0)
ON CONFLICT (key) DO NOTHING;
