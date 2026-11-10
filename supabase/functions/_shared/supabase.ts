import { createClient } from "jsr:@supabase/supabase-js@2";

// =============================================================================
// Shared helpers for the remaining Edge Functions.
//
// Removed with the Supabase-only migration (0006):
//   * Backblaze B2 helpers (authenticateB2 lived in _shared/backblaze.ts)
//   * FCM helpers (getFcmAccessToken) and the service-account.json import
//   * files-table writers (setFileEntry / setFileUploaded / setDownloadToken /
//     getFile / deleteFileEntry / setB2FileId) — the app now writes its own
//     files rows and uploads bytes straight to the "media" Storage bucket.
//   * getUser (only RevenueCat / FCM functions used it).
// =============================================================================

export async function getUserPlanStatus(
  authorization: string,
  fileSize: number,
  deviceId: string,
) {
  let status = 200;
  let error = "";
  let devices = 0;
  const supabaseClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    {
      global: {
        headers: { Authorization: authorization },
      },
    },
  );
  // First get the token from the Authorization header
  const userToken = authorization.replace("Bearer ", "");

  // Now we can get the session or user object
  const {
    data: { user },
  } = await supabaseClient.auth.getUser(userToken);
  const userId = user?.id;

  // Get user plan (free default plan seeded by handle_new_user, 0006).
  const { data: plan, error: planError } = await supabaseClient
    .from("plans")
    .select("b2_limit,expires_at,devices")
    .eq("user_id", userId)
    .order("expires_at", { ascending: false }) // Get the latest plan
    .limit(1) // Ensure only one row is returned
    .maybeSingle();

  if (planError || !plan) {
    status = 400;
    error = "Failed to fetch plan";
    return { status, userId, error, devices };
  }

  devices = plan.devices;

  if (plan.expires_at < new Date().getTime()) {
    status = 400;
    error = "Plan expired";
    return { status, userId, error, devices };
  }

  const { data: storage, error: storageError } = await supabaseClient
    .from("storage")
    .select("b2_size")
    .eq("id", userId)
    .single();

  if (storageError || !storage) {
    error = "Failed to fetch storage";
    status = 400;
    return { status, userId, error, devices };
  }

  if (fileSize > (plan.b2_limit - storage.b2_size)) {
    status = 400;
    error = "Storage limit exceeded";
    return { status, userId, error, devices };
  }

  if (deviceId.length > 0) {
    const now = new Date().getTime();
    const { data: device, error: deviceError } = await supabaseClient.from(
      "devices",
    ).update({ "last_at": now }).eq("id", deviceId).eq("user_id", userId).eq(
      "status",
      1,
    ).select().single();
    if (deviceError || !device) {
      error = "device not registered";
      status = 400;
    }
  }

  return { status, userId, error, devices };
}
