"use client";

import { useRef, useState } from "react";
import { useTranslations } from "next-intl";

import { AVATAR_BUCKET } from "@/lib/avatar-bucket";
import { Avatar } from "@/components/ui/avatar";
import { Button, Callout } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Choose a photograph.
 *
 * THE FILE IS RE-ENCODED IN THE BROWSER BEFORE IT LEAVES, and that is not only about size. A photo
 * off a phone carries EXIF, which includes GPS -- so uploading the original would put the member's
 * home coordinates in a bucket, attached to their face, for a product whose entire privacy posture
 * is that locations are not casually shared. Drawing it to a canvas and re-encoding as JPEG drops
 * every tag. It is the same technique the request wizard uses on recovery photos, and the rule in
 * CLAUDE.md is never to add a path that uploads the original file.
 *
 * It also squares and downscales to 512px: an avatar is rendered at 80px at most, and a 4MB
 * portrait would be slow to fetch on the one-bar connection this app is built for.
 *
 * THE WRITE ORDER MATTERS. Upload first, then record the path. The reverse would point the profile
 * at an object that might never arrive, and the screen would show a broken picture for a member
 * who had done nothing wrong. If the upload succeeds and the update fails, the orphan sits in the
 * bucket costing nothing and the member still sees their old photograph.
 */
export function AvatarUpload({
  userId,
  name,
  initialSrc,
}: {
  userId: string;
  name: string | null;
  /** A signed URL from the server, or null. */
  initialSrc: string | null;
}) {
  const t = useTranslations("account");
  const input = useRef<HTMLInputElement>(null);

  const [src, setSrc] = useState<string | null>(initialSrc);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function choose(file: File) {
    setBusy(true);
    setError(null);

    try {
      const jpeg = await toSquareJpeg(file);

      const signRes = await fetch("/api/photos/avatar/sign-upload", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ contentType: "image/jpeg" }),
      });

      if (!signRes.ok) {
        const body = (await signRes.json().catch(() => ({}))) as { error?: string };
        setError(body.error === "rate_limited" ? t("photoTooMany") : t("photoFailed"));
        return;
      }

      const { path, token } = (await signRes.json()) as { path: string; token: string };

      const supabase = supabaseBrowser();
      const { error: uploadError } = await supabase.storage
        .from(AVATAR_BUCKET)
        .uploadToSignedUrl(path, token, jpeg, { contentType: "image/jpeg" });

      if (uploadError) {
        setError(t("photoFailed"));
        return;
      }

      // Only now does the profile point at it. By user_id, like every other write on this screen:
      // profiles_self_read is "own row OR app.is_admin()", so an admin without this filter would
      // be writing against a statement that matched five rows.
      const { data: written, error: saveError } = await supabase
        .from("profiles")
        .update({ avatar_path: path })
        .eq("user_id", userId)
        .select("user_id");

      if (saveError || !written || written.length === 0) {
        setError(t("photoFailed"));
        return;
      }

      // Show it immediately from the local file rather than waiting for a round trip to mint a
      // signed URL for an object the browser already has.
      setSrc(URL.createObjectURL(jpeg));
    } catch {
      setError(t("photoFailed"));
    } finally {
      setBusy(false);
      // Clear the input, or choosing the SAME file again fires no change event and the member
      // thinks the second attempt was ignored.
      if (input.current) input.current.value = "";
    }
  }

  async function remove() {
    setBusy(true);
    setError(null);

    // ASK FOR THE ROW BACK, exactly as choose() does above. A zero-row UPDATE through PostgREST is
    // a silent success, so without this the picture disappears from the screen, the member is told
    // nothing is wrong, and a reload brings it straight back -- the same shape as the /account save
    // that reported "Saved" while writing nothing, which cost the owner a day on 2026-10-04.
    const { data: written, error: saveError } = await supabaseBrowser()
      .from("profiles")
      .update({ avatar_path: null })
      .eq("user_id", userId)
      .select("user_id");

    setBusy(false);

    if (saveError || !written || written.length === 0) {
      setError(t("photoFailed"));
      return;
    }

    // The object is deliberately left in the bucket. Deleting it needs the service role, and a
    // member removing a picture from their profile is not a request to erase it from storage --
    // account deletion is, and that is a different path.
    setSrc(null);
  }

  return (
    <div className="space-y-3">
      {error ? <Callout tone="danger">{error}</Callout> : null}

      <div className="flex items-center gap-4">
        <Avatar name={name} src={src} size="lg" />
        <div className="min-w-0 flex-1 space-y-2">
          <input
            ref={input}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            className="hidden"
            onChange={(event) => {
              const file = event.target.files?.[0];
              if (file) void choose(file);
            }}
          />
          <Button variant="secondary" onClick={() => input.current?.click()} disabled={busy}>
            {busy ? t("photoWorking") : src ? t("photoChange") : t("photoAdd")}
          </Button>
          {src ? (
            <Button variant="quiet" onClick={remove} disabled={busy}>
              {t("photoRemove")}
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/**
 * Square, downscale and re-encode as JPEG.
 *
 * `createImageBitmap(file, { imageOrientation: "from-image" })` applies the EXIF rotation before
 * drawing, so a portrait taken sideways is not stored sideways -- and the canvas re-encode is what
 * drops the rest of the EXIF, GPS included. Without `from-image` the orientation tag is discarded
 * along with everything else and the picture ends up rotated.
 */
async function toSquareJpeg(file: File): Promise<Blob> {
  const SIZE = 512;

  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });

  // Centre crop to a square, so a wide photo is not squashed into a circle.
  const side = Math.min(bitmap.width, bitmap.height);
  const sx = (bitmap.width - side) / 2;
  const sy = (bitmap.height - side) / 2;

  const canvas = document.createElement("canvas");
  canvas.width = SIZE;
  canvas.height = SIZE;

  const context = canvas.getContext("2d");
  if (!context) throw new Error("no canvas context");

  context.drawImage(bitmap, sx, sy, side, side, 0, 0, SIZE, SIZE);
  bitmap.close();

  return await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("encode failed"))),
      "image/jpeg",
      0.85,
    );
  });
}
