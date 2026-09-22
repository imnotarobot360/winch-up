"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card, ChoiceList, Field, TextArea } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Trail = {
  id: string;
  slug: string;
  name: string;
  region: string | null;
  lng: number;
  lat: number;
  access: string;
  access_source: string | null;
  access_checked_at: string | null;
  difficulty: string | null;
  difficulty_source: string | null;
  summary: string | null;
  description: string | null;
  min_drivetrain: string;
  recommended_equipment: string[];
  verified_at: string | null;
  saved: boolean;
};

type Condition = {
  id: string;
  state: string;
  note: string | null;
  created_at: string;
  mine: boolean;
  author_name: string;
};

type Payload = {
  ok: boolean;
  error?: string;
  trail?: Trail;
  conditions?: Condition[];
  condition_window_days?: number;
};

const STATES = ["good", "wet", "muddy", "flooded", "impassable", "access_blocked"] as const;
type State = (typeof STATES)[number];

/**
 * One trail.
 *
 * The page is built in two clearly separated halves, and the separation is the feature:
 *
 *   Above -- what an admin checked, with the source of every claim and the date it was checked.
 *   Below -- what members saw, each one dated, none of it verified, all of it ageing off after
 *            45 days.
 *
 * They are never interleaved and never styled alike. A reader should not have to work out which
 * kind of statement they are looking at, because the two answer different questions: "am I
 * allowed to be here" and "what was it like on Saturday".
 */
