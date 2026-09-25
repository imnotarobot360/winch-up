"use client";

import { useState } from "react";
import { useLocale, useTranslations } from "next-intl";

import { Button, Callout, Field, TextInput } from "@/components/ui/primitives";
import { Link, useRouter } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Mode = "signin" | "signup";

/**
 * Email and password, for both signing in and signing up.
 *
 * One component for both because the two forms differ by one field and one call; two components
 * would mean two places to get the error handling wrong.
 *
 * Errors are mapped to our own keys rather than shown raw. Supabase's messages are English-only,
 * and some of them ("User already registered") tell an attacker whether an address has an
 * account here -- see the signup branch below.
 */
export function AuthForm({ mode }: { mode: Mode }) {
  const t = useTranslations("auth");
  const locale = useLocale();
  const router = useRouter();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  // Set when the account has a second factor and this session has not used it yet.
  const [mfaFactorId, setMfaFactorId] = useState<string | null>(null);
  const [code, setCode] = useState("");

  const valid = /^\S+@\S+\.\S+$/.test(email) && password.length >= 8;

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!valid || busy) return;

    setBusy(true);
    setError(null);

    const supabase = supabaseBrowser();

    if (mode === "signup") {
      const { error: signUpError } = await supabase.auth.signUp({
        email,
        password,
        options: {
          emailRedirectTo: `${window.location.origin}/auth/callback`,
          // The only place the member ever tells us their language. There is no locale column on
          // profiles -- it is a URL segment -- and the welcome email is queued by a database
          // trigger on email confirmation, long after this tab is gone. Without this the trigger
          // has nothing to read and every welcome email is English. See 20260924000300.
          data: { locale },
        },
      });

      setBusy(false);

      if (signUpError) {
        setError(signUpError.status === 422 ? "weak_password" : "signup_failed");
        return;
      }

      // Shown whether or not the address was already registered. Supabase does not say which,
      // and neither do we: "that email is taken" is an account-enumeration oracle.
      setSent(true);
      return;
    }

    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });

    if (signInError) {
      setBusy(false);
      setError(signInError.status === 400 ? "bad_credentials" : "signin_failed");
      return;
    }

    // A password is only the first factor. If this account has an authenticator, the session is
    // at aal1 and Supabase will tell us it could be at aal2 -- which is exactly the state the
    // admin gate refuses once enforcement is on.
    const { data: level } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();

    if (level?.nextLevel === "aal2" && level.currentLevel !== "aal2") {
      const { data: factors } = await supabase.auth.mfa.listFactors();
      const factor = factors?.totp?.find((f) => f.status === "verified");

      setBusy(false);

      if (!factor) {
        // Enrolled but unusable. Better to say so than to drop them into a console that will
        // refuse every action without explaining why.
        setError("mfa_unavailable");
        return;
      }

      setMfaFactorId(factor.id);
      return;
    }

    setBusy(false);
    router.push("/me");
    router.refresh();
  }

  async function submitCode(event: React.FormEvent) {
    event.preventDefault();
    if (!mfaFactorId || busy) return;

    setBusy(true);
    setError(null);

    const supabase = supabaseBrowser();

    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({
      factorId: mfaFactorId,
    });

    if (challengeError || !challenge) {
      setBusy(false);
      setError("challenge_failed");
      return;
    }

    const { error: verifyError } = await supabase.auth.mfa.verify({
      factorId: mfaFactorId,
      challengeId: challenge.id,
      code: code.trim(),
    });

    setBusy(false);

    if (verifyError) {
      setError("bad_code");
      return;
    }

    router.push("/me");
    router.refresh();
  }

  if (mfaFactorId) {
    return (
      <form onSubmit={submitCode} className="space-y-4" noValidate>
        {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

        <p className="text-lg">{t("mfaPrompt")}</p>

        <Field label={t("mfaLabel")} hint={t("mfaHint")}>
          <TextInput
            inputMode="numeric"
            autoComplete="one-time-code"
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value)}
            maxLength={6}
          />
        </Field>

        <Button type="submit" size="lg" disabled={busy || code.trim().length < 6}>
          {busy ? t("working") : t("mfaSubmit")}
        </Button>
      </form>
    );
  }

  if (sent) {
    return (
      <Callout tone="good">
        <p className="text-lg font-semibold">{t("checkEmailTitle")}</p>
        <p className="mt-1">{t("checkEmailBody", { email })}</p>
      </Callout>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      <Field label={t("emailLabel")}>
        <TextInput
          type="email"
          name="email"
          autoComplete="email"
          inputMode="email"
          autoCapitalize="none"
          spellCheck={false}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
      </Field>

      <Field label={t("passwordLabel")} hint={mode === "signup" ? t("passwordHint") : undefined}>
        <TextInput
          type="password"
          name="password"
          // new-password on signup stops password managers offering the old one, and prompts
          // them to generate a strong one.
          autoComplete={mode === "signup" ? "new-password" : "current-password"}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
          minLength={8}
        />
      </Field>

      <Button type="submit" size="lg" disabled={!valid || busy}>
        {busy ? t("working") : t(mode === "signup" ? "createAccount" : "signIn")}
      </Button>

      <div className="flex flex-wrap justify-between gap-3 pt-2 text-base">
        {mode === "signin" ? (
          <>
            <Link href="/reset" className="text-brand-text underline underline-offset-4">
              {t("forgot")}
            </Link>
            <Link href="/signup" className="text-brand-text underline underline-offset-4">
              {t("needAccount")}
            </Link>
          </>
        ) : (
          <Link href="/signin" className="text-brand-text underline underline-offset-4">
            {t("haveAccount")}
          </Link>
        )}
      </div>
    </form>
  );
}
