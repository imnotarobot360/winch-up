"use client";

import { useRef, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout } from "@/components/ui/primitives";
import { LIMITS } from "@/config/app";
import { preparePhoto, uploadPhoto, type UploadedPhoto } from "@/lib/photos";

/**
 * Photos are optional. A request with no photo still dispatches — the step exists because a
 * picture of how buried the truck is tells a volunteer whether to bring a tractor, not because
 * it is required paperwork.
 */
export function PhotoStep({
  draftId,
  photos,
  onChange,
}: {
  draftId: string;
  photos: UploadedPhoto[];
  onChange: (next: UploadedPhoto[]) => void;
}) {
  const t = useTranslations("request.photos");
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleFiles(files: FileList | null) {
    if (!files?.length) return;

    setBusy(true);
    setError(null);

    const room = LIMITS.maxPhotos - photos.length;
    const accepted = Array.from(files).slice(0, Math.max(0, room));
    const added: UploadedPhoto[] = [];

    for (const [offset, file] of accepted.entries()) {
      try {
        const prepared = await preparePhoto(file);
        const uploaded = await uploadPhoto(prepared, draftId, photos.length + offset);
        added.push(uploaded);
      } catch (uploadError) {
        console.error("[photos]", uploadError);
        setError(uploadError instanceof Error ? uploadError.message : "upload_failed");
      }
    }

    if (added.length) onChange([...photos, ...added]);
    setBusy(false);
    if (inputRef.current) inputRef.current.value = "";
  }

  function remove(path: string) {
    const target = photos.find((photo) => photo.path === path);
    if (target) URL.revokeObjectURL(target.previewUrl);
    onChange(photos.filter((photo) => photo.path !== path));
  }

  return (
    <div className="space-y-4">
      <p className="text-base text-ink-soft">{t("help")}</p>

      {photos.length > 0 ? (
        <ul className="grid grid-cols-3 gap-3">
          {photos.map((photo) => (
            <li key={photo.path} className="space-y-2">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={photo.previewUrl}
                alt=""
                className="aspect-square w-full rounded-field border-2 border-line object-cover"
              />
              <Button
                type="button"
                size="md"
                variant="quiet"
                onClick={() => remove(photo.path)}
              >
                {t("remove")}
              </Button>
            </li>
          ))}
        </ul>
      ) : null}

      {error ? <Callout tone="danger">{t("failed")}</Callout> : null}

      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        capture="environment"
        multiple
        className="sr-only"
        onChange={(event) => handleFiles(event.target.files)}
      />

      <Button
        type="button"
        variant="secondary"
        disabled={busy || photos.length >= LIMITS.maxPhotos}
        onClick={() => inputRef.current?.click()}
      >
        {busy
          ? t("uploading")
          : photos.length === 0
            ? t("add")
            : t("addMore", { remaining: LIMITS.maxPhotos - photos.length })}
      </Button>

      <p className="text-sm text-ink-faint">{t("privacy")}</p>
    </div>
  );
}
