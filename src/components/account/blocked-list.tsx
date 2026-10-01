"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { Avatar } from "@/components/ui/avatar";
import { supabaseBrowser } from "@/lib/supabase/client";

type Blocked = {
  user_id: string;
  display_name: string;
  created_at: string;
};

/**
 * Who you have blocked, and the way back.
 *
 * BLOCKING WAS ONE-WAY UNTIL THIS EXISTED. community_block takes a boolean and the only call in
 * the app passed true; community_blocked_list had no caller at all. So an accidental tap was
 * permanent: the only route to unblocking somebody is finding a post of theirs, which is
 * precisely what blocking stops you doing. Both halves had been in the database since phase 8.
 *
 * Found by the sweep in docs/built-but-unreachable.md rather than by anybody using it, which is
 * the uncomfortable part -- a member who did this to the wrong person had no way to say so.
 *
 * No confirmation on unblocking. Blocking is the protective act and it asks before it happens;
 * undoing it only restores the ordinary state, and a dialog in the way of that is an obstacle
 * for somebody fixing a mistake.
 */
export function BlockedList() {
  const t = useTranslations("blocked");
  const format = useFormatter();

  const [rows, setRows] = useState<Blocked[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const { data, error } = await supabaseBrowser().rpc("community_blocked_list");

      if (error) {
        setFailed(true);
        return;
      }

      const result = data as { ok: boolean; blocked?: Blocked[] };
      setFailed(!result?.ok);
      setRows(result?.ok ? (result.blocked ?? []) : []);
    } catch {
      setFailed(true);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function unblock(userId: string) {
    setBusy(userId);
    setFailed(false);

    const { data, error } = await supabaseBrowser().rpc("community_block", {
      p_user_id: userId,
      p_on: false,
    });

    setBusy(null);

    const result = data as { ok: boolean } | null;
    if (error || !result?.ok) {
      setFailed(true);
      return;
    }

    await load();
  }

  if (rows === null) {
    return (
      <div className="space-y-3" aria-busy="true" aria-live="polite">
        <span className="sr-only">{t("loading")}</span>
        <div className="h-20 animate-pulse rounded-2xl bg-surface-sunk" />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {failed ? <Callout tone="danger">{t("failed")}</Callout> : null}

      {rows.length === 0 ? (
        <Card>
          <p className="text-base font-semibold text-ink">{t("emptyTitle")}</p>
          <p className="mt-1 text-base text-ink-soft">{t("emptyBody")}</p>
        </Card>
      ) : (
        <ul className="space-y-3">
          {rows.map((b) => (
            <li key={b.user_id}>
              <Card className="flex flex-wrap items-center justify-between gap-3">
                <div className="flex min-w-0 items-center gap-3">
                  <Avatar name={b.display_name || null} />
                  <div className="min-w-0">
                    {/* A blocked member may have no display name, and "" would render as a
                        nameless row with a button beside it. */}
                    <p className="truncate text-base font-bold text-ink">
                      {b.display_name || t("someone")}
                    </p>
                    <p className="text-sm text-ink-soft">
                      {t("since", {
                        date: format.dateTime(new Date(b.created_at), {
                          day: "numeric",
                          month: "short",
                          year: "numeric",
                        }),
                      })}
                    </p>
                  </div>
                </div>

                <Button
                  variant="secondary"
                  disabled={busy !== null}
                  onClick={() => void unblock(b.user_id)}
                >
                  {busy === b.user_id ? t("working") : t("unblock")}
                </Button>
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
