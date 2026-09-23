"use server";

import { revalidatePath } from "next/cache";
import { after } from "next/server";

import { drainPush } from "@/lib/push/send";
import { supabaseServer } from "@/lib/supabase/server";

export type TeamActionResult = { ok: true } | { ok: false; error: string };

/**
 * What a helper can say about themselves on a recovery they are already on.
 *
 * Session-bound client, never the service role: every one of these RPCs works out who you are
 * from auth.uid() and refuses to act on somebody else's membership. Passing a user id from the
 * browser would be the bug, so there is nowhere to pass one.
 */

function unwrap(data: unknown): TeamActionResult {
  const result = data as { ok?: boolean; error?: string } | null;
  if (!result?.ok) return { ok: false, error: result?.error ?? "server_error" };
  return { ok: true };
}

/**
 * Both of these notify the rest of the team, and those notifications are queued rather than sent.
 * Flushing here means somebody says "on site" and the others' phones buzz now, instead of on
 * whenever the next drain happens to run.
 */
function flushPush() {
  after(async () => {
    try {
      await drainPush(50);
    } catch (error) {
      console.error("[team action] push drain failed", error);
    }
  });
}

export async function setMyStatusAction(
  requestId: string,
  status: string,
): Promise<TeamActionResult> {
  if (!requestId || !status) return { ok: false, error: "not_found" };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("set_my_participant_status", {
    p_request_id: requestId,
    p_status: status,
  });

  if (error) {
    console.error("[set_my_participant_status] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  flushPush();
  revalidatePath("/me");
  return unwrap(data);
}

/**
 * Leaving a recovery.
 *
 * Revokes access to what is said next, keeps the history, tells everybody still on it, and hands
 * the lead to the next helper — or, if there is no next helper, puts the request back to
 * unmatched so it reappears on /help rather than leaving somebody on a page that says help is
 * coming. All of that is one RPC, deliberately: a partial withdrawal is worse than none.
 */
export async function withdrawAction(requestId: string): Promise<TeamActionResult> {
  if (!requestId) return { ok: false, error: "not_found" };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("withdraw_from_recovery", {
    p_request_id: requestId,
  });

  if (error) {
    console.error("[withdraw_from_recovery] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  flushPush();
  revalidatePath("/me");
  return unwrap(data);
}

/** Silence one busy thread without silencing the recovery's own status changes. */
export async function setRecoveryMuteAction(
  requestId: string,
  muted: boolean,
): Promise<TeamActionResult> {
  if (!requestId) return { ok: false, error: "not_found" };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("set_recovery_mute", {
    p_request_id: requestId,
    p_muted: muted,
  });

  if (error) {
    console.error("[set_recovery_mute] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  return unwrap(data);
}
