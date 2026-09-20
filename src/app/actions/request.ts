"use server";

import { headers } from "next/headers";
import { after } from "next/server";

import { drainSmsOutbox } from "@/lib/sms/drain";
import { clientIpFrom, supabaseAdmin } from "@/lib/supabase/admin";
import { toRpcPayload, validateRequest } from "@/lib/validation/request";

export type CreateRequestResult =
  | { ok: true; token: string; shortCode: string; replayed: boolean }
  | { ok: false; error: string; field?: string };

/**
 * The only way a request gets created.
 *
 * Runs server-side with the service-role key so that the IP used for rate limiting and stored
 * with the waiver acceptance is one we derived, not one the client handed us.
 */
export async function createRequestAction(raw: unknown): Promise<CreateRequestResult> {
  const parsed = validateRequest(raw);

  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return {
      ok: false,
      error: issue?.message ?? "validation_failed",
      field: issue?.path?.join(".") ?? undefined,
    };
  }

  const headerList = await headers();
  const siteUrl =
    process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ??
    `https://${headerList.get("host") ?? "localhost:3000"}`;

  const payload = toRpcPayload(parsed.data, {
    ip: clientIpFrom(headerList),
    userAgent: headerList.get("user-agent"),
  });

  const { data, error } = await supabaseAdmin().rpc("create_request", {
    p_payload: payload,
    p_site_url: siteUrl,
  });

  if (error) {
    console.error("[create_request] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  const result = data as
    | { ok: true; token: string; short_code: string; replayed: boolean }
    | { ok: false; error: string };

  if (!result?.ok) {
    return { ok: false, error: result?.error ?? "server_error" };
  }

  // Send the status link straight away rather than waiting up to a minute for the tick.
  // `after` runs once the response is on its way, so a slow Twilio call does not keep a
  // stranded driver staring at a spinner.
  after(async () => {
    try {
      await drainSmsOutbox(5);
    } catch (drainError) {
      console.error("[create_request] outbox drain failed", drainError);
    }
  });

  return {
    ok: true,
    token: result.token,
    shortCode: result.short_code,
    replayed: result.replayed,
  };
}
