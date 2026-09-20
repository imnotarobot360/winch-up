import { NextResponse } from "next/server";

import { LIMITS } from "@/config/app";
import { clientIpFrom, PHOTO_BUCKET, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ALLOWED = new Set(["image/jpeg", "image/png", "image/webp"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Mint a short-lived signed upload URL for one photo.
 *
 * The browser never holds a Storage credential and the bucket has no anon policies, so this is
 * the only way a photo gets in. Photos are written under `incoming/<draftId>/` before a request
 * row exists; `create_request` records those paths as-is. Anything under `incoming/` that is not
 * referenced by `request_photos` after 24 h is sweepable.
 */
export async function POST(request: Request) {
  let body: { draftId?: string; index?: number; contentType?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const { draftId, index, contentType } = body;

  if (!draftId || !UUID.test(draftId)) {
    return NextResponse.json({ error: "bad_draft_id" }, { status: 400 });
  }

  if (typeof index !== "number" || index < 0 || index >= LIMITS.maxPhotos) {
    return NextResponse.json({ error: "bad_index" }, { status: 400 });
  }

  if (!contentType || !ALLOWED.has(contentType)) {
    return NextResponse.json({ error: "bad_content_type" }, { status: 400 });
  }

  const db = supabaseAdmin();
  const ip = clientIpFrom(request.headers);

  // 30 signed URLs an hour per address is far more than 3 photos a request needs, and far less
  // than anyone can use the bucket as free storage with.
  if (ip) {
    const { data: allowed, error: limitError } = await db.rpc("check_rate_limit", {
      p_key: `upload:ip:${ip}`,
      p_max: 30,
      p_window_seconds: 3600,
    });

    if (limitError) {
      console.error("[sign-upload] rate limit check failed", limitError);
    } else if (allowed === false) {
      return NextResponse.json({ error: "rate_limited" }, { status: 429 });
    }
  }

  const extension =
    contentType === "image/png" ? "png" : contentType === "image/webp" ? "webp" : "jpg";
  const path = `incoming/${draftId}/${index}.${extension}`;

  const { data, error } = await db.storage
    .from(PHOTO_BUCKET)
    .createSignedUploadUrl(path, { upsert: true });

  if (error || !data) {
    console.error("[sign-upload] could not sign", error);
    return NextResponse.json({ error: "sign_failed" }, { status: 500 });
  }

  return NextResponse.json({
    path: data.path,
    signedUrl: data.signedUrl,
    token: data.token,
    contentType,
  });
}
