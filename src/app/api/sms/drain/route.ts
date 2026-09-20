import { NextResponse } from "next/server";

import { drainSmsOutbox } from "@/lib/sms/drain";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Drain the SMS outbox.
 *
 * Called by the scheduled dispatch job (M3) and available for manual kicks during development.
 * Guarded by a shared secret: anyone who can call this can make the app send texts.
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

  const summary = await drainSmsOutbox(50);
  return NextResponse.json(summary);
}
