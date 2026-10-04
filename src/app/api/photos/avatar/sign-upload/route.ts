import { NextResponse } from "next/server";

import { AVATAR_BUCKET } from "@/lib/avatar-bucket";
import { clientIpFrom, supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ALLOWED = new Set(["image/jpeg", "image/png", "image/webp"]);

/**
 * Mint a short-lived signed upload URL for one member's photograph.
 *
 * Modelled on /api/photos/vehicle/sign-upload, and the important property is the same one: THE
 * PATH COMES FROM THE SESSION, never from the request body. If the browser picked the prefix, one
 * member could write into another's folder -- and the read side trusts that prefix to decide whose
 * photograph it is.
 *
 * The filename is a fresh uuid per upload rather than a fixed "avatar.jpg". Overwriting one object
 * would mean every signed URL already in flight suddenly resolves to the new picture, and a
 * replaced photo would be served from caches under its old name. A new object each time, and the
 * old path simply stops being referenced.
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

  // Lower than the rig limit: a member has one face and changes it rarely. Ten an hour is
  // generous for somebody trying three crops and leaves no room for using this as free storage.
  if (ip) {
    const { data: allowed, error: limitError } = await db.rpc("check_rate_limit", {
      p_key: `avatar-upload:ip:${ip}`,
      p_max: 10,
      p_window_seconds: 3600,
    });

    if (limitError) {
      console.error("[avatar sign-upload] rate limit check failed", limitError);
    } else if (allowed === false) {
      return NextResponse.json({ error: "rate_limited" }, { status: 429 });
    }
  }

  const extension =
    contentType === "image/png" ? "png" : contentType === "image/webp" ? "webp" : "jpg";
  const path = `${user.id}/${crypto.randomUUID()}.${extension}`;

  const { data, error } = await db.storage
    .from(AVATAR_BUCKET)
    .createSignedUploadUrl(path, { upsert: true });

  if (error || !data) {
    console.error("[avatar sign-upload] could not sign", error);
    return NextResponse.json({ error: "sign_failed" }, { status: 500 });
  }

  return NextResponse.json({
    path: data.path,
    signedUrl: data.signedUrl,
    token: data.token,
    contentType,
  });
}
