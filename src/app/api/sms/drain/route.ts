import { NextResponse } from "next/server";

import { drainSmsOutbox } from "@/lib/sms/drain";
import { supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Drain the SMS outbox.
 *
 * Called by the scheduled dispatch job (M3) and available for manual kicks during development.
 * Guarded by a shared secret: anyone who can call this can make the app send texts.
 *
 * It drains two queues, because they run on the same clock and neither deserves its own cron
 * entry to forget to set up: the SMS outbox, and notification deliveries. The notification
 * drain also sends event reminders, which is why it runs even when there is no SMS to send.
 *
 * A failure in one must not stop the other. Somebody stuck in a ditch is waiting on the first.
 */
export async function POST(request: Request) {
  const secret = process.env.DISPATCH_TICK_SECRET;

  if (!secret) {
    return NextResponse.json({ error: "not_configured" }, { status: 503 });
  }

  const authorization = request.headers.get("authorization");
  if (authorization !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const sms = await drainSmsOutbox(50);

  let notifications: unknown = { ok: false, error: "not_run" };
  try {
    const { data, error } = await supabaseAdmin().rpc("drain_notifications", { p_limit: 200 });
    notifications = error ? { ok: false, error: error.message } : data;
  } catch (error) {
    // Logged, not thrown. The SMS half already ran and its result is worth returning.
    console.error("[sms/drain] notification drain failed", error);
    notifications = { ok: false, error: "threw" };
  }

  // Retention: scrub the phone number and exact pin off recoveries that closed long enough
  // ago that nobody needs them. Cheap when there is nothing to do, and it means no separate
  // cron entry for the one job whose failure nobody would notice.
  let retention: unknown = { ok: false, error: "not_run" };
  try {
    const { data, error } = await supabaseAdmin().rpc("apply_retention", {});
    retention = error ? { ok: false, error: error.message } : data;
  } catch (error) {
    console.error("[sms/drain] retention failed", error);
    retention = { ok: false, error: "threw" };
  }

  return NextResponse.json({ ...sms, notifications, retention });
}
