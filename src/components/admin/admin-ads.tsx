"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { cn } from "@/lib/utils";

import { adminAction, useAdminData } from "./use-admin";

type Business = {
  id: string;
  name: string;
  slug: string;
  category: string;
  description: string | null;
  website: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  status: string;
  service_counties: string[];
  verification_note: string | null;
  owner_name: string;
};

type Campaign = {
  id: string;
  name: string;
  status: string;
  surfaces: string[];
  starts_on: string;
  ends_on: string | null;
  monthly_price_cents: number;
  business_name: string;
  business_category: string;
};

type Creative = {
  id: string;
  headline: string;
  body: string | null;
  cta_label: string | null;
  cta_url: string;
  status: string;
  campaign_name: string;
  business_name: string;
  business_category: string;
};

type Payload = {
  ok: boolean;
  businesses: Business[];
  campaigns: Campaign[];
  creatives: Creative[];
};

const FILTERS = ["pending", "approved", "rejected"] as const;

/**
 * Approving advertising.
 *
 * Three separate decisions, because they are three separate risks: whether this business is real,
 * whether this campaign should run where it says, and whether these exact words should appear
 * next to a volunteer recovery group's name.
 *
 * Approving a business needs a sentence saying what was checked. The database refuses without
 * one; this screen says so before the button rather than after, and keeps the rule about not
 * implying advertisers are better recovery providers on screen while somebody decides.
 */
