"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, TextInput } from "@/components/ui/primitives";
import { formatUsPhone } from "@/lib/utils";

import { adminAction, useAdminData } from "./use-admin";

type Responder = {
  id: string;
  first_name: string;
  last_name: string | null;
  phone: string;
  locale: string;
  home_address_text: string | null;
  radius_miles: number;
  equipment: string[];
  vehicle_class: string;
  vehicle_desc: string | null;
  approval: "pending" | "approved" | "rejected" | "banned";
  availability: string;
  recoveries_count: number;
  created_at: string;
  review_reason: string | null;
};

const FILTERS = ["pending", "approved", "rejected", "banned"] as const;

/**
 * Approving volunteers is the single most important admin job in this product.
 *
 * Nobody is dispatched to until a human has looked at them, which is what keeps tow companies
 * and scammers out of a volunteer list — the reason the Facebook groups vet members by hand
 * today.
 */
export function AdminResponders() {
  const t = useTranslations("admin.responders");
  const tEnum = useTranslations("enum");

  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("pending");
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);

  const { data, loading, reload } = useAdminData<Responder[]>("admin_list_responders", {
    p_approval: filter,
  });

  async function setApproval(id: string, approval: string) {
    setBusy(true);
    setActionError(null);

    const result = await adminAction("admin_set_responder_approval", {
      p_responder_id: id,
      p_approval: approval,
      p_reason: reason.trim() || null,
    });

    if (!result.ok) setActionError(result.error ?? "failed");

    setReason("");
    await reload();
    setBusy(false);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap gap-2">
        {FILTERS.map((value) => (
          <button
            key={value}
            type="button"
            onClick={() => setFilter(value)}
            aria-pressed={filter === value}
            className={`min-h-12 flex-1 rounded-field border-2 px-3 font-semibold ${
              filter === value ? "border-brand bg-brand-tint" : "border-line"
            }`}
          >
            {tEnum(`responderApproval.${value}`)}
          </button>
        ))}
      </div>

      {actionError ? <Callout tone="danger">{actionError}</Callout> : null}
      {loading ? <p className="text-center text-ink-faint">{t("loading")}</p> : null}

      {!loading && (data ?? []).length === 0 ? (
        <Card>
          <p className="text-center text-lg text-ink-soft">{t("empty")}</p>
        </Card>
      ) : null}

      {(data ?? []).map((responder) => (
        <Card key={responder.id} className="space-y-3">
          <div>
            <p className="text-lg font-semibold">
              {responder.first_name} {responder.last_name ?? ""}
            </p>
            <p className="text-base">
              <a href={`tel:${responder.phone}`} className="underline underline-offset-4">
                {formatUsPhone(responder.phone)}
              </a>
              {responder.locale === "es" ? " · Español" : ""}
            </p>
            <p className="text-base text-ink-soft">
              {responder.home_address_text ?? t("noAddress")} ·{" "}
              {t("radius", { miles: responder.radius_miles })}
            </p>
            <p className="text-base text-ink-soft">
              {tEnum(`vehicleClass.${responder.vehicle_class}`)}
              {responder.vehicle_desc ? ` · ${responder.vehicle_desc}` : ""}
            </p>
            <p className="text-base text-ink-soft">
              {responder.equipment.map((item) => tEnum(`equipment.${item}`)).join(", ") ||
                t("noEquipment")}
            </p>
            {responder.recoveries_count > 0 ? (
              <p className="text-base font-medium">
                {t("recoveries", { count: responder.recoveries_count })}
              </p>
            ) : null}
            {responder.review_reason ? (
              <p className="text-base italic text-ink-soft">{responder.review_reason}</p>
            ) : null}
          </div>

          {filter !== "approved" ? (
            <TextInput
              value={reason}
              placeholder={t("reasonPlaceholder")}
              maxLength={200}
              onChange={(event) => setReason(event.target.value)}
            />
          ) : null}

          <div className="flex flex-wrap gap-2">
            {responder.approval !== "approved" ? (
              <Button
                type="button"
                className="w-auto flex-1"
                disabled={busy}
                onClick={() => setApproval(responder.id, "approved")}
              >
                {t("approve")}
              </Button>
            ) : null}
            {responder.approval !== "rejected" ? (
              <Button
                type="button"
                variant="secondary"
                className="w-auto flex-1"
                disabled={busy}
                onClick={() => setApproval(responder.id, "rejected")}
              >
                {t("reject")}
              </Button>
            ) : null}
            {responder.approval !== "banned" ? (
              <Button
                type="button"
                variant="danger"
                className="w-auto flex-1"
                disabled={busy}
                onClick={() => setApproval(responder.id, "banned")}
              >
                {t("ban")}
              </Button>
            ) : null}
          </div>
        </Card>
      ))}
    </div>
  );
}
