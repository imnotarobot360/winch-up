import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";
import { APP_NAME } from "@/config/app";

import { renderEmail, type EmailParams, type EmailTemplateKey } from "./templates";

/**
 * Sending account email, behind a driver so the provider is one swap rather than a rewrite.
 *
 * WHY THERE IS A DRIVER AT ALL
 *
 * As of 2026-09-24 winch-up.com has no MX record, no SPF and no DMARC, which means the mailbox
 * this is all supposed to come from does not exist yet and nothing is authorised to send as it.
 * Choosing a provider costs money and needs DNS changes, so it is the owner's call. Everything
 * on this side of that decision -- the copy, the logging, the idempotency, the screens -- is the
 * same whichever way it goes, so it is built now and the provider is an adapter plus env vars.
 *
 * Until one is configured the driver is `none`: it renders the message, records the attempt with
 * status `skipped` and a reason, and returns. It does NOT throw and it does NOT pretend to have
 * sent. A caller that needs to know can read the result.
 *
 * WHAT THIS DOES NOT SEND
 *
 * Not the verification email and not the password reset. Supabase Auth owns both, mints their
 * single-use tokens and sends them itself; §3 of the brief is explicit that a provider's own
 * verification flow must not be replaced with hand-rolled tokens, and rolling our own here would
 * mean minting credentials in application code. Those two get branded by pointing Supabase at
 * the same provider's SMTP and pasting the rendered templates into its dashboard -- see
 * docs/email-setup.md. This module sends the ones Supabase has no opinion about: welcome, and
 * the account-security notices.
 */

export type SendResult =
  | { ok: true; providerMessageId: string | null; deduped: boolean }
  | { ok: false; skipped: true; reason: string }
  | { ok: false; skipped: false; error: string };

export type SendArgs = {
  to: string;
  key: EmailTemplateKey;
  /** Who this is about, for the delivery log. Null for an address with no account yet. */
  userId?: string | null;
  locale?: string;
  actionUrl?: string;
  params?: EmailParams;
  /**
   * Makes a repeat call a no-op. §5 and §8 both require the welcome email to go once per
   * verified account, and a retry, a double webhook or a second tab must not produce a second
   * one. Same key twice = one email, enforced by a unique index rather than by a read-then-write.
   */
  idempotencyKey?: string;
};

type Driver = (message: {
  from: string;
  to: string;
  subject: string;
  html: string;
  text: string;
  replyTo?: string;
}) => Promise<{ id: string | null }>;

/* ------------------------------------------------------------------ config */

function config() {
  const provider = (process.env.EMAIL_PROVIDER ?? "none").toLowerCase();
  const supportEmail = process.env.EMAIL_SUPPORT_ADDRESS ?? "help@winch-up.com";
  return {
    provider,
    supportEmail,
    from: process.env.EMAIL_FROM ?? `${APP_NAME} <${supportEmail}>`,
    // Set this when the sending domain cannot receive mail, so replies reach a real inbox
    // instead of bouncing into nothing.
    replyTo: process.env.EMAIL_REPLY_TO || undefined,
    siteUrl: (process.env.NEXT_PUBLIC_SITE_URL ?? "https://www.winch-up.com").replace(/\/$/, ""),
  };
}

/* ----------------------------------------------------------------- drivers */

const DRIVERS: Record<string, Driver> = {
  /**
   * Resend. Chosen as the first adapter because it gives SMTP credentials for Supabase Auth and
   * an HTTP API for these, so one account covers both halves. Nothing here is Resend-specific
   * beyond this function.
   */
  resend: async (message) => {
    const apiKey = process.env.RESEND_API_KEY;
    if (!apiKey) throw new Error("EMAIL_PROVIDER=resend but RESEND_API_KEY is not set");

    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        from: message.from,
        to: [message.to],
        subject: message.subject,
        html: message.html,
        text: message.text,
        ...(message.replyTo ? { reply_to: message.replyTo } : {}),
      }),
    });

    if (!response.ok) {
      // The body carries the reason; the status alone does not distinguish a bad key from an
      // unverified domain, and those need different fixes.
      const body = await response.text().catch(() => "");
      throw new Error(`resend ${response.status}: ${body.slice(0, 300)}`);
    }

    const json = (await response.json()) as { id?: string };
    return { id: json.id ?? null };
  },

  /**
   * Any SMTP server, including Google Workspace.
   *
   * Generic rather than Gmail-specific on purpose: the same driver covers Workspace, a mailbox
   * host's relay, or a transactional provider's SMTP endpoint, and switching between them is
   * four environment variables rather than code.
   *
   * THINGS THAT BITE WITH GOOGLE WORKSPACE, all of them configuration rather than code:
   *
   *  - The password must be an app password, which needs 2-step verification on the account.
   *    A normal account password fails, and Workspace policy can disable app passwords outright.
   *  - The From address must be the authenticated mailbox or an alias it owns. Gmail silently
   *    REWRITES a From it does not recognise, so mail arrives from the wrong address and looks
   *    like a bug in this file. EMAIL_FROM has to match SMTP_USER.
   *  - Sending is capped at roughly 2,000 recipients a day with per-minute throttling on top.
   *    A signup spike hits that, and the failure is a temporary block rather than a clear error.
   *  - There are no delivery webhooks, so a bounce is invisible here. `email_deliveries` records
   *    that the server ACCEPTED the message, which is not the same as it arriving.
   */
  smtp: async (message) => {
    const host = process.env.SMTP_HOST ?? "smtp.gmail.com";
    const port = Number(process.env.SMTP_PORT ?? 465);
    const user = process.env.SMTP_USER;
    const pass = process.env.SMTP_PASSWORD;

    if (!user || !pass) {
      throw new Error("EMAIL_PROVIDER=smtp but SMTP_USER or SMTP_PASSWORD is not set");
    }

    // Imported here rather than at module scope so that a deployment using Resend, or none at
    // all, never loads it. This module is pulled in by the drain on every tick.
    const nodemailer = (await import("nodemailer")).default;

    const transport = nodemailer.createTransport({
      host,
      port,
      // 465 is implicit TLS; 587 starts plaintext and upgrades with STARTTLS. Deriving this from
      // the port rather than asking for it separately removes a way to get it subtly wrong.
      secure: port === 465,
      auth: { user, pass },
    });

    const info = await transport.sendMail({
      from: message.from,
      to: message.to,
      subject: message.subject,
      html: message.html,
      text: message.text,
      ...(message.replyTo ? { replyTo: message.replyTo } : {}),
    });

    // SMTP has no provider-side id, so this is the Message-ID we generated. It is still the
    // thing to grep for in the Workspace admin log, which is the only delivery trail there is.
    return { id: info.messageId ?? null };
  },
};

