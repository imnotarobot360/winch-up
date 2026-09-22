"use client";

import { useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import {
  Button,
  Callout,
  Card,
  Checkbox,
  Field,
  TextArea,
  TextInput,
} from "@/components/ui/primitives";
import { cn } from "@/lib/utils";

import { adminAction, useAdminData } from "./use-admin";

type Trail = {
  id: string;
  slug: string;
  name: string;
  region: string | null;
  status: string;
  access: string;
  access_source: string | null;
  access_checked_at: string | null;
  difficulty: string | null;
  difficulty_source: string | null;
  summary: string | null;
  description: string | null;
  min_drivetrain: string;
  recommended_equipment: string[];
  lng: number;
  lat: number;
  condition_count: number;
};

type Edit = {
  id: string;
  kind: "new" | "correction" | "problem";
  body: string;
  name: string | null;
  region: string | null;
  status: string;
  admin_notes: string | null;
  created_at: string;
  trail_slug: string | null;
  trail_name: string | null;
  lng: number | null;
  lat: number | null;
  author_name: string;
};

const ACCESS = ["unknown", "open_public", "permit_required", "private_permission", "closed"];
const DIFFICULTY = ["", "easy", "moderate", "difficult", "extreme"];
const DRIVETRAIN = ["unknown", "2wd", "4wd", "awd"];
const EQUIPMENT = [
  "winch",
  "kinetic_rope",
  "traction_boards",
  "tractor",
  "second_truck",
  "lifted_4x4",
  "air_compressor",
  "tire_repair",
];

const BLANK = {
  id: "",
  slug: "",
  name: "",
  region: "",
  lat: "",
  lng: "",
  access: "unknown",
  access_source: "",
  difficulty: "",
  difficulty_source: "",
  summary: "",
  description: "",
  min_drivetrain: "unknown",
  recommended_equipment: [] as string[],
  status: "pending",
};

/**
 * Adding and publishing trails.
 *
 * The form is built so the source field cannot be treated as optional decoration: choosing any
 * access other than "we don't know" reveals a required source, and the Save button stays disabled
 * until it is filled. The database refuses it anyway, but a person who has just typed for five
 * minutes deserves to be told before they press the button, not after.
 *
 * Publishing is what stamps a verifier onto the row. That is the whole difference between this
 * table and the condition reports underneath it.
 */
export function AdminTrails() {
  const t = useTranslations("admin.trails");
  const tEnum = useTranslations("enum");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [tab, setTab] = useState<"trails" | "suggestions">("trails");

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      <div role="group" aria-label={t("title")} className="flex flex-wrap gap-2">
        {(["trails", "suggestions"] as const).map((key) => (
          <button
            key={key}
            type="button"
            aria-pressed={tab === key}
            onClick={() => setTab(key)}
            className={cn(
              "min-h-12 rounded-field border-2 px-4 py-2 text-base font-semibold",
              tab === key ? "border-brand bg-brand-tint text-ink" : "border-line text-ink-soft",
            )}
          >
            {t(`tabs.${key}`)}
          </button>
        ))}
      </div>

      {tab === "trails" ? (
        <TrailAdmin t={t} tEnum={tEnum} />
      ) : (
        <Suggestions t={t} relative={relative} />
      )}
    </div>
  );
}

