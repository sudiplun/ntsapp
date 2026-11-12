-- =============================================================================
-- 0003_plans_keys_devices_profiles.sql
-- Subscription plans, encryption key material, registered devices, profiles.
--
-- plans
--   * written by webhook_rc (service-role): upsert on rc_id with
--     { rc_id, expires_at, b2_limit, devices }
--   * written by set_id_rc (service-role): SELECT user_id WHERE rc_id=...
--     then UPDATE user_id (claims an unassigned plan row)
--   * read by client (anon key):
--       lib/ui/pages/page_plan_status.dart
--       lib/ui/pages/page_user_task.dart
--       .from("plans").select(...).eq("user_id", uid)
--         .order("expires_at", desc).limit(1).maybeSingle()
--   * read by _shared getUserPlanStatus (service-role, same shape)
--   Note: a user may have multiple historical plan rows, hence SELECT on own.
--
-- keys
--   * written by client (anon key) ONLY:
--       lib/ui/pages/page_password_key_create.dart
--       lib/ui/pages/page_access_key_notice.dart
--       supabaseClient.from("keys").upsert(serverKeys).eq("id", userId)
--     serverKeys = { cipher, nonce, salt } (+ salt is null for key-based
--     accounts). See utils_crypto.dart generatePasswordKeys / generateKeys.
--   * read by client (anon key): page_user_task.dart
--       .from("keys").select().eq("id", userId)
--   * NOTE: the Dart app calls .upsert(...) WITHOUT an onConflict target and
--     passes .eq("id", ...), which the PostgREST upsert endpoint ignores. The
--     upsert therefore conflicts on the PRIMARY KEY. The PK on id makes the
--     client call work; no unique index beyond the PK is needed.
--
-- devices
--   * written by register_device / remove_device / update_fcm (service-role)
--   * read by client (anon key):
--       lib/ui/pages/page_devices.dart  .select('id,title,last_at,status')
--       lib/utils/utils_sync.dart       .select("status").eq("id", deviceId)
--   * updated by _shared getUserPlanStatus (service-role): last_at heartbeat
--   Client needs SELECT only; the row-level ownership check (user_id = uid)
--   keeps other users' device lists private.
--
-- profiles
--   * the only client-side write in the repo is:
--       lib/utils/utils_sync.dart pushProfileChange
--       .from("profiles").update(changeMap).eq('id', id).gt('updated_at', updatedAt)
--     with changeMap = { updated_at, username?, url? }
--   * fetchMapChanges contains a commented-out SELECT of profiles
--     (.gt("server_at", ...)); if you uncomment it, add a server_at column.
--   * no client INSERT is present (profiles are created locally from the
--     auth user), so we grant UPDATE (own row) only.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- plans
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plans (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rc_id       TEXT UNIQUE,                  -- RevenueCat original_app_user_id
  user_id     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  b2_limit    BIGINT NOT NULL DEFAULT 0,    -- bytes
  expires_at  BIGINT NOT NULL DEFAULT 0,    -- epoch ms
  devices     INTEGER NOT NULL DEFAULT 1,   -- max active devices
  created_at  BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT
);

-- getUserPlanStatus / pages: order by expires_at desc, limit 1 per user
CREATE INDEX IF NOT EXISTS idx_plans_user_expires
  ON public.plans (user_id, expires_at DESC);

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "plans_select_own" ON public.plans;
CREATE POLICY "plans_select_own"
  ON public.plans FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());
-- INSERT/UPDATE go through service-role (webhook_rc, set_id_rc).

-- -----------------------------------------------------------------------------
-- keys
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.keys (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  cipher     TEXT NOT NULL,                 -- master key encrypted (base64)
  nonce      TEXT NOT NULL,                 -- nonce for `cipher` (base64)
  salt       TEXT,                          -- pwhash salt; NULL for key-based accounts
  created_at BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT
);

ALTER TABLE public.keys ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "keys_select_own" ON public.keys;
CREATE POLICY "keys_select_own"
  ON public.keys FOR SELECT
  TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS "keys_upsert_own" ON public.keys;
CREATE POLICY "keys_upsert_own"
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
CREATE TABLE IF NOT EXISTS public.devices (
  id        TEXT PRIMARY KEY,               -- client-generated UUID (v4)
  user_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title     TEXT,
  fcm_id    TEXT,
  last_at   BIGINT,                         -- heartbeat epoch ms
  status    INTEGER NOT NULL DEFAULT 1      -- 1 = active, 0 = removed
);

CREATE INDEX IF NOT EXISTS idx_devices_user_status
  ON public.devices (user_id, status);

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "devices_select_own" ON public.devices;
CREATE POLICY "devices_select_own"
  ON public.devices FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());
-- INSERT/UPDATE/DELETE go through service-role (register_device,
-- remove_device, update_fcm, and the getUserPlanStatus heartbeat).

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       TEXT,
  username    TEXT,
  url         TEXT,
  thumbnail   TEXT,                         -- base64 or NULL
  type        INTEGER,
  updated_at  BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
  at          BIGINT
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- pushProfileChange: .update({updated_at, username?, url?}).eq('id').gt('updated_at', ...)
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());
