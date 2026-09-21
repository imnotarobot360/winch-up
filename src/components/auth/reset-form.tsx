"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Field, TextInput } from "@/components/ui/primitives";
import { Link, useRouter } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Password reset, both halves.
 *
 * Which half shows depends on whether Supabase has put a recovery session in place: following
 * the emailed link signs the browser in with a short-lived session whose only useful power is
 * changing the password. So we ask Supabase what it has rather than reading the URL, which
 * differs between the hash and PKCE flows.
 */
export function ResetForm() {
  const t = useTranslations("auth");
  const router = useRouter();

  const [phase, setPhase] = useState<"checking" | "request" | "set">("checking");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    supabaseBrowser()
      .auth.getSession()
      .then(({ data }) => {
        if (alive) setPhase(data.session ? "set" : "request");
      });
    return () => {
      alive = false;
    };
  }, []);

  async function requestLink(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);

    await supabaseBrowser().auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset`,
    });

    setBusy(false);
    // Always the same answer, sent or not: whether an address has an account here is not
    // something an unauthenticated form should reveal.
    setSent(true);
  }

  async function setNewPassword(event: React.FormEvent) {
    event.preventDefault();
    if (busy || password.length < 8) return;
    setBusy(true);
    setError(null);

    const { error: updateError } = await supabaseBrowser().auth.updateUser({ password });
    setBusy(false);

    if (updateError) {
      setError("reset_failed");
      return;
    }

    router.push("/me");
    router.refresh();
  }

  if (phase === "checking") return null;

  if (sent) {
    return (
      <Callout tone="good">
        <p className="text-lg font-semibold">{t("resetSentTitle")}</p>
        <p className="mt-1">{t("resetSentBody")}</p>
      </Callout>
    );
  }

  if (phase === "set") {
    return (
      <form onSubmit={setNewPassword} className="space-y-4" noValidate>
        {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}
        <Field label={t("newPasswordLabel")} hint={t("passwordHint")}>
          <TextInput
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            minLength={8}
          />
        </Field>
        <Button type="submit" size="lg" disabled={busy || password.length < 8}>
          {busy ? t("working") : t("savePassword")}
        </Button>
      </form>
    );
  }

  return (
    <form onSubmit={requestLink} className="space-y-4" noValidate>
      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}
      <Field label={t("emailLabel")} hint={t("resetHint")}>
        <TextInput
          type="email"
          autoComplete="email"
          inputMode="email"
          autoCapitalize="none"
          spellCheck={false}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
      </Field>
      <Button type="submit" size="lg" disabled={busy || !/^\S+@\S+\.\S+$/.test(email)}>
        {busy ? t("working") : t("sendResetLink")}
      </Button>
      <Link href="/signin" className="block pt-2 text-base text-brand-text underline underline-offset-4">
        {t("backToSignIn")}
      </Link>
    </form>
  );
}
