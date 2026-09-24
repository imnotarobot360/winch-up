"use client";

import { useEffect, useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";

import { createRequestAction } from "@/app/actions/request";
import {
  Button,
  Callout,
  Card,
  Checkbox,
  ChoiceList,
  Field,
  TextArea,
  TextInput,
  Toggle,
} from "@/components/ui/primitives";
import { useRouter } from "@/i18n/navigation";
import { containsContactInfo } from "@/lib/contact-info";
import type { UploadedPhoto } from "@/lib/photos";
import { toE164Us } from "@/lib/utils";
import {
  DRIVETRAINS,
  LAND_TYPES,
  STUCK_DEPTHS,
  STUCK_TYPES,
  VEHICLE_CLASSES,
} from "@/lib/validation/request";

import { LocationStep, type LocationValue } from "./location-step";
import { PhotoStep } from "./photo-step";
import { StepProgress } from "./step-progress";

/**
 * One question per screen.
 *
 * Draft state is kept in sessionStorage so that a reload — which a cheap Android under memory
 * pressure will do on its own — does not cost someone the whole form. sessionStorage rather than
 * localStorage on purpose: a phone that gets handed around should not keep a stranger's number.
 */

const DRAFT_KEY = "txr:draft:v1";

const STEPS = [
  "emergency",
  "location",
  "photos",
  "vehicle",
  "situation",
  "land",
  "contact",
  "consent",
] as const;

type StepName = (typeof STEPS)[number];

type Draft = {
  submissionId: string;
  emergencyAck: boolean;
  location: LocationValue | null;
  photos: UploadedPhoto[];
  vehicleClass: (typeof VEHICLE_CLASSES)[number] | null;
  vehicleMake: string;
  vehicleModel: string;
  vehicleYear: string;
  drivetrain: (typeof DRIVETRAINS)[number];
  stuckType: (typeof STUCK_TYPES)[number] | null;
  stuckDepth: (typeof STUCK_DEPTHS)[number] | null;
  needsTractor: boolean;
  needsSecondTruck: boolean;
  landType: (typeof LAND_TYPES)[number] | null;
  landPermissionNote: string;
  notes: string;
  name: string;
  phone: string;
  waiverAccepted: boolean;
  rulesAccepted: boolean;
};

function emptyDraft(): Draft {
  return {
    submissionId: crypto.randomUUID(),
    emergencyAck: false,
    location: null,
    photos: [],
    vehicleClass: null,
    vehicleMake: "",
    vehicleModel: "",
    vehicleYear: "",
    drivetrain: "unknown",
    stuckType: null,
    stuckDepth: null,
    needsTractor: false,
    needsSecondTruck: false,
    landType: null,
    landPermissionNote: "",
    notes: "",
    name: "",
    phone: "",
    waiverAccepted: false,
    rulesAccepted: false,
  };
}

export function RequestWizard() {
  const t = useTranslations("request");
  const tEnum = useTranslations("enum");
  const locale = useLocale();
  const router = useRouter();

  const [draft, setDraft] = useState<Draft | null>(null);
  const [stepIndex, setStepIndex] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  // Restore on mount. Photos keep their storage paths but lose their object-URL previews, which
  // is fine: the upload already happened.
  useEffect(() => {
    try {
      const stored = sessionStorage.getItem(DRAFT_KEY);
      if (stored) {
        const parsed = JSON.parse(stored) as Draft;
        if (parsed?.submissionId) {
          setDraft({ ...emptyDraft(), ...parsed });
          return;
        }
      }
    } catch {
      // A corrupt draft is not worth a broken form.
    }
    setDraft(emptyDraft());
  }, []);

  useEffect(() => {
    if (!draft) return;
    try {
      sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
    } catch {
      // Private mode, or a full quota. The form still works, it just will not survive a reload.
    }
  }, [draft]);

  const step: StepName = STEPS[stepIndex];

  const update = (patch: Partial<Draft>) =>
    setDraft((current) => (current ? { ...current, ...patch } : current));

  const phoneE164 = useMemo(() => (draft ? toE164Us(draft.phone) : null), [draft]);

  if (!draft) {
    return <p className="p-6 text-center text-ink-faint">{t("loading")}</p>;
  }

  const canAdvance = ((): boolean => {
    switch (step) {
      case "emergency":
        return draft.emergencyAck;
      case "location":
        return draft.location !== null;
      case "photos":
        return true;
      case "vehicle":
        return draft.vehicleClass !== null;
      case "situation":
        return draft.stuckType !== null;
      case "land":
        return draft.landType !== null && !containsContactInfo(draft.notes);
      case "contact":
        return draft.name.trim().length > 0 && phoneE164 !== null;
      case "consent":
        return draft.waiverAccepted && draft.rulesAccepted;
    }
  })();

  async function submit() {
    if (!draft || !draft.location || !phoneE164) return;

    setSubmitting(true);
    setSubmitError(null);

    const result = await createRequestAction({
      submissionId: draft.submissionId,
      locale,
      emergencyAck: true,
      lat: draft.location.lat,
      lng: draft.location.lng,
      accuracyM: draft.location.accuracyM,
      locationSource: draft.location.source,
      locationNote: draft.location.note || null,
      photos: draft.photos.map((photo) => ({
        path: photo.path,
        contentType: photo.contentType,
        bytes: photo.bytes,
        width: photo.width,
        height: photo.height,
      })),
      vehicleClass: draft.vehicleClass,
      vehicleMake: draft.vehicleMake || null,
      vehicleModel: draft.vehicleModel || null,
      vehicleYear: draft.vehicleYear ? Number(draft.vehicleYear) : null,
      drivetrain: draft.drivetrain,
      stuckType: draft.stuckType,
      stuckDepth: draft.stuckDepth,
      needsTractor: draft.needsTractor,
      needsSecondTruck: draft.needsSecondTruck,
      landType: draft.landType,
      landPermissionNote: draft.landPermissionNote || null,
      notes: draft.notes || null,
      name: draft.name.trim(),
      phone: phoneE164,
      waiverAccepted: true,
      rulesAccepted: true,
    });

    if (!result.ok) {
      setSubmitError(result.error);
      setSubmitting(false);
      return;
    }

    try {
      sessionStorage.removeItem(DRAFT_KEY);
    } catch {
      // Nothing to do; the draft is stale either way.
    }

    router.replace(`/r/${result.token}`);
  }

  const isLastStep = stepIndex === STEPS.length - 1;

  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-xl flex-col">
      <header className="sticky top-0 z-10 space-y-2 border-b border-line bg-surface px-4 py-3">
        {/* The reference's three dots over the eight-step flow. The groups are real -- where you
            are, what you need, what you agree to -- so this is not decoration bolted on to match
            a mockup; it is information the wizard always had and never showed. */}
        <StepProgress
          step={step}
          labels={[t("groups.location"), t("groups.details"), t("groups.review")]}
        />
        <div>
          <p className="text-sm font-medium text-ink-faint">
            {t("progress", { current: stepIndex + 1, total: STEPS.length })}
          </p>
          <h1 className="text-2xl font-bold leading-tight">{t(`steps.${step}.title`)}</h1>
        </div>
      </header>

      <main className="flex-1 space-y-5 px-4 py-5">
        {step === "emergency" ? (
          <EmergencyStep
            acknowledged={draft.emergencyAck}
            onAcknowledge={(next) => update({ emergencyAck: next })}
          />
        ) : null}

        {step === "location" ? (
          <LocationStep
            value={draft.location}
            locale={locale}
            onChange={(next) => update({ location: next })}
          />
        ) : null}

        {step === "photos" ? (
          <PhotoStep
            draftId={draft.submissionId}
            photos={draft.photos}
            onChange={(next) => update({ photos: next })}
          />
        ) : null}

        {step === "vehicle" ? (
          <div className="space-y-5">
            <ChoiceList
              name={t("steps.vehicle.title")}
              columns={2}
              value={draft.vehicleClass}
              onChange={(next) => update({ vehicleClass: next })}
              options={VEHICLE_CLASSES.map((value) => ({
                value,
                label: tEnum(`vehicleClass.${value}`),
              }))}
            />
            <div className="grid grid-cols-2 gap-3">
              <Field label={t("vehicle.make")} htmlFor="make">
                <TextInput
                  id="make"
                  value={draft.vehicleMake}
                  maxLength={40}
                  autoComplete="off"
                  onChange={(event) => update({ vehicleMake: event.target.value })}
                />
              </Field>
              <Field label={t("vehicle.model")} htmlFor="model">
                <TextInput
                  id="model"
                  value={draft.vehicleModel}
                  maxLength={40}
                  autoComplete="off"
                  onChange={(event) => update({ vehicleModel: event.target.value })}
                />
              </Field>
            </div>
            <Field label={t("vehicle.drivetrain")}>
              <ChoiceList
                name={t("vehicle.drivetrain")}
                columns={2}
                value={draft.drivetrain}
                onChange={(next) => update({ drivetrain: next })}
                options={DRIVETRAINS.map((value) => ({
                  value,
                  label: tEnum(`drivetrain.${value}`),
                }))}
              />
            </Field>
          </div>
        ) : null}

        {step === "situation" ? (
          <div className="space-y-5">
            <ChoiceList
              name={t("steps.situation.title")}
              columns={2}
              value={draft.stuckType}
              onChange={(next) => update({ stuckType: next })}
              options={STUCK_TYPES.map((value) => ({
                value,
                label: tEnum(`stuckType.${value}`),
              }))}
            />
            <Field label={t("situation.depth")} hint={t("situation.depthHint")}>
              <ChoiceList
                name={t("situation.depth")}
                value={draft.stuckDepth}
                onChange={(next) => update({ stuckDepth: next })}
                options={STUCK_DEPTHS.map((value) => ({
                  value,
                  label: tEnum(`stuckDepth.${value}`),
                }))}
              />
            </Field>
            <Toggle
              checked={draft.needsTractor}
              onChange={(next) => update({ needsTractor: next })}
              label={t("situation.needsTractor")}
              hint={t("situation.needsTractorHint")}
            />
            <Toggle
              checked={draft.needsSecondTruck}
              onChange={(next) => update({ needsSecondTruck: next })}
              label={t("situation.needsSecondTruck")}
              hint={t("situation.needsSecondTruckHint")}
            />
          </div>
        ) : null}

        {step === "land" ? (
          <div className="space-y-5">
            <ChoiceList
              name={t("steps.land.title")}
              value={draft.landType}
              onChange={(next) => update({ landType: next })}
              options={LAND_TYPES.map((value) => ({
                value,
                label: tEnum(`landType.${value}`),
              }))}
            />
            {draft.landType === "private_permission" ? (
              <Field
                label={t("land.permissionLabel")}
                hint={t("land.permissionHint")}
                htmlFor="permission"
              >
                <TextInput
                  id="permission"
                  value={draft.landPermissionNote}
                  maxLength={200}
                  onChange={(event) =>
                    update({ landPermissionNote: event.target.value })
                  }
                />
              </Field>
            ) : null}
            <Field
              label={t("land.notesLabel")}
              hint={t("land.notesHint")}
              htmlFor="notes"
              error={
                containsContactInfo(draft.notes) ? t("errors.contact_info_not_allowed") : null
              }
            >
              <TextArea
                id="notes"
                value={draft.notes}
                maxLength={500}
                placeholder={t("land.notesPlaceholder")}
                onChange={(event) => update({ notes: event.target.value })}
              />
            </Field>
          </div>
        ) : null}

        {step === "contact" ? (
          <div className="space-y-5">
            <Field label={t("contact.nameLabel")} htmlFor="name">
              <TextInput
                id="name"
                value={draft.name}
                maxLength={60}
                autoComplete="name"
                onChange={(event) => update({ name: event.target.value })}
              />
            </Field>
            <Field
              label={t("contact.phoneLabel")}
              hint={t("contact.phoneHint")}
              htmlFor="phone"
              error={
                draft.phone.length > 0 && phoneE164 === null
                  ? t("errors.invalid_phone")
                  : null
              }
            >
              <TextInput
                id="phone"
                value={draft.phone}
                type="tel"
                inputMode="tel"
                autoComplete="tel"
                placeholder="(281) 555-0123"
                onChange={(event) => update({ phone: event.target.value })}
              />
            </Field>
            <Callout tone="neutral">{t("contact.privacy")}</Callout>
          </div>
        ) : null}

        {step === "consent" ? (
          <div className="space-y-5">
            <Summary
              draft={draft}
              vehicleLabel={
                draft.vehicleClass ? tEnum(`vehicleClass.${draft.vehicleClass}`) : ""
              }
              stuckLabel={draft.stuckType ? tEnum(`stuckType.${draft.stuckType}`) : ""}
              photosLabel={t("consent.photoCount", { count: draft.photos.length })}
            />
            <Checkbox
              id="waiver"
              checked={draft.waiverAccepted}
              onChange={(next) => update({ waiverAccepted: next })}
            >
              {t.rich("consent.waiver", {
                link: (chunks) => (
                  <a href="/waiver" target="_blank" className="font-semibold underline">
                    {chunks}
                  </a>
                ),
              })}
            </Checkbox>
            <Checkbox
              id="rules"
              checked={draft.rulesAccepted}
              onChange={(next) => update({ rulesAccepted: next })}
            >
              {t.rich("consent.rules", {
                link: (chunks) => (
                  <a href="/terms" target="_blank" className="font-semibold underline">
                    {chunks}
                  </a>
                ),
              })}
            </Checkbox>
            {submitError ? (
              <Callout tone="danger">{t(`errors.${submitError}`)}</Callout>
            ) : null}
          </div>
        ) : null}
      </main>

      <footer className="sticky bottom-0 border-t border-line bg-surface px-4 py-3">
        <div className="flex gap-3">
          {stepIndex > 0 ? (
            <Button
              type="button"
              variant="secondary"
              className="w-28"
              onClick={() => setStepIndex((index) => Math.max(0, index - 1))}
            >
              {t("back")}
            </Button>
          ) : null}
          <Button
            type="button"
            disabled={!canAdvance || submitting}
            onClick={() =>
              isLastStep ? submit() : setStepIndex((index) => index + 1)
            }
          >
            {submitting ? t("sending") : isLastStep ? t("send") : t("next")}
          </Button>
        </div>
      </footer>
    </div>
  );
}

