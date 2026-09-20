"use server";

import { revalidatePath } from "next/cache";
import { after } from "next/server";

import { drainSmsOutbox } from "@/lib/sms/drain";
import { supabaseAdmin } from "@/lib/supabase/admin";

export type StatusActionResult = { ok: true } | { ok: false; error: string };

/**
 * Requester actions on their own request. The token is the credential: whoever holds the link
 * can close the job, which is exactly the behaviour the Facebook groups have today when someone
 * edits the post to "#### Recovered ####".
 */

function flushOutbox() {
  after(async () => {
    try {
      await drainSmsOutbox(5);
    } catch (error) {
      console.error("[status action] outbox drain failed", error);
    }
  });
}

async function callRpc(
  fn: string,
  args: Record<string, unknown>,
  token: string,
): Promise<StatusActionResult> {
  const { data, error } = await supabaseAdmin().rpc(fn, args);

  if (error) {
    console.error(`[${fn}] rpc failed`, error);
    return { ok: false, error: "server_error" };
  }

  const result = data as { ok: boolean; error?: string };
  if (!result?.ok) {
    return { ok: false, error: result?.error ?? "server_error" };
  }

  flushOutbox();
  revalidatePath(`/r/${token}`);
  return { ok: true };
}

export async function cancelRequestAction(
  token: string,
  reason?: string,
): Promise<StatusActionResult> {
  if (!token) return { ok: false, error: "not_found" };
  return callRpc(
    "cancel_request_by_token",
    { p_token: token, p_reason: reason ?? null },
    token,
  );
}

export async function markRecoveredAction(
  token: string,
  thankYou?: string,
): Promise<StatusActionResult> {
  if (!token) return { ok: false, error: "not_found" };
  return callRpc(
    "mark_recovered_by_token",
    { p_token: token, p_thank_you: thankYou?.trim() || null },
    token,
  );
}

export async function thankResponderAction(
  token: string,
  note: string,
): Promise<StatusActionResult> {
  if (!token) return { ok: false, error: "not_found" };
  if (!note.trim()) return { ok: false, error: "empty_note" };
  return callRpc("thank_responder_by_token", { p_token: token, p_note: note }, token);
}
