"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { offerAssistanceAction, withdrawOfferAction } from "@/app/actions/offers";
import { Button, Callout, Card, Checkbox, TextArea, TextInput } from "@/components/ui/primitives";
import { mapAppUrl } from "@/lib/geo";

export type HelpRow = {
  request_id: string;
  short_code: string;
  status: string;
  distance_miles: number | null;
  lat: number;
  lng: number;
  vehicle_class: string;
  stuck_type: string;
  stuck_depth: string | null;
  needs_tractor: boolean;
  needs_second_truck: boolean;
  land_type: string;
  required_equipment: string[] | null;
  county: string | null;
  created_at: string;
  offer_state: string | null;
  i_offered: boolean;
};

const POLL_MS = 30_000;

/** Every refusal `offer_assistance` and `withdraw_my_offer` can return, each with a string. */
const KNOWN_ERRORS = [
  "already_covered",
  "already_closed",
  "own_request",
  "not_signed_in",
  "no_recovery_profile",
  "equipment_not_acknowledged",
  "offer_not_possible",
  "no_open_offer",
  "not_found",
  "server_error",
];

/**
 * Help Someone (spec section 3).
 *
 * The other half of a dispatcher that only ever pushed. Until now a volunteer waited to be
 * texted; there was no screen that answered "who near me needs help right now", because under
 * the old model nobody was allowed to ask.
 *
 * WHAT IS NOT ON THIS SCREEN
 *
 * The exact pin, and any way to reach anybody. Every row here is the blurred location — about a
 * mile off — and the database is what enforces that, not this component: `nearby_requests` has
 * no branch that can return the real coordinates. Contact details are released to one person at
 * one moment, which is when the requester accepts. A member browsing this list is a stranger to
 * the person in the ditch, and the screen treats them that way until the requester decides
 * otherwise.
 */
