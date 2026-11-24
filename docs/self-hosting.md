# Self-Hosting Note Safe with Supabase

Note Safe does not require any proprietary backend services. The entire backend runs on standard **Supabase** (Database, Storage, Auth, and Realtime). You can use a free cloud project on [supabase.com](https://supabase.com) or run your own self-hosted Supabase instance.

---

## 1. Create a Supabase Project

If you haven't already:
1. Create a new project in the [Supabase Dashboard](https://supabase.com/dashboard) (or via local Supabase CLI).
2. Note your **Project URL** and **Anon / Publishable API Key** from **Project Settings > API**.

---

## 2. Apply Database & Storage Migrations

A complete setup script is available at [`supabase/media_and_sync_setup.sql`](../supabase/media_and_sync_setup.sql).

It creates:
- The private `media` and `thmbs` storage buckets.
- Row-Level Security (RLS) policies ensuring users can only read and write their own encrypted folders (`<userId>/<filename>`).
- Tables for sync items (`category`, `itemgroup`, `item`), devices, profiles, and media keys (`files`, `thmbs`).
- The `sync_events` realtime publication table for instant multi-device push notifications.

### Option A: Using Supabase CLI (Recommended)

Link your project and run the script:

```bash
# Link to your project ref
supabase link --project-ref <your-project-ref>

# Apply the setup script
supabase db query --remote --yes -f supabase/media_and_sync_setup.sql
```

### Option B: Using the Supabase Dashboard

1. In the Supabase Dashboard, go to **SQL Editor** in the left sidebar.
2. Click **New Query**.
3. Open [`supabase/media_and_sync_setup.sql`](../supabase/media_and_sync_setup.sql) in your code editor, copy its contents, paste them into the SQL Editor, and click **Run**.

---

## 3. Deploy Edge Functions

Note Safe uses lightweight Edge Functions for atomic row-level sync, device heartbeats, and device registration.

Deploy them with the Supabase CLI:

```bash
supabase functions deploy push_changes
supabase functions deploy fetch_changes
supabase functions deploy register_device
supabase functions deploy remove_device
```

---

## 4. Connect the App

Put your project credentials into your `.env` file:

```bash
SUPABASE_URL=https://<your-project-ref>.supabase.co
SUPABASE_KEY=<your-anon-or-publishable-key>
```

Build or run the app with `./run.sh` or `./build.sh`. Your app will now connect and sync through your own Supabase instance!
