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
};

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
      const rendered = renderEmail(row.template_key as EmailTemplateKey, {
        locale: row.locale,
        siteUrl,
        supportEmail,
        // The welcome email's button goes to the app itself. It carries no token: unlike
        // verification, there is nothing single-use about "open the app", and putting a
        // credential in an email that exists to say hello would be gratuitous.
        actionUrl: siteUrl,
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
