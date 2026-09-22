"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Checkbox, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

type Creative = {
  id: string;
  headline: string;
  body: string | null;
  cta_label: string | null;
  cta_url: string;
  status: string;
  is_active: boolean;
  review_note: string | null;
};

type Campaign = {
  id: string;
  name: string;
  status: string;
  review_note: string | null;
  surfaces: string[];
  starts_on: string;
  ends_on: string | null;
  monthly_price_cents: number;
  creatives: Creative[];
  impressions: number;
  clicks: number;
};

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
  review_note: string | null;
  campaigns: Campaign[];
};

const CATEGORIES = [
  "recovery_towing",
  "offroad_shop",
  "tires_wheels",
  "fabrication",
  "parts",
  "powersports",
  "land_access",
  "food_lodging",
  "insurance",
  "other",
];

const SURFACES = ["community_feed", "trails", "resources"] as const;

async function call(fn: string, args: Record<string, unknown>) {
  const { data, error } = await supabaseBrowser().rpc(fn, args);
  if (error) return { ok: false, error: "failed" } as const;
  return (data as { ok: boolean; error?: string; id?: string }) ?? { ok: false, error: "failed" };
}

function slugify(name: string) {
  return name
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 50);
}

/**
 * Where a business runs its own advertising.
 *
 * Two things this screen says out loud rather than burying, both because the alternative is a
 * business owner discovering them after paying:
 *
 *   Nothing runs until a person has read it. Business, campaign and every individual creative
 *   are reviewed separately, and editing an approved one sends it back.
 *
 *   The numbers are real or they are zero. There is no sample data anywhere in this feature.
 */
export function AdvertiserDashboard() {
  const t = useTranslations("business");
  const tEnum = useTranslations("enum");

  const [businesses, setBusinesses] = useState<Business[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [registering, setRegistering] = useState(false);

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("advertiser_overview", {});
    if (rpcError) {
      setError("failed");
      return;
    }
    const result = data as { ok: boolean; error?: string; businesses?: Business[] };
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }
    setError(null);
    setBusinesses(result.businesses ?? []);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("intro")}</p>
      </div>

      {/* The promise this feature must not break. */}
      <Callout tone="neutral">
        <p className="font-semibold">{t("freeTitle")}</p>
        <p className="mt-1 text-sm">{t("freeBody")}</p>
      </Callout>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {businesses === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : businesses.length === 0 && !registering ? (
        <Card className="space-y-3">
          <p className="text-base text-ink-soft">{t("noBusiness")}</p>
          <Button onClick={() => setRegistering(true)}>{t("register")}</Button>
        </Card>
      ) : null}

      {registering ? (
        <BusinessForm
          t={t}
          tEnum={tEnum}
          business={null}
          onDone={() => {
            setRegistering(false);
            void load();
          }}
          onCancel={() => setRegistering(false)}
        />
      ) : null}

      {(businesses ?? []).map((business) => (
        <BusinessPanel key={business.id} business={business} t={t} tEnum={tEnum} onChanged={load} />
      ))}
    </div>
  );
}

function StatusPill({ status, t }: { status: string; t: (k: string) => string }) {
  return (
    <span
      className={cn(
        "rounded-field border-2 px-2 py-1 text-xs font-bold uppercase tracking-wide",
        status === "approved"
          ? "border-good text-good"
          : status === "rejected"
            ? "border-danger text-danger"
            : "border-line text-ink-faint",
      )}
    >
      {t(`statuses.${status}`)}
    </span>
  );
}