export function HelpList({ initial }: { initial: HelpRow[] }) {
  const t = useTranslations("help");
  const tEnum = useTranslations("enum");
  const format = useFormatter();
  const now = useNow({ updateInterval: POLL_MS });

  const [rows, setRows] = useState(initial);
  const [openFor, setOpenFor] = useState<string | null>(null);
  const [coords, setCoords] = useState<{ lat: number; lng: number } | null>(null);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  // Somebody opening this screen is usually already out somewhere, so their live position beats
  // whatever they saved as home. Refused permission is not an error state: the list still works,
  // it just orders by recency instead of distance.
  useEffect(() => {
    if (!("geolocation" in navigator)) return;
    navigator.geolocation.getCurrentPosition(
      (position) =>
        setCoords({ lat: position.coords.latitude, lng: position.coords.longitude }),
      () => undefined,
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 120_000 },
    );
  }, []);

  const refresh = useCallback(async () => {
    try {
      const query = coords ? `?lat=${coords.lat}&lng=${coords.lng}` : "";
      const response = await fetch(`/api/help${query}`, { cache: "no-store" });
      if (!response.ok) return;
      setRows((await response.json()) as HelpRow[]);
    } catch {
      // Next tick tries again.
    }
  }, [coords]);

  useEffect(() => {
    if (coords) void refresh();
  }, [coords, refresh]);

  useEffect(() => {
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, POLL_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  return (
    <div className="mx-auto w-full max-w-2xl px-4 py-6">
      <h1 className="font-display text-3xl">{t("title")}</h1>
      <p className="mt-1 text-ink-soft">{t("subtitle")}</p>

      <Callout tone="neutral" className="mt-4 text-sm">
        {t("privacyNote")}
      </Callout>

      {error ? (
        <Callout tone="danger" className="mt-4" role="alert">
          {/* The database returns a small, closed set of reasons an offer can be refused, and each
              one has a string. Anything unexpected falls back rather than rendering a raw code at
              somebody -- a missing key would otherwise throw and take the page with it. */}
          {KNOWN_ERRORS.includes(error)
            ? t(`errors.${error}` as never)
            : t("errors.server_error")}
        </Callout>
      ) : null}

      {rows.length === 0 ? (
        <Card className="mt-6 text-center text-ink-soft">{t("empty")}</Card>
      ) : (
        <ul className="mt-6 space-y-4">
          {rows.map((row) => (
            <li key={row.request_id}>
              <Card>
                <div className="flex items-baseline justify-between gap-3">
                  <span className="font-display text-xl">{row.short_code}</span>
                  <span className="text-sm text-ink-soft">
                    {format.relativeTime(new Date(row.created_at), now)}
                  </span>
                </div>

                <p className="mt-2">
                  {tEnum(`vehicleClass.${row.vehicle_class}` as never)} ·{" "}
                  {tEnum(`stuckType.${row.stuck_type}` as never)}
                  {row.stuck_depth
                    ? ` · ${tEnum(`stuckDepth.${row.stuck_depth}` as never)}`
                    : ""}
                </p>

                <p className="mt-1 text-sm text-ink-soft">
                  {row.distance_miles !== null
                    ? t("milesAway", { miles: row.distance_miles })
                    : t("distanceUnknown")}
                  {row.county ? ` · ${t("county", { county: row.county })}` : ""}
                  {" · "}
                  {t("approxArea")}
                </p>

                {row.needs_tractor || row.needs_second_truck ? (
                  <p className="mt-1 text-sm font-semibold text-brand">
                    {[
                      row.needs_tractor ? t("needsTractor") : null,
                      row.needs_second_truck ? t("needsSecondTruck") : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>
                ) : null}

                {row.required_equipment && row.required_equipment.length > 0 ? (
                  <p className="mt-1 text-sm text-ink-soft">
                    {t("equipmentNeeded", {
                      list: row.required_equipment
                        .map((e) => tEnum(`equipment.${e}` as never))
                        .join(", "),
                    })}
                  </p>
                ) : null}

                <div className="mt-4 flex flex-wrap gap-3">
                  <a
                    className="text-sm text-ink-soft underline underline-offset-4"
                    href={mapAppUrl(row.lat, row.lng)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {t("openArea")}
                  </a>
                </div>

                {row.i_offered ? (
                  <div className="mt-4">
                    <Callout tone="good" className="text-sm">
                      {t("alreadyOffered")}
                    </Callout>
                    <Button
                      variant="quiet"
                      size="md"
                      className="mt-2"
                      disabled={pending}
                      onClick={() =>
                        startTransition(async () => {
                          setError(null);
                          const result = await withdrawOfferAction(row.request_id);
                          if (!result.ok) setError(result.error);
                          else void refresh();
                        })
                      }
                    >
                      {t("withdraw")}
                    </Button>
                  </div>
                ) : openFor === row.request_id ? (
                  <OfferForm
                    pending={pending}
                    onCancel={() => setOpenFor(null)}
                    onSubmit={(input) =>
                      startTransition(async () => {
                        setError(null);
                        const result = await offerAssistanceAction(row.request_id, input);
                        if (!result.ok) setError(result.error);
                        else {
                          setOpenFor(null);
                          void refresh();
                        }
                      })
                    }
                  />
                ) : (
                  <Button className="mt-4" onClick={() => setOpenFor(row.request_id)}>
                    {t("offerToHelp")}
                  </Button>
                )}
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/**
 * The confirmation step the spec asks for.
 *
 * "Ask the member whether they have the necessary equipment and can safely provide the requested
 * assistance" — so the submit button stays disabled until they say so, and the database refuses
 * the offer without it as well. Two gates for one question, because this is the point where
 * somebody decides to drive into a situation they may not be equipped for, and a checkbox that
 * only the browser enforces is a checkbox that a stale page can skip.
 */
function OfferForm({
  pending,
  onCancel,
  onSubmit,
}: {
  pending: boolean;
  onCancel: () => void;
  onSubmit: (input: { note?: string; etaMinutes: number | null; equipmentAck: boolean }) => void;
}) {
  const t = useTranslations("help");
  const [ack, setAck] = useState(false);
  const [eta, setEta] = useState("");
  const [note, setNote] = useState("");

  const parsedEta = eta.trim() === "" ? null : Number.parseInt(eta, 10);
  const etaValid = parsedEta === null || (Number.isFinite(parsedEta) && parsedEta >= 1 && parsedEta <= 600);

  return (
    <div className="mt-4 border-t border-line pt-4">
      <Callout tone="brand" className="text-sm">
        {t("safetyPrompt")}
      </Callout>

      <div className="mt-3">
        <Checkbox id="offer-ack" checked={ack} onChange={setAck}>
          {t("equipmentAck")}
        </Checkbox>
      </div>

      <div className="mt-3">
        <label className="block text-sm text-ink-soft" htmlFor="offer-eta">
          {t("etaLabel")}
        </label>
        <TextInput
          id="offer-eta"
          inputMode="numeric"
          value={eta}
          onChange={(event) => setEta(event.target.value.replace(/[^0-9]/g, ""))}
          placeholder={t("etaPlaceholder")}
        />
        {!etaValid ? (
          <p className="mt-1 text-sm text-danger">{t("etaInvalid")}</p>
        ) : null}
      </div>

      <div className="mt-3">
        <label className="block text-sm text-ink-soft" htmlFor="offer-note">
          {t("noteLabel")}
        </label>
        <TextArea
          id="offer-note"
          rows={2}
          maxLength={200}
          value={note}
          onChange={(event) => setNote(event.target.value)}
          placeholder={t("notePlaceholder")}
        />
        {/* The database rejects a note containing a phone number or a URL, the same as every
            other public free-text field here. Saying so up front beats a refusal after typing. */}
        <p className="mt-1 text-xs text-ink-faint">{t("noteHint")}</p>
      </div>

      <div className="mt-4 flex gap-3">
        <Button
          disabled={!ack || !etaValid || pending}
          onClick={() => onSubmit({ note, etaMinutes: parsedEta, equipmentAck: ack })}
        >
          {t("sendOffer")}
        </Button>
        <Button variant="secondary" disabled={pending} onClick={onCancel}>
          {t("cancel")}
        </Button>
      </div>
    </div>
  );
}
