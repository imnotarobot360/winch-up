import { NextResponse } from "next/server";

import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The Help Someone feed, refetched as the browser learns where it is.
 *
 * Read through the session client, never the service role, for the same reason /api/board is: if
 * the grant on `nearby_requests()` is ever wrong this breaks loudly rather than quietly serving
 * open recovery requests to anybody who calls it. The RPC is granted to `authenticated` only,
 * and it reads auth.uid() itself to work out whose offers to mark and whose own requests to
 * hide -- so a signed-out caller gets nothing, from the database, not from a check here.
 */
export async function GET(request: Request) {
  const url = new URL(request.url);

  // Both or neither. A half-supplied coordinate is a bug somewhere upstream, and guessing which
  // half to keep would put somebody at latitude zero.
  const lat = Number.parseFloat(url.searchParams.get("lat") ?? "");
  const lng = Number.parseFloat(url.searchParams.get("lng") ?? "");
  const hasPoint =
    Number.isFinite(lat) && Number.isFinite(lng) &&
    Math.abs(lat) <= 90 && Math.abs(lng) <= 180;

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("nearby_requests", {
    p_lat: hasPoint ? lat : null,
    p_lng: hasPoint ? lng : null,
    p_radius_miles: 60,
    p_limit: 50,
  });

  if (error) {
    console.error("[help] rpc failed", error);
    return NextResponse.json([], { status: 200 });
  }

  return NextResponse.json(data ?? [], {
    headers: { "cache-control": "no-store" },
  });
}
