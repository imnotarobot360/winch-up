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
