"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Callout } from "@/components/ui/primitives";
import type { SocialProvider } from "@/lib/auth/social-providers";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Continue with Apple, Google or Facebook.
 *
 * Renders nothing at all when no provider is configured, which is the state this ships in. The
 * caller decides -- see enabledSocialProviders() for why the dashboard, not this repo, is the
 * source of truth.
 *
 * NO PROVIDER SECRET IS INVOLVED. The OAuth client id and secret live in Supabase and never
 * reach the browser; signInWithOAuth only asks Supabase to begin the flow, and Supabase does
 * the exchange server-side. There is nothing here to leak.
 *
 * THE WAIVER IS NOT BYPASSED BY THIS ROUTE, which is the spec's one hard rule about social
 * login. Every provider lands on /auth/callback, the same PKCE callback the emailed link uses,
 * and that route already checks the membership agreement and diverts to /agreement before
 * anything else. It was written for email verification and covers OAuth for free, because the
 * check is on the SESSION rather than on how the session was obtained. The server-side gate in
 * create_request and offer_assistance is the second line and does not care either.
 */
export function SocialButtons({ providers }: { providers: SocialProvider[] }) {
  const t = useTranslations("auth.social");
  const [busy, setBusy] = useState<SocialProvider | null>(null);
  const [error, setError] = useState(false);

  if (providers.length === 0) return null;

  async function start(provider: SocialProvider) {
    setBusy(provider);
    setError(false);

    const { error: oauthError } = await supabaseBrowser().auth.signInWithOAuth({
      provider,
      options: {
        // EXACTLY the URL the email flow uses, with no query string, and that is deliberate.
        //
        // Supabase matches redirect_to against an allowlist in its dashboard. The bare callback
        // is already on it -- email verification has worked in production for days -- but an
        // entry registered as an exact URL does not match that same URL carrying `?next=...`.
        // Supabase then silently falls back to the Site URL, and the symptom is "Google
        // sign-in sends me to the wrong page", with nothing in any log to explain it.
        //
        // Nothing needs to ride in the query string anyway: the callback sends everybody to
        // /me, and next-intl resolves the language from its own cookie.
        redirectTo: `${window.location.origin}/auth/callback`,
      },
    });

    if (oauthError) {
      // Includes the member closing the provider's window, which is not an error worth
      // shouting about -- the button simply becomes pressable again.
      setBusy(null);
      setError(true);
    }
    // No else: on success the browser is already navigating away.
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-3" aria-hidden>
        <span className="h-px flex-1 bg-line" />
        <span className="text-sm text-ink-faint">{t("divider")}</span>
        <span className="h-px flex-1 bg-line" />
      </div>

      {error ? (
        <Callout tone="danger" role="alert">
          {t("failed")}
        </Callout>
      ) : null}

      <div className="flex flex-col gap-2">
        {providers.map((p) => (
          <button
            key={p}
            type="button"
            disabled={busy !== null}
            onClick={() => start(p)}
            className="tap-target flex w-full items-center justify-center gap-3 rounded-field border-2 border-line bg-surface px-4 text-base font-semibold text-ink transition-colors hover:bg-surface-sunk disabled:cursor-not-allowed disabled:text-ink-faint"
          >
            <ProviderMark provider={p} />
            {busy === p ? t("opening") : t(`continueWith.${p}`)}
          </button>
        ))}
      </div>
    </div>
  );
}

/**
 * The provider marks.
 *
 * Drawn rather than loaded: three remote logo files would be three more requests on the slowest
 * screen in the app, and each provider's brand guidelines forbid recolouring their asset --
 * which a dark UI would otherwise be tempted to do. These are monochrome glyphs in currentColor,
 * which is what the guidelines permit and what matches every other icon here.
 */
function ProviderMark({ provider }: { provider: SocialProvider }) {
  const common = {
    width: 20,
    height: 20,
    viewBox: "0 0 24 24",
    "aria-hidden": true,
    focusable: "false" as const,
    className: "shrink-0",
  };

  if (provider === "apple") {
    return (
      <svg {...common} fill="currentColor">
        <path d="M16.3 12.8c0-2.2 1.8-3.3 1.9-3.3-1-1.5-2.6-1.7-3.2-1.7-1.4-.1-2.7.8-3.3.8-.7 0-1.7-.8-2.8-.8-1.5 0-2.8.8-3.6 2.1-1.5 2.6-.4 6.5 1.1 8.6.7 1 1.6 2.2 2.7 2.2 1.1 0 1.5-.7 2.8-.7s1.6.7 2.8.7c1.1 0 1.9-1 2.6-2.1.8-1.2 1.1-2.3 1.2-2.4-.1 0-2.2-.9-2.2-3.4zM14.3 6.3c.6-.7 1-1.7.9-2.7-.9 0-2 .6-2.6 1.3-.6.6-1.1 1.6-.9 2.6 1 .1 2-.5 2.6-1.2z" />
      </svg>
    );
  }

  // Google's mark is multi-colour by brand guideline and must not be recoloured, so it is the
  // one exception to currentColor here. It is also the fallback branch: SOCIAL_PROVIDERS has
  // exactly two members, so anything that is not Apple is Google.
  return (
    <svg {...common}>
      <path fill="#4285F4" d="M21.6 12.2c0-.7-.1-1.4-.2-2H12v3.9h5.4a4.6 4.6 0 0 1-2 3v2.5h3.2c1.9-1.7 3-4.3 3-7.4z" />
      <path fill="#34A853" d="M12 22c2.7 0 5-.9 6.6-2.4l-3.2-2.5c-.9.6-2 1-3.4 1-2.6 0-4.8-1.8-5.6-4.1H3.1v2.6A10 10 0 0 0 12 22z" />
      <path fill="#FBBC05" d="M6.4 14a6 6 0 0 1 0-3.8V7.6H3.1a10 10 0 0 0 0 8.9L6.4 14z" />
      <path fill="#EA4335" d="M12 5.9c1.5 0 2.8.5 3.8 1.5l2.8-2.8A10 10 0 0 0 3.1 7.6l3.3 2.6C7.2 7.8 9.4 5.9 12 5.9z" />
    </svg>
  );
}
