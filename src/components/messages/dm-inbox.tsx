"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Avatar } from "@/components/ui/avatar";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Thread = {
  thread_id: string;
  other_user_id: string;
  other_name: string | null;
  other_avatar_path: string | null;
  other_suspended: boolean;
  last_message_at: string | null;
  preview: string | null;
  preview_is_mine: boolean;
  unread: number;
};

/**
 * Conversations this member is in.
 *
 * The preview is the last message WHOEVER it came from, prefixed with "You:" when it is yours. An inbox
 * that showed only the other person's last line would read as though they had gone quiet whenever you
 * had the last word, which is most of the time.
 *
 * Polled on the same fifteen seconds as the thread. See dm-thread.tsx for why this is not a socket.
 */
const POLL_MS = 15_000;

export function DmInbox() {
  const t = useTranslations("dm");
  const format = useFormatter();

  const [threads, setThreads] = useState<Thread[] | null>(null);
  const [failed, setFailed] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabaseBrowser().rpc("dm_inbox", {});
    const result = data as { ok?: boolean; threads?: Thread[] } | null;
    if (error || !result?.ok) {
      setFailed(true);
      setThreads([]);
      return;
    }
    setFailed(false);
    setThreads(result.threads ?? []);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    const timer = setInterval(() => void load(), POLL_MS);
    return () => clearInterval(timer);
  }, [load]);

  if (threads === null) {
    return <p className="py-8 text-center text-base text-ink-soft">{t("loading")}</p>;
  }

  if (failed) {
    return <Callout tone="danger">{t("loadFailed")}</Callout>;
  }

  if (threads.length === 0) {
    return (
      <div className="space-y-2 rounded-field border-2 border-line bg-surface-sunk p-4">
        <p className="text-base font-semibold text-ink">{t("emptyTitle")}</p>
        {/* Says where a conversation starts, because an empty inbox with no route out of it is a dead
            end -- and the route is the directory, which is the screen this feature exists beside. */}
        <p className="text-base text-ink-soft">{t("emptyBody")}</p>
        <p>
          <Link href="/members" className="text-base underline underline-offset-4">
            {t("emptyLink")}
          </Link>
        </p>
      </div>
    );
  }

  return (
    <ul className="space-y-3">
      {threads.map((thread) => (
        <li key={thread.thread_id}>
          <Link
            href={`/messages/${thread.thread_id}`}
            className="winch-panel flex min-h-20 items-center gap-3 rounded-2xl border border-line bg-surface-sunk p-4 hover:border-brand"
          >
            <Avatar name={thread.other_name} />

            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-baseline justify-between gap-x-2">
                <p className="truncate text-base font-bold text-ink">
                  {thread.other_name ?? t("someone")}
                </p>
                <span className="shrink-0 text-xs text-ink-faint">
                  {thread.last_message_at
                    ? format.relativeTime(new Date(thread.last_message_at))
                    : null}
                </span>
              </div>

              <p className="truncate text-sm text-ink-soft">
                {thread.preview_is_mine
                  ? t("previewMine", { body: thread.preview ?? "" })
                  : (thread.preview ?? "")}
              </p>
            </div>

            {thread.unread > 0 ? (
              <span className="shrink-0 rounded-full bg-brand px-2 py-0.5 text-xs font-bold text-on-brand">
                {thread.unread}
              </span>
            ) : null}
          </Link>
        </li>
      ))}
    </ul>
  );
}
