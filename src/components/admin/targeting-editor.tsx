"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";

/**
 * One geographic target. Mirrors a row of `target_locations`, and the shape CHECK on that table is
 * what actually enforces this — a city needs a state, a radius needs a centre and a distance.
 */
export type Target =
  | { kind: "state"; state: string }
  | { kind: "city"; city: string; state: string }
  | { kind: "postal_code"; postal_code: string }
  | { kind: "radius"; lng: number; lat: number; radius_miles: number };

/**
 * Choosing who something reaches (spec section 16's geographic selector).
 *
 * ONE COMPONENT FOR ALL THREE THINGS that can be targeted — campaigns, events, announcements —
 * because `target_locations` is one table with one matching rule. Three editors would be three places
 * for "a ZIP code is text, not a number" to be wrong independently.
 *
 * AN EMPTY LIST MEANS EVERYBODY, and the component says so in words rather than leaving a blank box.
 * That is not a UI convenience: the database represents "All Members" as the ABSENCE of rows, so that
 * adding a city cannot leave a stale "everyone" rule behind it. The screen has to make the empty state
 * legible or an admin will reasonably assume it means "nobody yet".
 *
 * WHAT THIS DOES NOT DO: pick a point on a map. Radius targeting takes typed coordinates, which is
 * honest about what exists — there is no member-facing map in this app to reuse, and a map picker is a
 * whole piece of work rather than a control. A ZIP or a city is what an admin actually reaches for, and
 * those are the first two options here for that reason.
 */
export function TargetingEditor({
  targets,
  onChange,
  audience,
}: {
  targets: Target[];
  onChange: (next: Target[]) => void;
  /** The estimated audience, when the caller has one to show. Section 14. */
  audience?: number | null;
}) {
  const t = useTranslations("adminContent");

  const [kind, setKind] = useState<Target["kind"]>("postal_code");
  const [state, setState] = useState("");
  const [city, setCity] = useState("");
  const [postal, setPostal] = useState("");
  const [lng, setLng] = useState("");
  const [lat, setLat] = useState("");
  const [miles, setMiles] = useState("25");
  const [problem, setProblem] = useState<string | null>(null);

  function add() {
    setProblem(null);

    if (kind === "state") {
      if (!/^[A-Z]{2}$/.test(state)) return setProblem(t("needState"));
      onChange([...targets, { kind: "state", state }]);
    }

    if (kind === "city") {
      // The state is required by the table's own CHECK, not merely by this form: Houston TX is not
      // Houston MO, and a bare city name would match four different towns.
      if (!city.trim()) return setProblem(t("needCity"));
      if (!/^[A-Z]{2}$/.test(state)) return setProblem(t("needState"));
      onChange([...targets, { kind: "city", city: city.trim(), state }]);
    }

    if (kind === "postal_code") {
      if (!/^[0-9]{5}$/.test(postal)) return setProblem(t("needPostal"));
      onChange([...targets, { kind: "postal_code", postal_code: postal }]);
    }

    if (kind === "radius") {
      const nLng = Number(lng);
      const nLat = Number(lat);
      const nMiles = Number(miles);
      if (!Number.isFinite(nLng) || !Number.isFinite(nLat)) return setProblem(t("needPoint"));
      if (!Number.isFinite(nMiles) || nMiles < 1 || nMiles > 500) return setProblem(t("needMiles"));
      onChange([...targets, { kind: "radius", lng: nLng, lat: nLat, radius_miles: nMiles }]);
    }

    setCity("");
    setPostal("");
  }

  function remove(index: number) {
    onChange(targets.filter((_, i) => i !== index));
  }

  return (
    <Card className="space-y-4 p-4">
      <div>
        <h3 className="text-base font-semibold text-ink">{t("targetingTitle")}</h3>
        <p className="mt-1 text-sm text-ink-soft">
          {targets.length === 0 ? t("targetingEveryone") : t("targetingAdditive")}
        </p>
      </div>

      {/* Section 14: the number an admin needs BEFORE publishing, and the question this screen is
          really asking is "is this aimed at anybody at all". Shown only once saved, because the count
          comes from the database against stored rows. */}
      {audience !== undefined && audience !== null ? (
        <Callout tone={audience === 0 ? "danger" : "neutral"}>
          {audience === 0 ? t("audienceNobody") : t("audienceCount", { count: audience })}
        </Callout>
      ) : null}

      {targets.length > 0 ? (
        <ul className="space-y-2">
          {targets.map((target, index) => (
            <li
              key={`${target.kind}-${index}`}
              className="flex min-w-0 items-center justify-between gap-2 rounded-field border-2 border-line px-3 py-2"
            >
              {/* min-w-0, or a long label pushes this row past the viewport on a phone: the parent's
                  default min-width:auto lets a flex child grow regardless of any max-width on it. */}
              <span className="min-w-0 break-words text-base text-ink">{describe(target)}</span>
              <button
                type="button"
                onClick={() => remove(index)}
                className="shrink-0 text-sm font-semibold text-danger underline underline-offset-4"
              >
                {t("remove")}
              </button>
            </li>
          ))}
        </ul>
      ) : null}

      {problem ? <Callout tone="danger">{problem}</Callout> : null}

      <Field label={t("addTarget")}>
        <select
          value={kind}
          onChange={(event) => setKind(event.target.value as Target["kind"])}
          className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
        >
          <option value="postal_code">{t("kindPostal")}</option>
          <option value="city">{t("kindCity")}</option>
          <option value="state">{t("kindState")}</option>
          <option value="radius">{t("kindRadius")}</option>
        </select>
      </Field>

      {kind === "postal_code" ? (
        <Field label={t("postalLabel")}>
          <TextInput
            value={postal}
            inputMode="numeric"
            maxLength={5}
            onChange={(event) =>
              setPostal(event.target.value.replace(/[^0-9]/g, "").slice(0, 5))
            }
          />
        </Field>
      ) : null}

      {kind === "city" ? (
        <>
          <Field label={t("cityLabel")}>
            <TextInput value={city} maxLength={80} onChange={(event) => setCity(event.target.value)} />
          </Field>
          <Field label={t("stateLabel")}>
            <TextInput
              value={state}
              maxLength={2}
              onChange={(event) => setState(event.target.value.toUpperCase().slice(0, 2))}
            />
          </Field>
        </>
      ) : null}

      {kind === "state" ? (
        <Field label={t("stateLabel")}>
          <TextInput
            value={state}
            maxLength={2}
            onChange={(event) => setState(event.target.value.toUpperCase().slice(0, 2))}
          />
        </Field>
      ) : null}

      {kind === "radius" ? (
        <>
          <Field label={t("lngLabel")} hint={t("pointHint")}>
            <TextInput value={lng} onChange={(event) => setLng(event.target.value)} />
          </Field>
          <Field label={t("latLabel")}>
            <TextInput value={lat} onChange={(event) => setLat(event.target.value)} />
          </Field>
          <Field label={t("milesLabel")}>
            <TextInput
              value={miles}
              inputMode="numeric"
              onChange={(event) => setMiles(event.target.value.replace(/[^0-9]/g, ""))}
            />
          </Field>
        </>
      ) : null}

      <Button variant="secondary" onClick={add}>
        {t("addTargetButton")}
      </Button>
    </Card>
  );
}

