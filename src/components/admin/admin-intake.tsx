"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import {
  Button,
  Callout,
  Card,
  ChoiceList,
  Field,
  TextArea,
  TextInput,
  Toggle,
} from "@/components/ui/primitives";
import { ENUMS } from "@/config/app";
import { parseLocationInput } from "@/lib/geo";
import { toE164Us } from "@/lib/utils";

import { adminAction } from "./use-admin";

/**
 * Intake from a Facebook post.
 *
 * Somebody posts in the group instead of using the site, and an admin copies it in here. The
 * location box takes whatever the poster shared — coordinates, a Maps link, a dropped pin — and
 * the request then joins the normal dispatch flow like any other.
 */
export function AdminIntake() {
  const t = useTranslations("admin.intake");
  const tEnum = useTranslations("enum");

  const [pasted, setPasted] = useState("");
  const [locationText, setLocationText] = useState("");
  const [coords, setCoords] = useState<{ lat: number; lng: number } | null>(null);
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [county, setCounty] = useState("");
  const [vehicleClass, setVehicleClass] = useState<(typeof ENUMS.vehicleClass)[number]>("truck");
  const [stuckType, setStuckType] = useState<(typeof ENUMS.stuckType)[number]>("mud");
  const [stuckDepth, setStuckDepth] = useState<(typeof ENUMS.stuckDepth)[number] | null>(null);
  const [needsTractor, setNeedsTractor] = useState(false);
  const [needsSecondTruck, setNeedsSecondTruck] = useState(false);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ short_code: string; token: string } | null>(null);
  const [error, setError] = useState<string | null>(null);

  const e164 = toE164Us(phone);

  async function resolveLocation() {
    const parsed = parseLocationInput(locationText);

    if (parsed.kind === "coords") {
      setCoords({ lat: parsed.lat, lng: parsed.lng });
      setError(null);
      return;
    }

    // Short links and what3words need the server.
    try {
      const response = await fetch("/api/geo/resolve", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: locationText }),
      });
      const payload = (await response.json()) as { lat?: number; lng?: number; error?: string };

      if (payload.lat != null && payload.lng != null) {
        setCoords({ lat: payload.lat, lng: payload.lng });
        setError(null);
      } else {
        setError(payload.error ?? "unrecognised");
      }
    } catch {
      setError("unrecognised");
    }
  }

  async function submit() {
    if (!coords || !e164) return;

    setBusy(true);
    setError(null);

    const { ok, error: actionError, ...rest } = (await adminAction("admin_create_request", {
      p_payload: {
        name: name.trim() || null,
        phone: e164,
        lat: coords.lat,
        lng: coords.lng,
        county: county.trim() || null,
        vehicle_class: vehicleClass,
        stuck_type: stuckType,
        stuck_depth: stuckDepth,
        needs_tractor: needsTractor,
        needs_second_truck: needsSecondTruck,
        notes: pasted.trim().slice(0, 500) || null,
        location_note: null,
      },
    })) as { ok: boolean; error?: string; short_code?: string; token?: string };

    setBusy(false);

    if (!ok) {
      setError(actionError ?? "failed");
      return;
    }

    setResult({ short_code: rest.short_code ?? "", token: rest.token ?? "" });
  }

  if (result) {
    return (
      <Card className="space-y-3">
        <Callout tone="good">
          <p className="text-lg font-bold">{t("created", { code: result.short_code })}</p>
          <p className="mt-1">{t("createdBody")}</p>
        </Callout>
        <a
          href={`/r/${result.token}`}
          className="tap-target flex w-full items-center justify-center rounded-field bg-brand text-lg font-bold text-on-brand"
        >
          {t("openStatus")}
        </a>
        <a
          href={`/post/${result.token}`}
          className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line text-lg font-semibold"
        >
          {t("openPost")}
        </a>
        <Button type="button" variant="quiet" onClick={() => window.location.reload()}>
          {t("another")}
        </Button>
      </Card>
    );
  }

  return (
    <div className="space-y-5">
      <Callout tone="neutral">{t("intro")}</Callout>
      {error ? <Callout tone="danger">{error}</Callout> : null}

      <Field label={t("pastedLabel")} hint={t("pastedHint")} htmlFor="pasted">
        <TextArea
          id="pasted"
          value={pasted}
          className="min-h-40"
          maxLength={2000}
          onChange={(event) => setPasted(event.target.value)}
        />
      </Field>

      <Field label={t("locationLabel")} hint={t("locationHint")} htmlFor="loc">
        <TextInput
          id="loc"
          value={locationText}
          onChange={(event) => {
            setLocationText(event.target.value);
            setCoords(null);
          }}
        />
      </Field>
      <Button
        type="button"
        variant="secondary"
        disabled={locationText.trim().length < 3}
        onClick={resolveLocation}
      >
        {coords ? `${coords.lat.toFixed(5)}, ${coords.lng.toFixed(5)}` : t("resolve")}
      </Button>

      <div className="grid grid-cols-2 gap-3">
        <Field label={t("nameLabel")} htmlFor="intake-name">
          <TextInput
            id="intake-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
        </Field>
        <Field
          label={t("phoneLabel")}
          htmlFor="intake-phone"
          error={phone.length > 0 && !e164 ? t("badPhone") : null}
        >
          <TextInput
            id="intake-phone"
            type="tel"
            value={phone}
            onChange={(event) => setPhone(event.target.value)}
          />
        </Field>
      </div>

      <Field label={t("countyLabel")} htmlFor="county">
        <TextInput
          id="county"
          value={county}
          onChange={(event) => setCounty(event.target.value)}
        />
      </Field>

      <Field label={t("vehicleLabel")}>
        <ChoiceList
          name={t("vehicleLabel")}
          columns={2}
          value={vehicleClass}
          onChange={setVehicleClass}
          options={ENUMS.vehicleClass.map((value) => ({
            value,
            label: tEnum(`vehicleClass.${value}`),
          }))}
        />
      </Field>

      <Field label={t("stuckLabel")}>
        <ChoiceList
          name={t("stuckLabel")}
          columns={2}
          value={stuckType}
          onChange={setStuckType}
          options={ENUMS.stuckType.map((value) => ({
            value,
            label: tEnum(`stuckType.${value}`),
          }))}
        />
      </Field>

      <Field label={t("depthLabel")}>
        <ChoiceList
          name={t("depthLabel")}
          value={stuckDepth}
          onChange={setStuckDepth}
          options={ENUMS.stuckDepth.map((value) => ({
            value,
            label: tEnum(`stuckDepth.${value}`),
          }))}
        />
      </Field>

      <Toggle
        checked={needsTractor}
        onChange={setNeedsTractor}
        label={tEnum("equipment.tractor")}
      />
      <Toggle
        checked={needsSecondTruck}
        onChange={setNeedsSecondTruck}
        label={tEnum("equipment.second_truck")}
      />

      <Callout tone="danger">{t("consentWarning")}</Callout>

      <Button type="button" disabled={busy || !coords || !e164} onClick={submit}>
        {busy ? t("creating") : t("create")}
      </Button>
    </div>
  );
}
