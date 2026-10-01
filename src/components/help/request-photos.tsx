"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

/**
 * A request's photographs, for a member deciding whether to go.
 *
 * Until 2026-10-01 only the ACCEPTED helper saw these, so the decision to drive forty minutes
 * was made from a vehicle class and a sentence. The owner's call was to show them to members in
 * the ring -- the people this recovery would have alerted anyway.
 *
 * LOADED ON DEMAND, not with the feed. Two reasons, and the first is the honest one:
 *
 *   the links are signed and expire in ten minutes, so fetching them for every card on a feed
 *   somebody scrolls past would mint dozens of credentials nobody looks at;
 *
 *   and it keeps the feed cheap on the connection this app is built for -- one bar, in a
 *   truck. Photographs are the heaviest thing here and they load when asked for.
 *
 * The button is shown without knowing whether there are any: finding out costs the same call.
 * An empty result says so rather than leaving a spinner.
 */
export function RequestPhotos({ requestId }: { requestId: string }) {
  const t = useTranslations("help");

  const [urls, setUrls] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  async function load() {
    setBusy(true);
    setFailed(false);

    try {
      const res = await fetch(`/api/requests/${requestId}/photos`);

      if (!res.ok) {
        // 404 is also what "you are not close enough" looks like, deliberately -- the route
        // refuses to distinguish. Either way there is nothing to show.
        setFailed(true);
        return;
      }

      const body = (await res.json()) as { ok: boolean; photo_urls?: string[] };
      setUrls(body.photo_urls ?? []);
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  }

  if (urls === null) {
    return (
      <div className="mt-3">
        <button
          type="button"
          onClick={() => void load()}
          disabled={busy}
          className="text-sm font-semibold text-ink underline underline-offset-4 disabled:text-ink-faint"
        >
          {busy ? t("photosLoading") : t("photosShow")}
        </button>
        {failed ? <p className="mt-1 text-sm text-ink-faint">{t("photosUnavailable")}</p> : null}
      </div>
    );
  }

  if (urls.length === 0) {
    return <p className="mt-3 text-sm text-ink-faint">{t("photosNone")}</p>;
  }

  return (
    <ul className="mt-3 flex gap-2 overflow-x-auto">
      {urls.map((url) => (
        <li key={url} className="shrink-0">
          {/* A plain img, not next/image: these are signed URLs that expire in ten minutes, so
              the optimiser would cache a link that stops working and serve a broken picture to
              the next person. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={url}
            alt={t("photoAlt")}
            className="h-28 w-28 rounded-field border-2 border-line object-cover"
            loading="lazy"
          />
        </li>
      ))}
    </ul>
  );
}
