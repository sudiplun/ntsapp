// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { getUserPlanStatus } from "../_shared/supabase.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
    });
  }
  try {
    const authorization = req.headers.get("Authorization") ?? "";
    const deviceId = req.headers.get("deviceId") ?? "";
    const plan = await getUserPlanStatus(authorization, 0, deviceId);
    if (plan.status > 200) {
      return new Response(JSON.stringify({ error: plan.error }), {
        status: plan.status,
      });
    }
    const { allChanges } = await req.json();
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );
    const userId = plan.userId;

    // Only the sync tables may be written through this endpoint (it runs with
    // the service role, so an arbitrary `table` would bypass RLS entirely).
    const allowedTables = new Set(["category", "itemgroup", "item"]);
    for (const entry of allChanges ?? []) {
      if (!allowedTables.has(entry.table)) {
        return new Response(
          JSON.stringify({ error: `Table not allowed: ${entry.table}` }),
          { status: 400 },
        );
      }
    }

    for (const { table, changes } of allChanges ?? []) {
      if (!Array.isArray(changes) || changes.length === 0) continue;
      for (const change of changes) {
        if (change.user_id !== userId) {
          return new Response(
            JSON.stringify({ error: "user_id mismatch" }),
            { status: 403 },
          );
        }
      }

      // Optimistic concurrency: never let a stale device overwrite a newer
      // server row. (Filters on an upsert are ignored by PostgREST, so the
      // guard has to be applied here.)
      const ids = changes.map((change) => change.id);
      const { data: existing, error: readError } = await supabaseClient
        .from(table)
        .select("id,updated_at")
        .in("id", ids);
      if (readError) {
        return new Response(
          JSON.stringify({ error: `${table}|read: ${readError.message}` }),
          { status: 500 },
        );
      }
      const existingUpdatedAt = new Map<string, number>(
        (existing ?? []).map((
          row: { id: string; updated_at: number },
        ) => [row.id, row.updated_at]),
      );
      const pending = changes.filter((change) =>
        (existingUpdatedAt.get(change.id) ?? -1) < change.updated_at
      );
      if (pending.length === 0) continue;

      const { error: upsertError } = await supabaseClient
        .from(table)
        .upsert(pending, { onConflict: "id" });
      if (upsertError) {
        return new Response(
          JSON.stringify({ error: `${table}|upsert: ${upsertError.message}` }),
          { status: 500 },
        );
      }
    }
    // Notify the user's other devices via Realtime (no Firebase FCM).
    await supabaseClient.from("sync_events").insert({
      user_id: userId,
      device_id: deviceId,
    });
    return new Response("", { status: 200 });
  } catch (error) {
    return new Response(JSON.stringify({ error: error }), { status: 400 });
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/push_changes' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZWRlbW8iLCJyb2xlIjoiYW5vbiIsImV4cCI6MTk4MzgxMjk5Nn0.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"name":"Functions"}'

*/
