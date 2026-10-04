import "server-only";

import { AVATAR_BUCKET } from "@/lib/avatar-bucket";
import { supabaseAdmin } from "@/lib/supabase/admin";

/** Ten minutes, matching rig photos: long enough to render and reload, short enough that a leaked URL dies. */
const TTL_SECONDS = 600;

/**
 * A signed URL for one member's photograph, server-side only.
 *
 * The bucket is private and has no anon policy, so this is the only way a face reaches a browser.
 *
 * A path that cannot be signed yields null rather than throwing. A deleted object should leave the
 * initials showing, not take down the account screen -- the same rule rig photos follow, and the
 * reason the Avatar component still renders initials when it gets no src.
 */
export async function signAvatar(path: string | null | undefined): Promise<string | null> {
  if (!path) return null;

  const { data, error } = await supabaseAdmin()
    .storage.from(AVATAR_BUCKET)
    .createSignedUrl(path, TTL_SECONDS);

  if (error || !data?.signedUrl) {
    console.error("[avatar] could not sign", error?.message);
    return null;
  }

  return data.signedUrl;
}
