import { NextResponse } from "next/server";

import { clientIpFrom, supabaseAdmin, VEHICLE_PHOTO_BUCKET } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ALLOWED = new Set(["image/jpeg", "image/png", "image/webp"]);

/**
 * Mint a short-lived signed upload URL for one rig photo.
 *
 * Same shape as /api/photos/sign-upload, with one difference that is the whole point: this one
 * REQUIRES A SESSION, and it derives the storage path from that session rather than from
 * anything the browser sent.
 *
 * The recovery-photo route cannot do that -- a request is filed before an account row exists,
 * so its path is keyed by a draft id the client supplies. A rig photo always belongs to a
 * signed-in member, so the path is keyed by their user id and the browser gets no say in it.
 * If the client picked the prefix, one member could write into another's folder, and the read
 * side trusts that prefix to decide whose photo it is.
 *
 * The filename is a fresh uuid per upload rather than the vehicle id, because the photo is
 * chosen before the vehicle row exists. It also means replacing a photo never overwrites an
 * object something else is mid-read on.
 */
export async function POST(request: Request) {
  let body: { contentType?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const { contentType } = body;

  if (!contentType || !ALLOWED.has(contentType)) {
    return NextResponse.json({ error: "bad_content_type" }, { status: 400 });
  }

  const {
    data: { user },
  } = await (await supabaseServer()).auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "account_required" }, { status: 401 });
  }

  const db = supabaseAdmin();
  const ip = clientIpFrom(request.headers);

  // Lower than the recovery-photo limit on purpose. Somebody filing a request needs three
  // photos in a minute; somebody editing their garage does not need twenty rigs an hour, and
  // this bucket is not swept the way `incoming/` is.
  if (ip) {
    const { data: allowed, error: limitError } = await db.rpc("check_rate_limit", {
      p_key: `vehicle-upload:ip:${ip}`,
      p_max: 20,
      p_window_seconds: 3600,
    });

    if (limitError) {
      console.error("[vehicle sign-upload] rate limit check failed", limitError);
    } else if (allowed === false) {
      return NextResponse.json({ error: "rate_limited" }, { status: 429 });
    }
  }

  const extension =
    contentType === "image/png" ? "png" : contentType === "image/webp" ? "webp" : "jpg";
  const path = `${user.id}/${crypto.randomUUID()}.${extension}`;

  const { data, error } = await db.storage
    .from(VEHICLE_PHOTO_BUCKET)
    .createSignedUploadUrl(path, { upsert: true });

  if (error || !data) {
    console.error("[vehicle sign-upload] could not sign", error);
    return NextResponse.json({ error: "sign_failed" }, { status: 500 });
  }

  return NextResponse.json({
    path: data.path,
    signedUrl: data.signedUrl,
    token: data.token,
    contentType,
  });
}
