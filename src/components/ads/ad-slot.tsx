"use client";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";

import { supabaseBrowser } from "@/lib/supabase/client";

type Ad = {
  creative_id: string;
  headline: string;
  body: string | null;
  cta_label: string | null;
  cta_url: string;
  image_path: string | null;
  business_name: string;
  category: string;
  surface: string;
  labelled: boolean;
  not_a_volunteer: boolean;
};

/**
 * One advertisement, on one of the three surfaces that may carry one.
 *
 * Things this component will not do, by construction:
 *
 * It will not render an ad that did not arrive with `labelled`. The label is not a prop, a
 * config flag or a styling decision — it comes back in the same row as the headline, and an ad
 * without it is treated as a bug and dropped.
 *
 * It will not render inside anything urgent. There is no surface value for the request wizard, a
 * live recovery or a message thread, so this component has nowhere to be mounted on those pages
 * even if somebody tried.
 *
 * It does not block anything. There is no interstitial, no delay, no "continue" button. A person
 * whose truck is in a creek never waits on this, and on a slow connection the slot simply stays
 * empty rather than holding the page.
 *
 * Counting goes to /api/ads/event, which holds the service-role key and rate limits on an IP it
 * does not store. Nothing about the reader reaches the database.
 */
export function AdSlot({
  surface,
  slug,
  className,
}: {
  surface: "community_feed" | "trails" | "resources";
  slug?: string;
  className?: string;
}) {
  const t = useTranslations("ads");
  const [ad, setAd] = useState<Ad | null>(null);
  const counted = useRef(false);

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const { data, error } = await supabaseBrowser().rpc("ads_for", {
        p_surface: surface,
        p_slug: slug ?? null,
        p_lng: null,
        p_lat: null,
        p_limit: 1,
      });

      if (cancelled || error) return;

      const result = data as { ok: boolean; ads?: Ad[] };
      const first = result.ok ? result.ads?.[0] : undefined;

      // The label arrives with the ad or the ad does not run.
      if (!first || !first.labelled) return;

      setAd(first);
    })();

    return () => {
      cancelled = true;
    };
  }, [surface, slug]);

  useEffect(() => {
    if (!ad || counted.current) return;
    counted.current = true;
    void record(ad.creative_id, surface, "impression");
  }, [ad, surface]);

  if (!ad) return null;

  return (
    <aside
      aria-label={t("label")}
      className={`rounded-2xl border-2 border-dashed border-line bg-surface-sunk p-4 ${className ?? ""}`}
    >
      {/* First thing in the box, before the advertiser's words. */}
      <p className="text-xs font-bold uppercase tracking-wide text-ink-faint">{t("label")}</p>

      <p className="mt-2 text-base font-semibold">{ad.headline}</p>
      {ad.body ? <p className="mt-1 text-base text-ink-soft">{ad.body}</p> : null}

      <p className="mt-2 text-sm text-ink-faint">{ad.business_name}</p>

      {/* The line that matters most in this whole feature. A tow operator advertising inside a
          volunteer recovery group must not be mistaken for one of the volunteers. */}
      {ad.not_a_volunteer ? (
        <p className="mt-2 rounded-field border-l-4 border-danger bg-danger-tint p-2 text-sm">
          {t("notAVolunteer")}
        </p>
      ) : null}

      <a
        href={ad.cta_url}
        target="_blank"
        rel="noreferrer nofollow sponsored"
        onClick={() => void record(ad.creative_id, surface, "click")}
        className="mt-3 inline-flex min-h-12 items-center rounded-field border-2 border-line px-4 text-base font-semibold"
      >
        {ad.cta_label ?? t("defaultCta")}
      </a>
    </aside>
  );
}

async function record(creativeId: string, surface: string, kind: "impression" | "click") {
  try {
    await fetch("/api/ads/event", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ creativeId, surface, kind }),
      keepalive: true,
    });
  } catch {
    // A count that does not arrive is a count that does not arrive. It is never worth an error
    // in front of a reader, and never worth retrying into a loop.
  }
}
