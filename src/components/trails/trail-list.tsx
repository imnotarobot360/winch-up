"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { AdSlot } from "@/components/ads/ad-slot";
import { Button, Callout, Card, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

type Trail = {
  id: string;
  slug: string;
  name: string;
  region: string | null;
  access: string;
  access_source: string | null;
  difficulty: string | null;
  summary: string | null;
  min_drivetrain: string;
  saved: boolean;
  distance_miles: number | null;
  latest_condition: { state: string; at: string } | null;
};

const ACCESS = ["open_public", "permit_required", "private_permission", "closed", "unknown"];
const DIFFICULTY = ["easy", "moderate", "difficult", "extreme"];

/**
 * The trail directory.
 *
 * Two things this screen refuses to do, both of them load-bearing:
 *
 * It never shows an access status on its own. `open_public` renders as the words plus the source
 * the admin cited plus the date it was checked, because "Open" in a coloured pill is a claim this
 * project is not in a position to make, and the person reading it is deciding whether to drive
 * forty miles down a caliche road.
 *
 * It never lets a member's condition report look like a fact about today. Every one carries its
 * date, and the database drops them off the page after 45 days rather than letting March read as
 * September.
 */
export function TrailList() {
  const t = useTranslations("trails");
  const tEnum = useTranslations("enum");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [trails, setTrails] = useState<Trail[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [query, setQuery] = useState("");
  const [access, setAccess] = useState<string | null>(null);
  const [difficulty, setDifficulty] = useState<string | null>(null);
  const [savedOnly, setSavedOnly] = useState(false);
  const [near, setNear] = useState<{ lng: number; lat: number } | null>(null);
  const [locating, setLocating] = useState(false);

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("trails_search", {
      p_query: query.trim() || null,
      p_access: access,
      p_difficulty: difficulty,
      p_saved_only: savedOnly,
      p_near_lng: near?.lng ?? null,
      p_near_lat: near?.lat ?? null,
      p_limit: 50,
    });

    if (rpcError) {
      setError("failed");
      return;
    }

    const result = data as { ok: boolean; error?: string; trails?: Trail[] };
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setError(null);
    setTrails(result.trails ?? []);
  }, [query, access, difficulty, savedOnly, near]);

  useEffect(() => {
    const timer = setTimeout(() => void load(), 250);
    return () => clearTimeout(timer);
  }, [load]);

  function locate() {
    if (!navigator.geolocation) return;
    setLocating(true);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setNear({ lng: pos.coords.longitude, lat: pos.coords.latitude });
        setLocating(false);
      },
      // No error message. Sorting by distance is a convenience; if the browser says no, the list
      // is still a list.
      () => setLocating(false),
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 300_000 },
    );
  }

  const chip = (active: boolean) =>
    cn(
      "min-h-12 rounded-field border-2 px-3 py-2 text-sm font-semibold",
      active ? "border-brand bg-brand-tint text-ink" : "border-line text-ink-soft",
    );

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("intro")}</p>
      </div>

      {/* Said once, at the top, before anything that looks like an answer. */}
      <Callout tone="neutral">
        <p className="font-semibold">{t("caveatTitle")}</p>
        <p className="mt-1 text-sm">{t("caveatBody")}</p>
      </Callout>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      <Card className="space-y-3">
        <Field label={t("searchLabel")}>
          <TextInput
            type="search"
            placeholder={t("searchPlaceholder")}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </Field>

        <div role="group" aria-label={t("accessFilterLabel")} className="flex flex-wrap gap-2">
          <button type="button" className={chip(access === null)} onClick={() => setAccess(null)}>
            {t("anyAccess")}
          </button>
          {ACCESS.map((a) => (
            <button
              key={a}
              type="button"
              aria-pressed={access === a}
              className={chip(access === a)}
              onClick={() => setAccess(access === a ? null : a)}
            >
              {tEnum(`trailAccess.${a}`)}
            </button>
          ))}
        </div>

        <div role="group" aria-label={t("difficultyFilterLabel")} className="flex flex-wrap gap-2">
          <button
            type="button"
            className={chip(difficulty === null)}
            onClick={() => setDifficulty(null)}
          >
            {t("anyDifficulty")}
          </button>
          {DIFFICULTY.map((d) => (
            <button
              key={d}
              type="button"
              aria-pressed={difficulty === d}
              className={chip(difficulty === d)}
              onClick={() => setDifficulty(difficulty === d ? null : d)}
            >
              {tEnum(`trailDifficulty.${d}`)}
            </button>
          ))}
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            aria-pressed={savedOnly}
            className={chip(savedOnly)}
            onClick={() => setSavedOnly((v) => !v)}
          >
            {t("savedOnly")}
          </button>
          <button
            type="button"
            aria-pressed={near !== null}
            className={chip(near !== null)}
            onClick={() => (near ? setNear(null) : locate())}
            disabled={locating}
          >
            {locating ? t("locating") : near ? t("nearMeOn") : t("nearMe")}
          </button>
        </div>
      </Card>

      {trails === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : trails.length === 0 ? (
        <Card className="space-y-2">
          <p className="text-base font-semibold">{t("emptyTitle")}</p>
          {/* The honest empty state. There is no imported dataset, on purpose. */}
          <p className="text-base text-ink-soft">{t("emptyBody")}</p>
        </Card>
      ) : (
        <ul className="space-y-3">
          {trails.map((trail) => (
            <li key={trail.id}>
              <Link
                href={`/trails/${trail.slug}`}
                className="block rounded-2xl border border-line bg-surface p-5 hover:bg-surface-sunk"
              >
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-lg font-semibold">{trail.name}</p>
                  {trail.distance_miles !== null ? (
                    <p className="text-sm text-ink-faint">
                      {t("milesAway", { miles: trail.distance_miles })}
                    </p>
                  ) : null}
                </div>

                {trail.region ? (
                  <p className="text-sm text-ink-faint">{trail.region}</p>
                ) : null}

                {/* Status and source together, always. One without the other is the thing the
                    schema exists to prevent. */}
                <p className="mt-2 text-sm">
                  <span className="font-semibold">{tEnum(`trailAccess.${trail.access}`)}</span>
                  {trail.access_source ? (
                    <span className="text-ink-faint"> · {trail.access_source}</span>
                  ) : null}
                </p>

                {trail.difficulty ? (
                  <p className="text-sm text-ink-soft">
                    {tEnum(`trailDifficulty.${trail.difficulty}`)}
                    {trail.min_drivetrain !== "unknown"
                      ? ` · ${tEnum(`drivetrain.${trail.min_drivetrain}`)}`
                      : ""}
                  </p>
                ) : null}

                {trail.summary ? (
                  <p className="mt-2 text-base text-ink-soft">{trail.summary}</p>
                ) : null}

                {trail.latest_condition ? (
                  <p className="mt-2 text-sm">
                    <span className="font-semibold text-brand-text">
                      {tEnum(`trailCondition.${trail.latest_condition.state}`)}
                    </span>
                    <span className="text-ink-faint">
                      {" "}
                      · {t("memberReport", { when: relative(trail.latest_condition.at) })}
                    </span>
                  </p>
                ) : null}

                {trail.saved ? (
                  <p className="mt-2 text-sm font-semibold text-ink-faint">{t("savedTag")}</p>
                ) : null}
              </Link>
            </li>
          ))}
        </ul>
      )}

      <AdSlot surface="trails" />

      <SuggestTrail onDone={() => void load()} />
    </div>
  );
}

