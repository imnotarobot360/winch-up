"use server";

import { revalidatePath } from "next/cache";
import { after } from "next/server";

import { drainSmsOutbox } from "@/lib/sms/drain";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export type OfferActionResult = { ok: true } | { ok: false; error: string };

/**
 * Offering help, and choosing who helps.
 *
 * Two different callers with two different credentials, which is why they are in one file: it
 * should be obvious at a glance which side of the handshake each function is on.
 *
 *   A member offering       signed in. The RPC reads auth.uid(), so this goes through the
 *                           session-bound client and the browser cannot name somebody else.
 *   A requester choosing    holds the status token. Service-role, like every other by_token
 *                           write here, so the token is checked server-side where the browser
 *                           cannot reach around it.
 */

function flushOutbox() {
  after(async () => {
    try {
      await drainSmsOutbox(5);
    } catch (error) {
      console.error("[offer action] outbox drain failed", error);
    }
  });
}

function unwrap(data: unknown): OfferActionResult {
  const result = data as { ok?: boolean; error?: string } | null;
  if (!result?.ok) return { ok: false, error: result?.error ?? "server_error" };
  return { ok: true };
}

/**
 * A member puts their hand up.
 *
 * `equipmentAck` is not a formality. Spec section 3 requires the member to be asked whether they
 * actually have the kit and can do this safely, and the database refuses the offer without it --
 * this argument is that answer travelling. Never default it to true here.
 */
export async function offerAssistanceAction(
  requestId: string,
  input: { note?: string; etaMinutes?: number | null; equipmentAck: boolean },
): Promise<OfferActionResult> {
  if (!requestId) return { ok: false, error: "not_found" };
  if (!input.equipmentAck) return { ok: false, error: "equipment_not_acknowledged" };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("offer_assistance", {
    p_request_id: requestId,
    p_note: input.note?.trim() || null,
    p_eta_minutes: input.etaMinutes ?? null,
    p_equipment_ack: true,
  });

  if (error) {
    console.error("[offer_assistance] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  revalidatePath("/help");
  revalidatePath("/me");
  return unwrap(data);
}

/** Taking your hand back down, before anyone has chosen. */
export async function withdrawOfferAction(requestId: string): Promise<OfferActionResult> {
  if (!requestId) return { ok: false, error: "not_found" };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("withdraw_my_offer", { p_request_id: requestId });

  if (error) {
    console.error("[withdraw_my_offer] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  revalidatePath("/help");
  revalidatePath("/me");
  return unwrap(data);
}

/**
 * The requester picks somebody. This is the moment contact details are released, in both
 * directions, and the only moment.
 */
export async function acceptOfferAction(
  token: string,
  dispatchId: string,
): Promise<OfferActionResult> {
  if (!token || !dispatchId) return { ok: false, error: "not_found" };

  const { data, error } = await supabaseAdmin().rpc("accept_offer_by_token", {
    p_token: token,
    p_dispatch_id: dispatchId,
  });

  if (error) {
    console.error("[accept_offer_by_token] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  flushOutbox();
  revalidatePath(`/r/${token}`);
  return unwrap(data);
}

/** Passing on one offer without closing the request -- others may still be coming. */
export async function declineOfferAction(
  token: string,
  dispatchId: string,
): Promise<OfferActionResult> {
  if (!token || !dispatchId) return { ok: false, error: "not_found" };

  const { data, error } = await supabaseAdmin().rpc("decline_offer_by_token", {
    p_token: token,
    p_dispatch_id: dispatchId,
  });

  if (error) {
    console.error("[decline_offer_by_token] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  revalidatePath(`/r/${token}`);
  return unwrap(data);
}

/**
 * The availability switch (spec section 5).
 *
 * Turning it ON is what makes somebody reachable by the dispatcher, and it is also the point
 * where their recovery profile is created if they have never had one -- which is how a member
 * becomes a volunteer now, with no second signup and nobody to approve them.
 */
export async function setAvailableToHelpAction(
  available: boolean,
): Promise<OfferActionResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("set_available_to_help", {
    p_available: available,
  });

  if (error) {
    console.error("[set_available_to_help] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  revalidatePath("/account");
  revalidatePath("/me");
  return unwrap(data);
}