export function AdminAds() {
  const t = useTranslations("admin.ads");
  const tEnum = useTranslations("enum");

  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("pending");
  const { data, loading, error, reload } = useAdminData<Payload>("admin_ad_queue", {
    p_status: filter,
  });

  const [notes, setNotes] = useState<Record<string, string>>({});
  const [verifications, setVerifications] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  async function review(kind: string, id: string, status: string) {
    setBusy(id);
    setProblem(null);
    const result = await adminAction("admin_review_ad", {
      p_kind: kind,
      p_id: id,
      p_status: status,
      p_note: notes[id] || null,
      p_verification_note: verifications[id] || null,
    });
    setBusy(null);

    if (!result.ok) {
      setProblem(result.error ?? "failed");
      return;
    }
    await reload();
  }

  const buttons = (kind: string, id: string, extraDisabled = false) => (
    <div className="flex flex-wrap gap-2">
      <Button
        size="md"
        className="w-auto"
        disabled={busy === id || extraDisabled}
        onClick={() => void review(kind, id, "approved")}
      >
        {t("approve")}
      </Button>
      <Button
        variant="danger"
        size="md"
        className="w-auto"
        disabled={busy === id}
        onClick={() => void review(kind, id, "rejected")}
      >
        {t("reject")}
      </Button>
    </div>
  );

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      {/* On screen while somebody decides, not in a policy document nobody opens. */}
      <Callout tone="neutral">
        <p className="font-semibold">{t("ruleTitle")}</p>
        <ul className="mt-1 list-outside list-disc space-y-1 pl-5 text-sm">
          <li>{t("rule1")}</li>
          <li>{t("rule2")}</li>
          <li>{t("rule3")}</li>
        </ul>
      </Callout>

      {error ? <Callout tone="danger">{error}</Callout> : null}
      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <div role="group" aria-label={t("title")} className="flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f}
            type="button"
            aria-pressed={filter === f}
            onClick={() => setFilter(f)}
            className={cn(
              "min-h-12 rounded-field border-2 px-4 py-2 text-base font-semibold",
              filter === f ? "border-brand bg-brand-tint text-ink" : "border-line text-ink-soft",
            )}
          >
            {t(`filters.${f}`)}
          </button>
        ))}
      </div>

      {loading ? <p className="text-base text-ink-soft">{t("loading")}</p> : null}

      <section className="space-y-3">
        <h3 className="text-lg font-semibold">{t("businesses")}</h3>
        {(data?.businesses ?? []).length === 0 ? (
          <p className="text-base text-ink-soft">{t("none")}</p>
        ) : (
          (data?.businesses ?? []).map((b) => (
            <Card key={b.id} className="space-y-2">
              <p className="text-lg font-semibold">{b.name}</p>
              <p className="text-sm text-ink-faint">
                {tEnum(`businessCategory.${b.category}`)} · {b.owner_name || t("someone")}
              </p>
              {b.description ? <p className="text-base">{b.description}</p> : null}
              <p className="break-all text-sm text-ink-faint">
                {[b.website, b.contact_email, b.contact_phone].filter(Boolean).join(" · ")}
              </p>

              {b.category === "recovery_towing" ? (
                <Callout tone="danger" className="text-sm">
                  {t("towingWarning")}
                </Callout>
              ) : null}

              {filter === "pending" ? (
                <>
                  <Field label={t("verification")} hint={t("verificationHint")}>
                    <TextInput
                      value={verifications[b.id] ?? ""}
                      onChange={(e) =>
                        setVerifications((prev) => ({ ...prev, [b.id]: e.target.value }))
                      }
                    />
                  </Field>
                  <Field label={t("note")}>
                    <TextArea
                      rows={2}
                      value={notes[b.id] ?? ""}
                      onChange={(e) => setNotes((prev) => ({ ...prev, [b.id]: e.target.value }))}
                    />
                  </Field>
                  {buttons("business", b.id, (verifications[b.id] ?? "").trim().length === 0)}
                  {(verifications[b.id] ?? "").trim().length === 0 ? (
                    <p className="text-sm text-ink-faint">{t("verificationRequired")}</p>
                  ) : null}
                </>
              ) : (
                <p className="text-sm text-ink-faint">{b.verification_note}</p>
              )}
            </Card>
          ))
        )}
      </section>

      <section className="space-y-3">
        <h3 className="text-lg font-semibold">{t("campaigns")}</h3>
        {(data?.campaigns ?? []).length === 0 ? (
          <p className="text-base text-ink-soft">{t("none")}</p>
        ) : (
          (data?.campaigns ?? []).map((c) => (
            <Card key={c.id} className="space-y-2">
              <p className="text-lg font-semibold">
                {c.business_name} · {c.name}
              </p>
              <p className="text-sm text-ink-faint">
                {c.surfaces.map((s) => tEnum(`adSurface.${s}`)).join(" · ")}
              </p>
              <p className="text-sm text-ink-faint">
                {c.starts_on} → {c.ends_on ?? t("ongoing")} ·{" "}
                {t("monthly", { amount: (c.monthly_price_cents / 100).toFixed(2) })}
              </p>
              {filter === "pending" ? (
                <>
                  <Field label={t("note")}>
                    <TextArea
                      rows={2}
                      value={notes[c.id] ?? ""}
                      onChange={(e) => setNotes((prev) => ({ ...prev, [c.id]: e.target.value }))}
                    />
                  </Field>
                  {buttons("campaign", c.id)}
                </>
              ) : null}
            </Card>
          ))
        )}
      </section>

      <section className="space-y-3">
        <h3 className="text-lg font-semibold">{t("creatives")}</h3>
        {(data?.creatives ?? []).length === 0 ? (
          <p className="text-base text-ink-soft">{t("none")}</p>
        ) : (
          (data?.creatives ?? []).map((cr) => (
            <Card key={cr.id} className="space-y-2">
              <p className="text-sm text-ink-faint">
                {cr.business_name} · {cr.campaign_name}
              </p>

              {/* Rendered close to how a member will see it, so the decision is made on the
                  thing itself rather than on a table row. */}
              <div className="rounded-2xl border-2 border-dashed border-line bg-surface-sunk p-4">
                <p className="text-xs font-bold uppercase tracking-wide text-ink-faint">
                  {t("adLabelPreview")}
                </p>
                <p className="mt-2 text-base font-semibold">{cr.headline}</p>
                {cr.body ? <p className="mt-1 text-base text-ink-soft">{cr.body}</p> : null}
                <p className="mt-2 text-sm text-ink-faint">{cr.business_name}</p>
                {cr.business_category === "recovery_towing" ? (
                  <p className="mt-2 rounded-field border-l-4 border-danger bg-danger-tint p-2 text-sm">
                    {t("notAVolunteerPreview")}
                  </p>
                ) : null}
                <p className="mt-2 break-all text-xs text-ink-faint">{cr.cta_url}</p>
              </div>

              {filter === "pending" ? (
                <>
                  <Field label={t("note")}>
                    <TextArea
                      rows={2}
                      value={notes[cr.id] ?? ""}
                      onChange={(e) => setNotes((prev) => ({ ...prev, [cr.id]: e.target.value }))}
                    />
                  </Field>
                  {buttons("creative", cr.id)}
                </>
              ) : null}
            </Card>
          ))
        )}
      </section>
    </div>
  );
}