/**
 * Hands one already-rendered message to the configured provider.
 *
 * Shared by the direct path below and by the queue drain, so there is one place that knows how
 * to talk to a provider and one place to change when the provider changes.
 *
 * Returns `null` for the id when no provider is configured, and throws only on a real provider
 * failure -- the caller decides whether an absent provider is a skip or an error, because for a
 * queued row it means "leave it queued" and for a direct send it means "say so and carry on".
 */
export async function deliverRendered(
  to: string,
  rendered: { subject: string; html: string; text: string },
): Promise<{ id: string | null; configured: boolean }> {
  const { provider, from, replyTo } = config();
  const driver = DRIVERS[provider];

  if (!driver) return { id: null, configured: false };

  const { id } = await driver({
    from,
    to,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    replyTo,
  });

  return { id, configured: true };
}

/** The rendering context the drain needs, so it does not re-derive site URL and support address. */
export function emailContext() {
  const { siteUrl, supportEmail, provider } = config();
  return { siteUrl, supportEmail, provider };
}

/* -------------------------------------------------------------------- send */

/**
 * Renders, records and (when a provider is configured) sends one message.
 *
 * The delivery row is written BEFORE the network call, so a send that crashes the process still
 * leaves evidence that it was attempted. "Why did nobody get told" needs an answer, which is the
 * same reasoning the SMS outbox uses for suppressed rows.
 */
export async function sendAccountEmail(args: SendArgs): Promise<SendResult> {
  const { provider, from, replyTo, siteUrl, supportEmail } = config();
  const db = supabaseAdmin();

  const rendered = renderEmail(args.key, {
    locale: args.locale,
    actionUrl: args.actionUrl,
    siteUrl,
    supportEmail,
    params: args.params,
  });

  const idempotencyKey = args.idempotencyKey ?? null;

  // Claim the send. A unique index on idempotency_key means the second caller loses the insert
  // rather than racing a SELECT, which is the whole point -- two verifications landing at once
  // must not produce two welcome emails.
  const { data: claimed, error: claimError } = await db
    .from("email_deliveries")
    .insert({
      user_id: args.userId ?? null,
      template_key: args.key,
      locale: args.locale === "es" ? "es" : "en",
      idempotency_key: idempotencyKey,
      status: "sending",
      provider: provider === "none" ? null : provider,
    })
    .select("id")
    .single();

  if (claimError) {
    // 23505 is the unique violation: somebody already sent this one.
    if (claimError.code === "23505") {
      return { ok: true, providerMessageId: null, deduped: true };
    }
    return { ok: false, skipped: false, error: `delivery log insert failed: ${claimError.message}` };
  }

  const rowId = claimed.id as string;

  const driver = DRIVERS[provider];

  if (!driver) {
    const reason =
      provider === "none"
        ? "no email provider configured (EMAIL_PROVIDER is unset)"
        : `unknown EMAIL_PROVIDER "${provider}"`;

    await db
      .from("email_deliveries")
      .update({ status: "skipped", failure_reason: reason, completed_at: new Date().toISOString() })
      .eq("id", rowId);

    return { ok: false, skipped: true, reason };
  }

  try {
    const { id } = await driver({
      from,
      to: args.to,
      subject: rendered.subject,
      html: rendered.html,
      text: rendered.text,
      replyTo,
    });

    await db
      .from("email_deliveries")
      .update({
        status: "sent",
        provider_message_id: id,
        completed_at: new Date().toISOString(),
      })
      .eq("id", rowId);

    return { ok: true, providerMessageId: id, deduped: false };
  } catch (cause) {
    const error = cause instanceof Error ? cause.message : String(cause);

    await db
      .from("email_deliveries")
      .update({
        status: "failed",
        failure_reason: error.slice(0, 500),
        completed_at: new Date().toISOString(),
      })
      .eq("id", rowId);

    return { ok: false, skipped: false, error };
  }
}

/** True when a provider is configured, for UI that should not promise an email nobody can send. */
export function emailIsConfigured(): boolean {
  const { provider } = config();
  return provider !== "none" && provider in DRIVERS;
}
