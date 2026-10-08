import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";

import { deliverRendered, emailContext } from "./send";
import { renderEmail, type EmailTemplateKey } from "./templates";

/**
 * Sending whatever the database has queued, on the same clock as the other four drains.
 *
 * The welcome email is queued by a trigger on auth.users the moment Supabase writes
 * email_confirmed_at (see 20260924000300), which is the only signal that cannot be missed --
 * the browser may never come back from the redirect. That leaves the actual sending to something
 * that runs on a timer, which is this.
 *
 * Runs from /api/sms/drain rather than a cron entry of its own, for the reason that route already
 * gives for the other four: they run on the same clock and neither deserves a separate schedule
 * to forget to set up.
 *
 * NO PROVIDER IS NOT A FAILURE. With EMAIL_PROVIDER unset the rows are put BACK to `queued`
 * rather than marked failed, so a member who verified before the provider was bought still gets
 * their welcome email on the first tick after it is configured. Marking them failed would burn
 * the queue silently, which is the mistake the push drain deliberately avoids too.
 */
export type EmailDrainResult = {
  ok: boolean;
  claimed: number;
  sent: number;
  failed: number;
  requeued: number;
  error?: string;
};

type ClaimedRow = {
  id: string;
  user_id: string;
  to_email: string;
  template_key: string;
  locale: string;
  /**
   * Built by claim_email_deliveries AT CLAIM TIME from the request the delivery points at, and
   * never stored. email_deliveries holds no address, subject, body or action URL on purpose, and
   * a params column would have made it a durable log of who is stuck where.
   */
  params?: Record<string, unknown> | null;
};

type Personalisation = { actionUrl: string; params?: Record<string, string | number> };

/**
 * What a given template needs beyond its copy, resolved at send time.
 *
 * Deliberately NOT stored on the queue row. `email_deliveries` holds no address, no subject, no
 * body and no action URL by design (see 20260924000200) -- it is a delivery log that identifies
 * nobody, which is why its rows can be kept. Putting a member's legal name in there to feed a
 * template would quietly undo that, and would leave two copies of a fact that can drift.
 *
 * So the drain reads it back from the record itself. One extra query, only for the templates
 * that need one.
 */
async function personalise(
  row: ClaimedRow,
  siteUrl: string,
  supportEmail: string,
): Promise<Personalisation> {
  // A RECOVERY CALL-OUT. The facts came with the claim, so there is no second round trip; this
  // only has to turn them into the words the template prints and point the button at /help with
  // the recovery in focus. Reply-by-text remains the other way in -- see sms/templates.ts.
  if (row.template_key === "recovery.offer") {
    const p = (row.params ?? {}) as Record<string, unknown>;
    const str = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v : undefined);

    const extras = [
      p.needs_tractor ? (row.locale === "es" ? "un tractor" : "a tractor") : null,
      p.needs_second_truck ? (row.locale === "es" ? "una segunda troca" : "a second truck") : null,
    ].filter(Boolean) as string[];

    return {
      // The short code focuses the feed on this recovery; /help is behind a sign-in, so the link
      // reveals nothing to somebody who merely has the email.
      actionUrl: str(p.short_code)
        ? `${siteUrl}/help?r=${encodeURIComponent(String(p.short_code))}`
        : `${siteUrl}/help`,
      params: {
        ...(typeof p.miles === "number" || typeof p.miles === "string"
          ? { miles: String(p.miles) }
          : {}),
        ...(str(p.vehicle_class) ? { vehicle: String(p.vehicle_class) } : {}),
        ...(str(p.stuck_type) ? { situation: String(p.stuck_type) } : {}),
        ...(extras.length ? { extras: extras.join(row.locale === "es" ? " y " : " and ") } : {}),
      },
    };
  }

  // A STAND-DOWN. Only the code, on purpose: see the template's note on why a cancelled
  // recovery's details do not belong in somebody's inbox. The button goes to their own dashboard
  // rather than the recovery, which no longer exists to look at.
  if (row.template_key === "recovery.stood_down") {
    const p = (row.params ?? {}) as Record<string, unknown>;
    const str = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v : undefined);
    return {
      // Their own dashboard, not the recovery: it is closed and there is nothing there to act on.
      actionUrl: `${siteUrl}/me`,
      params: {
        ...(str(p.short_code) ? { code: String(p.short_code) } : {}),
        // recovered | cancelled | expired. The three endings are not interchangeable.
        ...(str(p.status) ? { status: String(p.status) } : {}),
      },
    };
  }

  if (row.template_key !== "membership.signed") {
    // The welcome email's button goes to the app itself. It carries no token: unlike
    // verification, there is nothing single-use about "open the app", and putting a credential
    // in an email that exists to say hello would be gratuitous.
    return { actionUrl: siteUrl };
  }

  const { data } = await supabaseAdmin()
    .from("membership_signatures")
    .select("legal_name, agreement_version, body_hash, signed_at")
    .eq("user_id", row.user_id)
    .order("signed_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const signedOn = data?.signed_at
    ? new Date(data.signed_at).toLocaleDateString(row.locale === "es" ? "es-US" : "en-US", {
        year: "numeric",
        month: "long",
        day: "numeric",
        timeZone: "America/Chicago",
      })
    : "";

  return {
    // Not a token. The page requires a session and shows the member their own signed version.
    actionUrl: `${siteUrl}/${row.locale === "es" ? "es/" : ""}agreement`,
    params: {
      legalName: data?.legal_name ?? "",
      signedOn,
      version: data?.agreement_version ?? "",
      // Enough to match an email against a record in the admin screen, and far too little to
      // be worth anything to anybody else. The whole hash would just be noise in an inbox.
      hashPrefix: data?.body_hash ? data.body_hash.slice(0, 12) : "",
      supportEmail,
    },
  };
}

export async function drainEmail(limit = 50): Promise<EmailDrainResult> {
  const db = supabaseAdmin();
  const { siteUrl, supportEmail, provider } = emailContext();

  const { data, error } = await db.rpc("claim_email_deliveries", { p_limit: limit });

  if (error) {
    return { ok: false, claimed: 0, sent: 0, failed: 0, requeued: 0, error: error.message };
  }

  const rows = (data ?? []) as ClaimedRow[];
  let sent = 0;
  let failed = 0;
  let requeued = 0;

  for (const row of rows) {
    try {
      const { actionUrl, params } = await personalise(row, siteUrl, supportEmail);

      const rendered = renderEmail(row.template_key as EmailTemplateKey, {
        locale: row.locale,
        siteUrl,
        supportEmail,
        actionUrl,
        params,
      });

      const { id, configured } = await deliverRendered(row.to_email, rendered);

      if (!configured) {
        await db.rpc("record_email_result", {
          p_id: row.id,
          p_status: "queued",
          p_error: "no email provider configured",
        });
        requeued += 1;
        continue;
      }

      await db.rpc("record_email_result", {
        p_id: row.id,
        p_status: "sent",
        p_provider: provider,
        p_message_id: id,
      });
      sent += 1;
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause);

      // A template that cannot render is a bug and will never succeed, so it fails rather than
      // being retried forever. A provider that refused is also marked failed -- there is no
      // backoff here yet, and pretending otherwise by requeueing would produce a tight retry
      // loop against a provider that is already unhappy.
      await db.rpc("record_email_result", {
        p_id: row.id,
        p_status: "failed",
        p_provider: provider,
        p_error: message,
      });
      failed += 1;
    }
  }

  return { ok: true, claimed: rows.length, sent, failed, requeued };
}
