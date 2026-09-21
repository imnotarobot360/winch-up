"use server";

import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export type AccountActionResult = { ok: true } | { ok: false; error: string };

/**
 * Delete the signed-in user's account.
 *
 * Service role, because removing a row from auth.users is not something a user's own session can
 * do. The id comes from the server's view of the session and never from the request body: an id
 * parameter here would be an "delete any account" endpoint wearing a disguise.
 *
 * Refused while the person is in the middle of a recovery. Deleting a requester mid-job strands
 * the volunteer driving toward them, and deleting an accepted volunteer strands the requester,
 * who is the one actually stuck. They can cancel or complete first.
 */
export async function deleteAccount(): Promise<AccountActionResult> {
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { ok: false, error: "not_signed_in" };

  const admin = supabaseAdmin();

  const OPEN = ["submitted", "dispatching", "unmatched", "accepted", "on_site"];

  const { count: openRequests, error: requestError } = await admin
    .from("requests")
    .select("id", { count: "exact", head: true })
    .eq("requester_user_id", user.id)
    .in("status", OPEN);

  if (requestError) {
    console.error("[deleteAccount] request check failed", requestError);
    return { ok: false, error: "server_error" };
  }

  if ((openRequests ?? 0) > 0) return { ok: false, error: "open_request" };

  const { data: responder, error: responderError } = await admin
    .from("responders")
    .select("id")
    .eq("user_id", user.id)
    .maybeSingle();

  if (responderError) {
    console.error("[deleteAccount] responder lookup failed", responderError);
    return { ok: false, error: "server_error" };
  }

  if (responder) {
    const { count: activeJobs, error: jobError } = await admin
      .from("requests")
      .select("id", { count: "exact", head: true })
      .eq("accepted_responder_id", responder.id)
      .in("status", ["accepted", "on_site"]);

    if (jobError) {
      console.error("[deleteAccount] job check failed", jobError);
      return { ok: false, error: "server_error" };
    }

    if ((activeJobs ?? 0) > 0) return { ok: false, error: "active_job" };
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);

  if (deleteError) {
    console.error("[deleteAccount] delete failed", deleteError.message);
    return { ok: false, error: "server_error" };
  }

  // The profile and role rows cascade. Audit rows, dispatch events and the volunteer record
  // survive with a null actor: what happened stays on the record, who it was does not.
  await supabase.auth.signOut();

  return { ok: true };
}
