-- =============================================================================
-- media_and_sync_setup.sql
-- Consolidated, idempotent setup script for Supabase Storage & Media Sync.
-- Run this in the Supabase Dashboard SQL Editor for your project.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Storage Buckets (media & thmbs)
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('media', 'media', false, 52428800)
ON CONFLICT (id) DO UPDATE SET public = false;

INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('thmbs', 'thmbs', false, 52428800)
ON CONFLICT (id) DO UPDATE SET public = false;

-- -----------------------------------------------------------------------------
-- 2. Storage Objects Policies ('media')
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "media_storage_select_own" ON storage.objects;
CREATE POLICY "media_storage_select_own"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "media_storage_insert_own" ON storage.objects;
CREATE POLICY "media_storage_insert_own"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "media_storage_update_own" ON storage.objects;
CREATE POLICY "media_storage_update_own"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  )
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "media_storage_delete_own" ON storage.objects;
CREATE POLICY "media_storage_delete_own"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

-- -----------------------------------------------------------------------------
-- 3. Storage Objects Policies ('thmbs')
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "thmbs_storage_select_own" ON storage.objects;
CREATE POLICY "thmbs_storage_select_own"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'thmbs'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "thmbs_storage_insert_own" ON storage.objects;
CREATE POLICY "thmbs_storage_insert_own"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'thmbs'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "thmbs_storage_update_own" ON storage.objects;
CREATE POLICY "thmbs_storage_update_own"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'thmbs'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  )
  WITH CHECK (
    bucket_id = 'thmbs'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

DROP POLICY IF EXISTS "thmbs_storage_delete_own" ON storage.objects;
CREATE POLICY "thmbs_storage_delete_own"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'thmbs'
    AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
  );

-- -----------------------------------------------------------------------------
-- 4. Thumbnails Key Table (public.thmbs)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.thmbs (
  id           TEXT PRIMARY KEY,             -- "<userId>|<rowId>"
  cipher_nonce TEXT NOT NULL,
  key_cipher   TEXT NOT NULL,
  key_nonce    TEXT NOT NULL
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.thmbs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.thmbs TO service_role;

ALTER TABLE public.thmbs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "thmbs_select_own" ON public.thmbs;
CREATE POLICY "thmbs_select_own"
  ON public.thmbs FOR SELECT
  TO authenticated
  USING (id LIKE (SELECT auth.uid()::text) || '|%');

DROP POLICY IF EXISTS "thmbs_insert_own" ON public.thmbs;
CREATE POLICY "thmbs_insert_own"
  ON public.thmbs FOR INSERT
  TO authenticated
  WITH CHECK (id LIKE (SELECT auth.uid()::text) || '|%');

DROP POLICY IF EXISTS "thmbs_update_own" ON public.thmbs;
CREATE POLICY "thmbs_update_own"
  ON public.thmbs FOR UPDATE
  TO authenticated
  USING (id LIKE (SELECT auth.uid()::text) || '|%')
  WITH CHECK (id LIKE (SELECT auth.uid()::text) || '|%');

DROP POLICY IF EXISTS "thmbs_delete_own" ON public.thmbs;
CREATE POLICY "thmbs_delete_own"
  ON public.thmbs FOR DELETE
  TO authenticated
  USING (id LIKE (SELECT auth.uid()::text) || '|%');

-- -----------------------------------------------------------------------------
-- 5. Files Metadata Table (public.files)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id             TEXT PRIMARY KEY,           -- "<userId>|<fileName>"
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  key_cipher     TEXT NOT NULL,
  key_nonce      TEXT NOT NULL,
  parts          INTEGER NOT NULL,
  size           BIGINT NOT NULL,
  parts_uploaded INTEGER NOT NULL DEFAULT 0,
  uploaded_at    BIGINT NOT NULL DEFAULT 0,
  b2_id          TEXT,
  token          TEXT,
  expires        BIGINT
);

CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.files TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.files TO service_role;

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "files_select_own" ON public.files;
CREATE POLICY "files_select_own"
  ON public.files FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "files_insert_own" ON public.files;
