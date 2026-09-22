import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";

import { renderLooksBroken, renderSms, segmentCount } from "./templates";
import { sendSms } from "./twilio";

type QueuedMessage = {
  id: string;
  to_phone: string;
  template_key: string | null;
  params: Record<string, string | number | null> | null;
  locale: string;
  body: string | null;
};

export type DrainSummary = {
  claimed: number;
  sent: number;
  failed: number;
  errors: string[];
};

/**
 * Drain the outbox.
 *
 * Called two ways: inline right after a request is created, so the requester gets their status
 * link in seconds instead of waiting up to a minute for the tick, and from /api/sms/drain for
 * everything else.
 *
 * `claim_sms_batch` already bumped the attempt counter and pushed `send_after` out, so a crash
 * here leaves the message to be retried rather than sent twice in the same minute.
 */
export async function drainSmsOutbox(limit = 20): Promise<DrainSummary> {
  const db = supabaseAdmin();
  const summary: DrainSummary = { claimed: 0, sent: 0, failed: 0, errors: [] };

  const { data, error } = await db.rpc("claim_sms_batch", { p_limit: limit });

  if (error) {
    summary.errors.push(`claim failed: ${error.message}`);
    return summary;
  }

  const messages = (data ?? []) as QueuedMessage[];
  summary.claimed = messages.length;

  for (const message of messages) {
    const body =
      message.body ??
      renderSms(message.template_key ?? "", message.params ?? {}, message.locale);

    if (!body) {
      summary.failed += 1;
      summary.errors.push(`unknown template: ${message.template_key}`);
      await db.rpc("mark_sms_failed", {
        p_id: message.id,
        p_error: `Unknown template key: ${message.template_key}`,
      });
      continue;
    }

    // Refuse rather than send. A text reading "es suyo. undefined, undefined" tells a
    // volunteer nothing and costs the trust the next one depends on; a failed row tells an
    // admin exactly which template and which request to look at.
    const broken = renderLooksBroken(body);

    if (broken) {
      summary.failed += 1;
      summary.errors.push(`${message.template_key}: ${broken}`);
      await db.rpc("mark_sms_failed", {
        p_id: message.id,
        p_error: `${broken} (template: ${message.template_key})`,
      });
      continue;
    }

    if (segmentCount(body) > 4) {
      // Not fatal, but someone wrote copy that will arrive as five texts.
      console.warn(
        `[sms] ${message.template_key} renders to ${segmentCount(body)} segments`,
      );
    }

    const result = await sendSms(message.to_phone, body);

    if (result.ok) {
      summary.sent += 1;
      await db.rpc("mark_sms_sent", {
        p_id: message.id,
        p_twilio_sid: result.sid,
        p_body: body,
      });
    } else {
      summary.failed += 1;
      summary.errors.push(result.error);
      await db.rpc("mark_sms_failed", { p_id: message.id, p_error: result.error });
    }
  }

  return summary;
}
