import "server-only";

import webpush from "web-push";

import { supabaseAdmin } from "@/lib/supabase/admin";
import en from "../../../messages/en.json";
import es from "../../../messages/es.json";

/**
 * Sending the push notifications the database has queued.
 *
 * The counterpart to `drainSmsOutbox`, and shaped the same way: the database decides who should
 * hear about what and records the outcome, and this does the part that needs a network and a
 * crypto library. `drain_notifications` deliberately leaves push rows alone so the two cannot
 * race — see 20260923000400_push.sql.
 *
 * WHAT GOES IN A PUSH PAYLOAD
 *
 * What is DISPLAYED is the kind of thing and nothing else. A push notification is rendered on a
 * lock screen that anybody standing nearby can read, so the title says "someone needs help
 * nearby" and never a name, a number, a pin or a set of coordinates. Tapping it opens the app,
 * which is authenticated, and the detail lives there.
 *
 * The `url` is not displayed, and it may contain a status token: Phase 13's notifications link
 * to /r/<token>, which is the member's own link to their own recovery. That is acceptable here
 * and nowhere else, for one specific reason — a Web Push payload is encrypted to the
 * subscription's own keys, so Apple, Google and Mozilla relay it without being able to read it.
 * Only the browser that registered decrypts it.
 *
 * The team notifications added later link to /recovery/<id> instead, not because a token here
 * would be a leak, but because nothing needs one to say "Mike is on site".
 */

const MESSAGES = { en, es } as Record<string, Record<string, unknown>>;

/** Both keys, or push is off. Absent locally and in CI, where nothing is sent. */
export function pushConfigured(): boolean {
  return Boolean(
    process.env.VAPID_PUBLIC_KEY &&
      process.env.VAPID_PRIVATE_KEY &&
      process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY,
  );
}

let configured = false;
function configure() {
  if (configured) return;
  webpush.setVapidDetails(
    // A contact for the push service to reach if this app misbehaves. Theirs, not a user's.
    process.env.VAPID_SUBJECT ?? "mailto:help@winch-up.com",
    process.env.VAPID_PUBLIC_KEY as string,
    process.env.VAPID_PRIVATE_KEY as string,
  );
  configured = true;
}

/**
 * Resolve a notification's title from the same strings the in-app list uses.
 *
 * Read out of the message JSON rather than through next-intl: this runs in a drain, outside any
 * request, where there is no locale context to hang a translator off. Reading the same files is
 * what stops push copy drifting away from the copy beside it in the inbox.
 */
function localise(titleKey: string, locale: string): string | null {
  const bundle = MESSAGES[locale] ?? MESSAGES.en;
  const path = titleKey.replace(/^notify\./, "").split(".");

  let node: unknown = bundle.notify;
  for (const segment of path) {
    if (node && typeof node === "object" && segment in (node as Record<string, unknown>)) {
      node = (node as Record<string, unknown>)[segment];
    } else {
      return null;
    }
  }

  return typeof node === "string" ? node : null;
}

type Claim = {
  delivery_id: string;
  subscription_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  kind: string;
  title_key: string;
  params: Record<string, unknown> | null;
  locale: string;
  url: string | null;
};

export type PushDrainResult = {
  sent: number;
  gone: number;
  failed: number;
  skipped: boolean;
};

export async function drainPush(limit = 100): Promise<PushDrainResult> {
  const result: PushDrainResult = { sent: 0, gone: 0, failed: 0, skipped: false };

  // No keys, nothing happens, and the rows stay queued rather than being burned. Somebody who
  // configures push later still gets the backlog, within its retry window.
  if (!pushConfigured()) {
    result.skipped = true;
    return result;
  }

  configure();
  const admin = supabaseAdmin();

  const { data, error } = await admin.rpc("claim_push_deliveries", { p_limit: limit });
  if (error) {
    console.error("[push] claim failed", error);
    return result;
  }

  const claims = (data as Claim[] | null) ?? [];

  for (const claim of claims) {
    const title =
      localise(claim.title_key, claim.locale) ?? localise(`kinds.${claim.kind}`, claim.locale);

    const payload = JSON.stringify({
      // Deliberately thin. See the note at the top of this file.
      title: title ?? "Winch Up",
      kind: claim.kind,
      // Where tapping it should land.
      //
      // This read claim.params?.url, which app.notify never sets -- the url has its own column --
      // so every push ever built here would have opened /me regardless of what it was about.
      // Unnoticed because push has never run in production and the one delivery test I wrote
      // checked that a payload arrived, not where it pointed.
      url: claim.url ?? "/me",
    });

    try {
      await webpush.sendNotification(
        {
          endpoint: claim.endpoint,
          keys: { p256dh: claim.p256dh, auth: claim.auth },
        },
        payload,
        { TTL: 60 * 30, urgency: claim.kind.startsWith("recovery") ? "high" : "normal" },
      );

      await admin.rpc("record_push_result", {
        p_delivery_id: claim.delivery_id,
        p_ok: true,
        p_subscription_id: claim.subscription_id,
      });
      result.sent += 1;
    } catch (caught) {
      // 404 and 410 are the push service saying this browser is gone for good. Anything else
      // might be transient and is backed off.
      const status = (caught as { statusCode?: number }).statusCode;
      const gone = status === 404 || status === 410;

      await admin.rpc("record_push_result", {
        p_delivery_id: claim.delivery_id,
        p_ok: false,
        p_error: `${status ?? "?"} ${(caught as Error).message ?? ""}`.slice(0, 200),
        p_gone: gone,
        p_subscription_id: claim.subscription_id,
      });

      if (gone) result.gone += 1;
      else result.failed += 1;
    }
  }

  return result;
}
