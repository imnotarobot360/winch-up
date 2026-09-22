"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

const POLL_MS = 60_000;

/**
 * The unread count in the header.
 *
 * Renders nothing at all when there is nothing unread, and nothing at all when signed out. A
 * permanently visible bell with a zero on it is a small piece of noise on every screen in the
 * app, including the one somebody reads while their truck is in a creek.
 *
 * Polls once a minute. Notifications here are things that have already happened and are already
 * recorded; a websocket held open on a phone with one bar would cost more than it buys.
 */
export function NotificationBell() {
  const t = useTranslations("notifications");
  const [unread, setUnread] = useState(0);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    // Check for a session before asking. This component is in the header of every page,
    // including the public ones, and my_notifications is granted only to `authenticated` --
    // calling it signed out is a guaranteed 401 that supabase-js logs to the console, on every
    // public page load, for every visitor. An end-to-end test that fails a page for logging
    // console errors caught it, which is exactly what that test is for.
    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session) {
      setUnread(0);
      return;
    }

    const { data, error } = await supabase.rpc("my_notifications", { p_limit: 1 });
    if (error) {
      setUnread(0);
      return;
    }
    const result = data as { ok: boolean; unread?: number };
    setUnread(result.ok ? (result.unread ?? 0) : 0);
  }, []);

  useEffect(() => {
    void load();
    const timer = setInterval(() => void load(), POLL_MS);
    return () => clearInterval(timer);
  }, [load]);

  if (unread === 0) return null;

  return (
    <Link
      href="/notifications"
      aria-label={t("unreadLabel", { count: unread })}
      className="flex min-h-12 items-center gap-2 rounded-field px-3 text-sm font-bold text-ink"
    >
      <span className="flex size-7 items-center justify-center rounded-full bg-brand text-on-brand">
        {unread > 9 ? "9+" : unread}
      </span>
    </Link>
  );
}
