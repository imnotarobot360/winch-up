"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

type Announcement = {
  id: string;
  title: string;
  body: string;
  category: string;
  link_url: string | null;
  link_label: string | null;
  pinned: boolean;
};

/**
 * Announcements from the admins (spec section 1).
 *
 * WHAT THE DATABASE HAS ALREADY DECIDED BY THE TIME THIS RENDERS, so that none of it is re-decided
 * here where it could drift: `my_announcements()` returns only published announcements, inside their
 * time window, that this member has not dismissed, and that the member's stated area matches. This
 * component sorts nothing and filters nothing.
 *
 * RENDERS NOTHING WHEN THERE IS NOTHING, including while loading. A skeleton for a banner that is
 * usually absent would mean every community page visit flashed a grey box — and unlike a feed, the
 * common case here is empty.
 *
 * DISMISSAL IS OPTIMISTIC AND IS NOT ROLLED BACK. If the write fails the announcement reappears on the
 * next load, which is the right way round: somebody who closed a notice and saw it vanish has had their
 * intention honoured, and the worst case is seeing it once more. The opposite — a card that refuses to
 * close while the request retries — is the thing people complain about.
 */
export function AnnouncementBanner() {
  const t = useTranslations("announcements");
  const [items, setItems] = useState<Announcement[]>([]);

  const load = useCallback(async () => {
    const { data, error } = await supabaseBrowser().rpc("my_announcements", {});

    // Silent on failure, deliberately. This is a banner nobody asked for; an error panel at the top of
    // the community page, above the member's actual reason for being there, would be worse than the
    // announcement being missed.
    if (error) return;

    const result = data as { ok: boolean; announcements?: Announcement[] } | null;
    if (result?.ok) setItems(result.announcements ?? []);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function dismiss(id: string) {
    setItems((current) => current.filter((item) => item.id !== id));
    await supabaseBrowser().rpc("dismiss_announcement", { p_id: id });
  }

  if (items.length === 0) return null;

  return (
    <div className="space-y-3">
      {items.map((item) => (
        <Card key={item.id} className="space-y-2 p-4">
          {/* Marketing says so, on the face of it. The same reasoning as `labelled` on an advert:
              somebody reading quickly should not have to work out whether this is the group telling
              them something or somebody selling to them. */}
          {item.category === "marketing" ? (
            <p className="text-xs font-semibold uppercase tracking-wide text-ink-faint">
              {t("sponsored")}
            </p>
          ) : null}

          <h2 className="text-lg font-semibold text-ink">{item.title}</h2>
          <p className="whitespace-pre-wrap text-base text-ink-soft">{item.body}</p>

          {item.link_url ? (
            <a
              href={item.link_url}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-block text-base font-semibold text-brand underline underline-offset-4"
            >
              {item.link_label ?? t("readMore")}
            </a>
          ) : null}

          {/* Stacked below, not beside: Button is unconditionally w-full in this design system. */}
          <Button variant="secondary" onClick={() => dismiss(item.id)}>
            {t("dismiss")}
          </Button>
        </Card>
      ))}
    </div>
  );
}

/**
 * Exported separately so a page can show the empty state if it ever wants one. Nothing uses it yet;
 * it exists so that "there are no announcements" is a decision a page makes rather than something
 * this component assumes on everybody's behalf.
 */
export function AnnouncementsEmpty() {
  const t = useTranslations("announcements");
  return <Callout tone="neutral">{t("none")}</Callout>;
}
