import "server-only";

/**
 * Twilio outbound. Deliberately thin: no SDK, one fetch.
 *
 * `SMS_DRY_RUN=1` logs the message instead of sending it. Leave it on until A2P 10DLC is
 * approved — messages sent from an unregistered number are silently dropped by the carriers,
 * which looks exactly like the app being broken.
 */

export type SendResult =
  | { ok: true; sid: string | null; dryRun: boolean }
  | { ok: false; error: string; retryable: boolean };

export function smsDryRun(): boolean {
  return process.env.SMS_DRY_RUN === "1";
}

export async function sendSms(to: string, body: string): Promise<SendResult> {
  if (smsDryRun()) {
    console.info(`[sms:dry-run] to=${to} body=${JSON.stringify(body)}`);
    return { ok: true, sid: null, dryRun: true };
  }

  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const messagingServiceSid = process.env.TWILIO_MESSAGING_SERVICE_SID;
  const from = process.env.TWILIO_FROM_NUMBER;

  if (!accountSid || !authToken || (!messagingServiceSid && !from)) {
    return {
      ok: false,
      retryable: false,
      error:
        "Twilio is not configured. Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN and either TWILIO_MESSAGING_SERVICE_SID or TWILIO_FROM_NUMBER, or set SMS_DRY_RUN=1.",
    };
  }

  const form = new URLSearchParams({ To: to, Body: body });
  if (messagingServiceSid) {
    form.set("MessagingServiceSid", messagingServiceSid);
  } else if (from) {
    form.set("From", from);
  }

  try {
    const response = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
      {
        method: "POST",
        headers: {
          Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString("base64")}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: form,
        // A stuck driver is waiting. Do not hang on a slow API.
        signal: AbortSignal.timeout(10_000),
      },
    );

    const payload = (await response.json().catch(() => null)) as
      | { sid?: string; message?: string; code?: number }
      | null;

    if (!response.ok) {
      return {
        ok: false,
        // 4xx means the message itself is wrong; retrying sends the same bad message again.
        retryable: response.status >= 500 || response.status === 429,
        error: payload?.message ?? `Twilio returned ${response.status}`,
      };
    }

    return { ok: true, sid: payload?.sid ?? null, dryRun: false };
  } catch (error) {
    return {
      ok: false,
      retryable: true,
      error: error instanceof Error ? error.message : "Network error calling Twilio",
    };
  }
}
