"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

import { adminAction } from "./use-admin";

type SecurityState = {
  ok: boolean;
  required: boolean;
  enrolled: number;
  current_aal: string;
  admins_with_mfa: number;
  admins_total: number;
};

type Factor = { id: string; friendly_name: string | null; status: string };

type Enrolling = { factorId: string; qr: string; secret: string };

/**
 * Second factor for administrators.
 *
 * An admin account can approve volunteers, read every requester's phone number and exact
 * location, ban people, and edit the waiver text everybody has legally accepted. A password is
 * thin protection for that.
 *
 * The screen insists on the order that cannot lock anybody out: enrol, sign in again so the
 * session is actually at aal2, and only then switch enforcement on. The database refuses to
 * accept the switch from an unchallenged session anyway, but a screen that lets you try and then
 * explains the refusal is a worse experience than one that does not offer it yet.
 */
export function AdminSecurity() {
  const t = useTranslations("admin.security");

  const [state, setState] = useState<SecurityState | null>(null);
  const [factors, setFactors] = useState<Factor[]>([]);
  const [enrolling, setEnrolling] = useState<Enrolling | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    const { data, error: rpcError } = await supabase.rpc("admin_security_state");
    if (rpcError) {
      setError(rpcError.message);
    } else {
      setState(data as SecurityState);
    }

    const { data: factorData } = await supabase.auth.mfa.listFactors();
    setFactors(((factorData?.totp ?? []) as Factor[]).filter((f) => f.status === "verified"));
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function startEnrolment() {
    setBusy(true);
    setError(null);
    setNote(null);

    const { data, error: enrolError } = await supabaseBrowser().auth.mfa.enroll({
      factorType: "totp",
      friendlyName: `Winch Up ${new Date().toISOString().slice(0, 10)}`,
    });

    setBusy(false);

    if (enrolError || !data) {
      setError(enrolError?.message ?? "enrol_failed");
      return;
    }

    setEnrolling({ factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
  }

  async function confirmEnrolment(event: React.FormEvent) {
    event.preventDefault();
    if (!enrolling || busy) return;

    setBusy(true);
    setError(null);

    const supabase = supabaseBrowser();

    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({
      factorId: enrolling.factorId,
    });

    if (challengeError || !challenge) {
      setBusy(false);
      setError(challengeError?.message ?? "challenge_failed");
      return;
    }

    const { error: verifyError } = await supabase.auth.mfa.verify({
      factorId: enrolling.factorId,
      challengeId: challenge.id,
      code: code.trim(),
    });

    setBusy(false);

    if (verifyError) {
      setError("bad_code");
      return;
    }

    setEnrolling(null);
    setCode("");
    setNote("enrolled");
    await load();
  }

  async function removeFactor(factorId: string) {
    setBusy(true);
    setError(null);
    const { error: unenrolError } = await supabaseBrowser().auth.mfa.unenroll({ factorId });
    setBusy(false);
    if (unenrolError) {
      setError(unenrolError.message);
      return;
    }
    await load();
  }

  async function setRequired(required: boolean) {
    setBusy(true);
    setError(null);
    setNote(null);
    const result = await adminAction("admin_set_mfa_required", { p_required: required });
    setBusy(false);
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }
    await load();
  }

  if (!state) return null;

  const atAal2 = state.current_aal === "aal2";
  const canEnforce = atAal2 && state.enrolled > 0;

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-base text-ink-soft">{t("body")}</p>
      </div>

      {error ? <Callout tone="danger">{t.has(`errors.${error}`) ? t(`errors.${error}`) : error}</Callout> : null}
      {note === "enrolled" ? <Callout tone="good">{t("enrolledNote")}</Callout> : null}

      <Card className="space-y-3">
        <h3 className="text-lg font-semibold">{t("yourFactors")}</h3>

        {factors.length === 0 ? (
          <p className="text-base text-ink-soft">{t("noFactors")}</p>
        ) : (
          <ul className="space-y-2">
            {factors.map((factor) => (
              <li
                key={factor.id}
                className="flex items-center justify-between gap-3 rounded-field border-2 border-line p-3"
              >
                <span className="text-base">{factor.friendly_name ?? t("authenticatorApp")}</span>
                <Button variant="danger" onClick={() => removeFactor(factor.id)} disabled={busy}>
                  {t("remove")}
                </Button>
              </li>
            ))}
          </ul>
        )}

        {enrolling ? (
          <form onSubmit={confirmEnrolment} className="space-y-3">
            <p className="text-base">{t("scanIt")}</p>
            {/* eslint-disable-next-line @next/next/no-img-element -- a data: URI from Supabase */}
            <img
              src={enrolling.qr}
              alt={t("qrAlt")}
              className="h-48 w-48 rounded-field bg-white p-2"
            />
            <p className="text-sm text-ink-faint">
              {t("orTypeIt")} <code className="break-all">{enrolling.secret}</code>
            </p>
            <Field label={t("codeLabel")} hint={t("codeHint")}>
              <TextInput
                inputMode="numeric"
                autoComplete="one-time-code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                maxLength={6}
              />
            </Field>
            <div className="flex flex-col gap-2 sm:flex-row">
              <Button type="submit" disabled={busy || code.trim().length < 6}>
                {busy ? t("working") : t("confirm")}
              </Button>
              <Button type="button" variant="secondary" onClick={() => setEnrolling(null)}>
                {t("cancel")}
              </Button>
            </div>
          </form>
        ) : (
          <Button onClick={startEnrolment} disabled={busy}>
            {t("addFactor")}
          </Button>
        )}
      </Card>

      <Card className="space-y-3">
        <h3 className="text-lg font-semibold">{t("enforcementTitle")}</h3>
        <p className="text-base text-ink-soft">{t("enforcementBody")}</p>

        <p className="text-base">
          {t("adminsCovered", { with: state.admins_with_mfa, total: state.admins_total })}
        </p>

        {state.required ? (
          <>
            <Callout tone="good">{t("enforcementOn")}</Callout>
            <Button variant="secondary" onClick={() => setRequired(false)} disabled={busy}>
              {t("turnOff")}
            </Button>
          </>
        ) : (
          <>
            <Callout tone="danger">{t("enforcementOff")}</Callout>
            {canEnforce ? (
              <Button onClick={() => setRequired(true)} disabled={busy}>
                {t("turnOn")}
              </Button>
            ) : (
              // Not a disabled button with a tooltip: say which step is missing.
              <Callout tone="neutral">
                {state.enrolled === 0 ? t("enrolFirst") : t("signInAgainFirst")}
              </Callout>
            )}
          </>
        )}
      </Card>
    </div>
  );
}
