/**
 * Sign in with Apple, natively.
 *
 * THE NONCE IS PASSED TWICE, IN TWO DIFFERENT FORMS, and swapping them is the classic failure of
 * this integration. Apple is given the SHA-256 HASH and embeds it in the identity token; Supabase
 * is given the RAW string, hashes it itself, and compares. Send the same form to both and the
 * token is rejected with a message that never mentions nonces. `signInWithApple` is written
 * against injected dependencies for exactly that reason: a test can assert which value went
 * where, which is the only way that mistake is caught before a device is involved.
 *
 * APPLE GIVES THE NAME ONCE. `fullName` is populated on the FIRST authorization for an Apple ID
 * and is null on every sign-in afterwards, for ever, unless the member removes the app from their
 * Apple account. So it is persisted on the way through rather than read later. It arrives from
 * the client, so it is a display name and never an identity claim -- the same position
 * `app.handle_new_user` already takes on the name typed at signup, which it validates and nulls
 * rather than trusting.
 *
 * CANCELLING IS NOT AN ERROR. Apple raises ERR_REQUEST_CANCELED when somebody dismisses the
 * sheet, and showing them a failure for choosing not to sign in is a bug, not diligence.
 */

export type AppleCredential = {
  identityToken: string | null;
  fullName?: { givenName?: string | null; familyName?: string | null } | null;
};

export type AppleSignInDeps = {
  /** False on Android, and on iOS below 13. */
  isAvailable: () => Promise<boolean>;
  /** Apple gets the HASHED nonce. */
  signInAsync: (opts: { nonce: string }) => Promise<AppleCredential>;
  /** Supabase gets the RAW nonce beside the token. */
  signInWithIdToken: (opts: { token: string; nonce: string }) => Promise<{ error: Error | null }>;
  randomNonce: () => string;
  sha256: (value: string) => Promise<string>;
};

export type AppleSignInResult =
  | { status: "signed_in"; displayName: string | null }
  | { status: "cancelled" }
  | { status: "unavailable" }
  | { status: "failed"; reason: string };

/** Apple's own code for a dismissed sheet. */
const CANCELLED = "ERR_REQUEST_CANCELED";

function isCancellation(e: unknown): boolean {
  return typeof e === "object" && e !== null && (e as { code?: string }).code === CANCELLED;
}

/**
 * Joins the two name parts Apple may send, each of which may be absent.
 *
 * Returns null rather than an empty or half-trimmed string: a blank display name is a blank
 * field, which the profile screen can prompt to fill, while " " is a name that looks set and is
 * not.
 */
export function displayNameFrom(fullName: AppleCredential["fullName"]): string | null {
  const parts = [fullName?.givenName, fullName?.familyName]
    .map((p) => (typeof p === "string" ? p.trim() : ""))
    .filter((p) => p.length > 0);
  return parts.length ? parts.join(" ") : null;
}

export async function signInWithApple(deps: AppleSignInDeps): Promise<AppleSignInResult> {
  if (!(await deps.isAvailable())) return { status: "unavailable" };

  const rawNonce = deps.randomNonce();
  const hashedNonce = await deps.sha256(rawNonce);

  let credential: AppleCredential;
  try {
    credential = await deps.signInAsync({ nonce: hashedNonce });
  } catch (e) {
    if (isCancellation(e)) return { status: "cancelled" };
    return { status: "failed", reason: "apple_sheet_failed" };
  }

  // Apple can return a credential with no token at all; Supabase would reject an empty string
  // with a less obvious message than this one.
  if (!credential.identityToken) return { status: "failed", reason: "no_identity_token" };

  const { error } = await deps.signInWithIdToken({
    token: credential.identityToken,
    nonce: rawNonce,
  });
  if (error) return { status: "failed", reason: "supabase_rejected_token" };

  return { status: "signed_in", displayName: displayNameFrom(credential.fullName) };
}