CREATE POLICY "files_insert_own"
  ON public.files FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "files_update_own" ON public.files;
CREATE POLICY "files_update_own"
  ON public.files FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "files_delete_own" ON public.files;
CREATE POLICY "files_delete_own"
  ON public.files FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- -----------------------------------------------------------------------------
-- 6. Storage Meter (public.storage) and Usage Sync Trigger
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.storage (
  id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  b2_size BIGINT NOT NULL DEFAULT 0
);

GRANT ALL ON public.storage TO service_role;
GRANT SELECT ON public.storage TO authenticated;

ALTER TABLE public.storage ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "storage_select_own" ON public.storage;
CREATE POLICY "storage_select_own"
  ON public.storage FOR SELECT
  TO authenticated
  USING (id = (SELECT auth.uid()));

-- Backfill storage rows for existing users
INSERT INTO public.storage (id, b2_size)
SELECT id, 0 FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- Function & Trigger to update b2_size automatically on files change
CREATE OR REPLACE FUNCTION public.update_storage_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  uid UUID;
  total BIGINT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    uid := OLD.user_id;
  ELSE
    uid := NEW.user_id;
  END IF;

  SELECT COALESCE(SUM(size), 0) INTO total
  FROM public.files
  WHERE user_id = uid;

  INSERT INTO public.storage (id, b2_size)
  VALUES (uid, total)
  ON CONFLICT (id) DO UPDATE SET b2_size = EXCLUDED.b2_size;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS files_update_storage_usage ON public.files;
CREATE TRIGGER files_update_storage_usage
  AFTER INSERT OR UPDATE OR DELETE ON public.files
  FOR EACH ROW
  EXECUTE FUNCTION public.update_storage_usage();

-- -----------------------------------------------------------------------------
-- 7. Plans (public.plans) & Profiles (public.profiles)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plans (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rc_id      TEXT UNIQUE,
  user_id    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  b2_limit   BIGINT NOT NULL DEFAULT 0,
  expires_at BIGINT NOT NULL DEFAULT 0,
  devices    INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_plans_user_expires
  ON public.plans (user_id, expires_at DESC);

GRANT ALL ON public.plans TO service_role;
GRANT SELECT ON public.plans TO authenticated;

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "plans_select_own" ON public.plans;
CREATE POLICY "plans_select_own"
  ON public.plans FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Backfill free default plan (5 GB, 3 devices, non-expiring) for existing users
INSERT INTO public.plans (rc_id, user_id, b2_limit, expires_at, devices)
SELECT NULL, u.id, 5368709120, 9999999999999, 3
FROM auth.users u
WHERE NOT EXISTS (
  SELECT 1 FROM public.plans p WHERE p.user_id = u.id
);

-- Profiles table
CREATE TABLE IF NOT EXISTS public.profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT,
  username   TEXT,
  url        TEXT,
  thumbnail  TEXT,
  type       INTEGER,
  updated_at BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
  at         BIGINT
);

GRANT ALL ON public.profiles TO service_role;
GRANT SELECT, UPDATE ON public.profiles TO authenticated;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));

INSERT INTO public.profiles (id, email, type, updated_at)
SELECT u.id, u.email, 0, (extract(epoch from now()) * 1000)::BIGINT
FROM auth.users u
ON CONFLICT (id) DO NOTHING;

-- Signup trigger for future users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.storage (id)
  VALUES (new.id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, email, type, updated_at)
  VALUES (new.id, new.email, 0, (extract(epoch from now()) * 1000)::BIGINT)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.plans (rc_id, user_id, b2_limit, expires_at, devices)
  VALUES (NULL, new.id, 5368709120, 9999999999999, 3);

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. Realtime Cross-Device Sync Events (public.sync_events)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sync_events (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id  TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_events_user_created
  ON public.sync_events (user_id, created_at);

GRANT SELECT ON public.sync_events TO authenticated;
GRANT ALL ON public.sync_events TO service_role;

ALTER TABLE public.sync_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sync_events_select_own" ON public.sync_events;
CREATE POLICY "sync_events_select_own"
  ON public.sync_events FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'sync_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.sync_events;
  END IF;
END $$;
