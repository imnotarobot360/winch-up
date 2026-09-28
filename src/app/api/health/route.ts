import { NextResponse } from "next/server";

import { supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Is this thing working?
 *
 * Built for an uptime checker to poll every few minutes, and for a person to open at eleven at
 * night when somebody says nothing happened after they filed a request.
 *
 * It answers the question that actually matters for this product, which is not "is the web
 * server up" — Vercel will tell you that — but "is the dispatcher alive". A dead pg_cron job
 * looks exactly like a quiet afternoon: no requests move, no texts go out, and the site serves
 * perfectly. `system_heartbeats` exists so the two can be told apart, and this is where that
 * gets read.
 *
 * Deliberately unauthenticated, and deliberately tells you nothing about anybody: counts and
 * ages, no names, no numbers, no locations, no request ids. An uptime checker cannot hold a
 * secret, and a status endpoint that needs one does not get polled.
 *
 * HTTP status carries the verdict so a checker can alert without parsing: 200 healthy,
 * 503 degraded. Anything that would need somebody to get out of bed is degraded.
 */
export async function GET() {
  const started = Date.now();

  let database = false;
  let schedulerAgeSeconds: number | null = null;
  let smsQueued: number | null = null;
  let notificationsQueued: number | null = null;
  let openRequests: number | null = null;
  let reachableVolunteers: number | null = null;
  const problems: string[] = [];
  const warnings: string[] = [];

  try {
    const db = supabaseAdmin();

    // Not admin_system_health(): that one is gated on app.require_admin(), and the service
    // role has no session to be an admin with. system_health_summary() returns counts and ages
    // and nothing that could identify a person.
    const { data, error } = await db.rpc("system_health_summary");

    if (error) {
      problems.push("database unreachable");
    } else {
      database = true;

      const health = (data ?? {}) as {
        scheduler_age_seconds?: number | null;
        sms_queued?: number | null;
        sms_failed_24h?: number | null;
        notifications_queued?: number | null;
        open_requests?: number | null;
        reachable_volunteers?: number | null;
      };

      schedulerAgeSeconds = health.scheduler_age_seconds ?? null;
      smsQueued = health.sms_queued ?? null;
      notificationsQueued = health.notifications_queued ?? null;
      openRequests = health.open_requests ?? null;
      reachableVolunteers = health.reachable_volunteers ?? null;
    }
  } catch {
    problems.push("database unreachable");
  }

  // The tick is meant to run every 60 seconds. Five minutes of silence is not a slow minute,
  // it is a stopped scheduler, and every recovery in flight is frozen behind it.
  if (database) {
    if (schedulerAgeSeconds === null) {
      problems.push("scheduler has never run");
    } else if (schedulerAgeSeconds > 300) {
      problems.push(`scheduler last ran ${Math.round(schedulerAgeSeconds)}s ago`);
    }

    // A backlog here means texts are not reaching volunteers. The drain handles 50 at a time
    // every minute, so a few hundred is a queue that is not moving.
    if ((smsQueued ?? 0) > 200) {
      problems.push(`${smsQueued} texts waiting to send`);
    }
  }

  // Reported, not alerted on. Zero is this project's actual state today and is not a fault --
  // but it is the quietest possible failure, so it belongs on the page that somebody opens when
  // nothing happened.
  //
  // "Reachable", not "approved". Approval stopped gating anything when membership became
  // universal, and this warning went on counting it: it would have stayed silent while every
  // member had alerts switched off, which is exactly the situation it exists to catch.
  if (database && reachableVolunteers === 0) {
    warnings.push("no volunteers are available to help: a request would reach nobody");
  }

  /**
   * Is outbound SMS actually able to send?
   *
   * This belongs here for the reason at the top of the file: "no texts go out" is one of the
   * failures this endpoint exists to tell apart from a quiet afternoon. Three separate things
   * have to line up, they live in three different places, and each fails silently on its own.
   *
   * The dangerous combination is the LAST one below. Between turning `sms.outbound_enabled` on
   * and putting the credentials in Vercel, app.queue_sms stops suppressing and writes real
   * outbox rows, and the drain then hits "Twilio is not configured", which returns
   * retryable: false -- so every call-out is marked failed and BURNED rather than retried.
   * That state existed in production for part of 2026-09-28 and nothing anywhere reported it;
   * it did no harm only because no recovery happened to be open.
   *
   * No secret is exposed. These are booleans and a prefix shape, in the same class as the
   * counts and ages already here -- never a SID, never a token, never a number.
   */
  const twilioSid = process.env.TWILIO_ACCOUNT_SID;
  const twilioToken = process.env.TWILIO_AUTH_TOKEN;
  const twilioService = process.env.TWILIO_MESSAGING_SERVICE_SID;
  const twilioFrom = process.env.TWILIO_FROM_NUMBER;

  const smsConfigured = Boolean(twilioSid && twilioToken && (twilioService || twilioFrom));

  // A messaging service SID is MG + 32 hex. Anything else in that variable is a misconfiguration
  // that Twilio rejects at send time with 21212 "Invalid From Number" -- which is what a CM...
  // identifier pasted into the equivalent Supabase field did on 2026-09-28. Checked by shape
  // rather than reported by value, so this says "wrong kind of thing" without printing it.
  const serviceSidLooksWrong = Boolean(twilioService) && !/^MG[0-9a-f]{32}$/i.test(twilioService!);

  if (serviceSidLooksWrong) {
    problems.push(
      "TWILIO_MESSAGING_SERVICE_SID is not an MG... messaging service id: Twilio will reject " +
        "every send with 21212",
    );
  }

  if (database && !smsConfigured) {
    let smsEnabled = false;
    try {
      const { data } = await supabaseAdmin()
        .from("app_settings")
        .select("value")
        .eq("key", "sms.outbound_enabled")
        .maybeSingle();
      smsEnabled = (data?.value as boolean | null) === true;
    } catch {
      // Unreadable settings are already covered by "database unreachable" above.
    }

    if (smsEnabled) {
      // Not a warning. Messages are being destroyed, one per call-out, silently.
      problems.push(
        "sms.outbound_enabled is ON but Twilio is not configured: every call-out is being " +
          "marked failed and discarded, and STOP replies are refused",
      );
    } else {
      warnings.push("Twilio is not configured; SMS is off, so messages are carried by push");
    }
  }

  const healthy = database && problems.length === 0;

  return NextResponse.json(
    {
      status: healthy ? "ok" : "degraded",
      checkedAt: new Date().toISOString(),
      tookMs: Date.now() - started,
      checks: {
        database,
        schedulerAgeSeconds,
        smsQueued,
        notificationsQueued,
        openRequests,
        reachableVolunteers,
        // Whether a text could go out at all, and whether the sender id is the right kind of
        // thing. Booleans only -- see the note above.
        smsConfigured,
        smsSenderOk: !serviceSidLooksWrong,
      },
      problems,
      warnings,
    },
    {
      status: healthy ? 200 : 503,
      headers: { "cache-control": "no-store" },
    },
  );
}
