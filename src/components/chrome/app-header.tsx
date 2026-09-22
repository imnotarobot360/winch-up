"use client";

import { NotificationBell } from "@/components/chrome/notification-bell";
import { Wordmark } from "@/components/brand/wordmark";
import { APP_NAME } from "@/config/app";
import { Link, usePathname } from "@/i18n/navigation";

/**
 * Compact logo bar for interior pages.
 *
 * Not shown on the landing page, which already opens with the full lockup, and not on the
 * request wizard, where the step header is the thing that has to be read and a second bar above
 * it would only push the question further down a small screen.
 */
const HIDDEN = [/^\/$/, /^\/request(\/|$)/];

export function AppHeader() {
  const pathname = usePathname();

  if (HIDDEN.some((r) => r.test(pathname))) return null;

  return (
    <header className="sticky top-0 z-20 border-b border-line bg-trail/95 backdrop-blur">
      <div className="relative mx-auto flex w-full max-w-xl items-center justify-center px-4 py-2">
        <Link href="/" aria-label={APP_NAME} className="flex items-center py-1">
          <Wordmark className="display text-3xl text-ink" />
        </Link>

        {/* Absolutely positioned so the wordmark stays centred whether or not there is
            anything unread. The bell renders nothing at zero. */}
        <div className="absolute right-2">
          <NotificationBell />
        </div>
      </div>
    </header>
  );
}
