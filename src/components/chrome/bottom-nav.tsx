"use client";

import { useTranslations } from "next-intl";

import { Link, usePathname } from "@/i18n/navigation";
import { IconHome, IconHook, IconPeople, IconPin, IconTruck } from "@/components/ui/icons";
import { cn } from "@/lib/utils";

/**
 * The tab bar from the brand mockups: Home, Map, SOS, Community, Profile.
 *
 * Every destination is a route that already exists, which is why this is five labels rather than
 * five new screens. Map is /board -- the map of every open request -- because Home is already a
 * map once you are signed in, and the useful distinction is "mine" against "everybody's".
 * Profile is /me, the volunteer dashboard, since that is where a member's rigs, kit, recoveries
 * and availability live; /account is settings and sits one tap deeper, as in the reference.
 *
 * The centre action is SOS. It was labelled "Get help", which is the same thing said at greater
 * length -- and on a phone held by somebody who is stuck, three letters they already know beat a
 * phrase they have to read.
 *
 * Hidden wherever it would fight the page for the bottom of the screen or the user's attention:
 * the request wizard has its own fixed action bar, and nobody reading a live recovery status,
 * working the admin or moderation queue, or copying a post needs a tab bar under it.
 */
const HIDDEN = [
  // Onboarding is full-bleed in the reference and offers its own two ways forward. A tab bar
  // under it would give a signed-out visitor five destinations that all bounce them to sign in.
  /^\/welcome$/,
  /^\/request(\/|$)/,
  /^\/r\//,
  /^\/admin(\/|$)/,
  /^\/moderation(\/|$)/,
  /^\/post\//,
];

type Tab = { href: string; key: string; icon: React.ReactNode };

const LEFT: Tab[] = [
  {
    href: "/",
    key: "home",
    icon: <IconHome size={26} />,
  },
  {
    // The public board, which is the map of everything happening. Home is a map too once you are
    // signed in; the difference is that Home is yours and this one is everybody's.
    href: "/board",
    key: "map",
    icon: <IconPin size={26} />,
  },
];

const RIGHT: Tab[] = [
  {
    href: "/community",
    key: "community",
    icon: <IconPeople size={26} />,
  },
  {
    // /me is what "profile" means here: your rigs, your kit, your recoveries, your availability.
    // /account is settings, one tap further in, which is where the design reference puts it too.
    href: "/me",
    key: "profile",
    icon: <IconTruck size={26} />,
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
            <span className="text-center leading-tight">{t("sos")}</span>
          </Link>

          {RIGHT.map(item)}
        </div>
      </nav>
    </>
  );
}
