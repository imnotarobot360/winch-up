"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";
import { toE164Us } from "@/lib/utils";

/**
 * Admins sign in the same way volunteers do: phone OTP. There is no password anywhere in this
 * product, which is one fewer thing to leak.
 *
 * Being signed in is not the same as being an admin. The `user_roles` check happens server-side
 * in the admin layout and again inside every `admin_*` RPC.
 */
export function AdminSignIn({ reason }: { reason: "signed_out" | "not_admin" }) {
  const t = useTranslations("admin.signin");

  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const e164 = toE164Us(phone);

  async function sendCode() {
    if (!e164) return;
    setBusy(true);
    setError(null);

    const { error: otpError } = await supabaseBrowser().auth.signInWithOtp({
      phone: e164,
      options: { channel: "sms", shouldCreateUser: false },
    });

    setBusy(false);

    if (otpError) {
      setError("send_failed");
      return;
    }

    setSent(true);
  }

  async function verify() {
    if (!e164) return;
    setBusy(true);
    setError(null);

    const { error: verifyError } = await supabaseBrowser().auth.verifyOtp({
      phone: e164,
      token: code.trim(),
      type: "sms",
    });

    setBusy(false);

    if (verifyError) {
      setError("bad_code");
      return;
    }

    // Full reload so the server layout re-runs its admin check with the new session cookie.
    window.location.reload();
  }

  return (
    <main className="mx-auto w-full max-w-md space-y-5 px-4 py-12">
      <h1 className="text-2xl font-bold">{t("title")}</h1>

      {reason === "not_admin" ? <Callout tone="danger">{t("notAdmin")}</Callout> : null}
      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      <Card className="space-y-4">
        {!sent ? (
          <>
            <Field label={t("phoneLabel")} htmlFor="admin-phone">
              <TextInput
                id="admin-phone"
                type="tel"
                inputMode="tel"
                value={phone}
                onChange={(event) => setPhone(event.target.value)}
              />
            </Field>
            <Button type="button" disabled={busy || !e164} onClick={sendCode}>
              {busy ? t("sending") : t("sendCode")}
            </Button>
          </>
        ) : (
          <>
            <Field label={t("codeLabel")} htmlFor="admin-code">
              <TextInput
                id="admin-code"
                inputMode="numeric"
                autoComplete="one-time-code"
                value={code}
                onChange={(event) => setCode(event.target.value)}
              />
            </Field>
            <Button type="button" disabled={busy} onClick={verify}>
              {busy ? t("checking") : t("verify")}
            </Button>
          </>
        )}
      </Card>
    </main>
  );
}
