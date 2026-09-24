"use client";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";

import {
  Button,
  Callout,
  Field,
  TextArea,
  TextInput,
} from "@/components/ui/primitives";
import { formatCoords, isInTexasish, type LocationSource } from "@/lib/geo";
import { formatAccuracy } from "@/lib/utils";

import { MapPicker } from "./map-picker";

export type LocationValue = {
  lat: number;
  lng: number;
  accuracyM: number | null;
  source: LocationSource;
  note: string;
};

/** Roughly the middle of the coverage area, used only to seed the map before a fix arrives. */
const FALLBACK_CENTER = { lat: 30.0, lng: -95.4 };

type GpsState =
  | { kind: "idle" }
  | { kind: "locating" }
  | { kind: "fixed"; lat: number; lng: number; accuracyM: number }
  | { kind: "denied" }
  | { kind: "unavailable" };

export function LocationStep({
  value,
  onChange,
  locale,
}: {
  value: LocationValue | null;
  onChange: (next: LocationValue) => void;
  locale: string;
}) {
  const t = useTranslations("request.location");
  const [mode, setMode] = useState<"gps" | "map" | "paste">("gps");
  const [gps, setGps] = useState<GpsState>({ kind: "idle" });
  const [pasted, setPasted] = useState("");
  // Where the map pin is right now, before anybody has agreed to it. Separate from `value` so
  // that panning around cannot quietly change what gets submitted.
  const [pending, setPending] = useState<{ lat: number; lng: number } | null>(null);
  const [pasteError, setPasteError] = useState<string | null>(null);
  const [resolving, setResolving] = useState(false);
  const [note, setNote] = useState(value?.note ?? "");
  const watchRef = useRef<number | null>(null);

  // Start locating as soon as the step opens. Every second spent waiting for a tap is a second
  // the GPS is not warming up.
  useEffect(() => {
    if (!("geolocation" in navigator)) {
      setGps({ kind: "unavailable" });
      return;
    }

    setGps({ kind: "locating" });

    const id = navigator.geolocation.watchPosition(
      (position) => {
        setGps((previous) => {
          const next = {
            kind: "fixed" as const,
            lat: position.coords.latitude,
            lng: position.coords.longitude,
            accuracyM: position.coords.accuracy,
          };
          // Keep the best fix seen, not the newest: accuracy usually improves then wobbles.
          if (previous.kind === "fixed" && previous.accuracyM <= next.accuracyM) {
            return previous;
          }
          return next;
        });
      },
      (error) => {
        setGps(error.code === error.PERMISSION_DENIED ? { kind: "denied" } : { kind: "unavailable" });
      },
      { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 },
    );

    watchRef.current = id;

    return () => {
      if (watchRef.current !== null) navigator.geolocation.clearWatch(watchRef.current);
    };
  }, []);

  function commit(next: Omit<LocationValue, "note">) {
    onChange({ ...next, note });
  }

  function updateNote(text: string) {
    setNote(text);
    if (value) onChange({ ...value, note: text });
  }

  async function resolvePasted() {
    setResolving(true);
    setPasteError(null);

    try {
      const response = await fetch("/api/geo/resolve", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: pasted }),
      });

      const payload = (await response.json()) as {
        lat?: number;
        lng?: number;
        source?: LocationSource;
        error?: string;
      };

      if (!response.ok || payload.lat == null || payload.lng == null) {
        setPasteError(payload.error ?? "unrecognised");
        return;
      }

      commit({
        lat: payload.lat,
        lng: payload.lng,
        accuracyM: null,
        source: payload.source ?? "coordinates",
      });
    } catch {
      setPasteError("network");
    } finally {
      setResolving(false);
    }
  }

  // Order matters: an un-confirmed pin beats a confirmed value, which beats the GPS fix, which
  // beats the fallback. Switching to Paste and back must not throw away the spot the member was
  // lining up, and it must not silently promote it either.
  const seed =
    pending ??
    value ??
    (gps.kind === "fixed" ? { lat: gps.lat, lng: gps.lng } : FALLBACK_CENTER);

  const outsideTexas = value ? !isInTexasish(value.lat, value.lng) : false;

  return (
    <div className="space-y-5">
      {value ? (
        <Callout tone="good">
          <p className="font-semibold">{t("haveIt")}</p>
          <p className="font-mono text-sm">{formatCoords(value.lat, value.lng)}</p>
          {value.accuracyM != null ? (
            <p className="text-sm">
              {t("accuracy", { value: formatAccuracy(value.accuracyM, locale) })}
            </p>
          ) : null}
        </Callout>
      ) : null}

      {outsideTexas ? <Callout tone="danger">{t("outsideArea")}</Callout> : null}

      <div className="grid grid-cols-3 gap-2">
        <ModeTab active={mode === "gps"} onClick={() => setMode("gps")} label={t("tabGps")} />
        <ModeTab active={mode === "map"} onClick={() => setMode("map")} label={t("tabMap")} />
        <ModeTab active={mode === "paste"} onClick={() => setMode("paste")} label={t("tabPaste")} />
      </div>

      {mode === "gps" ? (
        <div className="space-y-3">
          {gps.kind === "locating" || gps.kind === "idle" ? (
            <Callout tone="neutral">{t("locating")}</Callout>
          ) : null}

          {gps.kind === "denied" ? <Callout tone="danger">{t("denied")}</Callout> : null}
          {gps.kind === "unavailable" ? (
            <Callout tone="danger">{t("unavailable")}</Callout>
          ) : null}

          {gps.kind === "fixed" ? (
            <>
              <Callout tone="neutral">
                <p className="font-mono text-base">{formatCoords(gps.lat, gps.lng)}</p>
                <p className="text-sm">
                  {t("accuracy", { value: formatAccuracy(gps.accuracyM, locale) })}
                </p>
                {gps.accuracyM > 100 ? (
                  <p className="mt-1 text-sm font-medium">{t("weakFix")}</p>
                ) : null}
              </Callout>
              <Button
                type="button"
                onClick={() =>
                  commit({
                    lat: gps.lat,
                    lng: gps.lng,
                    accuracyM: gps.accuracyM,
                    source: "gps",
                  })
                }
              >
                {t("useThis")}
              </Button>
            </>
          ) : null}
        </div>
      ) : null}

      {mode === "map" ? (
        <div className="space-y-3">
          <p className="text-base text-ink-soft">{t("mapHelp")}</p>
          <MapPicker
            lat={seed.lat}
            lng={seed.lng}
            label={t("mapLabel")}
            unavailableLabel={t("mapUnavailable")}
            retryLabel={t("mapRetry")}
            confirmLabel={t("mapConfirm")}
            confirmedLabel={t("mapConfirmed")}
            standardLabel={t("mapStandard")}
            satelliteLabel={t("mapSatellite")}
            confirmed={value && value.source === "map_pin" ? { lat: value.lat, lng: value.lng } : null}
            /* Provisional. The pin moving is not the member choosing -- it happens on every pan,
               including the ones that overshoot. Held here so the coordinate readout and the
               confirm button track the map, and written to the form only on confirm. */
            onChange={setPending}
            onConfirm={(next) => {
              commit({ ...next, accuracyM: null, source: "map_pin" });
              setPending(null);
            }}
          />
        </div>
      ) : null}

      {mode === "paste" ? (
        <div className="space-y-3">
          <Field
            label={t("pasteLabel")}
            hint={t("pasteHint")}
            htmlFor="paste-location"
            error={pasteError ? t(`pasteError.${pasteError}`) : null}
          >
            <TextInput
              id="paste-location"
              value={pasted}
              inputMode="text"
              autoComplete="off"
              placeholder={t("pastePlaceholder")}
              onChange={(event) => setPasted(event.target.value)}
            />
          </Field>
          <Button
            type="button"
            variant="secondary"
            disabled={resolving || pasted.trim().length === 0}
            onClick={resolvePasted}
          >
            {resolving ? t("resolving") : t("resolve")}
          </Button>
        </div>
      ) : null}

      <Field label={t("noteLabel")} hint={t("noteHint")} htmlFor="location-note">
        <TextArea
          id="location-note"
          value={note}
          maxLength={200}
          placeholder={t("notePlaceholder")}
          onChange={(event) => updateNote(event.target.value)}
        />
      </Field>
    </div>
  );
}

function ModeTab({
  active,
  onClick,
  label,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`min-h-12 rounded-field border-2 px-2 text-base font-semibold ${
        active ? "border-brand bg-brand-tint" : "border-line bg-surface"
      }`}
    >
      {label}
    </button>
  );
}
