import { NextResponse } from "next/server";

import { isPlausibleCoordinate, parseLocationInput } from "@/lib/geo";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Resolve the two location formats the browser cannot work out on its own:
 *
 *  - a Google Maps short link (maps.app.goo.gl/...), which carries no coordinates until it is
 *    followed
 *  - a what3words address, which needs their API
 *
 * what3words is optional. Without `W3W_API_KEY` set this returns `w3w_unavailable` and the
 * wizard tells the person to use GPS or the map pin instead — it never silently drops the
 * location on the floor.
 */

const SHORT_LINK_HOSTS = new Set(["maps.app.goo.gl", "goo.gl"]);

export async function POST(request: Request) {
  let body: { text?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const text = (body.text ?? "").trim();
  if (!text || text.length > 500) {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const parsed = parseLocationInput(text);

  if (parsed.kind === "coords") {
    return NextResponse.json({
      lat: parsed.lat,
      lng: parsed.lng,
      source: parsed.source,
    });
  }

  if (parsed.kind === "short_link") {
    return resolveShortLink(parsed.url);
  }

  if (parsed.kind === "what3words") {
    return resolveWhat3Words(parsed.words);
  }

  return NextResponse.json({ error: "unrecognised" }, { status: 422 });
}

async function resolveShortLink(url: string) {
  let target: URL;

  try {
    target = new URL(url);
  } catch {
    return NextResponse.json({ error: "unrecognised" }, { status: 422 });
  }

  // Only ever follow Google's own shorteners. This endpoint must not become a way to make the
  // server fetch arbitrary URLs.
  if (!SHORT_LINK_HOSTS.has(target.hostname.toLowerCase())) {
    return NextResponse.json({ error: "unrecognised" }, { status: 422 });
  }

  try {
    const response = await fetch(target.toString(), {
      redirect: "follow",
      signal: AbortSignal.timeout(6000),
      headers: { "user-agent": "Mozilla/5.0 (compatible; Winch Up/1.0)" },
    });

    const resolved = parseLocationInput(response.url);
    if (resolved.kind === "coords") {
      return NextResponse.json({
        lat: resolved.lat,
        lng: resolved.lng,
        source: "google_maps_link",
      });
    }

    return NextResponse.json({ error: "short_link_no_coords" }, { status: 422 });
  } catch {
    return NextResponse.json({ error: "short_link_failed" }, { status: 502 });
  }
}

async function resolveWhat3Words(words: string) {
  const key = process.env.W3W_API_KEY;

  if (!key) {
    return NextResponse.json({ error: "w3w_unavailable" }, { status: 501 });
  }

  try {
    const response = await fetch(
      `https://api.what3words.com/v3/convert-to-coordinates?words=${encodeURIComponent(words)}&key=${encodeURIComponent(key)}`,
      { signal: AbortSignal.timeout(6000) },
    );

    const payload = (await response.json()) as {
      coordinates?: { lat: number; lng: number };
    };

    const lat = payload?.coordinates?.lat;
    const lng = payload?.coordinates?.lng;

    if (typeof lat === "number" && typeof lng === "number" && isPlausibleCoordinate(lat, lng)) {
      return NextResponse.json({ lat, lng, source: "what3words" });
    }

    return NextResponse.json({ error: "w3w_not_found" }, { status: 422 });
  } catch {
    return NextResponse.json({ error: "w3w_failed" }, { status: 502 });
  }
}
