"use client";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";

import { Button } from "@/components/ui/primitives";
import { preparePhoto, uploadVehiclePhoto } from "@/lib/photos";
import { supabaseBrowser } from "@/lib/supabase/client";
import { VEHICLE_PHOTO_BUCKET } from "@/lib/vehicle-photo-bucket";

/**
 * Pick a photo of your rig.
 *
 * Uploads as soon as a file is chosen rather than on form submit. A 4 MB photo on one bar
 * should not be racing the Save button, and a member who picks a picture and then spends two
 * minutes filling in tyre sizes has given the upload two minutes to finish.
 *
 * The consequence is orphans: choose a photo, change your mind, close the tab, and an object
 * sits in the bucket referenced by nothing. That is deliberate and is the same trade the
 * recovery-photo flow makes -- anything not referenced by vehicles.photo_path is sweepable,
 * and it is a far better failure than losing the photo because Save was pressed too early.
 *
 * The preview is signed CLIENT-SIDE. The bucket is private, but 20260928000900 lets a member
 * read objects under their own user-id prefix, so the garage screen needs no privileged hop.
 */
export function RigPhotoField({
  value,
  onChange,
}: {
  value: string | null;
  onChange: (path: string | null) => void;
}) {
  const t = useTranslations("vehicles");
  const input = useRef<HTMLInputElement>(null);

  const [preview, setPreview] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Sign a URL for whatever is already saved. Re-runs when the path changes, which covers both
  // opening the form on an existing rig and finishing a fresh upload.
  useEffect(() => {
    let cancelled = false;

    async function load() {
      if (!value) {
        setPreview(null);
        return;
      }
      const { data } = await supabaseBrowser()
        .storage.from(VEHICLE_PHOTO_BUCKET)
        .createSignedUrl(value, 600);
      if (!cancelled) setPreview(data?.signedUrl ?? null);
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [value]);

  async function pick(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    // Always clear the input: picking the same file twice in a row fires no change event
    // otherwise, so a retry after a failed upload would silently do nothing.
    event.target.value = "";
    if (!file) return;

    setBusy(true);
    setError(null);

    try {
      // Shrinks and strips EXIF. The second matters more here than on a recovery photo: this
      // one is usually taken at home, so its GPS tag is the member's address.
      const prepared = await preparePhoto(file);
      const path = await uploadVehiclePhoto(prepared);
      // Show the local bitmap immediately; the effect above replaces it with the signed URL.
      setPreview(prepared.previewUrl);
      onChange(path);
    } catch {
      setError(t("photo.failed"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-2">
      <p className="text-base font-semibold text-ink">{t("photo.label")}</p>
      <p className="text-sm text-ink-faint">{t("photo.hint")}</p>

      {preview ? (
        // Not next/image: the src is a short-lived signed URL on a Storage host, so the
        // optimiser would cache a URL that expires in ten minutes.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={preview}
          alt={t("photo.alt")}
          className="aspect-video w-full rounded-xl border-2 border-line object-cover"
        />
      ) : (
        <div className="flex aspect-video w-full items-center justify-center rounded-xl border-2 border-dashed border-line bg-surface-sunk text-sm text-ink-faint">
          {t("photo.empty")}
        </div>
      )}

      {error ? <p className="text-sm text-danger">{error}</p> : null}

      <input
        ref={input}
        type="file"
        accept="image/*"
        // `capture` is deliberately NOT set. On a phone that would force the camera and stop
        // somebody choosing the good photo of their rig they already have.
        className="hidden"
        onChange={pick}
      />

      <div className="flex gap-2">
        <Button
          type="button"
          variant="secondary"
          size="md"
          disabled={busy}
          onClick={() => input.current?.click()}
        >
          {busy ? t("photo.uploading") : preview ? t("photo.replace") : t("photo.add")}
        </Button>

        {preview ? (
          <Button
            type="button"
            variant="quiet"
            size="md"
            disabled={busy}
            onClick={() => {
              onChange(null);
              setPreview(null);
            }}
          >
            {t("photo.remove")}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
