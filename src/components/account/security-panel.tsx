"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { useRouter } from "@/i18n/navigation";
import { confirmPhoneCode, sendPhoneCode } from "@/lib/auth/link-phone";
import type { SocialProvider } from "@/lib/auth/social-providers";
import { supabaseBrowser, supabaseThrowaway } from "@/lib/supabase/client";
import { formatUsPhone, toE164Us } from "@/lib/utils";

type SecurityState = {
  email: string;
  email_confirmed: boolean;
  phone: string;
  phone_confirmed: boolean;
  has_password: boolean;
  providers: string[];
  methods: number;
};

type Busy = null | "password" | "phone" | "code" | "signout" | SocialProvider;

/**
 * Account & Security.
 *
 * WHAT THIS SCREEN IS FOR: a member should be able to see every way into their account in one
 * place, and change any of them, without having to remember which one they used to sign up.
 *
 * THE ONE RULE IT MUST NEVER BREAK: never let somebody remove their last way in. There is no
 * support desk behind this product -- no one can restore an account by checking a driving
 * licence -- so a member locked out is locked out permanently, along with their recovery
 * history and their signed waiver. Every removal is therefore checked against a count that
 * comes from the DATABASE (my_security_state), not from the session object, and is re-read
 * after every change. A stale count is the thing that locks somebody out.
 *
 * The count deliberately does NOT treat a confirmed email as a way in; the reasoning is in the
 * migration, and it is the difference between refusing a removal that might have been
 * survivable and permanently orphaning an account.
 *
 * WHAT IS NOT HERE, and why rather than silently:
 *
 *   Changing the email address. supabase.auth.updateUser({ email }) is one line, but the
 *   confirmation link it sends lands on /auth/callback, which today only understands the PKCE
 *   `code` parameter. An email-change link that dead-ends leaves somebody unable to sign in
 *   with either address. The screen says so instead of offering a button that half-works.
 *
 *   Deleting the account. That stayed on /account, where it already is, tested and linked --
 *   moving it would have been churn for its own sake. There is a link to it at the bottom.
 */
