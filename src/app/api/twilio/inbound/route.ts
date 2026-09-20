import crypto from "node:crypto";

import { renderSms } from "@/lib/sms/templates";
import { supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Twilio inbound webhook.
 *
 * Deliberately thin. It checks that the request really came from Twilio, hands the message body
 * to `handle_inbound_sms()`, and renders whatever reply that returns. Every decision about what
 * "1" means lives in SQL, where it is covered by tests and where the row lock is.
 *
 * The reply goes back as TwiML rather than through the outbox: an answer to an inbound message
 * is free, instant, and does not need to survive a retry.
 */

function escapeXml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function twiml(message: string | null): Response {
  const body = message
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeXml(message)}</Message></Response>`
    : `<?xml version="1.0" encoding="UTF-8"?><Response></Response>`;

  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/xml; charset=utf-8" },
  });
}

/**
 * Twilio signs the exact URL it posted to, concatenated with every POST parameter in
 * alphabetical order, HMAC-SHA1 with the auth token.
 *
 * Behind a proxy the host header is what the browser sent, so `TWILIO_WEBHOOK_URL` can pin it
 * when the reconstruction is wrong.
 */
function verifySignature(
  url: string,
  params: Record<string, string>,
  signature: string | null,
  authToken: string,
): boolean {
  if (!signature) return false;

  const payload = Object.keys(params)
    .sort()
    .reduce((acc, key) => acc + key + params[key], url);

  const expected = crypto
    .createHmac("sha1", authToken)
    .update(Buffer.from(payload, "utf8"))
    .digest("base64");

  const a = Buffer.from(expected);
  const b = Buffer.from(signature);

  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export async function POST(request: Request) {
  const authToken = process.env.TWILIO_AUTH_TOKEN;

  const form = await request.formData();
  const params: Record<string, string> = {};
  for (const [key, value] of form.entries()) {
    if (typeof value === "string") params[key] = value;
  }

  const signature = request.headers.get("x-twilio-signature");

  if (authToken) {
    const host = request.headers.get("host");
    const url =
      process.env.TWILIO_WEBHOOK_URL ?? `https://${host}/api/twilio/inbound`;

    if (!verifySignature(url, params, signature, authToken)) {
      console.warn("[twilio] rejected a request with a bad signature");
      return new Response("forbidden", { status: 403 });
    }
  } else if (process.env.NODE_ENV === "production") {
    // Never accept unsigned webhooks in production: anyone who can guess the URL could accept
    // jobs on a volunteer's behalf.
    console.error("[twilio] TWILIO_AUTH_TOKEN is not set; refusing inbound webhook");
    return new Response("not configured", { status: 503 });
  }

  const from = params.From;
  const body = params.Body ?? "";

  if (!from) {
    return twiml(null);
  }

  const { data, error } = await supabaseAdmin().rpc("handle_inbound_sms", {
    p_from: from,
    p_body: body,
    p_to: params.To ?? null,
    p_twilio_sid: params.MessageSid ?? params.SmsSid ?? null,
  });

  if (error) {
    console.error("[twilio] handle_inbound_sms failed", error);
    // Still 200: a 500 makes Twilio retry, which would replay the same "1" against a job that
    // may now be covered.
    return twiml(null);
  }

  const result = data as {
    reply_template: string | null;
    locale?: string;
    params?: Record<string, string | number | null>;
  } | null;

  if (!result?.reply_template) {
    return twiml(null);
  }

  const message = renderSms(
    result.reply_template,
    result.params ?? {},
    result.locale ?? "en",
  );

  return twiml(message);
}
