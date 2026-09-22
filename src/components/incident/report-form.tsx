"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { reportIncident, reportIncidentByToken } from "@/app/actions/incident";
import { Button, Callout, Card, Field, TextArea } from "@/components/ui/primitives";

const CATEGORIES = [
  "asked_for_money",
  "unsafe_behavior",
  "no_show",
  "property_damage",
  "injury",
  "harassment",
  "impersonation",
  "other",
] as const;

/**
 * Reporting what went wrong.
 *
 * Collapsed to a single link until someone opens it. Most people never need this, and a form
 * sitting open on a status page reads as an accusation waiting to happen.
 *
 * Two modes, because there are two kinds of participant. A requester reports with their status
 * link -- no password, an hour after being pulled out of a ditch. A volunteer reports from their
 * own session.
 */
export function ReportForm({ token, requestId }: { token?: string; requestId?: string }) {
  const t = useTranslations("report");
  const tEnum = useTranslations("enum.incidentCategory");

  const [open, setOpen] = useState(false);
  const [category, setCategory] = useState<string>("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const valid = category !== "" && description.trim().length >= 10;

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!valid || busy) return;

    setBusy(true);
    setError(null);

    const result = token
      ? await reportIncidentByToken(token, category, description)
      : await reportIncident(category, description, requestId);

    setBusy(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    setDone(true);
  }

  if (done) {
    return (
      <Callout tone="good">
        <p className="text-lg font-semibold">{t("thanksTitle")}</p>
        <p className="mt-1">{t("thanksBody")}</p>
      </Callout>
    );
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="text-base text-ink-faint underline underline-offset-4"
      >
        {t("openLink")}
      </button>
    );
  }

  return (
    <Card className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      {error ? <Callout tone="danger">{t("errors." + error)}</Callout> : null}

      <form onSubmit={submit} className="space-y-4">
        <Field label={t("categoryLabel")}>
          <div className="space-y-2">
            {CATEGORIES.map((key) => (
              <label
                key={key}
                htmlFor={"incident-" + key}
                className={`flex cursor-pointer items-center gap-3 rounded-field border-2 p-3 ${
                  category === key ? "border-brand bg-brand-tint" : "border-line"
                }`}
              >
                <input
                  id={"incident-" + key}
                  type="radio"
                  name="incident-category"
                  value={key}
                  checked={category === key}
                  onChange={() => setCategory(key)}
                  className="h-6 w-6 shrink-0 accent-brand"
                />
                <span className="text-base">{tEnum(key)}</span>
              </label>
            ))}
          </div>
        </Field>

        <Field label={t("whatHappened")} hint={t("whatHappenedHint")}>
          <TextArea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            maxLength={2000}
            rows={5}
            required
          />
        </Field>

        <div className="flex flex-col gap-2 sm:flex-row">
          <Button type="submit" size="lg" disabled={!valid || busy}>
            {busy ? t("sending") : t("send")}
          </Button>
          <Button type="button" variant="secondary" size="lg" onClick={() => setOpen(false)}>
            {t("cancel")}
          </Button>
        </div>
      </form>
    </Card>
  );
}
