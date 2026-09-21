"use client";

import { useTranslations } from "next-intl";

import { Link, usePathname } from "@/i18n/navigation";
import { cn } from "@/lib/utils";

/**
 * The tab bar from the brand mockups.
 *
 * Every destination here is a route that exists. The mockups also show Community and Profile
 * tabs; there is no community feed, and the responder dashboard is what "profile" means in this
 * product, so those slots are Volunteer and Rules instead of tabs that lead nowhere.
 *
 * Hidden wherever it would fight the page for the bottom of the screen or the user's attention:
 * the request wizard has its own fixed action bar, and nobody reading a live recovery status,
 * working the admin queue or copying a post needs a tab bar under it.
 */
const HIDDEN = [/^\/request(\/|$)/, /^\/r\//, /^\/admin(\/|$)/, /^\/post\//];

type Tab = { href: string; key: string; icon: React.ReactNode };

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.75,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg viewBox="0 0 24 24" width="26" height="26" aria-hidden="true" {...stroke}>
      {children}
    </svg>
  );
}

const LEFT: Tab[] = [
  {
    href: "/",
    key: "home",
    icon: <Icon><path d="M3 10.5 12 3l9 7.5" /><path d="M5.5 9.5V20h13V9.5" /></Icon>,
  },
  {
    href: "/board",
    key: "board",
    icon: <Icon><path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Z" /><circle cx="12" cy="10" r="2.5" /></Icon>,
  },
];

const RIGHT: Tab[] = [
  {
    href: "/me",
    key: "volunteer",
    icon: <Icon><path d="M3 16V7h11v9" /><path d="M14 10h4l3 3.5V16" /><circle cx="7" cy="17.5" r="2" /><circle cx="17" cy="17.5" r="2" /></Icon>,
  },
  {
    href: "/waiver",
    key: "rules",
    icon: <Icon><path d="M5 4h10l4 4v12H5z" /><path d="M15 4v4h4" /><path d="M8.5 12.5h7M8.5 16h5" /></Icon>,
  },
];

export function BottomNav() {
  const pathname = usePathname();
  const t = useTranslations("nav");

  if (HIDDEN.some((r) => r.test(pathname))) return null;

  const item = (tab: Tab) => {
    const active = tab.href === "/" ? pathname === "/" : pathname.startsWith(tab.href);
    return (
      <Link
        key={tab.key}
        href={tab.href}
        aria-current={active ? "page" : undefined}
        className={cn(
          "flex min-h-14 flex-1 flex-col items-center justify-center gap-1 px-1 text-xs font-semibold",
          active ? "text-brand-text" : "text-ink-faint",
        )}
      >
        {tab.icon}
        <span className="text-center leading-tight">{t(tab.key)}</span>
      </Link>
    );
  };

  return (
    <>
      {/* Keeps the last of the page clear of the fixed bar, and only when the bar is showing. */}
      <div aria-hidden="true" className="h-24" />

      <nav
        aria-label={t("label")}
        className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-surface-sunk pb-[env(safe-area-inset-bottom)]"
      >
        <div className="mx-auto flex w-full max-w-xl items-end">
          {LEFT.map(item)}

          {/* The one action that matters, raised out of the bar as in the mockups. */}
          <Link
            href="/request"
            className="flex flex-1 flex-col items-center justify-end gap-1 px-1 text-xs font-bold text-ink"
          >
            <span className="-mt-6 flex size-16 items-center justify-center rounded-full border-4 border-surface bg-brand text-on-brand shadow-lg">
              <svg viewBox="0 0 24 24" width="30" height="30" aria-hidden="true" {...stroke} strokeWidth={2}>
                <path d="M12 3v5" />
                <path d="M9 8h6l-1.2 4.2a3 3 0 1 1-4.6 0Z" />
              </svg>
            </span>
            <span className="text-center leading-tight">{t("getHelp")}</span>
          </Link>

          {RIGHT.map(item)}
        </div>
      </nav>
    </>
  );
}
