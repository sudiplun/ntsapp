-- =============================================================================
-- 0002_files_thumbnails.sql
-- Media-file bookkeeping (files), thumbnail key rows (thmbs) and the private
-- "thmbs" Supabase Storage bucket that holds the encrypted thumbnail bytes.
--
-- -----------------------------------------------------------------------------
-- files
-- -----------------------------------------------------------------------------
-- Server-side media registry. id = "<userId>|<fileName>" everywhere.
--
-- WRITERS (service-role):
--   _shared/supabase.ts setFileEntry        INSERT {id,user_id,key_cipher,key_nonce,parts,size}
--                                           (SELECT first; only inserts if missing)
--   _shared/supabase.ts setFileUploaded     UPDATE parts_uploaded,uploaded_at
--                                           WHERE id AND uploaded_at < now
--   _shared/supabase.ts setB2FileId         UPDATE b2_id WHERE id AND b2_id IS NULL
--   _shared/supabase.ts setDownloadToken    UPDATE token,expires WHERE id
--   _shared/supabase.ts deleteFileEntry     DELETE WHERE id
--   (called from start_parts_upload / finish_parts_upload / get_download_url /
--    delete_file Edge Functions)
--
-- CLIENT (anon key, RLS applies) — lib/utils/utils_sync.dart:
--   :940  SELECT *            WHERE id = "<userId>|<fileName>"   (checkPushFile)
--   :1045 SELECT *            WHERE id = ...                     (pushFile)
--   :882  UPDATE uploaded_at, parts_uploaded, b2_id
--         WHERE id AND uploaded_at < X                           (pushFiles)
--   :1062 UPDATE parts_uploaded  WHERE id AND parts_uploaded < N (pushFile)
--   :1086 UPDATE b2_id           WHERE id AND b2_id IS NULL      (pushFile)
--
-- READERS (service-role):
--   get_download_url reads uploaded_at, token, expires, key_cipher, key_nonce.
--
-- NOTE: this is a DIFFERENT table from the app's local SQLite "files" table
-- (lib/storage/storage_sqlite.dart). The local one has change_id + path
-- columns and an FK into the local change table; the server one has user_id,
-- token and expires and no FKs.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id             TEXT PRIMARY KEY,           -- "<userId>|<fileName>"
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  key_cipher     TEXT NOT NULL,              -- file key encrypted with master key (b64)
  key_nonce      TEXT NOT NULL,              -- b64
  parts          INTEGER NOT NULL,           -- total part count (1 for small files)
  size           BIGINT NOT NULL,            -- encrypted file size in bytes
  parts_uploaded INTEGER NOT NULL DEFAULT 0, -- parts confirmed uploaded so far
  uploaded_at    BIGINT NOT NULL DEFAULT 0,  -- 0 = not fully uploaded; else epoch ms
  b2_id          TEXT,                       -- Backblaze B2 file id (large files)
  token          TEXT,                       -- cached B2 download authorization token
  expires        BIGINT                      -- download token expiry, epoch ms
);

-- Client always looks up by id (PK); user_id index serves RLS + user cascade.
CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.files TO service_role;
GRANT SELECT, UPDATE ON public.files TO authenticated;
-- Client never INSERTs (setFileEntry does) nor DELETEs (delete_file does).

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "files_select_own" ON public.files;
CREATE POLICY "files_select_own"
  ON public.files FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "files_update_own" ON public.files;
CREATE POLICY "files_update_own"
  ON public.files FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- thmbs (table)
