-- =============================================================================
-- 0003_account_tables.sql
-- Subscription plans, encryption key material, registered devices, profiles
-- and the per-user B2 usage meter.
--
-- -----------------------------------------------------------------------------
-- plans
-- -----------------------------------------------------------------------------
-- WRITERS (service-role):
--   webhook_rc (supabase/functions/webhook_rc/index.ts) — RevenueCat webhook:
--     .from("plans").upsert(
--        {rc_id, expires_at, b2_limit, devices},
--        { onConflict: "rc_id" })
--     => rc_id MUST be UNIQUE. user_id is NOT in the payload, so an already
--        claimed row keeps its user on renewal.
--   set_id_rc (supabase/functions/set_id_rc/index.ts) — claims a plan row:
--     SELECT user_id WHERE rc_id = ? (single())
--     UPDATE user_id = <auth uid> WHERE rc_id = ?   (only when user_id IS NULL)
--   _shared/supabase.ts getUserPlanStatus — every sync call checks the plan:
--     SELECT b2_limit,expires_at,devices WHERE user_id = ?
--       ORDER BY expires_at DESC LIMIT 1 (maybeSingle())
--     => user NEEDS AT LEAST ONE ROW, else every sync 400s with
--        "Failed to fetch plan".
--
-- CLIENT (anon key) — lib/ui/pages/page_plan_status.dart:105 and
-- lib/ui/pages/page_user_task.dart:132:
--   SELECT b2_limit,expires_at / expires_at,rc_id
--   WHERE user_id = <uid> ORDER BY expires_at DESC LIMIT 1 (maybeSingle())
--
-- expires_at is epoch MILLISECONDS (compared against new Date().getTime()
-- in the Edge Function and DateTime.now().toUtc().millisecondsSinceEpoch in
-- the app). b2_limit is bytes.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plans (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rc_id      TEXT UNIQUE,                    -- RevenueCat original_app_user_id
  user_id    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  b2_limit   BIGINT NOT NULL DEFAULT 0,      -- bytes
  expires_at BIGINT NOT NULL DEFAULT 0,      -- epoch ms
  devices    INTEGER NOT NULL DEFAULT 1      -- max active devices
);

-- "latest plan per user" is the hottest query (every sync + plan screens).
CREATE INDEX IF NOT EXISTS idx_plans_user_expires
  ON public.plans (user_id, expires_at DESC);

GRANT ALL ON public.plans TO service_role;
GRANT SELECT ON public.plans TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.plans_id_seq TO service_role;
-- No client INSERT/UPDATE: rows arrive via webhook_rc / set_id_rc.

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "plans_select_own" ON public.plans;
CREATE POLICY "plans_select_own"
  ON public.plans FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- keys
-- -----------------------------------------------------------------------------
-- Per-user encrypted master key (E2E: server stores only the ciphertext).
--
-- WRITER (CLIENT, anon key) — lib/ui/pages/page_password_key_create.dart:179
-- and lib/ui/pages/page_access_key_notice.dart:69:
--     supabaseClient.from("keys").upsert(serverKeys).eq("id", userId)
--   serverKeys = { cipher, nonce, salt, id } where:
--     cipher = master key encrypted with the password-derived/access key (b64)
--     nonce  = nonce of that encryption (b64)
--     salt   = pwhash salt (b64) — NULL for key-based accounts
--     id     = auth user uuid
--   NOTE: .upsert() is called WITHOUT an on_conflict param, so PostgREST uses
--   the PRIMARY KEY as conflict target — the PK on id is what makes the call
--   an update instead of a duplicate-key error.
--
-- READER (CLIENT) — lib/ui/pages/page_user_task.dart:401:
--     SELECT * WHERE id = <uid>   (checks salt == null to pick password vs
--                                  access-key unlock screen)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.keys (
  id       UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  cipher   TEXT NOT NULL,                    -- b64
  nonce    TEXT NOT NULL,                    -- b64
  salt     TEXT                              -- b64; NULL for key-based accounts
);

GRANT ALL ON public.keys TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.keys TO authenticated;

ALTER TABLE public.keys ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "keys_select_own" ON public.keys;
CREATE POLICY "keys_select_own"
  ON public.keys FOR SELECT
  TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS "keys_insert_own" ON public.keys;
CREATE POLICY "keys_insert_own"
  ON public.keys FOR INSERT
  TO authenticated
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS "keys_update_own" ON public.keys;
CREATE POLICY "keys_update_own"
  ON public.keys FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- -----------------------------------------------------------------------------