/**
 * "We don't have this one." The same door as a correction, because a member who drove somewhere
 * new should not have to work out which of three forms they want.
 */
function SuggestTrail({ onDone }: { onDone: () => void }) {
  const t = useTranslations("trails");

  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [region, setRegion] = useState("");
  const [coords, setCoords] = useState("");
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;

    // "30.2672, -97.7431" — the format people paste out of a maps app.
    const match = coords.trim().match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/);
    if (!match) {
      setProblem("bad_coords");
      return;
    }

    setBusy(true);
    setProblem(null);

    const { data, error } = await supabaseBrowser().rpc("submit_trail_edit", {
      p_payload: {
        kind: "new",
        name: name.trim(),
        region: region.trim() || null,
        lat: Number(match[1]),
        lng: Number(match[2]),
        body: body.trim(),
      },
    });

    setBusy(false);

    const result = data as { ok: boolean; error?: string } | null;
    if (error || !result?.ok) {
      setProblem(result?.error ?? "failed");
      return;
    }

    setName("");
    setRegion("");
    setCoords("");
    setBody("");
    setSent(true);
    setOpen(false);
    onDone();
  }

  if (sent) {
    return <Callout tone="good">{t("suggestThanks")}</Callout>;
  }

  if (!open) {
    return (
      <Button variant="secondary" onClick={() => setOpen(true)}>
        {t("suggest")}
      </Button>
    );
  }

  return (
    <Card>
      <form onSubmit={submit} className="space-y-3">
        <h2 className="text-lg font-semibold">{t("suggestTitle")}</h2>
        <p className="text-sm text-ink-faint">{t("suggestNote")}</p>

        {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

        <Field label={t("suggestName")}>
          <TextInput value={name} onChange={(e) => setName(e.target.value)} maxLength={120} />
        </Field>

        <Field label={t("suggestRegion")}>
          <TextInput value={region} onChange={(e) => setRegion(e.target.value)} maxLength={120} />
        </Field>

        <Field label={t("suggestCoords")} hint={t("suggestCoordsHint")}>
          <TextInput
            inputMode="decimal"
            placeholder="30.2672, -97.7431"
            value={coords}
            onChange={(e) => setCoords(e.target.value)}
          />
        </Field>

        <Field label={t("suggestBody")}>
          <TextArea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            maxLength={2000}
            rows={3}
          />
        </Field>

        <Button type="submit" disabled={busy || name.trim().length < 2 || body.trim().length === 0}>
          {busy ? t("sending") : t("suggestSend")}
        </Button>
        <Button variant="quiet" onClick={() => setOpen(false)}>
          {t("cancel")}
        </Button>
      </form>
    </Card>
  );
}
