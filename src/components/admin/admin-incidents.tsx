"use client";

import { useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card, TextArea } from "@/components/ui/primitives";
import { formatUsPhone } from "@/lib/utils";

import { adminAction, useAdminData } from "./use-admin";

type Incident = {
  id: string;
  category: string;
  status: "new" | "reviewing" | "actioned" | "dismissed";
  description: string;
  admin_notes: string | null;
  created_at: string;
  reviewed_at: string | null;
  reporter_kind: string;
  request_code: string | null;
  request_status: string | null;
  subject_responder_id: string | null;
  subject_first_name: string | null;
  subject_phone: string | null;
  subject_approval: string | null;
  subject_prior_reports: number;
};

type Payload = {
  ok: boolean;
  counts: Record<string, number> | null;
  incidents: Incident[];
};

const FILTERS = ["new", "reviewing", "actioned", "dismissed"] as const;

// The two that stop being fixable if they sit in a queue.
const URGENT = ["asked_for_money", "injury", "harassment"];

/**
 * Safety report triage.
 *
 * What is deliberately not on this screen: who filed the report. An admin deciding whether to
 * ban somebody does not need to know which requester complained, and a screen that shows it will
 * eventually be read aloud to the person it is about. admin_incidents() does not return it.
 */
export function AdminIncidents() {
  const t = useTranslations("admin.incidents");
  const tEnum = useTranslations("enum");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const [filter, setFilter] = useState<(typeof FILTERS)[number] | null>("new");
  const { data, loading, error, reload } = useAdminData<Payload>("admin_incidents", {
    p_status: filter,
  });

  const [notes, setNotes] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  async function review(id: string, status: string) {
    setBusy(id);
    setActionError(null);
    const result = await adminAction("admin_review_incident", {
      p_id: id,
      p_status: status,
      p_notes: notes[id] ?? null,
    });
    setBusy(null);

    if (!result.ok) {
      setActionError(result.error ?? "failed");
      return;
    }
    setNotes((prev) => ({ ...prev, [id]: "" }));
    await reload();
  }

  const counts = data?.counts ?? {};

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      {error ? <Callout tone="danger">{error}</Callout> : null}
      {actionError ? <Callout tone="danger">{actionError}</Callout> : null}

      <div className="flex flex-wrap gap-2">
        {FILTERS.map((value) => (
          <button
            key={value}
            type="button"
            onClick={() => setFilter(value)}
            aria-pressed={filter === value}
            className={`min-h-12 rounded-field border-2 px-4 font-semibold ${
              filter === value ? "border-brand bg-brand-tint" : "border-line"
            }`}
          >
            {t("filters." + value)}
            {counts[value] ? ` (${counts[value]})` : ""}
          </button>
        ))}
        <button
          type="button"
          onClick={() => setFilter(null)}
          aria-pressed={filter === null}
          className={`min-h-12 rounded-field border-2 px-4 font-semibold ${
            filter === null ? "border-brand bg-brand-tint" : "border-line"
          }`}
        >
          {t("filters.all")}
        </button>
      </div>

      {loading ? null : data?.incidents.length === 0 ? (
        <Card>
          <p className="text-lg text-ink-soft">{t("empty")}</p>
        </Card>
      ) : (
        data?.incidents.map((incident) => (
          <Card key={incident.id} className="space-y-3">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <h3 className="text-lg font-bold">
                {tEnum("incidentCategory." + incident.category)}
              </h3>
              <span className="text-sm text-ink-faint">
                {format.relativeTime(new Date(incident.created_at), now)}
              </span>
            </div>

            {URGENT.includes(incident.category) && incident.status === "new" ? (
              <Callout tone="danger">{t("urgent")}</Callout>
            ) : null}

            <p className="whitespace-pre-wrap text-base">{incident.description}</p>

            <dl className="grid gap-x-4 gap-y-1 text-sm text-ink-soft sm:grid-cols-2">
              <div>
                <dt className="inline font-semibold">{t("reportedBy")}: </dt>
                <dd className="inline">{t("reporterKind." + incident.reporter_kind)}</dd>
              </div>
              {incident.request_code ? (
                <div>
                  <dt className="inline font-semibold">{t("request")}: </dt>
                  <dd className="inline">
                    {incident.request_code} · {incident.request_status}
                  </dd>
                </div>
              ) : null}
              {incident.subject_first_name ? (
                <>
                  <div>
                    <dt className="inline font-semibold">{t("subject")}: </dt>
                    <dd className="inline">
                      {incident.subject_first_name}
                      {incident.subject_phone ? ` · ${formatUsPhone(incident.subject_phone)}` : ""}
                      {incident.subject_approval ? ` · ${incident.subject_approval}` : ""}
                    </dd>
                  </div>
                  <div>
                    <dt className="inline font-semibold">{t("priorReports")}: </dt>
                    <dd className="inline">{incident.subject_prior_reports}</dd>
                  </div>
                </>
              ) : (
                <div>
                  <dt className="inline font-semibold">{t("subject")}: </dt>
                  <dd className="inline">{t("noSubject")}</dd>
                </div>
              )}
            </dl>

            {incident.admin_notes ? (
              <p className="rounded-field border-2 border-line p-3 text-sm">
                {incident.admin_notes}
              </p>
            ) : null}

            {incident.status === "actioned" || incident.status === "dismissed" ? (
              <p className="text-sm text-ink-faint">
                {t("closedAs", { status: t("filters." + incident.status) })}
              </p>
            ) : (
              <div className="space-y-2">
                <TextArea
                  aria-label={t("notesLabel")}
                  placeholder={t("notesPlaceholder")}
                  value={notes[incident.id] ?? ""}
                  onChange={(e) =>
                    setNotes((prev) => ({ ...prev, [incident.id]: e.target.value }))
                  }
                  rows={2}
                />
                <div className="flex flex-wrap gap-2">
                  {incident.status === "new" ? (
                    <Button
                      variant="secondary"
                      onClick={() => review(incident.id, "reviewing")}
                      disabled={busy === incident.id}
                    >
                      {t("markReviewing")}
                    </Button>
                  ) : null}
                  <Button
                    onClick={() => review(incident.id, "actioned")}
                    disabled={busy === incident.id}
                  >
                    {t("markActioned")}
                  </Button>
                  <Button
                    variant="secondary"
                    onClick={() => review(incident.id, "dismissed")}
                    disabled={busy === incident.id}
                  >
                    {t("markDismissed")}
                  </Button>
                </div>
                {incident.subject_responder_id ? (
                  <p className="text-sm text-ink-faint">{t("banHint")}</p>
                ) : null}
              </div>
            )}
          </Card>
        ))
      )}
    </div>
  );
}
