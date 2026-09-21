"use client";

import { useTranslations } from "next-intl";

import { Link, usePathname } from "@/i18n/navigation";
import { IconDoc, IconHome, IconHook, IconPin, IconTruck } from "@/components/ui/icons";
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

const LEFT: Tab[] = [
  {
    href: "/",
    key: "home",
    icon: <IconHome size={26} />,
  },
  {
    href: "/board",
    key: "board",
    icon: <IconPin size={26} />,
  },
];

const RIGHT: Tab[] = [
  {
    href: "/me",
    key: "volunteer",
    icon: <IconTruck size={26} />,
  },
  {
    href: "/waiver",
    key: "rules",
    icon: <IconDoc size={26} />,
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
              <IconHook size={30} />
            </span>
            <span className="text-center leading-tight">{t("getHelp")}</span>
          </Link>

          {RIGHT.map(item)}
        </div>
      </nav>
    </>
  );
}