function BusinessPanel({
  business,
  t,
  tEnum,
  onChanged,
}: {
  business: Business;
  t: ReturnType<typeof useTranslations<"business">>;
  tEnum: ReturnType<typeof useTranslations<"enum">>;
  onChanged: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [addingCampaign, setAddingCampaign] = useState(false);
  const [busy, setBusy] = useState(false);

  return (
    <Card className="space-y-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-xl font-semibold">{business.name}</h2>
        <StatusPill status={business.status} t={t} />
      </div>

      <p className="text-sm text-ink-faint">{tEnum(`businessCategory.${business.category}`)}</p>

      {business.review_note ? (
        <Callout tone="neutral">
          <p className="text-sm font-semibold">{t("reviewNote")}</p>
          <p className="mt-1 text-sm">{business.review_note}</p>
        </Callout>
      ) : null}

      {business.status === "draft" ? (
        <Button
          size="md"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            await call("submit_for_review", { p_kind: "business", p_id: business.id });
            setBusy(false);
            onChanged();
          }}
        >
          {t("submitBusiness")}
        </Button>
      ) : null}

      <Button variant="secondary" size="md" onClick={() => setEditing((v) => !v)}>
        {editing ? t("cancel") : t("editBusiness")}
      </Button>

      {editing ? (
        <>
          {business.status === "approved" ? (
            <Callout tone="neutral">{t("editSendsBack")}</Callout>
          ) : null}
          <BusinessForm
            t={t}
            tEnum={tEnum}
            business={business}
            onDone={() => {
              setEditing(false);
              onChanged();
            }}
            onCancel={() => setEditing(false)}
          />
        </>
      ) : null}

      {business.status === "approved" ? (
        <div className="space-y-3 border-t border-line pt-3">
          <h3 className="text-lg font-semibold">{t("campaigns")}</h3>

          {business.campaigns.length === 0 ? (
            <p className="text-base text-ink-soft">{t("noCampaigns")}</p>
          ) : (
            business.campaigns.map((campaign) => (
              <CampaignPanel
                key={campaign.id}
                campaign={campaign}
                t={t}
                tEnum={tEnum}
                onChanged={onChanged}
              />
            ))
          )}

          {addingCampaign ? (
            <CampaignForm
              t={t}
              tEnum={tEnum}
              businessId={business.id}
              campaign={null}
              onDone={() => {
                setAddingCampaign(false);
                onChanged();
              }}
              onCancel={() => setAddingCampaign(false)}
            />
          ) : (
            <Button variant="secondary" onClick={() => setAddingCampaign(true)}>
              {t("addCampaign")}
            </Button>
          )}
        </div>
      ) : (
        <p className="text-sm text-ink-faint">{t("campaignsAfterApproval")}</p>
      )}
    </Card>
  );
}

function CampaignPanel({
  campaign,
  t,
  tEnum,
  onChanged,
}: {
  campaign: Campaign;
  t: ReturnType<typeof useTranslations<"business">>;
  tEnum: ReturnType<typeof useTranslations<"enum">>;
  onChanged: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [addingCreative, setAddingCreative] = useState(false);
  const [busy, setBusy] = useState(false);

  const money = (campaign.monthly_price_cents / 100).toFixed(2);

  return (
    <div className="space-y-2 rounded-field border-2 border-line p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-base font-semibold">{campaign.name}</p>
        <StatusPill status={campaign.status} t={t} />
      </div>

      <p className="text-sm text-ink-faint">
        {campaign.surfaces.map((s) => tEnum(`adSurface.${s}`)).join(" · ")}
      </p>
      <p className="text-sm text-ink-faint">
        {t("schedule", { from: campaign.starts_on, to: campaign.ends_on ?? t("ongoing") })}
      </p>
      <p className="text-sm text-ink-faint">{t("monthly", { amount: money })}</p>

      {/* Real counts, or zero. There is no sample data in this feature anywhere. */}
      <p className="text-sm">
        {t("counts", { impressions: campaign.impressions, clicks: campaign.clicks })}
      </p>

      {campaign.review_note ? (
        <p className="text-sm text-ink-soft">{campaign.review_note}</p>
      ) : null}

      <div className="flex flex-wrap gap-2">
        {campaign.status === "draft" || campaign.status === "rejected" ? (
          <Button
            size="md"
            className="w-auto"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              await call("submit_for_review", { p_kind: "campaign", p_id: campaign.id });
              setBusy(false);
              onChanged();
            }}
          >
            {t("submitCampaign")}
          </Button>
        ) : null}

        {campaign.status === "approved" || campaign.status === "paused" ? (
          <Button
            variant="secondary"
            size="md"
            className="w-auto"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              await call("set_campaign_running", {
                p_id: campaign.id,
                p_running: campaign.status !== "approved",
              });
              setBusy(false);
              onChanged();
            }}
          >
            {campaign.status === "approved" ? t("pause") : t("resume")}
          </Button>
        ) : null}

        <Button
          variant="secondary"
          size="md"
          className="w-auto"
          onClick={() => setEditing((v) => !v)}
        >
          {editing ? t("cancel") : t("edit")}
        </Button>
      </div>

      {editing ? (
        <CampaignForm
          t={t}
          tEnum={tEnum}
          businessId={null}
          campaign={campaign}
          onDone={() => {
            setEditing(false);
            onChanged();
          }}
          onCancel={() => setEditing(false)}
        />
      ) : null}

      <div className="space-y-2 border-t border-line pt-2">
        <p className="text-sm font-semibold">{t("creatives")}</p>

        {campaign.creatives.length === 0 ? (
          <p className="text-sm text-ink-faint">{t("noCreatives")}</p>
        ) : (
          <ul className="space-y-2">
            {campaign.creatives.map((creative) => (
              <li key={creative.id} className="rounded-field bg-surface-sunk p-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-base font-semibold">{creative.headline}</p>
                  <StatusPill status={creative.status} t={t} />
                </div>
                {creative.body ? (
                  <p className="mt-1 text-sm text-ink-soft">{creative.body}</p>
                ) : null}
                <p className="mt-1 break-all text-xs text-ink-faint">{creative.cta_url}</p>
                {creative.review_note ? (
                  <p className="mt-1 text-sm text-danger">{creative.review_note}</p>
                ) : null}
                <CreativeForm
                  t={t}
                  campaignId={campaign.id}
                  creative={creative}
                  onDone={onChanged}
                />
              </li>
            ))}
          </ul>
        )}

        {addingCreative ? (
          <CreativeFormFull
            t={t}
            campaignId={campaign.id}
            creative={null}
            onDone={() => {
              setAddingCreative(false);
              onChanged();
            }}
            onCancel={() => setAddingCreative(false)}
          />
        ) : (
          <Button variant="secondary" size="md" onClick={() => setAddingCreative(true)}>
            {t("addCreative")}
          </Button>
        )}
      </div>
    </div>
  );
}