export function SecurityPanel({ providers }: { providers: SocialProvider[] }) {
  const t = useTranslations("security");
  const router = useRouter();

  const [state, setState] = useState<SecurityState | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [busy, setBusy] = useState<Busy>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  // Password
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [showPassword, setShowPassword] = useState(false);

  // Phone
  const [showPhone, setShowPhone] = useState(false);
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [linking, setLinking] = useState(true);
  const [phase, setPhase] = useState<"number" | "code">("number");

  const load = useCallback(async () => {
    try {
      const { data, error: rpcError } = await supabaseBrowser().rpc("my_security_state");
      if (rpcError) {
        setLoadFailed(true);
        return;
      }
      setState(data as SecurityState);
      setLoadFailed(false);
    } catch {
      setLoadFailed(true);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  function reset(message: string) {
    setDone(message);
    setError(null);
    setBusy(null);
  }

  async function savePassword(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;
    if (next.length < 8) {
      setError("weak_password");
      return;
    }

    setBusy("password");
    setError(null);
    setDone(null);

    const supabase = supabaseBrowser();

    /**
     * Prove the current password before changing it, when there is one.
     *
     * Supabase has a "secure password change" setting that does this server-side, but it is a
     * dashboard toggle this repo cannot see or set, and a security screen whose protection
     * depends on a switch nobody here can verify is not protection. Signing in with the
     * current password is a real check that works either way.
     *
     * ON A THROWAWAY CLIENT, which is the part that is easy to get wrong. signInWithPassword
     * REPLACES the stored session, and a session that has been through MFA is at aal2 while a
     * fresh password sign-in is at aal1 -- so doing this on the normal client would quietly
     * demote an admin in the middle of changing their password and cost them admin access,
     * with nothing on screen to explain it. The throwaway client holds its session in memory
     * under a different storage key and is discarded; the real session is untouched, and the
     * updateUser below still runs on it.
     *
     * Somebody with NO password is not asked for one -- they proved who they are with Google,
     * or with a code to their handset, which is the session they are holding right now.
     */
    if (state?.has_password) {
      // By phone when there is no email. A volunteer can join by SMS and later set a password,
      // and signInWithPassword({ email: "" }) would fail as a wrong password -- telling somebody
      // their correct password is wrong, on the screen where they cannot do anything about it.
      // Supabase accepts either identifier; auth.users.phone is stored without the leading '+',
      // which signInWithPassword does not want back.
      const identifier = state.email
        ? { email: state.email }
        : { phone: state.phone.startsWith("+") ? state.phone : `+${state.phone}` };

      const { error: checkError } = await supabaseThrowaway().auth.signInWithPassword({
        ...identifier,
        password: current,
      });

      if (checkError) {
        setBusy(null);
        setError("bad_current");
        return;
      }
    }

    const { error: updateError } = await supabase.auth.updateUser({ password: next });

    if (updateError) {
      console.error("[security] password change failed", {
        status: updateError.status,
        code: updateError.code,
        message: updateError.message,
      });
      setBusy(null);
      setError(updateError.code === "weak_password" ? "weak_password" : "password_failed");
      return;
    }

    setCurrent("");
    setNext("");
    setShowPassword(false);
    reset("password_saved");
    await load();
  }

  async function startPhone(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;

    const e164 = toE164Us(phone);
    if (!e164) {
      setError("invalid_phone");
      return;
    }

    setBusy("phone");
    setError(null);
    setDone(null);

    const sent = await sendPhoneCode(supabaseBrowser(), e164, "security");

    setLinking(sent.linking);
    setBusy(null);

    if (!sent.ok) {
      setError(sent.error);
      return;
    }

    setPhase("code");
  }

  async function finishPhone(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;

    const e164 = toE164Us(phone);
    if (!e164 || code.trim().length < 4) {
      setError("bad_code");
      return;
    }

    setBusy("code");
    setError(null);

    const confirmed = await confirmPhoneCode(supabaseBrowser(), e164, code, linking, "security");

    setBusy(null);

    if (!confirmed.ok) {
      setError(confirmed.error);
      return;
    }

    setPhone("");
    setCode("");
    setPhase("number");
    setShowPhone(false);
    reset("phone_saved");
    await load();
  }

  async function connect(provider: SocialProvider) {
    setBusy(provider);
    setError(null);
    setDone(null);

    const { error: linkError } = await supabaseBrowser().auth.linkIdentity({
      provider,
      // The bare callback, with no query string. Supabase matches redirect_to against an exact
      // allowlist, and an entry registered without a query string does not match the same URL
      // carrying one -- it silently falls back to the Site URL, and the symptom is "it sent me
      // to the wrong page" with nothing in any log.
      options: { redirectTo: `${window.location.origin}/auth/callback` },
    });

    if (linkError) {
      console.error("[security] link failed", {
        provider,
        status: linkError.status,
        code: linkError.code,
        message: linkError.message,
      });
      setBusy(null);
      // Manual linking is OFF by default on a Supabase project and is a dashboard setting, not
      // anything this repo can turn on. Saying "try again" to somebody hitting that would be a
      // lie they could repeat forever.
      setError(
        /manual linking/i.test(linkError.message ?? "") ? "linking_disabled" : "link_failed",
      );
      return;
    }
    // On success the browser is already navigating to the provider.
  }

  async function disconnect(provider: SocialProvider) {
    if (!state) return;

    // Belt and braces. The button is not rendered when this would be the last method, but a
    // stale render, a double click or a second tab must not be able to get past it either.
    if (state.methods <= 1) {
      setError("last_method");
      return;
    }

    setBusy(provider);
    setError(null);
    setDone(null);

    const supabase = supabaseBrowser();
    const { data, error: listError } = await supabase.auth.getUserIdentities();
    const identity = data?.identities?.find((i) => i.provider === provider);

    if (listError || !identity) {
      setBusy(null);
      setError("unlink_failed");
      return;
    }

    const { error: unlinkError } = await supabase.auth.unlinkIdentity(identity);

    if (unlinkError) {
      console.error("[security] unlink failed", {
        provider,
        status: unlinkError.status,
        code: unlinkError.code,
        message: unlinkError.message,
      });
      setBusy(null);
      setError("unlink_failed");
      return;
    }

    reset("disconnected");
    await load();
  }

  async function signOutEverywhere() {
    setBusy("signout");
    setError(null);

    // scope: "global" revokes every refresh token on the account, which is the point: this is
    // the button for a lost phone. It ends THIS session too, so the screen navigates home
    // rather than sitting there looking signed in.
    const { error: signOutError } = await supabaseBrowser().auth.signOut({ scope: "global" });

    if (signOutError) {
      setBusy(null);
      setError("signout_failed");
      return;
    }

    router.push("/");
    router.refresh();
  }

  if (loadFailed) {
    return <Callout tone="danger">{t("loadFailed")}</Callout>;
  }

  if (!state) {
    return (
      <div className="space-y-3" aria-busy="true" aria-live="polite">
        <span className="sr-only">{t("loading")}</span>
        <div className="h-28 animate-pulse rounded-2xl bg-surface-sunk" />
        <div className="h-28 animate-pulse rounded-2xl bg-surface-sunk" />
      </div>
    );
  }

  const onlyOneWayIn = state.methods <= 1;

  return (
    <div className="space-y-5">
      {error ? (
        <Callout tone="danger" role="alert">
          {t(`errors.${error}`)}
        </Callout>
      ) : null}
      {done ? <Callout tone="good">{t(`done.${done}`)}</Callout> : null}

      {/* The summary line. A member who cannot answer "what happens if I lose my phone" has no
          way to find out otherwise -- the sign-in screen does not tell them, and neither does
          the provider. */}
      <Callout tone={onlyOneWayIn ? "brand" : "neutral"}>
        {onlyOneWayIn ? t("oneWayIn") : t("waysIn", { count: state.methods })}
      </Callout>

      <Card className="space-y-4">
        <h2 className="text-xl font-semibold">{t("methodsTitle")}</h2>

        {/* Email: shown, never changed here. See the header. */}
        <Row
          label={t("emailLabel")}
          value={state.email || t("emailNone")}
          note={
            state.email
              ? state.email_confirmed
                ? t("emailConfirmed")
                : t("emailUnconfirmed")
              : undefined
          }
        />

        <Row
          label={t("passwordLabel")}
          value={state.has_password ? t("passwordSet") : t("passwordNone")}
          note={state.has_password ? undefined : t("passwordWhy")}
          action={
            <Button variant="secondary" onClick={() => setShowPassword((v) => !v)}>
              {state.has_password ? t("passwordChange") : t("passwordSet2")}
            </Button>
          }
        />

        {showPassword ? (
          <form onSubmit={savePassword} className="space-y-3 rounded-xl bg-surface-sunk p-4">
            {state.has_password ? (
              <Field label={t("currentLabel")}>
                <TextInput
                  type="password"
                  autoComplete="current-password"
                  value={current}
                  onChange={(e) => setCurrent(e.target.value)}
                />
              </Field>
            ) : null}

            <Field label={t("newLabel")} hint={t("newHint")}>
              <TextInput
                type="password"
                autoComplete="new-password"
                value={next}
                onChange={(e) => setNext(e.target.value)}
                minLength={8}
              />
            </Field>

            <Button type="submit" disabled={busy !== null || next.length < 8}>
              {busy === "password" ? t("working") : t("save")}
            </Button>
          </form>
        ) : null}

        <Row
          label={t("phoneLabel")}
          value={
            state.phone
              ? formatUsPhone(state.phone.startsWith("+") ? state.phone : `+${state.phone}`)
              : t("phoneNone")
          }
          note={state.phone && !state.phone_confirmed ? t("phoneUnconfirmed") : undefined}
          action={
            <Button variant="secondary" onClick={() => setShowPhone((v) => !v)}>
              {state.phone ? t("phoneChange") : t("phoneAdd")}
            </Button>
          }
        />

        {showPhone ? (
          <div className="space-y-3 rounded-xl bg-surface-sunk p-4">
            {phase === "number" ? (
              <form onSubmit={startPhone} className="space-y-3">
                <Field label={t("phoneNumberLabel")} hint={t("phoneNumberHint")}>
                  <TextInput
                    type="tel"
                    inputMode="tel"
                    autoComplete="tel"
                    value={phone}
                    onChange={(e) => setPhone(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy !== null}>
                  {busy === "phone" ? t("working") : t("phoneSend")}
                </Button>
              </form>
            ) : (
              <form onSubmit={finishPhone} className="space-y-3">
                <Field label={t("codeLabel")} hint={t("codeHint")}>
                  <TextInput
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    value={code}
                    onChange={(e) => setCode(e.target.value)}
                  />
                </Field>
                <Button type="submit" disabled={busy !== null}>
                  {busy === "code" ? t("working") : t("codeSubmit")}
                </Button>
              </form>
            )}
          </div>
        ) : null}
      </Card>

      {/* Only the providers the Supabase dashboard actually has configured, read at runtime by
          the page -- the same rule the sign-in screen follows. A "Connect Apple" button that
          bounces to an error page is worse than no button. */}
      {providers.length > 0 ? (
        <Card className="space-y-4">
          <h2 className="text-xl font-semibold">{t("connectedTitle")}</h2>
          <p className="text-base text-ink-soft">{t("connectedBody")}</p>

          {providers.map((provider) => {
            const connected = state.providers.includes(provider);
            // Removing this would leave nothing: no button, and the reason said out loud.
            const lastOne = connected && state.methods <= 1;

            return (
              <Row
                key={provider}
                label={t(`provider.${provider}`)}
                value={connected ? t("connected") : t("notConnected")}
                note={lastOne ? t("cannotDisconnect") : undefined}
                action={
                  lastOne ? null : (
                    <Button
                      variant={connected ? "secondary" : "primary"}
                      disabled={busy !== null}
                      onClick={() => (connected ? disconnect(provider) : connect(provider))}
                    >
                      {busy === provider
                        ? t("working")
                        : connected
                          ? t("disconnect")
                          : t("connect")}
                    </Button>
                  )
                }
              />
            );
          })}
        </Card>
      ) : null}

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("sessionsTitle")}</h2>
        <p className="text-base text-ink-soft">{t("sessionsBody")}</p>
        <Button variant="secondary" onClick={signOutEverywhere} disabled={busy !== null}>
          {busy === "signout" ? t("working") : t("signOutAll")}
        </Button>
      </Card>
    </div>
  );
}

/**
 * One fact and what you can do about it.
 *
 * Wrapping on small screens rather than squeezing: the labels are short but the values are
 * email addresses, which do not truncate gracefully on a 360px phone in bright sun.
 */
function Row({
  label,
  value,
  note,
  action,
}: {
  label: string;
  value: string;
  note?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4 first:border-0 first:pt-0">
      <div className="min-w-0">
        <p className="text-sm text-ink-faint">{label}</p>
        <p className="break-words text-base font-semibold text-ink">{value}</p>
        {note ? <p className="mt-1 text-sm text-ink-soft">{note}</p> : null}
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}
