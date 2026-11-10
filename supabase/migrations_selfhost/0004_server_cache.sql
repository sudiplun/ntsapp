-- =============================================================================
-- 0004_server_cache.sql
-- Key/value service-role cache used by authenticateB2
-- (supabase/functions/_shared/backblaze.ts) to share the Backblaze B2 account
-- authorization token between Edge Function instances.
--
-- Access pattern (ALL service-role — no client code touches this table):
--   SELECT value,state WHERE key = 'b2_account_token'  (single())
--   UPDATE state = 1 WHERE key = ? AND state = 0       (atomic "lock")
--   UPDATE state = 0 WHERE key = ?                      (reset)
--   UPSERT {key,value,state} ON CONFLICT key            (store new token)
--
-- The lock logic REQUIRES the seed row to exist: the atomic
-- "UPDATE ... WHERE state = 0" is a no-op when the row is missing, and the
-- comment in the code says "ignore if can not update (if no row exist)" —
-- i.e. the first caller would otherwise never authenticate. The seed row is
-- created below with ON CONFLICT DO NOTHING, so re-running this file is safe.
--
-- RLS is enabled with NO policies: anon/authenticated are denied, which is
-- exactly the intent (the token is a shared secret; only service-role
-- bypasses RLS).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.server (
  key   TEXT PRIMARY KEY,
  value TEXT,
  state INTEGER NOT NULL DEFAULT 0           -- 1 => token refresh in progress
);

GRANT ALL ON public.server TO service_role;

ALTER TABLE public.server ENABLE ROW LEVEL SECURITY;
-- No policies on purpose.

INSERT INTO public.server (key, value, state)
VALUES ('b2_account_token', NULL, 0)
ON CONFLICT (key) DO NOTHING;
