"use client";

import { useTranslations } from "next-intl";

import { Callout, Card } from "@/components/ui/primitives";

import { useAdminData } from "./use-admin";

type Stats = {
  ok: boolean;
  window_days: number;
  alerts: {
    helpers_notified: number;
    recoveries: number;
    offers_received: number;
    declined: number;
    no_reply: number;
    avg_response_seconds: number | null;
    median_response_seconds: number | null;
  };
  by_wave: {
    wave: number;
    radius_miles: number;
    notified: number;
    offers: number;
    avg_distance_miles: number | null;
  }[];
  sms: { sent: number; delivered: number; failed: number; queued: number; suppressed: number };
  teams: {
    recoveries_wanting_more_than_one: number;
    accepted: number;
    unmatched: number;
  };
  settings: {
    radii_miles: number[];
    helpers: number[];
    waits_minutes: number[];
    unmatched_after_minutes: number;
    location_freshness_minutes: number;
    sms_outbound_enabled: boolean;
  };
};

function Stat({ label, value, tone }: { label: string; value: number | string; tone?: "bad" }) {
  return (
    <div className="rounded-field border-2 border-line p-3">
      <div className={`text-2xl font-bold ${tone === "bad" ? "text-danger" : "text-ink"}`}>
        {value}
      </div>
      <div className="text-sm text-ink-soft">{label}</div>
    </div>
  );
}

/**
 * Seconds as something a person reads, without pretending to a precision the number does not have.
 *
 * The RPC returns seconds because a number can be compared across windows and formatting is this
 * layer's job. A null means nobody has replied yet in the window, which is a different statement
 * from zero and must not render as "0s".
 */
function duration(seconds: number | null, none: string): string {
  if (seconds === null || Number.isNaN(seconds)) return none;
  if (seconds < 90) return `${Math.round(seconds)}s`;
  return `${Math.round(seconds / 60)}m`;
}

/**
 * Did the call-outs reach anybody, and how fast did people answer?
 *
 * Every number here is derived from `dispatches` and `sms_messages` at read time rather than kept
 * in counters. A counters table needs a writer on every path that touches either, and the morning
 * one is missed this screen reads confidently wrong -- which is worse than reading nothing,
 * because nobody re-checks a figure that has always looked fine.
 *
 * THE SETTINGS ARE SHOWN BESIDE THE NUMBERS THEY CAUSED. Wave sizes, radii and waits are what the
 * counts above are a consequence of, and keeping them on a different screen means comparing them
 * from memory. They are read-only here: /admin/settings already edits every setting, and a second
 * editor for the same rows is two places to get it wrong.
 */
export function AdminAlerts() {
  const t = useTranslations("admin.alerts");
  const { data, loading, error } = useAdminData<Stats>("admin_recovery_alert_stats", {
    p_days: 7,
  });

  if (loading) return <p className="text-ink-soft">{t("loading")}</p>;
  if (error) return <Callout tone="danger">{error}</Callout>;
  if (!data) return null;

  const { alerts, by_wave, sms, teams, settings } = data;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="font-display text-3xl">{t("title")}</h1>
        <p className="text-ink-soft">{t("window", { days: data.window_days })}</p>
      </div>

      {/*
        THE FIRST THING ON THE PAGE WHEN IT IS TRUE. Every other number being zero has one
        overwhelmingly likely explanation, and an admin should not have to deduce it from a screen
        of empty tiles. sms.outbound_enabled ships false and carries recoveries by push and in-app
        instead; the call-outs are still recorded, just not sent.
      */}
      {!settings.sms_outbound_enabled ? (
        <Callout tone="neutral">{t("smsOff")}</Callout>
      ) : null}

      <Card>
        <h2 className="mb-3 font-display text-xl">{t("reach")}</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <Stat label={t("helpersNotified")} value={alerts.helpers_notified} />
          <Stat label={t("recoveries")} value={alerts.recoveries} />
          <Stat label={t("offers")} value={alerts.offers_received} />
          <Stat label={t("declined")} value={alerts.declined} />
          <Stat label={t("noReply")} value={alerts.no_reply} />
          <Stat
            label={t("avgResponse")}
            value={duration(alerts.avg_response_seconds, t("noneYet"))}
          />
        </div>
        <p className="mt-3 text-sm text-ink-soft">{t("medianNote", {
          median: duration(alerts.median_response_seconds, t("noneYet")),
        })}</p>
      </Card>

      <Card>
        <h2 className="mb-3 font-display text-xl">{t("byWave")}</h2>
        {by_wave.length === 0 ? (
          <p className="text-ink-soft">{t("noWaves")}</p>
        ) : (
          <div className="space-y-2">
            {by_wave.map((w) => (
              <div
                key={w.wave}
                className="flex flex-wrap items-baseline justify-between gap-2 rounded-field border-2 border-line p-3"
              >
                <span className="font-bold">
                  {t("waveLabel", { wave: w.wave, miles: w.radius_miles })}
                </span>
                <span className="text-sm text-ink-soft">
                  {t("waveCounts", {
                    notified: w.notified,
                    offers: w.offers,
                    miles: w.avg_distance_miles ?? 0,
                  })}
                </span>
              </div>
            ))}
          </div>
        )}
      </Card>

      <Card>
        <h2 className="mb-3 font-display text-xl">{t("texts")}</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
          <Stat label={t("sent")} value={sms.sent} />
          <Stat label={t("delivered")} value={sms.delivered} />
          <Stat label={t("failed")} value={sms.failed} tone={sms.failed > 0 ? "bad" : undefined} />
          <Stat label={t("queued")} value={sms.queued} />
          {/*
            Suppressed is deliberately NOT styled as a failure. With the master switch off this is
            every call-out, and a wall of red for a system behaving as configured teaches an admin
            to ignore the colour.
          */}
          <Stat label={t("suppressed")} value={sms.suppressed} />
        </div>
      </Card>

      <Card>
        <h2 className="mb-3 font-display text-xl">{t("teams")}</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <Stat label={t("multiHelper")} value={teams.recoveries_wanting_more_than_one} />
          <Stat label={t("accepted")} value={teams.accepted} />
          <Stat
            label={t("unmatched")}
            value={teams.unmatched}
            tone={teams.unmatched > 0 ? "bad" : undefined}
          />
        </div>
      </Card>

      <Card>
        <h2 className="mb-3 font-display text-xl">{t("settingsTitle")}</h2>
        <p className="mb-3 text-sm text-ink-soft">{t("settingsNote")}</p>
        <dl className="space-y-1 text-sm">
          <div className="flex justify-between gap-4">
            <dt className="text-ink-soft">{t("radii")}</dt>
            <dd className="font-mono">{settings.radii_miles.join(" / ")} mi</dd>
          </div>
          <div className="flex justify-between gap-4">
            <dt className="text-ink-soft">{t("helpersPerWave")}</dt>
            <dd className="font-mono">{settings.helpers.join(" / ")}</dd>
          </div>
          <div className="flex justify-between gap-4">
            <dt className="text-ink-soft">{t("waits")}</dt>
            <dd className="font-mono">{settings.waits_minutes.join(" / ")} min</dd>
          </div>
          <div className="flex justify-between gap-4">
            <dt className="text-ink-soft">{t("unmatchedAfter")}</dt>
            <dd className="font-mono">{settings.unmatched_after_minutes} min</dd>
          </div>
          <div className="flex justify-between gap-4">
            <dt className="text-ink-soft">{t("freshness")}</dt>
            <dd className="font-mono">{settings.location_freshness_minutes} min</dd>
          </div>
        </dl>
      </Card>
    </div>
  );
}
