"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Callout, Card } from "@/components/ui/primitives";
import { BOARD } from "@/config/app";
import { mapAppUrl } from "@/lib/geo";

export type BoardRow = {
  short_code: string;
  status: string;
  lat: number;
  lng: number;
  is_approximate: boolean;
  county: string | null;
  state: string;
  vehicle_class: string;
  stuck_type: string;
  stuck_depth: string | null;
  needs_tractor: boolean;
  needs_second_truck: boolean;
  notes: string | null;
  photo_count: number;
  responder_first_name: string | null;
  created_at: string;
  accepted_at: string | null;
  recovered_at: string | null;
};

const POLL_MS = 30_000;

const OPEN = ["submitted", "dispatching", "unmatched"];

/**
 * The public board: what the Facebook group feed was, minus the parts that should never have
 * been public.
 *
 * No names, no phone numbers, and the pin is the blurred one — about a mile off, and stable, so
 * nobody can average several page loads back to a real address.
 */
export function BoardList({ initial }: { initial: BoardRow[] }) {
  const t = useTranslations("board");
  const tEnum = useTranslations("enum");
  const format = useFormatter();

  const [rows, setRows] = useState(initial);
  const [filter, setFilter] = useState<"open" | "all">("open");

  const refresh = useCallback(async () => {
    try {
      const response = await fetch("/api/board", { cache: "no-store" });
      if (!response.ok) return;
      setRows((await response.json()) as BoardRow[]);
    } catch {
      // Next tick tries again.
    }
  }, []);

  useEffect(() => {
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  const visible = filter === "open" ? rows.filter((row) => OPEN.includes(row.status)) : rows;
  const openCount = rows.filter((row) => OPEN.includes(row.status)).length;

  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 px-4 py-6">
      <header>
        <h1 className="text-3xl font-bold leading-tight">{t("title")}</h1>
        <p className="mt-2 text-base text-ink-soft">{t("subtitle")}</p>
      </header>

      <Callout tone="neutral">{t("privacyNote", { miles: BOARD.blurMiles })}</Callout>

      <div className="flex gap-2">
        <button
          type="button"
          onClick={() => setFilter("open")}
          aria-pressed={filter === "open"}
          className={`min-h-12 flex-1 rounded-field border-2 px-3 font-semibold ${
            filter === "open" ? "border-brand bg-brand-tint" : "border-line"
          }`}
        >
          {t("filterOpen", { count: openCount })}
        </button>
        <button
          type="button"
          onClick={() => setFilter("all")}
          aria-pressed={filter === "all"}
          className={`min-h-12 flex-1 rounded-field border-2 px-3 font-semibold ${
            filter === "all" ? "border-brand bg-brand-tint" : "border-line"
          }`}
        >
          {t("filterAll")}
        </button>
      </div>

      {visible.length === 0 ? (
        <Card>
          <p className="text-center text-lg text-ink-soft">{t("empty")}</p>
        </Card>
      ) : null}

      <ul className="space-y-3">
        {visible.map((row) => (
          <li key={row.short_code}>
            <Card className="space-y-2">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-mono text-sm text-ink-faint">{row.short_code}</p>
                  <p className="text-lg font-semibold">
                    {tEnum(`vehicleClass.${row.vehicle_class}`)} ·{" "}
                    {tEnum(`stuckType.${row.stuck_type}`)}
                    {row.stuck_depth ? ` · ${tEnum(`stuckDepth.${row.stuck_depth}`)}` : ""}
                  </p>
                </div>
                <span
                  className={`shrink-0 rounded-full px-3 py-1 text-sm font-semibold ${
                    OPEN.includes(row.status)
                      ? "bg-brand-tint text-brand-dark"
                      : "bg-good-tint text-good"
                  }`}
                >
                  {tEnum(`requestStatus.${row.status}`)}
                </span>
              </div>

              <p className="text-base text-ink-soft">
                {row.county ? t("county", { county: row.county, state: row.state }) : row.state}
                {" · "}
                {format.relativeTime(new Date(row.created_at))}
              </p>

              {row.needs_tractor ? (
                <p className="text-base font-medium">{t("needsTractor")}</p>
              ) : null}
              {row.needs_second_truck ? (
                <p className="text-base font-medium">{t("needsSecondTruck")}</p>
              ) : null}

              {row.notes ? <p className="text-base">{row.notes}</p> : null}

              {row.responder_first_name ? (
                <p className="text-base font-medium text-good">
                  {t("takenBy", { name: row.responder_first_name })}
                </p>
              ) : null}

              <a
                href={mapAppUrl(row.lat, row.lng)}
                target="_blank"
                rel="noreferrer"
                className="inline-block text-base underline underline-offset-4"
              >
                {row.is_approximate ? t("approxArea") : t("exactArea")}
              </a>
            </Card>
          </li>
        ))}
      </ul>

      <p className="pb-6 text-center text-sm text-ink-faint">
        {t("autoRefresh", { seconds: POLL_MS / 1000 })}
      </p>
    </main>
  );
}
