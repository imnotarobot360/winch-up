"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

type Item = {
  target_kind: "post" | "comment";
  target_id: string;
  created_at: string;
  report_count: number;
  reasons: string[];
  note: string | null;
  content: string | null;
  content_status: "visible" | "hidden" | "removed" | null;
  author_name: string;
};

const FILTERS = ["new", "actioned", "dismissed"] as const;
type Filter = (typeof FILTERS)[number];

/**
 * What a moderator sees, and the limit of what a moderator can do.
 *
 * The queue is grouped by the reported item rather than by the report. Five people reporting one
 * post is one decision, not five; a per-report list makes a moderator act on the same thing over
 * and over and makes a pile-on look like evidence.
 *
 * Who reported it is not on this screen and is not in the payload. A moderator deciding whether
 * to hide something does not need it, and a screen that shows it eventually gets read aloud to
 * the person it is about.
 */
export function ModerationQueue() {
  const t = useTranslations("moderation");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  // useNow ticks on an interval, so something written seconds ago can be newer than the clock it
  // is measured against, and next-intl then honestly reports it as "in 40 seconds". Measuring
  // from whichever is later reads as "now".
  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [filter, setFilter] = useState<Filter>("new");
  const [items, setItems] = useState<Item[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    setItems(null);
    const { data, error: rpcError } = await supabaseBrowser().rpc("moderation_queue", {
      p_status: filter,
    });

    if (rpcError) {
      setError(rpcError.message);
      return;
    }

    const result = data as { ok: boolean; items?: Item[] };
    setError(null);
    setItems(result.items ?? []);
  }, [filter]);

  useEffect(() => {
    void load();
  }, [load]);

  async function act(item: Item, fn: string, action?: string) {
    setBusy(item.target_id);
    const args: Record<string, unknown> = { p_kind: item.target_kind, p_id: item.target_id };
    if (action) args.p_action = action;

    const { error: rpcError } = await supabaseBrowser().rpc(fn, args);
    setBusy(null);

    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    await load();
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("intro")}</p>
      </div>

      {error ? <Callout tone="danger">{error}</Callout> : null}

      <div role="group" aria-label={t("filterLabel")} className="flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f}
            type="button"
            aria-pressed={filter === f}
            onClick={() => setFilter(f)}
            className={cn(
              "min-h-12 rounded-field border-2 px-4 py-2 text-base font-semibold",
              filter === f ? "border-brand bg-brand-tint text-ink" : "border-line text-ink-soft",
            )}
          >
            {t(`filters.${f}`)}
          </button>
        ))}
      </div>

      {items === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : items.length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">{t("empty")}</p>
        </Card>
      ) : (
        <ul className="space-y-4">
          {items.map((item) => (
            <li key={`${item.target_kind}:${item.target_id}`}>
              <Card className="space-y-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-base font-semibold">
                    {t(`kind.${item.target_kind}`)} · {item.author_name || t("someone")}
                  </p>
                  <p className="text-sm text-ink-faint">{relative(item.created_at)}</p>
                </div>

                <p className="text-sm font-semibold text-ink-soft">
                  {t("reportedBy", { count: item.report_count })} ·{" "}
                  {item.reasons.map((r) => t(`reasons.${r}`)).join(", ")}
                </p>

                {item.note ? (
                  <p className="text-sm italic text-ink-soft">&ldquo;{item.note}&rdquo;</p>
                ) : null}

                <blockquote className="whitespace-pre-wrap rounded-field border-2 border-line bg-surface-sunk p-3 text-base">
                  {item.content ?? t("gone")}
                </blockquote>

                {item.content_status && item.content_status !== "visible" ? (
                  <p className="text-sm font-semibold text-ink-faint">
                    {t(`status.${item.content_status}`)}
                  </p>
                ) : null}

                <div className="flex flex-wrap gap-2">
                  {item.content_status === "visible" ? (
                    <Button
                      variant="danger"
                      size="md"
                      className="w-auto"
                      disabled={busy === item.target_id}
                      onClick={() => void act(item, "moderate_content", "hide")}
                    >
                      {t("hide")}
                    </Button>
                  ) : (
                    <Button
                      variant="secondary"
                      size="md"
                      className="w-auto"
                      disabled={busy === item.target_id || item.content_status === "removed"}
                      onClick={() => void act(item, "moderate_content", "restore")}
                    >
                      {t("restore")}
                    </Button>
                  )}

                  {filter === "new" ? (
                    <Button
                      variant="secondary"
                      size="md"
                      className="w-auto"
                      disabled={busy === item.target_id}
                      onClick={() => void act(item, "moderation_dismiss")}
                    >
                      {t("dismiss")}
                    </Button>
                  ) : null}
                </div>
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
