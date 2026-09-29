import "server-only";

/**
 * The providers this app offers, in the order the design reference draws them.
 *
 * FACEBOOK WAS REMOVED on 2026-09-29, by the owner's decision. It is deliberately absent from
 * this list rather than merely left unconfigured, so that enabling it in the Supabase dashboard
 * — by accident or by a future hand — does not make a button appear that nobody intended.
 * The list is the app's answer to "what do we offer"; the dashboard only answers "is it usable".
 *
 * The cost of the original plan was never the code: Meta needs App Review before the button
 * works for anyone but the developer, and possibly Business Verification on top. Google and
 * email/password both work, so nobody is blocked from joining.
 */
export const SOCIAL_PROVIDERS = ["apple", "google"] as const;
export type SocialProvider = (typeof SOCIAL_PROVIDERS)[number];

/**
 * Which social providers are actually usable right now.
 *
 * Read from Supabase at runtime rather than from an env var or a constant in this repo, and
 * that is the important decision here.
 *
 * A provider works only if its client id and secret are set in the Supabase dashboard. If this
 * app decided independently which buttons to draw, the two would drift, and the failure is
 * ugly: a "Continue with Google" button that bounces the member to an error page. The project's
 * own brief says no button may be decorative, and a button that cannot work is worse than
 * decorative.
 *
 * So the dashboard is the single source of truth and the UI follows it. Enabling a provider
 * makes its button appear with no deploy; disabling one makes it vanish before anybody can
 * press it.
 *
 * `/auth/v1/settings` is public and returns no secrets -- it is the same endpoint the Supabase
 * client libraries read to decide what to offer.
 */
export async function enabledSocialProviders(): Promise<SocialProvider[]> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key) return [];

  try {
    const res = await fetch(`${url}/auth/v1/settings`, {
      headers: { apikey: key },
      // Five minutes. Long enough that a busy sign-in page is not re-asking on every render,
      // short enough that turning a provider on in the dashboard shows up while somebody is
      // still sitting there wondering why it has not.
      next: { revalidate: 300 },
    });

    if (!res.ok) return [];

    const body = (await res.json()) as { external?: Record<string, boolean> };
    return SOCIAL_PROVIDERS.filter((p) => body.external?.[p] === true);
  } catch {
    // A sign-in page that will not render because a settings lookup timed out is far worse than
    // one showing only email and password, which always works.
    return [];
  }
}
