"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * You are an admin; this session has not been challenged.
 *
 * A SEPARATE SCREEN FROM AdminSignIn, not a third `reason` on it. That component is a phone-OTP
 * form, and showing it here would be wrong twice: the person is already signed in, and its OTP path
 * does not do the second-factor step-up at all -- Supabase returns a session at aal1 with
 * `nextLevel: aal2`, so following it would land them right back here, having done work.
 *
 * The one path that does step up is /signin, whose form checks
 * `getAuthenticatorAssuranceLevel()` after the password and asks for the authenticator code. So the
 * instruction is to sign out and go there, and the button does exactly that rather than describing
 * it.
 *
 * WHY THIS EXISTS AT ALL. With enforcement on and a session at aal1, a real admin used to pass the
 * layout's role check, get the whole console, and find every screen showing an empty list -- each
 * RPC behind them raising `mfa_required`, which nothing in the app rendered. Locked and broken look
 * identical from the outside, and only one of them is worth a support message.
 */
export function AdminNeedsMfa() {
  const t = useTranslations("admin.mfa");
  const [busy, setBusy] = useState(false);

  async function signOutAndIn() {
    setBusy(true);
    await supabaseBrowser().auth.signOut();
    // A full navigation, not a client push: the admin layout is server-rendered and its gate has
    // to run again with the new (absent) session.
    window.location.href = "/signin";
  }

  return (
    <Card className="space-y-4 p-4">
      <h2 className="text-xl font-semibold text-ink">{t("title")}</h2>
      <Callout tone="neutral">{t("why")}</Callout>
      <p className="text-base text-ink-soft">{t("what")}</p>
      <Button onClick={signOutAndIn} disabled={busy}>
        {busy ? t("signingOut") : t("signOutAndIn")}
      </Button>
    </Card>
  );
}