function BusinessForm({
  t,
  tEnum,
  business,
  onDone,
  onCancel,
}: {
  t: ReturnType<typeof useTranslations<"business">>;
  tEnum: ReturnType<typeof useTranslations<"enum">>;
  business: Business | null;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(business?.name ?? "");
  const [slug, setSlug] = useState(business?.slug ?? "");
  const [category, setCategory] = useState(business?.category ?? "offroad_shop");
  const [description, setDescription] = useState(business?.description ?? "");
  const [website, setWebsite] = useState(business?.website ?? "");
  const [email, setEmail] = useState(business?.contact_email ?? "");
  const [phone, setPhone] = useState(business?.contact_phone ?? "");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const effectiveSlug = slug.trim() || slugify(name);

  return (
    <Card className="space-y-3">
      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <Field label={t("name")}>
        <TextInput value={name} onChange={(e) => setName(e.target.value)} maxLength={120} />
      </Field>

      <Field label={t("slug")} hint={t("slugHint")}>
        <TextInput
          value={effectiveSlug}
          onChange={(e) => setSlug(e.target.value)}
        />
      </Field>

      <Field label={t("category")}>
        <select
          className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
          value={category}
          onChange={(e) => setCategory(e.target.value)}
        >
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {tEnum(`businessCategory.${c}`)}
            </option>
          ))}
        </select>
      </Field>

      {category === "recovery_towing" ? (
        // Said at the moment they pick it, not after they have paid.
        <Callout tone="neutral">{t("towingNote")}</Callout>
      ) : null}

      <Field label={t("description")}>
        <TextArea
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          maxLength={1000}
          rows={3}
        />
      </Field>

      <Field label={t("website")} hint={t("websiteHint")}>
        <TextInput value={website} onChange={(e) => setWebsite(e.target.value)} />
      </Field>

      <Field label={t("contactEmail")}>
        <TextInput
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </Field>

      <Field label={t("contactPhone")}>
        <TextInput type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
      </Field>

      <Button
        disabled={busy || name.trim().length < 2}
        onClick={async () => {
          setBusy(true);
          setProblem(null);
          const result = await call("save_business", {
            p_payload: {
              id: business?.id ?? null,
              name: name.trim(),
              slug: effectiveSlug,
              category,
              description: description.trim() || null,
              website: website.trim() || null,
              contact_email: email.trim() || null,
              contact_phone: phone.trim() || null,
            },
          });
          setBusy(false);
          if (!result.ok) {
            setProblem(result.error ?? "failed");
            return;
          }
          onDone();
        }}
      >
        {busy ? t("saving") : t("save")}
      </Button>
      <Button variant="quiet" onClick={onCancel}>
        {t("cancel")}
      </Button>
    </Card>
  );
}

