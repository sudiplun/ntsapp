-- =============================================================================
-- 0006_supabase_only.sql
-- Drop the external dependencies: Backblaze B2, RevenueCat and Firebase FCM.
--
-- Media bytes move from B2 to a private Supabase Storage bucket ("media");
-- subscriptions become a free default plan seeded at sign-up; push triggers
-- become Supabase Realtime events on a small sync_events table.
--
-- This file is additive: it keeps the old B2/RevenueCat columns and tables in
-- place (unused) so existing rows are not destroyed. Re-running it is safe.
--
-- Must run AFTER 0002 (files table + thmbs bucket pattern), 0003 (plans +
-- storage) and 0005 (handle_new_user).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. media bucket (private) — same layout as thmbs: "<userId>/<fileName>"
-- -----------------------------------------------------------------------------
-- Client (anon key, RLS) — lib/utils/utils_sync.dart:
--   storage.from('media').uploadBinary("<userId>/<fileName>", bytes, ...)
--   storage.from('media').download("<userId>/<fileName>")
--   storage.from('media').remove(["<userId>/<fileName>"])
--
-- Bytes are already end-to-end encrypted client-side (cryptoUtils.encryptFile),
-- so the bucket only ever holds ciphertext.
-- =============================================================================
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
  VALUES ('media', 'media', false)
  ON CONFLICT (id) DO NOTHING;

  DROP POLICY IF EXISTS "media_storage_select_own" ON storage.objects;
  CREATE POLICY "media_storage_select_own"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "media_storage_insert_own" ON storage.objects;
  CREATE POLICY "media_storage_insert_own"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "media_storage_update_own" ON storage.objects;
  CREATE POLICY "media_storage_update_own"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = auth.uid()::text
    )
    WITH CHECK (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );

  DROP POLICY IF EXISTS "media_storage_delete_own" ON storage.objects;
  CREATE POLICY "media_storage_delete_own"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = auth.uid()::text
    );
END $$;

-- -----------------------------------------------------------------------------
-- 2. files table — the client now writes its own rows (no Edge Function)
-- -----------------------------------------------------------------------------
-- The app inserts the row before uploading (uploaded_at = 0), updates it after
-- a successful upload, and deletes it when the file is removed. RLS already
-- has SELECT/UPDATE policies (0002); add INSERT and DELETE for the owner.
-- =============================================================================
GRANT INSERT, DELETE ON public.files TO authenticated;

DROP POLICY IF EXISTS "files_insert_own" ON public.files;
CREATE POLICY "files_insert_own"
  ON public.files FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "files_delete_own" ON public.files;
CREATE POLICY "files_delete_own"
  ON public.files FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 3. storage.b2_size meter — maintained from files.size by trigger
-- -----------------------------------------------------------------------------
-- Nothing wrote b2_size before (see 0003 ASSUMPTIONS); now the sum of the
-- user's files is kept in sync automatically, so the plan screen and the
-- storage-limit check in getUserPlanStatus keep working unchanged.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.update_storage_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
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
-- 4. sync_events — Realtime trigger for cross-device sync
-- -----------------------------------------------------------------------------
-- push_changes (service-role) inserts one row per push. Clients subscribe to
-- INSERTs on this table (Postgres Changes) and run fetch_changes when the
-- event comes from another device. No Firebase FCM needed.
--
-- RLS: authenticated users may SELECT their own rows only; inserts happen
-- service-role (RLS bypassed). No client INSERT/UPDATE/DELETE policies.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sync_events (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id  TEXT NOT NULL,                   -- device that caused the change
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Realtime fans out events per user; the app filters out its own device_id.
CREATE INDEX IF NOT EXISTS idx_sync_events_user_created
  ON public.sync_events (user_id, created_at);

GRANT SELECT ON public.sync_events TO authenticated;
GRANT ALL ON public.sync_events TO service_role;

ALTER TABLE public.sync_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sync_events_select_own" ON public.sync_events;
CREATE POLICY "sync_events_select_own"
  ON public.sync_events FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Realtime only publishes tables that are in the supabase_realtime publication.
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

-- -----------------------------------------------------------------------------
-- 5. default (free) plan — seeded at sign-up
-- -----------------------------------------------------------------------------
-- Every user gets 5 GB of media storage and 3 devices, never expiring. This
-- keeps getUserPlanStatus and the plan screen working without RevenueCat.
-- plans.rc_id is left NULL (multiple NULLs are allowed by UNIQUE).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Every user needs a usage row (getUserPlanStatus .single()).
  INSERT INTO public.storage (id)
  VALUES (new.id)
  ON CONFLICT (id) DO NOTHING;

  -- Profile row so pushProfileChange's UPDATE has something to update.
  INSERT INTO public.profiles (id, email, type, updated_at)
  VALUES (new.id, new.email, 0, (extract(epoch from now()) * 1000)::BIGINT)
  ON CONFLICT (id) DO NOTHING;

  -- Free default plan (5 GB / 3 devices / never expires).
  INSERT INTO public.plans (rc_id, user_id, b2_limit, expires_at, devices)
  VALUES (NULL, new.id, 5368709120, 9999999999999, 3);

  RETURN NEW;
END;
$$;

-- Backfill for users that signed up before this migration.
INSERT INTO public.plans (rc_id, user_id, b2_limit, expires_at, devices)
SELECT NULL, u.id, 5368709120, 9999999999999, 3
FROM auth.users u
WHERE NOT EXISTS (
  SELECT 1 FROM public.plans p WHERE p.user_id = u.id
);

-- -----------------------------------------------------------------------------
-- 6. drop the B2-only server cache
-- -----------------------------------------------------------------------------
-- authenticate_b2 (removed) was the only reader/writer of public.server.
-- =============================================================================
DROP TABLE IF EXISTS public.server;

-- =============================================================================
-- ASSUMPTIONS / VERIFY:
-- 1. The "media" bucket is private and capped at 50 MB per upload on the Free
--    plan (Pro: 500 GB). The app must reject larger files client-side.
-- 2. Realtime must be enabled for the project, and sync_events must be in the
--    supabase_realtime publication (handled above). On hosted Supabase you can
--    also toggle it in Dashboard -> Database -> Replication.
-- 3. files.parts is NOT NULL with no default: the app inserts parts = 1 for a
--    single-shot upload. b2_id / token / expires stay NULL and are unused.
-- 4. Existing files rows that point at B2 will no longer download (their bytes
--    are not in the media bucket). Irrelevant on a fresh project.
-- 5. plans.rc_id stays UNIQUE; the seeded rows all use NULL, which Postgres
--    treats as distinct, so there is no conflict.
-- =============================================================================
