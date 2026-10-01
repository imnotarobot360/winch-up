"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { EQUIPMENT_ICONS } from "@/components/ui/icons";
import { Button, Callout, Card, Toggle } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

import { VehicleForm, type Vehicle } from "./vehicle-form";

const COLUMNS =
  "id, make, model, year, vehicle_class, drivetrain, tire_size, recovery_points, " +
  "has_winch, winch_capacity_lb, equipment, notes, photo_path, is_primary, " +
  "show_in_community";

/**
 * A member's rigs.
 *
 * Reads and writes under RLS with the member's own session, so this component cannot see or
 * touch anybody else's vehicles even if it tried. Promoting a rig to primary goes through
 * set_primary_vehicle() because demoting the old one and promoting the new one have to happen
 * together -- a partial unique index enforces that, and two separate statements from a browser
 * would lose the race with a second tab.
 */
export function VehiclesManager({ userId }: { userId: string }) {
  const t = useTranslations("vehicles");
  const tEnum = useTranslations("enum");

  const [rows, setRows] = useState<Vehicle[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [editing, setEditing] = useState<Vehicle | null>(null);
  const [adding, setAdding] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error: loadError } = await supabaseBrowser()
      .from("vehicles")
      .select(COLUMNS)
      .order("is_primary", { ascending: false })
      .order("created_at", { ascending: true });

    if (loadError) {
      setError("load_failed");
    } else {
      // select() built from a string constant cannot be inferred by the client's types.
      setRows((data ?? []) as unknown as Vehicle[]);
      setError(null);
    }
    setLoaded(true);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  /**
   * Show this rig on my profile, or do not.
   *
   * Optimistic, with a reload on failure rather than a rollback: the list is re-read anyway
   * after anything else that changes it, and a switch that silently snaps back is worse than
   * one that corrects itself from the server.
   *
   * It defaults to ON for every rig, new and existing. The spec lists vehicle details among
   * what members may see, and a default-off flag here would mean profiles with no rigs on them
   * -- which is the exact shape of the mistake the directory itself just climbed out of. This
   * is for the one rig somebody would rather not show: a work truck with signage, a plate in
   * the photograph.
   */
  async function setShown(id: string, shown: boolean) {
    setRows((current) =>
      current.map((v) => (v.id === id ? { ...v, show_in_community: shown } : v)),
    );

    const { error: saveError } = await supabaseBrowser()
      .from("vehicles")
      .update({ show_in_community: shown })
      .eq("id", id);

    if (saveError) {
      setError("load_failed");
      await load();
    }
  }

  async function makePrimary(id: string) {
    setError(null);
    const { data, error: rpcError } = await supabaseBrowser().rpc("set_primary_vehicle", {
      p_vehicle_id: id,
    });

    if (rpcError || (data && (data as { ok?: boolean }).ok === false)) {
      setError("primary_failed");
      return;
    }
    await load();
  }

  async function remove(id: string) {
    setError(null);
    const { error: deleteError } = await supabaseBrowser().from("vehicles").delete().eq("id", id);
    if (deleteError) {
      setError("delete_failed");
      return;
    }
    setConfirmDelete(null);
    await load();
  }

  if (!loaded) return null;

  if (adding || editing) {
    return (
      <VehicleForm
        userId={userId}
        initial={editing ?? undefined}
        onDone={() => {
          setAdding(false);
          setEditing(null);
          void load();
        }}
        onCancel={() => {
          setAdding(false);
          setEditing(null);
        }}
      />
    );
  }

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{t("errors." + error)}</Callout> : null}

      {rows.length === 0 ? (
        <Card>
          <p className="text-lg text-ink-soft">{t("empty")}</p>
        </Card>
      ) : (
        rows.map((vehicle) => {
          const title =
            [vehicle.year, vehicle.make, vehicle.model].filter(Boolean).join(" ") ||
            tEnum("vehicleClass." + vehicle.vehicle_class);

          return (
            <Card key={vehicle.id} className="space-y-3">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <h2 className="text-xl font-semibold">{title}</h2>
                {vehicle.is_primary ? (
                  <span className="rounded-field bg-brand-tint px-3 py-1 text-sm font-bold text-brand-text">
                    {t("primary")}
                  </span>
                ) : null}
              </div>

              <p className="text-base text-ink-soft">
                {[
                  tEnum("vehicleClass." + vehicle.vehicle_class),
                  tEnum("drivetrain." + vehicle.drivetrain),
                  vehicle.tire_size,
                  vehicle.has_winch
                    ? vehicle.winch_capacity_lb
                      ? t("winchWithCapacity", { lb: vehicle.winch_capacity_lb })
                      : t("winchOnly")
                    : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>

              {vehicle.equipment.length > 0 ? (
                <ul className="flex flex-wrap gap-2">
                  {vehicle.equipment.map((key) => {
                    const Glyph = EQUIPMENT_ICONS[key as keyof typeof EQUIPMENT_ICONS];
                    return (
                      <li
                        key={key}
                        className="flex items-center gap-2 rounded-field border-2 border-line px-3 py-1 text-sm"
                      >
                        {Glyph ? <Glyph size={20} className="text-ink-faint" /> : null}
                        {tEnum("equipment." + key)}
                      </li>
                    );
                  })}
                </ul>
              ) : null}

              {vehicle.notes ? <p className="text-base text-ink-soft">{vehicle.notes}</p> : null}

              {/* WHAT OTHER MEMBERS SEE. The notes field is never published -- it has no
                  contains_contact_info CHECK on it, so it is the one place a phone number can
                  legitimately sit, and member_rigs() leaves it out. This switch is about the
                  rest: the make, the photograph, the gear. */}
              <Toggle
                checked={vehicle.show_in_community !== false}
                onChange={(v) => void setShown(vehicle.id, v)}
                label={t("showInCommunity")}
                hint={t("showInCommunityHint")}
              />

              {confirmDelete === vehicle.id ? (
                <div className="space-y-2">
                  <Callout tone="danger">{t("deleteConfirm", { name: title })}</Callout>
                  <div className="flex flex-col gap-2 sm:flex-row">
                    <Button variant="danger" onClick={() => remove(vehicle.id)}>
                      {t("deleteYes")}
                    </Button>
                    <Button variant="secondary" onClick={() => setConfirmDelete(null)}>
                      {t("cancel")}
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="flex flex-wrap gap-2">
                  <Button variant="secondary" onClick={() => setEditing(vehicle)}>
                    {t("edit")}
                  </Button>
                  {!vehicle.is_primary ? (
                    <Button variant="secondary" onClick={() => makePrimary(vehicle.id)}>
                      {t("makePrimary")}
                    </Button>
                  ) : null}
                  <Button variant="danger" onClick={() => setConfirmDelete(vehicle.id)}>
                    {t("delete")}
                  </Button>
                </div>
              )}
            </Card>
          );
        })
      )}

      <Button size="lg" onClick={() => setAdding(true)}>
        {t("addVehicle")}
      </Button>
    </div>
  );
}
