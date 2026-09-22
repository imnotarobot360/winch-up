"use client";

import { useFormatter, useNow, useTranslations } from "next-intl";

import { Callout, Card } from "@/components/ui/primitives";

import { useAdminData } from "./use-admin";

type Health = {
  ok: boolean;
  dispatch: {
    last_tick_at: string | null;
    seconds_since_tick: number | null;
    stalled: boolean;
  };
  sms: { queued: number; failed: number; sent_24h: number; exhausted: number };
  recent_failures: {
    template_key: string | null;
    locale: string;
    attempts: number;
    error_message: string | null;
    created_at: string;
    short_code: string | null;
  }[];
  requests: { open: number; dispatching_with_no_contact: number };
  volunteers: { approved_active: number; pending: number; reachable: number };
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
 * Is anything still running?
 *
 * The question this page exists for. An idle system and a dead one look identical from the
 * outside: no requests move, no texts go out, every other screen looks fine. The heartbeat is
 * what tells them apart, and it is the first thing here because a stalled tick means nobody is
 * being dispatched to at all.
 */
export function AdminSystem() {
  const t = useTranslations("admin.system");
  const format = useFormatter();
  const now = useNow({ updateInterval: 30_000 });

  const { data, loading, error } = useAdminData<Health>("admin_system_health");

  if (loading || !data) return null;

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      {error ? <Callout tone="danger">{error}</Callout> : null}

      {data.dispatch.stalled ? (
        <Callout tone="danger">
          <p className="text-lg font-semibold">{t("stalledTitle")}</p>
          <p className="mt-1">
            {data.dispatch.last_tick_at
              ? t("stalledSince", {
                  when: format.relativeTime(new Date(data.dispatch.last_tick_at), now),
                })
              : t("neverRan")}
          </p>
          <p className="mt-2 text-sm">{t("stalledWhatToDo")}</p>
        </Callout>
      ) : (
        <Callout tone="good">
          {t("running", { seconds: data.dispatch.seconds_since_tick ?? 0 })}
        </Callout>
      )}

      <Card className="space-y-3">
        <h3 className="text-lg font-semibold">{t("volunteersTitle")}</h3>
        <div className="grid grid-cols-3 gap-2">
          <Stat
            label={t("reachable")}
            value={data.volunteers.reachable}
            tone={data.volunteers.reachable === 0 ? "bad" : undefined}
          />
          <Stat label={t("approvedActive")} value={data.volunteers.approved_active} />
          <Stat label={t("pending")} value={data.volunteers.pending} />
        </div>
        {data.volunteers.reachable === 0 ? (
          // The number that decides whether any of this works. Worth saying out loud.
          <Callout tone="danger">{t("noneReachable")}</Callout>
        ) : null}
      </Card>

      <Card className="space-y-3">
        <h3 className="text-lg font-semibold">{t("smsTitle")}</h3>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Stat label={t("sent24h")} value={data.sms.sent_24h} />
          <Stat label={t("queued")} value={data.sms.queued} />
          <Stat
            label={t("exhausted")}
            value={data.sms.exhausted}
            tone={data.sms.exhausted > 0 ? "bad" : undefined}
          />
          <Stat
            label={t("failed")}
            value={data.sms.failed}
            tone={data.sms.failed > 0 ? "bad" : undefined}
          />
        </div>

        {data.recent_failures.length > 0 ? (
          <ul className="space-y-2">
            {data.recent_failures.map((failure, index) => (
              <li key={index} className="rounded-field border-2 border-line p-3 text-sm">
                <div className="font-semibold">
                  {failure.template_key ?? t("unknownTemplate")}
                  {failure.short_code ? ` · ${failure.short_code}` : ""}
                  {` · ${t("attempts", { n: failure.attempts })}`}
                </div>
                {failure.error_message ? (
                  <div className="mt-1 text-ink-soft">{failure.error_message}</div>
                ) : null}
                <div className="mt-1 text-ink-faint">
                  {format.relativeTime(new Date(failure.created_at), now)}
                </div>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-base text-ink-soft">{t("noFailures")}</p>
        )}
      </Card>

      <Card className="space-y-3">
        <h3 className="text-lg font-semibold">{t("requestsTitle")}</h3>
        <div className="grid grid-cols-2 gap-2">
          <Stat label={t("open")} value={data.requests.open} />
          <Stat
            label={t("noContact")}
            value={data.requests.dispatching_with_no_contact}
            tone={data.requests.dispatching_with_no_contact > 0 ? "bad" : undefined}
          />
        </div>
      </Card>
    </div>
  );
}
