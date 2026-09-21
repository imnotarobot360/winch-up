"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

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
  const router = useRouter();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

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
        options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
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
    setBusy(false);

    if (signInError) {
      setError(signInError.status === 400 ? "bad_credentials" : "signin_failed");
      return;
    }

    router.push("/me");
    router.refresh();
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
