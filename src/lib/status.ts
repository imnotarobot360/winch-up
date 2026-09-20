import "server-only";

import { PHOTO_BUCKET, supabaseAdmin } from "@/lib/supabase/admin";
import type { StatusPayload, StatusView } from "@/lib/types/status";

/**
 * Load a requester's own status page by token, and sign its photo URLs.
 *
 * The RPC does the redaction (the responder's phone appears only after acceptance); this just
 * turns storage paths into links that work for ten minutes.
 */
export async function loadStatus(token: string): Promise<StatusView | null> {
  if (!token || token.length < 16 || token.length > 64) return null;

  const db = supabaseAdmin();
  const { data, error } = await db.rpc("get_request_by_token", { p_token: token });

  if (error) {
    console.error("[status] rpc failed", error);
    return null;
  }

  const payload = data as StatusPayload | null;
  if (!payload) return null;

  const photoUrls: string[] = [];

  for (const photo of payload.photos ?? []) {
    const { data: signed } = await db.storage
      .from(PHOTO_BUCKET)
      .createSignedUrl(photo.path, 600);

    if (signed?.signedUrl) photoUrls.push(signed.signedUrl);
  }

  return { ...payload, photo_urls: photoUrls };
}
