"use client";

import { useState } from "react";
import { useLocale, useTranslations } from "next-intl";

import { signMembershipAction } from "@/app/actions/membership";
import { Button, Callout, Checkbox, Field, TextInput } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

/**
 * Reading the agreement and signing it.
 *
 * Three things here are requirements rather than taste, and should not be tidied away:
 *
 *  1. Both boxes start UNCHECKED and are never pre-filled (requirement 4). A pre-ticked consent
 *     box is not consent, and a "select all" convenience would amount to one.
 *
 *  2. The risk summary sits ABOVE the document, in a danger callout, in its own words
 *     (requirement 5). Burying assumption of risk in clause fourteen of a wall of text is the
 *     normal way to do this and it is exactly what the spec rules out. The callout does not
 *     replace the agreement -- the full text is right below it -- it makes sure the part that
 *     can get somebody killed is the part nobody can miss.
 *
 *  3. The signature field is separate from the legal-name field and must match it. Typing your
 *     name twice is friction on purpose: it is the moment the form stops being a form.
 *
 * The download is built from the same string that is rendered, not fetched again, so the copy
 * somebody keeps is definitionally the copy they were shown.
 */
export function AgreementForm({
  version,
  body,
  bodyHash,
  effectiveAt,
}: {
  version: number;
  body: string;
  bodyHash: string;
  effectiveAt: string | null;
}) {
  const t = useTranslations("membership");
  const locale = useLocale();

  const [riskAck, setRiskAck] = useState(false);
  const [accepted, setAccepted] = useState(false);
  const [legalName, setLegalName] = useState("");
  const [signature, setSignature] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [declining, setDeclining] = useState(false);

  function download() {
    const header = [
      t("title"),
      t("version", { version }),
      effectiveAt ? t("effective", { date: new Date(effectiveAt).toLocaleDateString(locale) }) : "",
      t("documentRef", { hash: bodyHash }),
      "",
      "",
    ].join("\n");

    const url = URL.createObjectURL(
      new Blob([header + body], { type: "text/plain;charset=utf-8" }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = `winch-up-membership-agreement-v${version}.txt`;
    a.click();
    URL.revokeObjectURL(url);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    // Checked here as well as on the server because the server never sees these two boxes --
    // they are the member's attestation that they read it, and there is nothing for the
    // database to verify about them. What the database does verify is the signature itself.
    if (!riskAck || !accepted) {
      setError(t("errors.not_accepted"));
      return;
    }

    setBusy(true);
    const result = await signMembershipAction({
      legalName,
      signatureText: signature,
      bodyHash,
      locale,
    });
    setBusy(false);

    if (!result.ok) {
      const key = `errors.${result.error}` as const;
      // A server error we have no copy for still has to say something true.
      const message = t.has(key) ? t(key) : t("errors.server_error");
      setError(message);
      return;
    }

    // A FULL NAVIGATION, not router.refresh().
    //
    // The confirmation -- the date, the legal name, the document reference -- is rendered by
    // the server component on this page, so the member only learns their signature was
    // recorded when the page re-renders. On WebKit router.refresh() did not produce it: the
    // row was written, the action returned ok, and the form sat there unchanged with no error.
    // Somebody signing a legal document on an iPhone was shown nothing at all, and the
    // reasonable response to that is to sign it again.
    //
    // It cost a reproducible [iphone] failure in membership-agreement.spec.ts that looked for
    // all the world like a broken write, and was only settled by reading the table: the
    // signature for version 33 was there, timestamped, while the screen still asked for it.
    //
    // A reload is the right instrument rather than a fallback. This happens once per version of
    // one document, and signing changes the home banner and what /request will let you do --
    // all of it server-rendered, all of it needing to be re-evaluated. There is nothing on this
    // page worth preserving across it.
    window.location.reload();
  }

  if (declining) {
    return (
      <Callout tone="neutral" className="space-y-3">
        <h2 className="text-xl font-bold">{t("declineHeading")}</h2>
        <p className="leading-relaxed">{t("declineBody")}</p>
        <div className="flex flex-col gap-2 pt-1 sm:flex-row">
          <Link href="/account" className="w-full">
            <Button variant="secondary" size="md">
              {t("declineLeave")}
            </Button>
          </Link>
          <Button variant="quiet" size="md" onClick={() => setDeclining(false)}>
            {t("declineBack")}
          </Button>
        </div>
      </Callout>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-5">
      {/* Requirement 5: above the document, not inside it. */}
      <Callout tone="danger" className="space-y-2">
        <h2 className="text-lg font-bold">{t("riskHeading")}</h2>
        <p className="leading-relaxed">{t("riskBody")}</p>
      </Callout>

      <div className="flex flex-wrap items-center gap-3 text-sm text-ink-faint">
        <span>{t("version", { version })}</span>
        {effectiveAt ? (
          <span>{t("effective", { date: new Date(effectiveAt).toLocaleDateString(locale) })}</span>
        ) : null}
        <Button type="button" variant="quiet" size="md" className="w-auto" onClick={download}>
          {t("download")}
        </Button>
      </div>

      <article
        // Scrollable rather than collapsed: the whole document is present and reachable by
        // keyboard and by a screen reader. tabIndex makes the region focusable so it can be
        // scrolled without a mouse, which an unfocusable overflow container cannot be.
        tabIndex={0}
        className="max-h-[28rem] overflow-y-auto rounded-xl border-2 border-line bg-surface-sunk p-4 text-base leading-relaxed whitespace-pre-wrap"
      >
        {body}
      </article>

      <p className="text-sm text-ink-faint">{t("consentNote")}</p>

      <Checkbox id="risk-ack" checked={riskAck} onChange={setRiskAck}>
        {t("riskAck")}
      </Checkbox>

      <Checkbox id="agreement-accept" checked={accepted} onChange={setAccepted}>
        {t("acceptLabel")}
      </Checkbox>

      <Field label={t("legalNameLabel")} hint={t("legalNameHint")}>
        <TextInput
          value={legalName}
          autoComplete="name"
          onChange={(e) => setLegalName(e.target.value)}
        />
      </Field>

      <Field label={t("signatureLabel")} hint={t("signatureHint")}>
        <TextInput
          value={signature}
          // Never autocompleted. The point of typing it a second time is that it is deliberate.
          autoComplete="off"
          onChange={(e) => setSignature(e.target.value)}
        />
      </Field>

      {error ? (
        <Callout tone="danger" role="alert">
          {error}
        </Callout>
      ) : null}

      <Button type="submit" disabled={busy}>
        {busy ? t("submitting") : t("submit")}
      </Button>

      <Button type="button" variant="quiet" size="md" onClick={() => setDeclining(true)}>
        {t("decline")}
      </Button>
    </form>
  );
}
