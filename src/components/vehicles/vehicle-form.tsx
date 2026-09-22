"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { EQUIPMENT_ICONS } from "@/components/ui/icons";
import {
  Button,
  Callout,
  Card,
  Checkbox,
  Field,
  TextArea,
  TextInput,
} from "@/components/ui/primitives";
import { ENUMS } from "@/config/app";
import { supabaseBrowser } from "@/lib/supabase/client";

export type Vehicle = {
  id: string;
  make: string | null;
  model: string | null;
  year: number | null;
  vehicle_class: string;
  drivetrain: string;
  tire_size: string | null;
  recovery_points: string;
  has_winch: boolean;
  winch_capacity_lb: number | null;
  equipment: string[];
  notes: string | null;
  is_primary: boolean;
};

type Draft = Omit<Vehicle, "id" | "is_primary">;

const BLANK: Draft = {
  make: "",
  model: "",
  year: null,
  vehicle_class: "truck",
  drivetrain: "4wd",
  tire_size: "",
  recovery_points: "unknown",
  has_winch: false,
  winch_capacity_lb: null,
  equipment: [],
  notes: "",
};

const selectClasses =
  "min-h-14 w-full rounded-field border-2 border-line bg-surface px-3 text-lg text-ink";

/**
 * Add or edit one rig.
 *
 * Writes straight from the browser. RLS restricts every row to its owner and the policies carry
 * a WITH CHECK, so a server action would add a hop without adding a guarantee. The one thing
 * that cannot be done this way is promoting a rig to primary: that needs two statements in one
 * transaction, so it goes through set_primary_vehicle().
 */
