"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import {
  Button,
  Callout,
  Card,
  Field,
  TextArea,
  TextInput,
} from "@/components/ui/primitives";

import { adminAction, useAdminData } from "./use-admin";

type Setting = {
  key: string;
  value: unknown;
  description: string | null;
  is_public: boolean;
};

type ProOption = {
  id: string;
  name: string;
  phone: string | null;
  url: string | null;
  blurb_en: string | null;
  blurb_es: string | null;
  is_active: boolean;
  sort_order: number;
};

/**
 * Settings, the paid-recovery list, legal copy and the blocklist.
 *
 * Settings are edited as raw JSON on purpose: they are numbers and arrays that an admin changes
 * rarely, and a bespoke widget per key would be more code than the thing it configures. The
 * value is validated by the RPC, and every change is written to the audit log.
 */
export function AdminSettings({ proOptions }: { proOptions: ProOption[] }) {
  const t = useTranslations("admin.settings");

  const { data: settings, reload } = useAdminData<Setting[]>("admin_list_settings");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [message, setMessage] = useState<{ tone: "good" | "danger"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  // Paid recovery list
  const [option, setOption] = useState<Partial<ProOption>>({ is_active: true, sort_order: 100 });

  // Legal copy
  const [slug, setSlug] = useState("requester_waiver");
  const [bodyEn, setBodyEn] = useState("");
  const [bodyEs, setBodyEs] = useState("");

  // Blocklist
  const [blockPhone, setBlockPhone] = useState("");
  const [blockReason, setBlockReason] = useState("");

  async function run(fn: string, args: Record<string, unknown>, okText: string) {
    setBusy(true);
    const result = await adminAction(fn, args);
    setMessage(
      result.ok
        ? { tone: "good", text: okText }
        : { tone: "danger", text: result.error ?? "failed" },
    );
    setBusy(false);
    return result.ok;
  }

  async function saveSetting(key: string) {
    const raw = drafts[key];
    if (raw === undefined) return;

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      setMessage({ tone: "danger", text: t("badJson") });
      return;
    }

    if (await run("admin_update_setting", { p_key: key, p_value: parsed }, t("saved"))) {
      setDrafts((current) => {
        const next = { ...current };
        delete next[key];
        return next;
      });
      await reload();
    }
  }

  return (
    <div className="space-y-8">
      {message ? <Callout tone={message.tone}>{message.text}</Callout> : null}

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">{t("dispatchTitle")}</h2>
        <p className="text-base text-ink-soft">{t("dispatchHint")}</p>

        {(settings ?? []).map((setting) => {
          const current = JSON.stringify(setting.value);
          const draft = drafts[setting.key] ?? current;
          const dirty = draft !== current;

          return (
            <Card key={setting.key} className="space-y-2">
              <p className="font-mono text-sm font-semibold">{setting.key}</p>
              {setting.description ? (
                <p className="text-sm text-ink-soft">{setting.description}</p>
              ) : null}
              <TextInput
                value={draft}
                onChange={(event) =>
                  setDrafts((cur) => ({ ...cur, [setting.key]: event.target.value }))
                }
              />
              {dirty ? (
                <Button
                  type="button"
                  size="md"
                  disabled={busy}
                  onClick={() => saveSetting(setting.key)}
                >
                  {t("save")}
                </Button>
              ) : null}
            </Card>
          );
        })}
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">{t("proTitle")}</h2>
        <p className="text-base text-ink-soft">{t("proHint")}</p>

        {proOptions.map((existing) => (
          <Card key={existing.id} className="space-y-1">
            <p className="text-lg font-semibold">{existing.name}</p>
            <p className="text-base text-ink-soft">
              {existing.phone ?? t("noPhone")} · {existing.is_active ? t("active") : t("hidden")}
            </p>
            <Button
              type="button"
              size="md"
              variant="secondary"
              disabled={busy}
              onClick={() =>
                run(
                  "admin_upsert_pro_option",
                  { p_payload: { id: existing.id, is_active: !existing.is_active } },
                  t("saved"),
                )
              }
            >
              {existing.is_active ? t("hide") : t("show")}
            </Button>
          </Card>
        ))}

        <Card className="space-y-3">
          <p className="text-lg font-semibold">{t("proAdd")}</p>
          <Field label={t("proName")} htmlFor="pro-name">
            <TextInput
              id="pro-name"
              value={option.name ?? ""}
              onChange={(event) => setOption((o) => ({ ...o, name: event.target.value }))}
            />
          </Field>
          <Field label={t("proPhone")} hint={t("proPhoneHint")} htmlFor="pro-phone">
            <TextInput
              id="pro-phone"
              value={option.phone ?? ""}
              placeholder="+12815550123"
              onChange={(event) => setOption((o) => ({ ...o, phone: event.target.value }))}
            />
          </Field>
          <Field label={t("proBlurbEn")} htmlFor="pro-en">
            <TextInput
              id="pro-en"
              value={option.blurb_en ?? ""}
              onChange={(event) => setOption((o) => ({ ...o, blurb_en: event.target.value }))}
            />
          </Field>
          <Field label={t("proBlurbEs")} htmlFor="pro-es">
            <TextInput
              id="pro-es"
              value={option.blurb_es ?? ""}
              onChange={(event) => setOption((o) => ({ ...o, blurb_es: event.target.value }))}
            />
          </Field>
          <Button
            type="button"
            disabled={busy || !option.name}
            onClick={async () => {
              if (await run("admin_upsert_pro_option", { p_payload: option }, t("saved"))) {
                setOption({ is_active: true, sort_order: 100 });
                window.location.reload();
              }
            }}
          >
            {t("proSave")}
          </Button>
        </Card>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">{t("legalTitle")}</h2>
        <Callout tone="danger">{t("legalWarning")}</Callout>

        <Card className="space-y-3">
          <Field label={t("legalDocument")} htmlFor="slug">
            <select
              id="slug"
              value={slug}
              onChange={(event) => setSlug(event.target.value)}
              className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg"
            >
              <option value="requester_waiver">{t("slugRequester")}</option>
              <option value="responder_waiver">{t("slugResponder")}</option>
              <option value="rules">{t("slugRules")}</option>
            </select>
          </Field>

          <Field label={t("legalEnglish")} htmlFor="body-en">
            <TextArea
              id="body-en"
              value={bodyEn}
              className="min-h-64 font-mono text-sm"
              onChange={(event) => setBodyEn(event.target.value)}
            />
          </Field>

          <Field label={t("legalSpanish")} hint={t("legalBothRequired")} htmlFor="body-es">
            <TextArea
              id="body-es"
              value={bodyEs}
              className="min-h-64 font-mono text-sm"
              onChange={(event) => setBodyEs(event.target.value)}
            />
          </Field>

          <Button
            type="button"
            disabled={busy || bodyEn.length < 20 || bodyEs.length < 20}
            onClick={() =>
              run(
                "admin_publish_waiver",
                { p_slug: slug, p_body_en: bodyEn, p_body_es: bodyEs },
                t("published"),
              )
            }
          >
            {t("publish")}
          </Button>
        </Card>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">{t("blockTitle")}</h2>
        <Card className="space-y-3">
          <Field label={t("blockPhone")} hint={t("blockHint")} htmlFor="block-phone">
            <TextInput
              id="block-phone"
              value={blockPhone}
              placeholder="+12815550123"
              onChange={(event) => setBlockPhone(event.target.value)}
            />
          </Field>
          <Field label={t("blockReason")} htmlFor="block-reason">
            <TextInput
              id="block-reason"
              value={blockReason}
              onChange={(event) => setBlockReason(event.target.value)}
            />
          </Field>
          <div className="flex gap-2">
            <Button
              type="button"
              variant="danger"
              className="flex-1"
              disabled={busy || !blockPhone}
              onClick={() =>
                run(
                  "admin_block_phone",
                  { p_phone: blockPhone, p_reason: blockReason || null },
                  t("blocked"),
                )
              }
            >
              {t("block")}
            </Button>
            <Button
              type="button"
              variant="secondary"
              className="flex-1"
              disabled={busy || !blockPhone}
              onClick={() => run("admin_unblock_phone", { p_phone: blockPhone }, t("unblocked"))}
            >
              {t("unblock")}
            </Button>
          </div>
        </Card>
      </section>
    </div>
  );
}
