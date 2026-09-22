"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

type Notification = {
  id: string;
  kind: string;
  title_key: string;
  params: Record<string, unknown>;
  url: string | null;
  read_at: string | null;
  created_at: string;
};

/**
 * Everything the app has told this person.
 *
 * The database stores a key and its parameters rather than a sentence, the same rule the SMS
 * outbox follows, so a notification written in September still renders in whichever language the
 * reader is using today. A key with no translation falls back to a plain description rather than
 * showing the key itself -- an unreadable notification is worse than a vague one.
 */
export function NotificationList() {
  const t = useTranslations("notifications");
  // The title keys the database stores live in their own namespace, so the copy for a
  // notification sits next to the SMS templates conceptually rather than next to this screen's
  // chrome. `notify.request.accepted` is `request.accepted` inside it.
  const tNotify = useTranslations("notify");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [items, setItems] = useState<Notification[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("my_notifications", {
      p_limit: 50,
    });

    if (rpcError) {
      setError("failed");
      return;
    }

    const result = data as { ok: boolean; error?: string; notifications?: Notification[] };
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setError(null);
    setItems(result.notifications ?? []);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function markAllRead() {
    setBusy(true);
    await supabaseBrowser().rpc("mark_notifications_read", { p_ids: null });
    setBusy(false);
    await load();
  }

  function label(item: Notification) {
    const key = item.title_key.replace(/^notify\./, "");

    // A key written to the database ahead of its translation must not render as
    // "request.on_site" in front of somebody. Fall back to the kind, which always exists.
    if (tNotify.has(key as never)) {
      return tNotify(key as never, item.params as never);
    }
    return t(`kinds.${item.kind}` as never);
  }

  const unread = (items ?? []).filter((i) => i.read_at === null).length;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        {unread > 0 ? (
          <Button variant="quiet" size="md" className="w-auto" disabled={busy} onClick={markAllRead}>
            {t("markAllRead")}
          </Button>
        ) : null}
      </div>

      <p className="text-base text-ink-soft">{t("intro")}</p>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {items === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : items.length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">{t("empty")}</p>
        </Card>
      ) : (
        <ul className="space-y-2">
          {items.map((item) => {
            const body = (
              <>
                <p className="text-base">{label(item)}</p>
                <p className="mt-1 text-sm text-ink-faint">
                  {t(`kinds.${item.kind}`)} · {relative(item.created_at)}
                </p>
              </>
            );

            return (
              <li
                key={item.id}
                className={cn(
                  "rounded-field border-2 p-3",
                  item.read_at === null ? "border-brand bg-brand-tint" : "border-line",
                )}
              >
                {item.url ? (
                  <Link href={item.url} className="block">
                    {body}
                  </Link>
                ) : (
                  body
                )}
              </li>
            );
          })}
        </ul>
      )}

      <Card className="space-y-2">
        <p className="text-base font-semibold">{t("preferencesTitle")}</p>
        <p className="text-base text-ink-soft">{t("preferencesBody")}</p>
        <Link href="/account" className="underline underline-offset-4">
          {t("preferencesLink")}
        </Link>
      </Card>
    </div>
  );
}
