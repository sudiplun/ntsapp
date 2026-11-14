# Changelog

All notable changes to NoteSafe are documented here.

## 1.0.0 (build 1) — 2026-11-14

### What's new

**Sync you can trust**
Notes, images, videos and files now reliably reach your other signed-in devices. New notes appear almost instantly thanks to a persistent realtime connection, with automatic reconnect and a 60 s fallback. Several cases where notes or their attachments could get stuck, silently dropped, or stop updating have been fixed.

**Simpler sign-in**
Email one-time codes are replaced by **email + password** (minimum 8 characters), translated into every supported language.

**Faster start-up**
Heavy initialisation is deferred and secure-storage reads are cached, so the app opens noticeably faster.

**Media storage on Supabase**
Attachments now upload directly to Supabase Storage (50 MB per file limit) and stay encrypted.

**Smaller, more modern app**
Removed unused models, services, pages, dependencies and bundled assets, and modernised the Android build (AGP 9, Gradle 9.5, Kotlin 2.4.20).

### Sync engine

- Replaced the persisted-timestamp "already syncing" guard with a real in-process flag, and clear `processRunningAt` when a cycle ends — pushes and realtime pulls are no longer parked forever.
- Each fetched row is isolated and failures are retried in a second pass, so one bad row can't abort the whole batch and loop forever.
- Create a placeholder group when a fetched note references a group not yet in the local DB, avoiding the NOT NULL foreign-key abort.
- `StorageSqlite.insert()` no longer uses `INSERT OR REPLACE` — that fired `ON DELETE CASCADE` and could wipe every note in a re-synced group.
- Pull failures now log the real error instead of swallowing everything except "Plan expired".
- Realtime listener: idempotent start, status callback with 5–60 s backoff, re-armed on app start and on foreground; requests arriving mid-sync are queued and re-run.
- Start realtime and trigger an immediate sync right after launch checks, instead of waiting up to 60 s.
- Device heartbeat now uses the service-role client (the RLS-bound client matched 0 rows, causing every push/fetch to fail with "device not registered").

### Media pipeline (images / video / files)

- Editing a note no longer cancels its queued media upload — the task stays at the media step until upload completes.
- Internal sync updates (download state, rewritten path, downloaded thumbnail) no longer move `updated_at` forward, which used to make later edits from other devices look "older" and be rejected.
- A fetched note row without a thumbnail no longer overwrites the existing local thumbnail with NULL.
- Notes without a thumbnail no longer leave the change stuck on the thumbnail step.
- Missing thumbnails (no key row or bucket 404) now advance the task instead of stalling the file behind it.
- Upload id is taken from the change data's file name, matching what the other device looks up.
- Fetched changes without file data no longer queue forever; decrypted temp copies are cleaned up.
- 50 MB upload cap enforced.

### Sync performance

- Removed the TCP probe to `8.8.8.8:53`. Corporate firewalls, some carriers and cloud VMs block outbound TCP/53, so it falsely reported "no internet" and skipped the whole cycle. Connectivity is now determined by the real request.
- `fetchMapChanges()` runs right after `pushMapChanges()` instead of behind all media uploads.
- The pull cursor is captured **before** a request is sent, so rows pushed concurrently can no longer be skipped (re-fetching is idempotent).

### Backend (Supabase)

- Supabase-only backend: private `media` bucket with RLS, files INSERT/DELETE policies, storage-usage trigger, `sync_events` table, free plan seeded at signup, and the B2 server-cache table dropped.
- Edge functions: keep `fetch_changes`, `push_changes`, `register_device`, `remove_device`, `ses_events`.
- `push_changes`: surfaces read/upsert errors, whitelists `category`/`itemgroup`/`item`, rejects cross-user rows, and applies the `updated_at` guard in code (PostgREST ignores filters on upserts).
- Auth: password sign-in/sign-up replacing email OTP, with localized strings in all locales.

### Platform & tooling

- Android application id renamed to `com.sudiplun.notes`.
- Migrated to AGP 9 built-in Kotlin; Gradle 9.5 / AGP 9.3.1 / Kotlin 2.4.20.
- `workmanager` 0.10.10: AGP 9 support plus Android 16 fixes (background tasks no longer fail after ~30 s, one-off work no longer stuck `RUNNING`, foreground-service permission opt-in).
- Crypto migrated from `sodium_libs` to `sodium` (`sodium_sumo`, `callRaw` for `pwhash`).
- `file_picker` adapted to the v12 `pickFiles` API (`List<PlatformFile>`).
- Added `build.sh` (`linux` / `android` / `all` / `clean` / `help`, `.env` dart-defines, artifact summary, removes stale universal APK) and `run.sh`.
- Self-hosted SQL/migrations parked under `supabase/migrations_selfhost/`, with superseded WIP in `_superseded_wip/`.
- New tests: `sync_media_test.dart` (9), `sync_pipeline_test.dart`, `sync_repro_test.dart`, `migration_repro_test.dart`.
