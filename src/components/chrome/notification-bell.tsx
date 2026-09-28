"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { IconBell } from "@/components/ui/icons";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

const POLL_MS = 60_000;

/**
 * The way into /notifications, and the unread count on it.
 *
 * THIS USED TO RENDER NOTHING WHENEVER THE COUNT WAS ZERO, AND THAT MADE THE PAGE UNREACHABLE.
 *
 * The reasoning was sound as far as it went -- a bell with a permanent "0" on it is noise on
 * every screen in the app, including the one somebody reads while their truck is in a creek --
 * but this link is the ONLY route to /notifications anywhere in the product. The bottom nav has
 * five tabs and none of them is this one. So the entry point appeared when something arrived
 * and vanished the moment it was read, and notification history could not be reached at all.
 *
 * The fix keeps the original objection intact: the BADGE still only exists when there is
 * something unread. What is always there, for a signed-in member, is the bell itself -- an
 * affordance rather than a count, the same as every other navigation icon in the app.
 *
 * Signed out it still renders nothing, because /notifications needs an account.
 */
export function NotificationBell() {
  const t = useTranslations("notifications");
  const [unread, setUnread] = useState(0);
  // null means "not asked yet". Rendering the bell before the session is known would flash it
  // onto every public page for a moment, which is the thing the header is careful about.
  const [signedIn, setSignedIn] = useState<boolean | null>(null);

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
      setSignedIn(false);
      setUnread(0);
      return;
    }

    setSignedIn(true);

    const { data, error } = await supabase.rpc("my_notifications", { p_limit: 1 });
    if (error) {
      // The count is unknown, not zero. The bell stays -- losing the only way to reach the page
      // because one poll failed would be the original bug in a smaller form.
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

  if (!signedIn) return null;

  return (
    <Link
      href="/notifications"
      // The count when there is one, the plain name when there is not. A screen reader should
      // not have to hear "0 unread notifications" to find the inbox.
      aria-label={unread > 0 ? t("unreadLabel", { count: unread }) : t("title")}
      className="relative flex min-h-12 min-w-12 items-center justify-center rounded-field text-ink"
    >
      <IconBell size={24} />

      {unread > 0 ? (
        <span
          // Overlapping the bell rather than sitting beside it, so the tap target stays the
          // same size and the header does not reflow when the first notification arrives.
          className="absolute right-1 top-1 flex min-w-5 items-center justify-center rounded-full bg-brand px-1 text-xs font-bold text-on-brand"
        >
          {unread > 9 ? "9+" : unread}
        </span>
      ) : null}
    </Link>
  );
}
