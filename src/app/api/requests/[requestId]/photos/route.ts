import { NextResponse } from "next/server";

import { PHOTO_BUCKET, supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Ten minutes, the same as the requester's own status page. */
const TTL_SECONDS = 600;

/**
 * A request's photographs, for a member the dispatcher would call out.
 *
 * TWO CLIENTS ON PURPOSE, and the split is the whole security of this route:
 *
 *   the USER's client asks request_photos_for_helper(), so the database decides -- with
 *   auth.uid() -- whether this member is inside the ring. The answer cannot be influenced by
 *   anything the browser sends except the request id.
 *
 *   the SERVICE ROLE client then signs the paths it was given, because the bucket is private
 *   and signing needs a key the browser must never hold. It signs what the first call
 *   returned and never looks anything up itself.
 *
 * Doing it the other way round -- service role reads the photos, route decides who may have
 * them -- is the same code with the authorisation in the weaker place, and one early return
 * away from handing a stranger the pictures.
 *
 * The refusal is always 404, matching request_photos_for_helper: too far away, closed, never
 * existed and not signed in must be indistinguishable, or this endpoint becomes a way to ask
 * whether a given id is a live recovery.
 */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ requestId: string }> },
) {
  const { requestId } = await params;

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("request_photos_for_helper", {
    p_request_id: requestId,
  });

  if (error) {
    console.error("[request photos] rpc failed", error.message);
    return NextResponse.json({ ok: false }, { status: 404 });
  }

  const result = data as { ok: boolean; paths?: string[] } | null;
  if (!result?.ok) return NextResponse.json({ ok: false }, { status: 404 });

  const db = supabaseAdmin();
  const urls: string[] = [];

  for (const path of result.paths ?? []) {
    const { data: signed } = await db.storage
      .from(PHOTO_BUCKET)
      .createSignedUrl(path, TTL_SECONDS);

    if (signed?.signedUrl) urls.push(signed.signedUrl);
  }

  // No caching: the link expires, and whether this member is still in the ring can change
  // between one request and the next.
  return NextResponse.json(
    { ok: true, photo_urls: urls },
    { headers: { "cache-control": "no-store" } },
  );
}
