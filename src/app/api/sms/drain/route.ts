import { NextResponse } from "next/server";

import { drainEmail } from "@/lib/email/drain";
import { drainPush } from "@/lib/push/send";
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

  // Push. Runs after the notification drain, which is what creates the deliveries it claims, so
  // something queued this tick goes out on this tick rather than waiting sixty seconds. It is a
  // no-op without VAPID keys and leaves the rows queued rather than burning their attempts.
  let push: unknown = { ok: false, error: "not_run" };
  try {
    push = await drainPush(100);
  } catch (error) {
    console.error("[sms/drain] push drain failed", error);
    push = { ok: false, error: "threw" };
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

  // Account email. Queued by a trigger the moment Supabase confirms an address, so the welcome
  // email goes out on the next tick rather than waiting for the member to come back to the site.
  // A no-op with no provider configured, and it leaves the rows queued rather than burning them.
  let email: unknown = { ok: false, error: "not_run" };
  try {
    email = await drainEmail(50);
  } catch (error) {
    console.error("[sms/drain] email drain failed", error);
    email = { ok: false, error: "threw" };
  }

  return NextResponse.json({ ...sms, notifications, push, retention, email });
}
