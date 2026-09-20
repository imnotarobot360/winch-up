import { NextResponse } from "next/server";

import { loadStatus } from "@/lib/status";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Polled by the status page every 15 s.
 *
 * Polling rather than a realtime socket on purpose: this page is read on one bar of signal in a
 * field, where a websocket that silently dies is worse than a request that visibly retries.
 */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ token: string }> },
) {
  const { token } = await params;
  const status = await loadStatus(token);

  if (!status) {
    return NextResponse.json({ error: "not_found" }, { status: 404 });
  }

  return NextResponse.json(status, {
    headers: { "cache-control": "no-store" },
  });
}