-- devices
-- -----------------------------------------------------------------------------
-- Registered client devices (for sync fan-out and the device limit).
-- id = client-generated uuid v4 (lib/ui/pages/page_user_task.dart:329,
-- Uuid().v4() stored in ModelPreferences).
--
-- WRITERS (all service-role):
--   register_device  INSERT {id,user_id,title,last_at,fcm_id,status=1}
--                    (after SELECT by id + device-limit count by user_id,status)
--   remove_device    DELETE WHERE id+user_id  (sign-out path, plan.devices>0)
--                    / UPDATE status=0        (device-management path)
--   update_fcm       UPDATE fcm_id WHERE user_id+id
--                    (lib/services/service_notification.dart:72)
--   _shared getUserPlanStatus  UPDATE last_at (heartbeat) WHERE
--                    id+user_id+status=1
--
-- CLIENT (anon key):
--   lib/utils/utils_sync.dart:209   SELECT status WHERE id = <deviceId>
--   lib/ui/pages/page_devices.dart:35
--                                   SELECT id,title,last_at,status
--                                   ORDER status DESC, last_at DESC
--   NOTE: NEITHER client query filters by user_id — the RLS policy is what
--   keeps other users' device lists private. Do not replace it with a
--   public-read policy.
--
-- status: 1 = active, 0 = disabled. checkDeviceStatus() (utils_sync.dart)
-- signs the user out and wipes local data when status = 0 (or row missing).
-- last_at: epoch ms.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.devices (
  id       TEXT PRIMARY KEY,                 -- client uuid v4
  user_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title    TEXT,                             -- device name (getDeviceName())
  fcm_id   TEXT,                             -- FCM registration token
  last_at  BIGINT,                           -- heartbeat, epoch ms
  status   INTEGER NOT NULL DEFAULT 1        -- 1 active / 0 disabled
);

-- register_device counts active rows per user; heartbeat filters status=1.
CREATE INDEX IF NOT EXISTS idx_devices_user_status
  ON public.devices (user_id, status);

GRANT ALL ON public.devices TO service_role;
GRANT SELECT ON public.devices TO authenticated;
-- No client INSERT/UPDATE/DELETE (register_device / remove_device / update_fcm).

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "devices_select_own" ON public.devices;
CREATE POLICY "devices_select_own"
  ON public.devices FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
-- Server-side user profile (username/avatar) shown to other synced users.
--
-- WRITER (CLIENT) — lib/utils/utils_sync.dart:568 pushProfileChange:
--     UPDATE {updated_at, username?, url?} WHERE id = <uid> AND updated_at < X
--   (called from lib/models/model_profile.dart update())
--
-- NO client INSERT exists in the repo, and the only SELECT is commented out
-- (utils_sync.dart:598, would also need a server_at column if re-enabled).
-- Rows are therefore seeded at sign-up by the handle_new_user trigger
-- (0005_signup_trigger.sql). If you re-enable that commented fetch, add a
-- server_at TIMESTAMPTZ column here first.
--
-- updated_at/at: epoch ms (ModelProfile.toMap).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT,
  username   TEXT,
  url        TEXT,                           -- avatar URL
  thumbnail  TEXT,                           -- base64 avatar or NULL
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
  USING (id = auth.uid());

-- pushProfileChange: UPDATE own row, only when server row is older.
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- -----------------------------------------------------------------------------
-- storage (per-user B2 usage meter)
-- -----------------------------------------------------------------------------
-- One row per user; id = user uuid.
--
-- CLIENT (anon key) — lib/ui/pages/page_plan_status.dart:99:
--     SELECT b2_size WHERE id = <uid>  .single()
--   .single() throws when no row exists, so EVERY user needs a row — the
--   handle_new_user trigger (0005) seeds it at sign-up.
--
-- READER (service-role) — _shared/supabase.ts getUserPlanStatus:
--     SELECT b2_size WHERE id = <uid> .single()
--   and enforces: fileSize > (plan.b2_limit - storage.b2_size) →
--   "Storage limit exceeded".
--
-- NO code in this repository WRITES b2_size. The webhook_b2 Edge Function
-- currently only logs the B2 webhook payload (verify: it returns 200 after
-- console.log). You must either extend webhook_b2 to recompute per-user
-- bytes from B2 inventory or update this column by other means, or the
-- usage bar / storage-limit check will always read 0.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.storage (
  id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  b2_size BIGINT NOT NULL DEFAULT 0          -- bytes currently stored in B2
);

GRANT ALL ON public.storage TO service_role;
GRANT SELECT ON public.storage TO authenticated;
-- INSERT (sign-up trigger, security definer) and UPDATE (webhook) run as
-- service_role / table owner, so no client policies are needed.

ALTER TABLE public.storage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "storage_select_own" ON public.storage;
CREATE POLICY "storage_select_own"
  ON public.storage FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- =============================================================================
-- ASSUMPTIONS / VERIFY:
-- 1. plans.user_id is ON DELETE SET NULL (not CASCADE): a plan is owned by the
--    RevenueCat customer id (rc_id); if a Supabase account is deleted and the
--    same rc_id is later re-claimed via set_id_rc, the row can be reused.
--    Verify this matches your expectation.
-- 2. plans.devices drives the register_device limit check
--    (supabase/functions/register_device/index.ts) — the value is parsed from
--    the RevenueCat product id (e.g. "10gb2devices" => 2 devices).
-- 3. The app has NO way to INSERT a plans row itself: until a RevenueCat
--    webhook fires (or you insert a row manually) every sync returns
--    "Failed to fetch plan". For a quick test insert:
--      INSERT INTO public.plans (rc_id, user_id, b2_limit, expires_at, devices)
--      VALUES ('test-rc', '<your-user-uuid>', 53687091200,
--              (extract(epoch from now() + interval '30 days') * 1000)::BIGINT, 1);
-- =============================================================================
