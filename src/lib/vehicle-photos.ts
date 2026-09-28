import "server-only";

import { supabaseAdmin, VEHICLE_PHOTO_BUCKET } from "@/lib/supabase/admin";

/** Ten minutes: long enough to render a page and reload it, short enough that a leaked URL dies. */
const TTL_SECONDS = 600;

/**
 * Signed URLs for rig photos, server-side only.
 *
 * The bucket is private and has no anon policy, so this is the only way a photo reaches a
 * browser. Same approach `lib/status.ts` uses for recovery photos.
 *
 * Batched rather than one call per photo, because the members list renders up to fifty rigs and
 * fifty sequential round trips to Storage would be the slowest thing on the screen.
 *
 * A path that cannot be signed yields null rather than throwing. A missing or deleted object
 * should leave a member's card without a picture, not take down the page listing everybody.
 */
export async function signVehiclePhotos(
  paths: (string | null | undefined)[],
): Promise<Map<string, string>> {
  const wanted = [...new Set(paths.filter((p): p is string => Boolean(p)))];
  const signed = new Map<string, string>();

  if (wanted.length === 0) return signed;

  const { data, error } = await supabaseAdmin()
    .storage.from(VEHICLE_PHOTO_BUCKET)
    .createSignedUrls(wanted, TTL_SECONDS);

  if (error) {
    console.error("[vehicle-photos] could not sign", error.message);
    return signed;
  }

  for (const row of data ?? []) {
    // createSignedUrls reports per-item failures in the row rather than throwing, so a single
    // missing object does not lose the other forty-nine.
    if (row.signedUrl && row.path) signed.set(row.path, row.signedUrl);
  }

  return signed;
}

/** The single-photo case, for a profile page showing one rig. */
export async function signVehiclePhoto(path: string | null | undefined): Promise<string | null> {
  if (!path) return null;
  const map = await signVehiclePhotos([path]);
  return map.get(path) ?? null;
}