function EmergencyStep({
  acknowledged,
  onAcknowledge,
}: {
  acknowledged: boolean;
  onAcknowledge: (next: boolean) => void;
}) {
  const t = useTranslations("emergency");

  return (
    <div className="space-y-5">
      <Callout tone="danger">
        <p className="text-xl font-bold">{t("heading")}</p>
        <p className="mt-2">{t("body")}</p>
      </Callout>

      <a
        href="tel:911"
        className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-danger bg-danger-tint text-xl font-bold text-danger"
      >
        {t("call911")}
      </a>

      <Checkbox id="ack" checked={acknowledged} onChange={onAcknowledge}>
        {t("acknowledge")}
      </Checkbox>
    </div>
  );
}

function Summary({
  draft,
  vehicleLabel,
  stuckLabel,
  photosLabel,
}: {
  draft: Draft;
  vehicleLabel: string;
  stuckLabel: string;
  photosLabel: string;
}) {
  const t = useTranslations("request.consent");

  return (
    <Card className="space-y-1 text-base">
      <p className="font-semibold">{t("summaryTitle")}</p>
      <p>
        {vehicleLabel} · {stuckLabel}
      </p>
      {draft.location ? (
        <p className="font-mono text-sm text-ink-soft">
          {draft.location.lat.toFixed(5)}, {draft.location.lng.toFixed(5)}
        </p>
      ) : null}
      <p className="text-sm text-ink-soft">{photosLabel}</p>
    </Card>
  );
}
