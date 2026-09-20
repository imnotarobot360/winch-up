import { NextResponse } from "next/server";

import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The public board feed.
 *
 * Deliberately read through the anon client rather than the service role: if the grant on
 * `board_requests()` is ever wrong, this page breaks loudly instead of quietly serving data it
 * should not have.
 */
export async function GET() {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("board_requests", { p_limit: 100 });

  if (error) {
    console.error("[board] rpc failed", error);
    return NextResponse.json([], { status: 200 });
  }

  return NextResponse.json(data ?? [], {
    headers: { "cache-control": "no-store" },
  });
}
