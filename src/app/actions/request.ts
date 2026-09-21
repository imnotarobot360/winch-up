"use server";

import { headers } from "next/headers";
import { after } from "next/server";

import { reverseGeocodeCounty } from "@/lib/geocode-server";
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
    | { ok: true; request_id: string; token: string; short_code: string; replayed: boolean }
    | { ok: false; error: string };

  if (!result?.ok) {
    return { ok: false, error: result?.error ?? "server_error" };
  }

  // Everything below runs once the response is on its way, so a slow third party never keeps a
  // stranded driver staring at a spinner.
  after(async () => {
    // County first: the volunteer offer text reads much better with it, and the first ring does
    // not go out until the next tick, so there is time.
    try {
      const county = await reverseGeocodeCounty(parsed.data.lat, parsed.data.lng);
      if (county) {
        await supabaseAdmin()
          .from("requests")
          .update({ county })
          .eq("id", result.request_id);
      }
    } catch (geocodeError) {
      console.error("[create_request] county lookup failed", geocodeError);
    }

    // Then the status link, rather than waiting up to a minute for the tick.
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
