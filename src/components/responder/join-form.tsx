"use client";

import { useState } from "react";
import { useLocale, useTranslations } from "next-intl";

import {
  Button,
  Callout,
  Card,
  Checkbox,
  ChoiceList,
  Field,
  TextInput,
  Toggle,
} from "@/components/ui/primitives";
import { ENUMS } from "@/config/app";
import { Link, useRouter } from "@/i18n/navigation";
import { geocodeAddress } from "@/lib/geocode";
import { supabaseBrowser } from "@/lib/supabase/client";
import { containsContactInfo } from "@/lib/contact-info";
import { toE164Us } from "@/lib/utils";

type Phase = "phone" | "code" | "profile" | "done";

type EquipmentKey = (typeof ENUMS.equipment)[number];
type VehicleKey = (typeof ENUMS.vehicleClass)[number];
type DriveKey = (typeof ENUMS.drivetrain)[number];

/**
 * Volunteer signup.
 *
 * Phone OTP first, profile second, and the phone in the profile is the verified one from the
 * token — never a number typed into a form. A volunteer who could type any number could sign up
 * as someone else and receive their dispatches.
 *
 * Everyone lands as `pending`. An admin approves them before they are ever texted, which is what
 * keeps tow companies out of a volunteer list.
 */
export function JoinForm() {
  const t = useTranslations("join");
  const tEnum = useTranslations("enum");
  const tLegal = useTranslations("legal");
  const locale = useLocale();
  const router = useRouter();

  const [phase, setPhase] = useState<Phase>("phone");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");

  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [address, setAddress] = useState("");
  const [home, setHome] = useState<{ lat: number; lng: number; label: string } | null>(null);
  const [radius, setRadius] = useState<number>(30);
  const [equipment, setEquipment] = useState<EquipmentKey[]>([]);
  const [vehicleClass, setVehicleClass] = useState<VehicleKey>("truck");
  const [vehicleDesc, setVehicleDesc] = useState("");
  const [drivetrain, setDrivetrain] = useState<DriveKey>("4wd");
  const [nightOk, setNightOk] = useState(true);
  const [waiver, setWaiver] = useState(false);

  const e164 = toE164Us(phone);

  async function sendCode() {
    if (!e164) {
      setError("invalid_phone");
      return;
    }

    setBusy(true);
    setError(null);

    const { error: otpError } = await supabaseBrowser().auth.signInWithOtp({
      phone: e164,
      options: { channel: "sms" },
    });

    setBusy(false);

    if (otpError) {
      setError("otp_send_failed");
      return;
    }

    setPhase("code");
  }

  async function verifyCode() {
    if (!e164 || code.trim().length < 4) {
      setError("bad_code");
      return;
    }

    setBusy(true);
    setError(null);

    const { error: verifyError } = await supabaseBrowser().auth.verifyOtp({
      phone: e164,
      token: code.trim(),
      type: "sms",
    });

    setBusy(false);

    if (verifyError) {
      setError("bad_code");
      return;
    }

    setPhase("profile");
  }

  async function lookUpAddress() {
    setBusy(true);
    setError(null);

    try {
      const result = await geocodeAddress(address);
      if (!result) {
        setError("address_not_found");
        return;
      }
      setHome(result);
      setAddress(result.label);
    } catch {
      setError("address_not_found");
    } finally {
      setBusy(false);
    }
  }

  function toggleEquipment(key: EquipmentKey) {
    setEquipment((current) =>
      current.includes(key) ? current.filter((item) => item !== key) : [...current, key],
    );
  }

  async function saveProfile() {
    if (!home) {
      setError("address_required");
      return;
    }

    setBusy(true);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc(
      "upsert_responder_profile",
      {
        p_payload: {
          first_name: firstName.trim(),
          last_name: lastName.trim() || null,
          locale,
          lat: home.lat,
          lng: home.lng,
          home_address_text: home.label,
          radius_miles: radius,
          equipment,
          vehicle_class: vehicleClass,
          vehicle_desc: vehicleDesc.trim() || null,
          drivetrain,
          night_ok: nightOk,
        },
      },
    );

    setBusy(false);

    if (rpcError) {
      setError("save_failed");
      return;
    }

    const result = data as { ok: boolean; error?: string } | null;

    if (!result?.ok) {
      setError(result?.error ?? "save_failed");
      return;
    }

    setPhase("done");
  }

  const profileReady =
    firstName.trim().length > 0 &&
    home !== null &&
    equipment.length > 0 &&
    waiver &&
    !containsContactInfo(vehicleDesc);

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <h1 className="text-3xl font-bold leading-tight">{t("title")}</h1>
        <p className="mt-2 text-lg text-ink-soft">{t("intro")}</p>
      </header>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {phase === "phone" ? (
        <Card className="space-y-4">
          <Field
            label={t("phoneLabel")}
            hint={t("phoneHint")}
            htmlFor="phone"
            error={phone.length > 0 && !e164 ? t("errors.invalid_phone") : null}
          >
            <TextInput
              id="phone"
              type="tel"
              inputMode="tel"
              autoComplete="tel"
              value={phone}
              placeholder="(281) 555-0123"
              onChange={(event) => setPhone(event.target.value)}
            />
          </Field>
          <Button type="button" disabled={busy || !e164} onClick={sendCode}>
            {busy ? t("sending") : t("sendCode")}
          </Button>
        </Card>
      ) : null}

      {phase === "code" ? (
        <Card className="space-y-4">
          <Field label={t("codeLabel")} hint={t("codeHint", { phone })} htmlFor="code">
            <TextInput
              id="code"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={8}
              value={code}
              onChange={(event) => setCode(event.target.value)}
            />
          </Field>
          <Button type="button" disabled={busy} onClick={verifyCode}>
            {busy ? t("checking") : t("verify")}
          </Button>
          <Button type="button" variant="quiet" onClick={() => setPhase("phone")}>
            {t("changeNumber")}
          </Button>
        </Card>
      ) : null}

      {phase === "profile" ? (
        <div className="space-y-5">
          <div className="grid grid-cols-2 gap-3">
            <Field label={t("firstName")} htmlFor="first">
              <TextInput
                id="first"
                value={firstName}
                maxLength={40}
                autoComplete="given-name"
                onChange={(event) => setFirstName(event.target.value)}
              />
            </Field>
            <Field label={t("lastName")} htmlFor="last">
              <TextInput
                id="last"
                value={lastName}
                maxLength={40}
                autoComplete="family-name"
                onChange={(event) => setLastName(event.target.value)}
              />
            </Field>
          </div>

          <Field label={t("homeLabel")} hint={t("homeHint")} htmlFor="address">
            <TextInput
              id="address"
              value={address}
              autoComplete="address-level2"
              placeholder={t("homePlaceholder")}
              onChange={(event) => {
                setAddress(event.target.value);
                setHome(null);
              }}
            />
          </Field>
          <Button
            type="button"
            variant="secondary"
            disabled={busy || address.trim().length < 3}
            onClick={lookUpAddress}
          >
            {home ? t("homeFound") : t("findHome")}
          </Button>

          <Field label={t("radiusLabel")} hint={t("radiusHint")}>
            <ChoiceList
              name={t("radiusLabel")}
              columns={2}
              value={String(radius)}
              onChange={(next) => setRadius(Number(next))}
              options={ENUMS.radiusMiles.map((miles) => ({
                value: String(miles),
                label: t("radiusOption", { miles }),
              }))}
            />
          </Field>

          <Field label={t("equipmentLabel")} hint={t("equipmentHint")}>
            <div className="space-y-2">
              {ENUMS.equipment.map((item) => (
                <Checkbox
                  key={item}
                  id={`equipment-${item}`}
                  checked={equipment.includes(item)}
                  onChange={() => toggleEquipment(item)}
                >
                  {tEnum(`equipment.${item}`)}
                </Checkbox>
              ))}
            </div>
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

          <Field
            label={t("vehicleDescLabel")}
            hint={t("vehicleDescHint")}
            htmlFor="vehicle-desc"
            error={containsContactInfo(vehicleDesc) ? t("errors.contact_info") : null}
          >
            <TextInput
              id="vehicle-desc"
              value={vehicleDesc}
              maxLength={120}
              placeholder={t("vehicleDescPlaceholder")}
              onChange={(event) => setVehicleDesc(event.target.value)}
            />
          </Field>

          <Field label={t("drivetrainLabel")}>
            <ChoiceList
              name={t("drivetrainLabel")}
              columns={2}
              value={drivetrain}
              onChange={setDrivetrain}
              options={ENUMS.drivetrain.map((value) => ({
                value,
                label: tEnum(`drivetrain.${value}`),
              }))}
            />
          </Field>

          <Toggle
            checked={nightOk}
            onChange={setNightOk}
            label={t("nightLabel")}
            hint={t("nightHint")}
          />

          <Checkbox id="responder-waiver" checked={waiver} onChange={setWaiver}>
            {t.rich("waiver", {
              link: (chunks) => (
                <a href="/waiver" target="_blank" className="font-semibold underline">
                  {chunks}
                </a>
              ),
            })}
          </Checkbox>

          <Button type="button" disabled={busy || !profileReady} onClick={saveProfile}>
            {busy ? t("saving") : t("save")}
          </Button>

          <p className="text-sm text-ink-faint">{tLegal("reviewBanner")}</p>
        </div>
      ) : null}

      {phase === "done" ? (
        <Card className="space-y-4">
          <Callout tone="good">
            <p className="text-lg font-bold">{t("pendingTitle")}</p>
            <p className="mt-1">{t("pendingBody")}</p>
          </Callout>
          <Button type="button" onClick={() => router.replace("/me")}>
            {t("goToDashboard")}
          </Button>
        </Card>
      ) : null}

      <p className="text-center">
        <Link href="/" className="text-base underline underline-offset-4">
          {tLegal("backHome")}
        </Link>
      </p>
    </main>
  );
}