function CampaignForm({
  t,
  tEnum,
  businessId,
  campaign,
  onDone,
  onCancel,
}: {
  t: ReturnType<typeof useTranslations<"business">>;
  tEnum: ReturnType<typeof useTranslations<"enum">>;
  businessId: string | null;
  campaign: Campaign | null;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(campaign?.name ?? "");
  const [surfaces, setSurfaces] = useState<string[]>(campaign?.surfaces ?? []);
  const [startsOn, setStartsOn] = useState(campaign?.starts_on ?? "");
  const [endsOn, setEndsOn] = useState(campaign?.ends_on ?? "");
  const [price, setPrice] = useState(
    campaign ? String(campaign.monthly_price_cents / 100) : "",
  );
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  return (
    <div className="space-y-3 rounded-field border-2 border-line p-3">
      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <Field label={t("campaignName")}>
        <TextInput value={name} onChange={(e) => setName(e.target.value)} maxLength={120} />
      </Field>

      <Field label={t("surfaces")} hint={t("surfacesHint")}>
        <div className="space-y-2">
          {SURFACES.map((s) => (
            <Checkbox
              key={s}
              id={`surface-${campaign?.id ?? "new"}-${s}`}
              checked={surfaces.includes(s)}
              onChange={(next) =>
                setSurfaces(next ? [...surfaces, s] : surfaces.filter((x) => x !== s))
              }
            >
              {tEnum(`adSurface.${s}`)}
            </Checkbox>
          ))}
        </div>
      </Field>

      <div className="grid grid-cols-2 gap-3">
        <Field label={t("startsOn")}>
          <TextInput type="date" value={startsOn} onChange={(e) => setStartsOn(e.target.value)} />
        </Field>
        <Field label={t("endsOn")}>
          <TextInput type="date" value={endsOn} onChange={(e) => setEndsOn(e.target.value)} />
        </Field>
      </div>

      <Field label={t("monthlyPrice")} hint={t("monthlyPriceHint")}>
        <TextInput
          inputMode="decimal"
          value={price}
          onChange={(e) => setPrice(e.target.value)}
        />
      </Field>

      <Button
        disabled={busy || name.trim().length < 2 || surfaces.length === 0}
        onClick={async () => {
          setBusy(true);
          setProblem(null);
          const result = await call("save_campaign", {
            p_payload: {
              id: campaign?.id ?? null,
              business_id: businessId,
              name: name.trim(),
              surfaces,
              starts_on: startsOn || null,
              ends_on: endsOn || null,
              monthly_price_cents: Math.round((Number(price) || 0) * 100),
            },
          });
          setBusy(false);
          if (!result.ok) {
            setProblem(result.error ?? "failed");
            return;
          }
          onDone();
        }}
      >
        {busy ? t("saving") : t("save")}
      </Button>
      <Button variant="quiet" onClick={onCancel}>
        {t("cancel")}
      </Button>
    </div>
  );
}

/** The inline "edit this creative" toggle on an existing one. */
function CreativeForm({
  t,
  campaignId,
  creative,
  onDone,
}: {
  t: ReturnType<typeof useTranslations<"business">>;
  campaignId: string;
  creative: Creative;
  onDone: () => void;
}) {
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button
        type="button"
        className="mt-2 text-sm font-semibold underline underline-offset-4"
        onClick={() => setOpen(true)}
      >
        {t("edit")}
      </button>
    );
  }

  return (
    <div className="mt-2">
      <Callout tone="neutral" className="mb-2 text-sm">
        {t("creativeEditSendsBack")}
      </Callout>
      <CreativeFormFull
        t={t}
        campaignId={campaignId}
        creative={creative}
        onDone={() => {
          setOpen(false);
          onDone();
        }}
        onCancel={() => setOpen(false)}
      />
    </div>
  );
}

function CreativeFormFull({
  t,
  campaignId,
  creative,
  onDone,
  onCancel,
}: {
  t: ReturnType<typeof useTranslations<"business">>;
  campaignId: string;
  creative: Creative | null;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [headline, setHeadline] = useState(creative?.headline ?? "");
  const [body, setBody] = useState(creative?.body ?? "");
  const [ctaLabel, setCtaLabel] = useState(creative?.cta_label ?? "");
  const [ctaUrl, setCtaUrl] = useState(creative?.cta_url ?? "");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  return (
    <div className="space-y-3">
      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

      <Field label={t("headline")}>
        <TextInput
          value={headline}
          onChange={(e) => setHeadline(e.target.value)}
          maxLength={60}
        />
      </Field>

      <Field label={t("body")}>
        <TextArea value={body} onChange={(e) => setBody(e.target.value)} maxLength={180} rows={2} />
      </Field>

      <Field label={t("ctaLabel")}>
        <TextInput value={ctaLabel} onChange={(e) => setCtaLabel(e.target.value)} maxLength={30} />
      </Field>

      <Field label={t("ctaUrl")} hint={t("ctaUrlHint")}>
        <TextInput value={ctaUrl} onChange={(e) => setCtaUrl(e.target.value)} />
      </Field>

      <Button
        size="md"
        disabled={busy || headline.trim().length < 2 || !/^https?:\/\//i.test(ctaUrl.trim())}
        onClick={async () => {
          setBusy(true);
          setProblem(null);
          const result = await call("save_creative", {
            p_payload: {
              id: creative?.id ?? null,
              campaign_id: campaignId,
              headline: headline.trim(),
              body: body.trim() || null,
              cta_label: ctaLabel.trim() || null,
              cta_url: ctaUrl.trim(),
            },
          });
          setBusy(false);
          if (!result.ok) {
            setProblem(result.error ?? "failed");
            return;
          }
          onDone();
        }}
      >
        {busy ? t("saving") : t("save")}
      </Button>
      <Button variant="quiet" size="md" onClick={onCancel}>
        {t("cancel")}
      </Button>
    </div>
  );
}
