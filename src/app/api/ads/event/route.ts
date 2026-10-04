import { NextResponse } from "next/server";

import { clientIpFrom, supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Every value of ad_surface, as of 20261003000800.
 *
 * THIS LIST GOING STALE IS SILENT, which is why it is worth a comment. Mounting an AdSlot on a new
 * surface while this set still had three entries meant the slot rendered, the advert was served, and
 * every impression came back 400 bad_surface -- a working advert that counts nothing, visible only in
 * a report that stays at zero. Found by reading this file after adding the events slot, not by anything
 * failing. If ad_surface grows again, grow this too.
 */
const SURFACES = new Set([
  "community_feed",
  "trails",
  "resources",
  "home_feed",
  "map",
  "events",
  "directory",
]);
const KINDS = new Set(["impression", "click"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Count an impression or a click.
 *
 * This exists as a server route rather than an RPC the browser can call because counting is the
 * one place an advertising system touches money, and the browser is not a witness anybody should
 * trust with that. `ad_record_event` is granted to nobody; this route holds the service-role key.
 *
 * The rate limit is keyed on the caller's IP, which is *used and not stored*. `ad_daily_stats`
 * has no column for it, and the rate-limit key is a hash-shaped string with a window, not a log.
 * That is the whole privacy position of this feature: the counts are per creative per day and
 * belong to nobody.
 *
 * It is not perfect. Somebody determined can still inflate a number from a handful of addresses,
 * and the honest answer to that is that this platform bills a flat monthly price rather than per
 * impression, so inflating the count wins nothing but a misleading chart.
 */
export async function POST(request: Request) {
  let body: { creativeId?: string; surface?: string; kind?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const { creativeId, surface, kind } = body;

  if (!creativeId || !UUID.test(creativeId)) {
    return NextResponse.json({ error: "bad_creative" }, { status: 400 });
  }

  if (!surface || !SURFACES.has(surface)) {
    return NextResponse.json({ error: "bad_surface" }, { status: 400 });
  }

  if (!kind || !KINDS.has(kind)) {
    return NextResponse.json({ error: "bad_kind" }, { status: 400 });
  }

  const db = supabaseAdmin();
  const ip = clientIpFrom(request.headers);

  if (ip) {
    // One reader scrolling a feed generates impressions steadily and clicks rarely, so the two
    // get very different allowances. Both are far above real use and far below "use this as a
    // counter API".
    const max = kind === "impression" ? 300 : 40;

    const { data: allowed, error } = await db.rpc("check_rate_limit", {
      p_key: `ad:${kind}:${ip}`,
      p_max: max,
      p_window_seconds: 3600,
    });

    if (error) {
      console.error("[ads/event] rate limit check failed", error);
    } else if (allowed === false) {
      // 204, not 429. A reader who trips this is not doing anything wrong and there is nothing
      // for the page to do about it; the count is simply not taken.
      return new NextResponse(null, { status: 204 });
    }
  }

  /**
   * The reader's stated area, read HERE and never accepted from the browser.
   *
   * This route holds the service-role key, so auth.uid() is null inside the RPC and the database
   * cannot look the reader up itself. The session client can: reading `profiles` as the member
   * returns their own row and nothing else, which is also a live check that the column grants from
   * 20261003000100 are in place.
   *
   * A city in the request body would let anybody write whatever they liked into an advertiser's
   * report, which is the one number on this page that is about money.
   *
   * A failure here is not a failure of the request. An impression with no area is recorded as
   * "unknown area", which is an honest row and the majority of them; losing the impression entirely
   * to protect a breakdown would be the wrong trade.
   */
  let area: { state: string | null; city: string | null; postal_code: string | null } = {
    state: null,
    city: null,
    postal_code: null,
  };

  try {
    const session = await supabaseServer();
    const {
      data: { user },
    } = await session.auth.getUser();

    if (user) {
      const { data: profile } = await session
        .from("profiles")
        .select("state, city, postal_code")
        // By id: profiles_self_read is "own row OR app.is_admin()", so for an admin this returns
        // every row and maybeSingle() fails. Here the failure was swallowed by the catch and the
        // impression filed under "no area given" -- wrong rather than loud.
        .eq("user_id", user.id)
        .maybeSingle();

      if (profile) {
        area = {
          state: profile.state ?? null,
          city: profile.city ?? null,
          postal_code: profile.postal_code ?? null,
        };
      }
    }
  } catch (locationError) {
    console.error("[ads/event] could not read the reader's area", locationError);
  }

  const { data, error } = await db.rpc("ad_record_event_at", {
    p_creative_id: creativeId,
    p_surface: surface,
    p_kind: kind,
    p_state: area.state,
    p_city: area.city,
    p_postal_code: area.postal_code,
  });

  if (error) {
    console.error("[ads/event] could not record", error);
    return NextResponse.json({ error: "failed" }, { status: 500 });
  }

  const result = data as { ok: boolean; error?: string } | null;

  // A creative that is no longer live answers 204 as well. It means a cached page is showing
  // something stale, which is not the reader's problem and must never become a billable event.
  if (!result?.ok) return new NextResponse(null, { status: 204 });

  return new NextResponse(null, { status: 204 });
}