-- -----------------------------------------------------------------------------
-- Per-row encrypted-thumbnail key material. The binary thumbnail itself goes
-- to the "thmbs" Storage bucket at path "<userId>/<rowId>"; this table stores
-- the libsodium keys needed to decrypt it.
--
-- id = changeId = "<userId>|<rowId>" (rowId = category/group/item uuid).
--
-- CLIENT (anon key, RLS applies) — lib/utils/utils_sync.dart:
--   :548  UPSERT {id, cipher_nonce, key_cipher, key_nonce} ON CONFLICT id
--         (pushThumbnail: after uploading bytes to the bucket)
--   :794  SELECT cipher_nonce,key_cipher,key_nonce WHERE id = changeId
--         (fetchThumbnails)
--   :481  DELETE WHERE id = changeId            (deleteThumbnails)
--
-- No service-role code touches this table, so a client upsert needs BOTH an
-- INSERT policy and an UPDATE policy (PostgREST upsert = INSERT ... ON
-- CONFLICT DO UPDATE).
--
-- Ownership check: the table has no user_id column; the user uuid is the
-- prefix of id before the "|" separator.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.thmbs (
  id           TEXT PRIMARY KEY,             -- "<userId>|<rowId>"
  cipher_nonce TEXT NOT NULL,                -- b64
  key_cipher   TEXT NOT NULL,                -- b64 (row key, enc. w/ master key)
  key_nonce    TEXT NOT NULL                 -- b64
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.thmbs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.thmbs TO service_role;

ALTER TABLE public.thmbs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "thmbs_select_own" ON public.thmbs;
CREATE POLICY "thmbs_select_own"
  ON public.thmbs FOR SELECT
  TO authenticated
  USING (id LIKE auth.uid()::text || '|%');

DROP POLICY IF EXISTS "thmbs_insert_own" ON public.thmbs;
CREATE POLICY "thmbs_insert_own"
  ON public.thmbs FOR INSERT
  TO authenticated
  WITH CHECK (id LIKE auth.uid()::text || '|%');

DROP POLICY IF EXISTS "thmbs_update_own" ON public.thmbs;
CREATE POLICY "thmbs_update_own"
  ON public.thmbs FOR UPDATE
  TO authenticated
  USING (id LIKE auth.uid()::text || '|%')
  WITH CHECK (id LIKE auth.uid()::text || '|%');

DROP POLICY IF EXISTS "thmbs_delete_own" ON public.thmbs;
CREATE POLICY "thmbs_delete_own"
  ON public.thmbs FOR DELETE
  TO authenticated
  USING (id LIKE auth.uid()::text || '|%');

-- -----------------------------------------------------------------------------
-- thmbs (Supabase Storage bucket)
-- -----------------------------------------------------------------------------
-- Client code (lib/utils/utils_sync.dart):
--   :480  storage.from('thmbs').remove(["<userId>/<rowId>"])
--   :532  storage.from('thmbs').uploadBinary("<userId>/<rowId>", bytes,
--           FileOptions(cacheControl: '900', upsert: true))
--   :790  storage.from('thmbs').download("<userId>/<rowId>")
--
-- A new Supabase project already ships per-user storage policies on
-- storage.objects keyed on the TOP-LEVEL FOLDER (storage.foldername(name)[1]
-- = auth.uid()), which matches the "<userId>/<rowId>" layout exactly. The
-- bucket must still be created (private), and the explicit policies below are
-- added so the app works even on installs whose default policies differ.
--
-- storage.objects is created by the Supabase Storage service at project
-- startup (not by the database init scripts), so guard for it the same way
-- Supabase's own migrations do.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage' AND c.relname = 'objects'
  ) THEN
    RAISE EXCEPTION
      'storage.objects not found - run this file after the Storage service has initialized (or re-run it later)';
  END IF;

  INSERT INTO storage.buckets (id, name, public)
  VALUES ('thmbs', 'thmbs', false)
  ON CONFLICT (id) DO NOTHING;

  DROP POLICY IF EXISTS "thmbs_storage_select_own" ON storage.objects;
  CREATE POLICY "thmbs_storage_select_own"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'thmbs'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "thmbs_storage_insert_own" ON storage.objects;
  CREATE POLICY "thmbs_storage_insert_own"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'thmbs'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "thmbs_storage_update_own" ON storage.objects;
  CREATE POLICY "thmbs_storage_update_own"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'thmbs'
      AND (storage.foldername(name))[1] = auth.uid()::text
    )
    WITH CHECK (
      bucket_id = 'thmbs'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "thmbs_storage_delete_own" ON storage.objects;
  CREATE POLICY "thmbs_storage_delete_own"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'thmbs'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );
END $$;

-- =============================================================================
-- ASSUMPTIONS / VERIFY:
-- 1. files.token / files.expires are written ONLY by the get_download_url
--    Edge Function (setDownloadToken, supabase/functions/_shared/supabase.ts)
--    and read by it to avoid re-minting a B2 download authorization.
-- 2. The production schema dump (supabase/01_init.sql) shows a thmbs table
--    with extra legacy columns (file_id, path, user_file_id). No code path in
--    the repo reads or writes them, so they are omitted here; add them back
--    only if you must migrate data from the hosted project.
-- 3. Storage bucket max file size defaults to 50 MiB (supabase/config.toml).
--    Encrypted thumbnails are small; media files go to B2, not this bucket.
-- 4. thmbs rows are only ever addressed by id, and id embeds the user uuid,
--    so the "LIKE '<uid>|%'" policies are per-user (rowId is a uuid v4 and
--    contains no '|').
-- =============================================================================