function TrailAdmin({
  t,
  tEnum,
}: {
  t: ReturnType<typeof useTranslations<"admin.trails">>;
  tEnum: ReturnType<typeof useTranslations<"enum">>;
}) {
  const { data, loading, error, reload } = useAdminData<{ ok: boolean; trails: Trail[] }>(
    "admin_trails",
    { p_status: null },
  );

  const [form, setForm] = useState<typeof BLANK | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  function edit(trail: Trail) {
    setProblem(null);
    setForm({
      id: trail.id,
      slug: trail.slug,
      name: trail.name,
      region: trail.region ?? "",
      lat: String(trail.lat),
      lng: String(trail.lng),
      access: trail.access,
      access_source: trail.access_source ?? "",
      difficulty: trail.difficulty ?? "",
      difficulty_source: trail.difficulty_source ?? "",
      summary: trail.summary ?? "",
      description: trail.description ?? "",
      min_drivetrain: trail.min_drivetrain,
      recommended_equipment: trail.recommended_equipment ?? [],
      status: trail.status,
    });
  }

  async function save() {
    if (!form) return;
    setBusy(true);
    setProblem(null);

    const result = await adminAction("admin_save_trail", {
      p_payload: {
        id: form.id || null,
        slug: form.slug.trim().toLowerCase(),
        name: form.name.trim(),
        region: form.region.trim() || null,
        lat: Number(form.lat),
        lng: Number(form.lng),
        access: form.access,
        access_source: form.access_source.trim() || null,
        difficulty: form.difficulty || null,
        difficulty_source: form.difficulty_source.trim() || null,
        summary: form.summary.trim() || null,
        description: form.description.trim() || null,
        min_drivetrain: form.min_drivetrain,
        recommended_equipment: form.recommended_equipment,
        status: form.status,
      },
    });

    setBusy(false);

    if (!result.ok) {
      setProblem(result.error ?? "failed");
      return;
    }

    setForm(null);
    await reload();
  }

  const needsSource = form !== null && form.access !== "unknown";
  const sourceMissing = needsSource && form!.access_source.trim().length === 0;
  const diffSourceMissing =
    form !== null && form.difficulty !== "" && form.difficulty_source.trim().length === 0;

  const canSave =
    form !== null &&
    form.name.trim().length >= 2 &&
    /^[a-z0-9]+(-[a-z0-9]+)*$/.test(form.slug.trim().toLowerCase()) &&
    form.lat.trim() !== "" &&
    form.lng.trim() !== "" &&
    !sourceMissing &&
    !diffSourceMissing;

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{error}</Callout> : null}

      {form === null ? (
        <Button onClick={() => setForm({ ...BLANK })}>{t("addTrail")}</Button>
      ) : (
        <Card className="space-y-3">
          <h3 className="text-lg font-semibold">{form.id ? t("editTitle") : t("addTitle")}</h3>

          {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}

          <Field label={t("name")}>
            <TextInput
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
            />
          </Field>

          <Field label={t("slug")} hint={t("slugHint")}>
            <TextInput
              value={form.slug}
              onChange={(e) => setForm({ ...form, slug: e.target.value })}
            />
          </Field>

          <Field label={t("region")}>
            <TextInput
              value={form.region}
              onChange={(e) => setForm({ ...form, region: e.target.value })}
            />
          </Field>

          <div className="grid grid-cols-2 gap-3">
            <Field label={t("lat")}>
              <TextInput
                inputMode="decimal"
                value={form.lat}
                onChange={(e) => setForm({ ...form, lat: e.target.value })}
              />
            </Field>
            <Field label={t("lng")}>
              <TextInput
                inputMode="decimal"
                value={form.lng}
                onChange={(e) => setForm({ ...form, lng: e.target.value })}
              />
            </Field>
          </div>

          <Field label={t("access")}>
            <select
              className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
              value={form.access}
              onChange={(e) => setForm({ ...form, access: e.target.value })}
            >
              {ACCESS.map((a) => (
                <option key={a} value={a}>
                  {tEnum(`trailAccess.${a}`)}
                </option>
              ))}
            </select>
          </Field>

          {needsSource ? (
            <Field
              label={t("accessSource")}
              hint={t("accessSourceHint")}
              error={sourceMissing ? t("errors.access_source_required") : null}
            >
              <TextInput
                value={form.access_source}
                onChange={(e) => setForm({ ...form, access_source: e.target.value })}
              />
            </Field>
          ) : null}

          <Field label={t("difficulty")}>
            <select
              className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
              value={form.difficulty}
              onChange={(e) => setForm({ ...form, difficulty: e.target.value })}
            >
              {DIFFICULTY.map((d) => (
                <option key={d} value={d}>
                  {d === "" ? t("noRating") : tEnum(`trailDifficulty.${d}`)}
                </option>
              ))}
            </select>
          </Field>

          {form.difficulty ? (
            <Field
              label={t("difficultySource")}
              hint={t("difficultySourceHint")}
              error={diffSourceMissing ? t("errors.difficulty_source_required") : null}
            >
              <TextInput
                value={form.difficulty_source}
                onChange={(e) => setForm({ ...form, difficulty_source: e.target.value })}
              />
            </Field>
          ) : null}

          <Field label={t("drivetrain")}>
            <select
              className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
              value={form.min_drivetrain}
              onChange={(e) => setForm({ ...form, min_drivetrain: e.target.value })}
            >
              {DRIVETRAIN.map((d) => (
                <option key={d} value={d}>
                  {tEnum(`drivetrain.${d}`)}
                </option>
              ))}
            </select>
          </Field>

          <Field label={t("equipment")}>
            <div className="grid grid-cols-1 gap-2">
              {EQUIPMENT.map((e) => (
                <Checkbox
                  key={e}
                  id={`trail-equipment-${e}`}
                  checked={form.recommended_equipment.includes(e)}
                  onChange={(next) =>
                    setForm({
                      ...form,
                      recommended_equipment: next
                        ? [...form.recommended_equipment, e]
                        : form.recommended_equipment.filter((x) => x !== e),
                    })
                  }
                >
                  {tEnum(`equipment.${e}`)}
                </Checkbox>
              ))}
            </div>
          </Field>

          <Field label={t("summary")}>
            <TextInput
              value={form.summary}
              onChange={(e) => setForm({ ...form, summary: e.target.value })}
              maxLength={300}
            />
          </Field>

          <Field label={t("description")}>
            <TextArea
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
              maxLength={4000}
              rows={4}
            />
          </Field>

          <Field label={t("status")} hint={t("statusHint")}>
            <select
              className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
              value={form.status}
              onChange={(e) => setForm({ ...form, status: e.target.value })}
            >
              {["pending", "published", "archived"].map((s) => (
                <option key={s} value={s}>
                  {t(`statuses.${s}`)}
                </option>
              ))}
            </select>
          </Field>

          <Button disabled={busy || !canSave} onClick={() => void save()}>
            {busy ? t("saving") : t("save")}
          </Button>
          <Button variant="quiet" onClick={() => setForm(null)}>
            {t("cancel")}
          </Button>
        </Card>
      )}

      {loading ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : (data?.trails ?? []).length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">{t("empty")}</p>
        </Card>
      ) : (
        <ul className="space-y-3">
          {(data?.trails ?? []).map((trail) => (
            <li key={trail.id}>
              <Card className="space-y-2">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-lg font-semibold">{trail.name}</p>
                  <p className="text-sm font-semibold text-ink-faint">
                    {t(`statuses.${trail.status}`)}
                  </p>
                </div>
                <p className="text-sm text-ink-faint">{trail.region ?? "—"}</p>
                <p className="text-sm">
                  {tEnum(`trailAccess.${trail.access}`)}
                  {trail.access_source ? ` · ${trail.access_source}` : ""}
                </p>
                <p className="text-sm text-ink-faint">
                  {t("conditionCount", { count: trail.condition_count })}
                </p>
                <Button variant="secondary" size="md" className="w-auto" onClick={() => edit(trail)}>
                  {t("edit")}
                </Button>
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Suggestions({
  t,
  relative,
}: {
  t: ReturnType<typeof useTranslations<"admin.trails">>;
  relative: (iso: string) => string;
}) {
  const [status, setStatus] = useState<string>("new");
  const { data, loading, error, reload } = useAdminData<{ ok: boolean; edits: Edit[] }>(
    "admin_trail_edits",
    { p_status: status },
  );
  const [busy, setBusy] = useState<string | null>(null);

  async function review(id: string, next: string) {
    setBusy(id);
    await adminAction("admin_review_trail_edit", { p_id: id, p_status: next, p_notes: null });
    setBusy(null);
    await reload();
  }

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{error}</Callout> : null}

      <div role="group" aria-label={t("tabs.suggestions")} className="flex flex-wrap gap-2">
        {["new", "actioned", "dismissed"].map((s) => (
          <button
            key={s}
            type="button"
            aria-pressed={status === s}
            onClick={() => setStatus(s)}
            className={cn(
              "min-h-12 rounded-field border-2 px-4 py-2 text-base font-semibold",
              status === s ? "border-brand bg-brand-tint text-ink" : "border-line text-ink-soft",
            )}
          >
            {t(`review.${s}`)}
          </button>
        ))}
      </div>

      {loading ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : (data?.edits ?? []).length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">{t("noSuggestions")}</p>
        </Card>
      ) : (
        <ul className="space-y-3">
          {(data?.edits ?? []).map((edit) => (
            <li key={edit.id}>
              <Card className="space-y-2">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-base font-semibold">
                    {t(`kinds.${edit.kind}`)}
                    {edit.trail_name ? ` · ${edit.trail_name}` : ""}
                    {edit.name ? ` · ${edit.name}` : ""}
                  </p>
                  <p className="text-sm text-ink-faint">{relative(edit.created_at)}</p>
                </div>

                {edit.region ? <p className="text-sm text-ink-faint">{edit.region}</p> : null}
                {edit.lat !== null && edit.lng !== null ? (
                  <p className="text-sm text-ink-faint">
                    {edit.lat.toFixed(5)}, {edit.lng.toFixed(5)}
                  </p>
                ) : null}

                <blockquote className="whitespace-pre-wrap rounded-field border-2 border-line bg-surface-sunk p-3 text-base">
                  {edit.body}
                </blockquote>

                <p className="text-sm text-ink-faint">{edit.author_name || t("someone")}</p>

                {status === "new" ? (
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="md"
                      className="w-auto"
                      disabled={busy === edit.id}
                      onClick={() => void review(edit.id, "actioned")}
                    >
                      {t("markDone")}
                    </Button>
                    <Button
                      variant="secondary"
                      size="md"
                      className="w-auto"
                      disabled={busy === edit.id}
                      onClick={() => void review(edit.id, "dismissed")}
                    >
                      {t("dismiss")}
                    </Button>
                  </div>
                ) : null}
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
