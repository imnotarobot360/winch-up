"use client";

import { useTranslations } from "next-intl";

import { BoardMap } from "@/components/board/board-map";
import { HeaderBar } from "@/components/chrome/app-header";
import type { BoardRow } from "@/components/board/board-list";
import { Link } from "@/i18n/navigation";

/**
 * Screen 4 of the design reference: the map, and the one button that matters over it.
 *
 * WHAT THE PINS ARE
 *
 * The same blurred pins the public board serves -- about a mile off the real spot, stable across
 * loads so repeated reads cannot be averaged back to an address. This component is deliberately
 * built on BoardMap rather than a new map: there is then exactly one piece of code that puts a
 * recovery on a map for somebody who is not on that recovery, and it is the one that has never
 * been able to see an exact pin. A second implementation is a second chance to leak.
 *
 * The reference shows a red SOS marker at the centre and a blue current-location dot. Neither is
 * drawn here. The red marker in the mockup is a request that does not exist until somebody files
 * one, and a current-location dot needs a geolocation permission prompt -- which this app asks
 * for when it has a reason to (the request wizard) and not for decoration on a home screen.
 *
 * EMPTY IS THE NORMAL CASE AND IT SAYS SO
 *
 * Most of the time nobody is stuck, and the brief is explicit: no fake markers, a clear empty
 * state. "Nothing open right now. Good." is the honest version of an empty map, and it is the
 * version a volunteer wants to read.
 */
export function HomeMap({ rows }: { rows: BoardRow[] }) {
  const t = useTranslations("homeMap");

  return (
    <div className="relative min-h-[100dvh] bg-surface">
      {/* The reference's home header: wordmark centred, bell right. No hamburger -- the mockup
          shows one, but there is no drawer behind it in this app, and the brief says no button
          may be decorative. The five tabs at the bottom are the navigation. */}
      <div className="relative z-10">
        <HeaderBar />
      </div>

      {/* The map fills what is left below the header. inset-0 with a top offset rather than a
          flex child, so the floating card can be positioned against the viewport bottom. */}
      <div className="absolute inset-x-0 bottom-0 top-[3.25rem]">
        <BoardMap rows={rows} fill />
      </div>

      {/* The floating card. Bottom-anchored above the tab bar, which is 6rem of fixed chrome --
          the brief says the nav must never cover an important button, and this is the important
          button. */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 z-10 px-4 pb-[calc(7rem+env(safe-area-inset-bottom))]">
        <div className="pointer-events-auto mx-auto w-full max-w-xl space-y-3 rounded-2xl border-2 border-line bg-surface-sunk/95 p-4 shadow-lg backdrop-blur">
          <div>
            <h2 className="text-xl font-bold text-ink">{t("needHelp")}</h2>
            <p className="mt-1 text-base text-ink-soft">{t("needHelpBody")}</p>
          </div>

          <Link
            href="/request"
            className="tap-target flex w-full items-center justify-center rounded-field bg-brand px-4 text-center text-lg font-bold text-on-brand"
          >
            {t("sendSos")}
          </Link>

          {/* The other half of universal membership. The brief asks for a clearly accessible way
              to go and help somebody, and a home screen that only offers "I need help" quietly
              tells every member which of the two roles they are. */}
          <Link
            href="/help"
            className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line px-4 text-center text-base font-semibold text-ink"
          >
            {t("helpSomeone")}
          </Link>

          <p className="text-center text-sm text-ink-faint">
            {rows.length > 0 ? t("openCount", { count: rows.length }) : t("noneOpen")}
          </p>
        </div>
      </div>
    </div>
  );
}
