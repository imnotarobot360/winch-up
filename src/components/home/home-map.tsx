"use client";

import { useTranslations } from "next-intl";
import { LifeBuoy, HandHelping, MapPin } from "lucide-react";

import { BoardMap } from "@/components/board/board-map";
import { HeaderBar } from "@/components/chrome/app-header";
import type { BoardRow } from "@/components/board/board-list";
import { Link } from "@/i18n/navigation";

/**
 * The member home: the public map and the two recovery actions.
 * On phones they stack without covering each other; on larger screens they sit side by side.
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
export function HomeMap({
  rows,
  banner,
}: {
  rows: BoardRow[];
  /** Slotted from the server: see where it is rendered below. */
  banner?: React.ReactNode;
}) {
  const t = useTranslations("homeMap");
  const openRows = rows.filter((row) => ["submitted", "dispatching", "unmatched"].includes(row.status));

  return (
    <>
      <HeaderBar />
      <main className="winch-screen winch-home mx-auto max-w-6xl">
        <section className="winch-home-map relative overflow-hidden rounded-2xl border border-line" aria-label={t("openCount", { count: openRows.length })}>
          <BoardMap rows={openRows} fill />
          <div className="pointer-events-none absolute left-3 top-3 z-10">
            <span className="winch-status-pill shadow-lg">
              <MapPin size={16} aria-hidden="true" />
              {openRows.length > 0 ? t("openCount", { count: openRows.length }) : t("noneOpen")}
            </span>
          </div>
        </section>

        <div className="mt-4 space-y-4 md:mt-0">
          <section className="winch-map-overlay space-y-4 p-5">
            <div>
              <h1 className="winch-heading flex items-center gap-3"><LifeBuoy size={28} className="shrink-0 text-brand-text" aria-hidden="true" />{t("needHelp")}</h1>
              <p className="mt-2 text-base text-ink-soft">{t("needHelpBody")}</p>
            </div>
            <Link href="/request" className="winch-primary-action">
              <LifeBuoy size={22} aria-hidden="true" />
              {t("sendSos")}
            </Link>
            <Link href="/help" className="winch-secondary-action">
              <HandHelping size={22} aria-hidden="true" />
              {t("helpSomeone")}
            </Link>
          </section>
          {banner}
        </div>
      </main>
    </>
  );
}
