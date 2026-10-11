import { NextResponse } from "next/server";

import { signAvatar } from "@/lib/avatar-photos";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PRIVATE_HEADERS = {
  "Cache-Control": "private, no-store, max-age=0",
  Vary: "Cookie, Authorization",
};

/**
 * Resolve the signed-in member's own avatar to a short-lived signed URL.
 *
 * Web uses its server session cookie. Expo uses its Supabase access token as a Bearer token.
 * The caller never supplies a user id or storage path: this route verifies the session, derives
 * the user id from it, filters the profile row to that id, and signs only that row's path.
 */
export async function POST(request: Request) {
  let user: { id: string } | null = null;
  const authorization = request.headers.get("authorization");
  const match = authorization?.match(/^Bearer\s+(.+)$/i);

  if (match?.[1]) {
    const { data, error } = await supabaseAdmin().auth.getUser(match[1]);
    if (error || !data.user) {
      return NextResponse.json({ error: "account_required" }, { status: 401, headers: PRIVATE_HEADERS });
    }
    user = data.user;
  } else {
    const {
      data: { user: cookieUser },
    } = await (await supabaseServer()).auth.getUser();
    user = cookieUser;
  }

  if (!user) {
    return NextResponse.json({ error: "account_required" }, { status: 401, headers: PRIVATE_HEADERS });
  }

  const db = supabaseAdmin();
  const { data: profile, error } = await db
    .from("profiles")
    .select("avatar_path")
    .eq("user_id", user.id)
    .maybeSingle();

  if (error) {
    console.error("[avatar sign-read] profile lookup failed", error.message);
    return NextResponse.json({ error: "profile_unavailable" }, { status: 503, headers: PRIVATE_HEADERS });
  }

  const avatarUrl = await signAvatar(profile?.avatar_path);
  return NextResponse.json({ avatarUrl }, { headers: PRIVATE_HEADERS });
}
