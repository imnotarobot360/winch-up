"use client";

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { mapAppUrl } from "@/lib/geo";
import { formatUsPhone } from "@/lib/utils";

import { adminAction, useAdminData } from "./use-admin";

type QueueRow = {
  id: string;
  short_code: string;
  public_token: string;
  status: string;
  created_at: string;
  current_ring: number;
  notified_count: number;
  requester_name: string;
  requester_phone: string;
  county: string | null;
  vehicle_class: string;
  stuck_type: string;
  stuck_depth: string | null;
  needs_tractor: boolean;
  needs_second_truck: boolean;
  notes: string | null;
  lat: number;
  lng: number;
  age_minutes: number;
  responder_first_name: string | null;
  responder_phone: string | null;
  eta_minutes: number | null;
};

type ResponderPin = {
  id: string;
  first_name: string;
  availability: string;
  radius_miles: number;
  equipment: string[];
  lat: number;
  lng: number;
  busy: boolean;
};

type Dashboard = {
  counts: Record<string, number>;
  queue: QueueRow[];
  responders: ResponderPin[];
};

/**
 * The queue is the important half of this screen.
 *
 * It is sorted oldest first and shows an age in minutes, because the only question an admin has
 * at 11pm is "what has been sitting too long". Anything past the unmatched threshold is loud.
 */
export function AdminDashboard() {
  const t = useTranslations("admin.dashboard");
  const tEnum = useTranslations("enum");

  const { data, loading, error, reload } = useAdminData<Dashboard>("admin_dashboard");
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);

  const available = useMemo(
    () => (data?.responders ?? []).filter((r) => !r.busy && r.availability === "active"),
    [data],
  );

  async function dispatchTo(requestId: string, responderId: string) {
    setBusy(true);
    setActionError(null);
    const result = await adminAction("admin_manual_dispatch", {
      p_request_id: requestId,
      p_responder_id: responderId,
    });
    if (!result.ok) setActionError(result.error ?? "failed");
    await reload();
    setBusy(false);
  }

  async function reassign(requestId: string, responderId: string) {
    setBusy(true);
    setActionError(null);
    const result = await adminAction("admin_reassign", {
      p_request_id: requestId,
      p_responder_id: responderId,
    });
    if (!result.ok) setActionError(result.error ?? "failed");
    await reload();
    setBusy(false);
  }

  if (loading) return <p className="p-8 text-center text-ink-faint">{t("loading")}</p>;
  if (error) return <Callout tone="danger">{error}</Callout>;
  if (!data) return null;

  return (
    <div className="space-y-5">
      <section className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {(
          [
            ["open", data.counts.open],
            ["assigned", data.counts.assigned],
            ["unmatched", data.counts.unmatched],
            ["recoveredToday", data.counts.recovered_today],
            ["respondersActive", data.counts.responders_active],
            ["respondersPending", data.counts.responders_pending],
            ["smsFailed", data.counts.sms_failed],
          ] as const
        ).map(([key, value]) => (
          <Card key={key} className="p-4">
            <p className="text-3xl font-bold">{value ?? 0}</p>
            <p className="text-sm text-ink-soft">{t(`counts.${key}`)}</p>
          </Card>
        ))}
      </section>

      {actionError ? <Callout tone="danger">{actionError}</Callout> : null}

      <section className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-semibold">{t("queueTitle")}</h2>
          <Button type="button" size="md" variant="secondary" className="w-auto" onClick={reload}>
            {t("refresh")}
          </Button>
        </div>

        {data.queue.length === 0 ? (
          <Card>
            <p className="text-center text-lg text-ink-soft">{t("queueEmpty")}</p>
          </Card>
        ) : null}

        {data.queue.map((row) => {
          const stale = row.age_minutes >= 25 && !row.responder_first_name;

          return (
            <Card key={row.id} className={stale ? "border-danger" : undefined}>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-mono text-sm text-ink-faint">{row.short_code}</p>
                  <p className="text-lg font-semibold">
                    {tEnum(`vehicleClass.${row.vehicle_class}`)} ·{" "}
                    {tEnum(`stuckType.${row.stuck_type}`)}
                    {row.stuck_depth ? ` · ${tEnum(`stuckDepth.${row.stuck_depth}`)}` : ""}
                  </p>
                  <p className="text-base text-ink-soft">
                    {tEnum(`requestStatus.${row.status}`)} ·{" "}
                    {t("age", { minutes: row.age_minutes })} ·{" "}
                    {t("ringAndCount", { ring: row.current_ring, count: row.notified_count })}
                  </p>
                </div>
                {stale ? (
                  <span className="shrink-0 rounded-full bg-danger-tint px-3 py-1 text-sm font-bold text-danger">
                    {t("stale")}
                  </span>
                ) : null}
              </div>

              <div className="mt-3 space-y-1 text-base">
                <p>
                  {row.requester_name} ·{" "}
                  <a
                    href={`tel:${row.requester_phone}`}
                    className="underline underline-offset-4"
                  >
                    {formatUsPhone(row.requester_phone)}
                  </a>
                </p>
                {row.county ? <p className="text-ink-soft">{row.county} County</p> : null}
                {row.notes ? <p>{row.notes}</p> : null}
                {row.responder_first_name ? (
                  <p className="font-medium text-good">
                    {t("assignedTo", {
                      name: row.responder_first_name,
                      eta: row.eta_minutes ?? 0,
                    })}
                  </p>
                ) : null}
              </div>

              <div className="mt-3 flex flex-wrap gap-3 text-base">
                <a
                  href={mapAppUrl(row.lat, row.lng)}
                  target="_blank"
                  rel="noreferrer"
                  className="underline underline-offset-4"
                >
                  {t("openPin")}
                </a>
                <Link href={`/r/${row.public_token}`} className="underline underline-offset-4">
                  {t("openStatus")}
                </Link>
                <Link href={`/post/${row.public_token}`} className="underline underline-offset-4">
                  {t("openPost")}
                </Link>
                <button
                  type="button"
                  className="underline underline-offset-4"
                  onClick={() => setExpanded(expanded === row.id ? null : row.id)}
                >
                  {expanded === row.id ? t("hideVolunteers") : t("dispatchManually")}
                </button>
              </div>

              {expanded === row.id ? (
                <div className="mt-3 space-y-2 border-t border-line pt-3">
                  <p className="text-sm text-ink-soft">{t("pickVolunteer")}</p>
                  {available.length === 0 ? (
                    <p className="text-base text-ink-soft">{t("noVolunteers")}</p>
                  ) : null}
                  {available.slice(0, 25).map((responder) => (
                    <div
                      key={responder.id}
                      className="flex items-center justify-between gap-3 rounded-field border border-line p-2"
                    >
                      <span className="text-base">
                        {responder.first_name}
                        <span className="block text-sm text-ink-faint">
                          {responder.equipment
                            .map((item) => tEnum(`equipment.${item}`))
                            .join(", ")}
                        </span>
                      </span>
                      <span className="flex shrink-0 gap-2">
                        <Button
                          type="button"
                          size="md"
                          variant="secondary"
                          className="w-auto"
                          disabled={busy}
                          onClick={() => dispatchTo(row.id, responder.id)}
                        >
                          {t("text")}
                        </Button>
                        <Button
                          type="button"
                          size="md"
                          className="w-auto"
                          disabled={busy}
                          onClick={() => reassign(row.id, responder.id)}
                        >
                          {t("assign")}
                        </Button>
                      </span>
                    </div>
                  ))}
                </div>
              ) : null}
            </Card>
          );
        })}
      </section>
    </div>
  );
}