export function TrailDetail({ slug }: { slug: string }) {
  const t = useTranslations("trails");
  const tEnum = useTranslations("enum");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [data, setData] = useState<Payload | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data: result, error } = await supabaseBrowser().rpc("trail_detail", { p_slug: slug });
    if (error) {
      setData({ ok: false, error: "failed" });
      return;
    }
    setData(result as Payload);
  }, [slug]);

  useEffect(() => {
    void load();
  }, [load]);

  async function toggleSave() {
    if (!data?.trail) return;
    setBusy(true);
    await supabaseBrowser().rpc("trail_save", {
      p_trail_id: data.trail.id,
      p_on: !data.trail.saved,
    });
    setBusy(false);
    await load();
  }

  if (data === null) return <p className="text-base text-ink-soft">{t("loading")}</p>;

  if (!data.ok || !data.trail) {
    return (
      <Card className="space-y-3">
        <p className="text-base">{t(`errors.${data.error ?? "not_found"}`)}</p>
        <Link href="/trails" className="underline underline-offset-4">
          {t("backToTrails")}
        </Link>
      </Card>
    );
  }

  const trail = data.trail;
  const conditions = data.conditions ?? [];
  const windowDays = data.condition_window_days ?? 45;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{trail.name}</h1>
        {trail.region ? <p className="text-base text-ink-soft">{trail.region}</p> : null}
      </div>

      {/* ---- What somebody checked ---------------------------------------- */}

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">{t("accessTitle")}</h2>

        <p className="text-xl font-bold">{tEnum(`trailAccess.${trail.access}`)}</p>

        {trail.access === "unknown" ? (
          <Callout tone="danger">{t("accessUnknown")}</Callout>
        ) : (
          <>
            <p className="text-base text-ink-soft">
              {/* Never the status alone. The source is the claim's whole warrant. */}
              {t("accessSource", { source: trail.access_source ?? "" })}
            </p>
            {trail.access_checked_at ? (
              <p className="text-sm text-ink-faint">
                {t("accessChecked", { when: relative(trail.access_checked_at) })}
              </p>
            ) : null}
          </>
        )}

        {trail.access === "private_permission" ? (
          <Callout tone="danger">{t("accessPrivate")}</Callout>
        ) : null}

        {trail.access === "closed" ? <Callout tone="danger">{t("accessClosed")}</Callout> : null}
      </Card>

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">{t("aboutTitle")}</h2>

        {trail.difficulty ? (
          <div>
            <p className="text-base font-semibold">
              {tEnum(`trailDifficulty.${trail.difficulty}`)}
            </p>
            <p className="text-sm text-ink-faint">
              {t("difficultySource", { source: trail.difficulty_source ?? "" })}
            </p>
          </div>
        ) : null}

        {trail.min_drivetrain !== "unknown" ? (
          <p className="text-base">
            {t("drivetrain", { value: tEnum(`drivetrain.${trail.min_drivetrain}`) })}
          </p>
        ) : null}

        {trail.recommended_equipment.length > 0 ? (
          <div>
            <p className="text-base font-semibold">{t("bringTitle")}</p>
            <ul className="mt-1 list-inside list-disc text-base text-ink-soft">
              {trail.recommended_equipment.map((e) => (
                <li key={e}>{tEnum(`equipment.${e}`)}</li>
              ))}
            </ul>
          </div>
        ) : null}

        {trail.description ? (
          <p className="whitespace-pre-wrap text-base text-ink-soft">{trail.description}</p>
        ) : null}

        <p className="text-sm text-ink-faint">
          {trail.lat.toFixed(5)}, {trail.lng.toFixed(5)}
        </p>

        <div className="flex flex-wrap gap-2">
          <Button
            variant={trail.saved ? "primary" : "secondary"}
            size="md"
            className="w-auto"
            disabled={busy}
            aria-pressed={trail.saved}
            onClick={() => void toggleSave()}
          >
            {trail.saved ? t("saved") : t("save")}
          </Button>
          <a
            href={`https://www.google.com/maps/search/?api=1&query=${trail.lat},${trail.lng}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-12 items-center rounded-field border-2 border-line px-4 text-base font-semibold"
          >
            {t("openInMaps")}
          </a>
        </div>
      </Card>

      {/* ---- What members saw --------------------------------------------- */}

      <div className="space-y-3 rounded-2xl border-2 border-dashed border-line p-4">
        <div>
          <h2 className="text-lg font-semibold">{t("conditionsTitle")}</h2>
          {/* The label that keeps this half from being read as the half above. */}
          <p className="mt-1 text-sm text-ink-faint">{t("conditionsNote", { days: windowDays })}</p>
        </div>

        {conditions.length === 0 ? (
          <p className="text-base text-ink-soft">{t("noConditions", { days: windowDays })}</p>
        ) : (
          <ul className="space-y-3">
            {conditions.map((c) => (
              <li key={c.id} className="rounded-field bg-surface-sunk p-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-base font-semibold">
                    {tEnum(`trailCondition.${c.state}`)}
                  </p>
                  {/* Dated, always, and never relative alone — "3 weeks ago" plus the date. */}
                  <p className="text-sm text-ink-faint">
                    {relative(c.created_at)} ·{" "}
                    {format.dateTime(new Date(c.created_at), {
                      day: "numeric",
                      month: "short",
                    })}
                  </p>
                </div>
                {c.note ? (
                  <p className="mt-1 whitespace-pre-wrap text-base">{c.note}</p>
                ) : null}
                <p className="mt-1 text-sm text-ink-faint">
                  {c.author_name || t("someone")}
                  {c.mine ? ` · ${t("yours")}` : ""}
                </p>
                {!c.mine ? (
                  <ReportCondition conditionId={c.id} />
                ) : null}
              </li>
            ))}
          </ul>
        )}

        <AddCondition trailId={trail.id} onDone={() => void load()} />
      </div>

      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <ReportListing trailId={trail.id} onProblem={setProblem} />
    </div>
  );
}

function AddCondition({ trailId, onDone }: { trailId: string; onDone: () => void }) {
  const t = useTranslations("trails");
  const tEnum = useTranslations("enum");

  const [open, setOpen] = useState(false);
  const [state, setState] = useState<State | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!state || busy) return;

    setBusy(true);
    setProblem(null);

    const { data, error } = await supabaseBrowser().rpc("report_trail_condition", {
      p_trail_id: trailId,
      p_state: state,
      p_note: note.trim() || null,
    });

    setBusy(false);

    const result = data as { ok: boolean; error?: string } | null;
    if (error || !result?.ok) {
      setProblem(result?.error ?? "failed");
      return;
    }

    setState(null);
    setNote("");
    setOpen(false);
    onDone();
  }

  if (!open) {
    return (
      <Button variant="secondary" size="md" onClick={() => setOpen(true)}>
        {t("addCondition")}
      </Button>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <Field label={t("conditionStateLabel")}>
        <ChoiceList
          name={t("conditionStateLabel")}
          value={state}
          onChange={setState}
          columns={2}
          options={STATES.map((s) => ({ value: s, label: tEnum(`trailCondition.${s}`) }))}
        />
      </Field>

      <Field label={t("conditionNoteLabel")} hint={t("conditionNoteHint")}>
        <TextArea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          maxLength={500}
          rows={2}
        />
      </Field>

      <Button type="submit" size="md" disabled={busy || !state}>
        {busy ? t("sending") : t("conditionSend")}
      </Button>
      <Button variant="quiet" size="md" onClick={() => setOpen(false)}>
        {t("cancel")}
      </Button>
    </form>
  );
}

function ReportCondition({ conditionId }: { conditionId: string }) {
  const t = useTranslations("trails");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);

  if (sent) return <p className="mt-1 text-sm text-ink-faint">{t("reportThanks")}</p>;

  return (
    <button
      type="button"
      disabled={busy}
      className="mt-1 text-sm font-semibold text-ink-faint underline underline-offset-4"
      onClick={async () => {
        setBusy(true);
        await supabaseBrowser().rpc("community_report", {
          p_kind: "trail_condition",
          p_id: conditionId,
          p_reason: "unsafe_advice",
          p_note: null,
        });
        setBusy(false);
        setSent(true);
      }}
    >
      {t("reportCondition")}
    </button>
  );
}

/**
 * "This listing is wrong." The most important form on the page: a new fence or a locked gate is
 * exactly the thing that makes a published access status dangerous, and the member standing at
 * the gate is the only person who knows.
 */
function ReportListing({
  trailId,
  onProblem,
}: {
  trailId: string;
  onProblem: (error: string | null) => void;
}) {
  const t = useTranslations("trails");

  const [open, setOpen] = useState(false);
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  if (sent) return <Callout tone="good">{t("listingReportThanks")}</Callout>;

  if (!open) {
    return (
      <Button variant="quiet" onClick={() => setOpen(true)}>
        {t("reportListing")}
      </Button>
    );
  }

  return (
    <Card>
      <form
        className="space-y-3"
        onSubmit={async (event) => {
          event.preventDefault();
          if (busy) return;
          setBusy(true);
          onProblem(null);

          const { data, error } = await supabaseBrowser().rpc("submit_trail_edit", {
            p_payload: { kind: "problem", trail_id: trailId, body: body.trim() },
          });

          setBusy(false);
          const result = data as { ok: boolean; error?: string } | null;

          if (error || !result?.ok) {
            onProblem(result?.error ?? "failed");
            return;
          }

          setBody("");
          setOpen(false);
          setSent(true);
        }}
      >
        <h2 className="text-lg font-semibold">{t("reportListingTitle")}</h2>
        <p className="text-sm text-ink-faint">{t("reportListingNote")}</p>

        <Field label={t("reportListingLabel")}>
          <TextArea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            maxLength={2000}
            rows={3}
          />
        </Field>

        <Button type="submit" size="md" disabled={busy || body.trim().length === 0}>
          {busy ? t("sending") : t("reportListingSend")}
        </Button>
        <Button variant="quiet" size="md" onClick={() => setOpen(false)}>
          {t("cancel")}
        </Button>
      </form>
    </Card>
  );
}