export function VehicleForm({
  userId,
  initial,
  onDone,
  onCancel,
}: {
  userId: string;
  initial?: Vehicle;
  onDone: () => void;
  onCancel: () => void;
}) {
  const t = useTranslations("vehicles");
  const tEnum = useTranslations("enum");

  const [draft, setDraft] = useState<Draft>(initial ? { ...initial } : { ...BLANK });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function set<K extends keyof Draft>(key: K, value: Draft[K]) {
    setDraft((prev) => ({ ...prev, [key]: value }));
  }

  function toggleEquipment(key: string) {
    setDraft((prev) => ({
      ...prev,
      equipment: prev.equipment.includes(key)
        ? prev.equipment.filter((item) => item !== key)
        : [...prev.equipment, key],
    }));
  }

  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;

    setBusy(true);
    setError(null);

    const row = {
      make: draft.make?.trim() || null,
      model: draft.model?.trim() || null,
      year: draft.year || null,
      vehicle_class: draft.vehicle_class,
      drivetrain: draft.drivetrain,
      tire_size: draft.tire_size?.trim() || null,
      recovery_points: draft.recovery_points,
      has_winch: draft.has_winch,
      // A capacity with no winch is a stray number that would outlive the checkbox.
      winch_capacity_lb: draft.has_winch ? draft.winch_capacity_lb || null : null,
      equipment: draft.equipment,
      notes: draft.notes?.trim() || null,
    };

    const supabase = supabaseBrowser();
    const { error: saveError } = initial
      ? await supabase.from("vehicles").update(row).eq("id", initial.id)
      : await supabase.from("vehicles").insert({ ...row, user_id: userId });

    setBusy(false);

    if (saveError) {
      // 23514 is the CHECK rejecting contact details in notes. The per-member cap is a trigger
      // raising the same class, so it is told apart by its message.
      const key = saveError.message.includes("vehicle_limit")
        ? "too_many"
        : saveError.code === "23514"
          ? "contact_in_notes"
          : "save_failed";
      setError(key);
      return;
    }

    onDone();
  }

  return (
    <Card>
      <form onSubmit={save} className="space-y-4">
        {error ? <Callout tone="danger">{t("errors." + error)}</Callout> : null}

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t("make")}>
            <TextInput
              value={draft.make ?? ""}
              onChange={(e) => set("make", e.target.value)}
              maxLength={40}
            />
          </Field>

          <Field label={t("model")}>
            <TextInput
              value={draft.model ?? ""}
              onChange={(e) => set("model", e.target.value)}
              maxLength={40}
            />
          </Field>

          <Field label={t("year")}>
            <TextInput
              type="number"
              inputMode="numeric"
              min={1900}
              max={2100}
              value={draft.year ?? ""}
              onChange={(e) => set("year", e.target.value ? Number(e.target.value) : null)}
            />
          </Field>

          <Field label={t("tireSize")} hint={t("tireSizeHint")}>
            <TextInput
              value={draft.tire_size ?? ""}
              onChange={(e) => set("tire_size", e.target.value)}
              maxLength={30}
            />
          </Field>
        </div>

        <Field label={t("class")}>
          <select
            className={selectClasses}
            value={draft.vehicle_class}
            onChange={(e) => set("vehicle_class", e.target.value)}
          >
            {ENUMS.vehicleClass.map((key) => (
              <option key={key} value={key}>
                {tEnum("vehicleClass." + key)}
              </option>
            ))}
          </select>
        </Field>

        <Field label={t("drivetrain")}>
          <select
            className={selectClasses}
            value={draft.drivetrain}
            onChange={(e) => set("drivetrain", e.target.value)}
          >
            {ENUMS.drivetrain.map((key) => (
              <option key={key} value={key}>
                {tEnum("drivetrain." + key)}
              </option>
            ))}
          </select>
        </Field>

        <Field label={t("recoveryPoints")} hint={t("recoveryPointsHint")}>
          <select
            className={selectClasses}
            value={draft.recovery_points}
            onChange={(e) => set("recovery_points", e.target.value)}
          >
            {ENUMS.recoveryPoints.map((key) => (
              <option key={key} value={key}>
                {tEnum("recoveryPoints." + key)}
              </option>
            ))}
          </select>
        </Field>

        <Checkbox
          id="has-winch"
          checked={draft.has_winch}
          onChange={(checked) => set("has_winch", checked)}
        >
          {t("hasWinch")}
        </Checkbox>

        {draft.has_winch ? (
          <Field label={t("winchCapacity")} hint={t("winchCapacityHint")}>
            <TextInput
              type="number"
              inputMode="numeric"
              min={1000}
              max={60000}
              step={500}
              value={draft.winch_capacity_lb ?? ""}
              onChange={(e) =>
                set("winch_capacity_lb", e.target.value ? Number(e.target.value) : null)
              }
            />
          </Field>
        ) : null}

        <Field label={t("equipment")} hint={t("equipmentHint")}>
          <div className="space-y-2">
            {ENUMS.equipment.map((key) => {
              const Glyph = EQUIPMENT_ICONS[key];
              return (
                <Checkbox
                  key={key}
                  id={"vehicle-equipment-" + key}
                  checked={draft.equipment.includes(key)}
                  onChange={() => toggleEquipment(key)}
                >
                  <span className="flex items-center gap-3">
                    <Glyph size={26} className="shrink-0 text-ink-faint" />
                    {tEnum("equipment." + key)}
                  </span>
                </Checkbox>
              );
            })}
          </div>
        </Field>

        <Field label={t("notes")} hint={t("notesHint")}>
          <TextArea
            value={draft.notes ?? ""}
            onChange={(e) => set("notes", e.target.value)}
            maxLength={280}
          />
        </Field>

        <div className="flex flex-col gap-2 sm:flex-row">
          <Button type="submit" size="lg" disabled={busy}>
            {busy ? t("working") : initial ? t("saveChanges") : t("addVehicle")}
          </Button>
          <Button type="button" variant="secondary" size="lg" onClick={onCancel} disabled={busy}>
            {t("cancel")}
          </Button>
        </div>
      </form>
    </Card>
  );
}