function describe(target: Target): string {
  switch (target.kind) {
    case "state":
      return target.state;
    case "city":
      return `${target.city}, ${target.state}`;
    case "postal_code":
      return target.postal_code;
    case "radius":
      return `${target.radius_miles} mi · ${target.lat.toFixed(4)}, ${target.lng.toFixed(4)}`;
  }
}

/**
 * What the admin RPCs return for an existing row's targeting, and what this editor needs to show it.
 *
 * SEPARATE FROM `Target` ON PURPOSE. The server sends every column of `target_locations` with nulls
 * for the ones this kind does not use, so a stored row is a loose bag of optional fields while a new
 * one is a discriminated union. Converting at the boundary keeps the loose shape out of the editor,
 * where it would mean a null check on every branch.
 */
export type StoredTarget = {
  kind: string;
  state: string | null;
  city: string | null;
  postal_code: string | null;
  radius_miles: number | null;
  // Optional, per the house rule: the app deploys on a push and the schema goes across separately, so
  // there is a window where the RPC has not started returning these. Added by 20261003001500 for
  // exactly the reason the comment in fromStored() describes.
  lng?: number | null;
  lat?: number | null;
};

export function fromStored(rows: StoredTarget[] | null | undefined): Target[] {
  if (!rows) return [];

  return rows.flatMap((row): Target[] => {
    if (row.kind === "state" && row.state) return [{ kind: "state", state: row.state }];
    if (row.kind === "city" && row.city && row.state)
      return [{ kind: "city", city: row.city, state: row.state }];
    if (row.kind === "postal_code" && row.postal_code)
      return [{ kind: "postal_code", postal_code: row.postal_code }];
    /**
     * A STORED RADIUS ROUND-TRIPS, and it is worth knowing why that needed a migration.
     *
     * The admin listings originally returned a radius target's distance and not its centre -- sensible
     * for a list, and silently destructive here. The editor loads a row's targets, the admin adds a ZIP
     * code, and the save sends the whole array; the writer replaces targeting wholesale when that key
     * is present, which is what "this is for everybody now" needs. A radius this function could not
     * represent would simply not be in the array sent back, so it would be deleted. Nothing errors, the
     * campaign quietly stops reaching the area it was bought for, and the only evidence is a number on
     * a report getting smaller.
     *
     * 20261003001500 added the centre to the payload. If it is missing -- a frontend deployed ahead of
     * that migration -- the row is dropped rather than guessed at, which is the same window every other
     * optional field in this app has, and the `?? []` equivalent of it.
     */
    if (
      row.kind === "radius" &&
      typeof row.lng === "number" &&
      typeof row.lat === "number" &&
      typeof row.radius_miles === "number"
    ) {
      return [{ kind: "radius", lng: row.lng, lat: row.lat, radius_miles: row.radius_miles }];
    }

    return [];
  });
}
