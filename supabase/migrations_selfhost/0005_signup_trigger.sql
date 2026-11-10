-- =============================================================================
-- 0005_signup_trigger.sql
-- Seed per-user rows when a new auth user is created.
--
-- WHY THIS IS REQUIRED (not optional):
--
-- 1. storage: _shared/supabase.ts getUserPlanStatus() runs
--      SELECT b2_size WHERE id = <uid>  .single()
--    on EVERY sync call (push_changes, fetch_changes, all B2 functions), and
--    .single() raises PGRST116 when zero rows match. The app's own plan screen
--    (lib/ui/pages/page_plan_status.dart:99) does the same. Nothing in the app
--    INSERTs into storage, so the row must be created here at sign-up or the
--    user's first sync fails with "Failed to fetch storage".
--
-- 2. profiles: no code path INSERTs profiles rows (only the client UPDATE in
--    utils_sync.dart pushProfileChange and the commented-out fetch at
--    utils_sync.dart:598). Seeding email/id at sign-up matches what the local
--    app does (lib/ui/pages/page_user_task.dart registerDevice ->
--    ModelProfile.fromMap({"id": userId, "email": user.email!})).
--
-- The app signs in with email OTP (lib/ui/pages/page_signin.dart:75
-- signInWithOtp / verifyOTP OtpType.email), so auth.users rows are created
-- for any new email on first OTP verification.
--
-- Must run AFTER 0003_account_tables.sql (storage, profiles).
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

  RETURN NEW;
END;
$$;

-- Harden: the SQL `public` pseudo-role grants EXECUTE by default on new
-- functions; revoke so users cannot call it directly via PostgRPC/SQL editor.
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- =============================================================================
-- ASSUMPTIONS / VERIFY:
-- 1. If you import EXISTING auth.users from the hosted project (e.g. via
--    pg_dump of the auth schema), run once more for backfill:
--      INSERT INTO public.storage (id)
--      SELECT id FROM auth.users
--      ON CONFLICT (id) DO NOTHING;
--      INSERT INTO public.profiles (id, email, type, updated_at)
--      SELECT id, email, 0, (extract(epoch from now()) * 1000)::BIGINT
--      FROM auth.users
--      ON CONFLICT (id) DO NOTHING;
-- 2. Supabase's own default trigger (if your project image created one) would
--    conflict by name — the DROP TRIGGER IF EXISTS above handles that.
-- =============================================================================
