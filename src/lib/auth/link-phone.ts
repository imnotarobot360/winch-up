import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Attaching a phone number to an account, in one place.
 *
 * THE BUG THIS EXISTS TO PREVENT, because the two primitives look interchangeable and are not:
 *
 *   signInWithOtp({ phone }) + verifyOtp({ type: "sms" })  authenticates the PHONE IDENTITY
 *   updateUser({ phone })    + verifyOtp({ type: "phone_change" })  attaches it to the CURRENT user
 *
 * /join called the first pair unconditionally. A member who joined by email or Google and then
 * verified their number was not linking it -- they were handed a SECOND account, with their
 * responder profile on the new one and their waiver signature, vehicles and requests on the
 * old. It looked perfect from the screen: a code arrives, it is accepted, the profile saves.
 * Three duplicate accounts reached production before anybody noticed, and they had to be
 * deleted by hand.
 *
 * It is extracted here because a SECOND screen now needs it (/account/security), and this is
 * exactly the kind of logic that gets re-derived slightly differently the second time. The
 * decision -- which pair to use -- is made once, from the session, and the answer is carried
 * to the verify step rather than re-derived there. Re-deriving is its own trap: signing in by
 * phone CREATES a session, so a second `getSession()` after a successful send can return one
 * where the first found none, and the verify would then use the wrong type.
 *
 * Guarded by `npm run linking:check`, which counts auth.users across the calls -- the only
 * thing that can see this. pgTAP cannot: the duplicate is created above the database by the
 * auth API. Playwright cannot: the UI is identical either way.
 */

export type PhoneLinkError = "phone_taken" | "otp_send_failed" | "bad_code";

/** What the send decided, and what verify must be told. */
export type PhoneSend =
  | { ok: true; linking: boolean }
  | { ok: false; error: PhoneLinkError; linking: boolean };

/**
 * Send the one-time code.
 *
 * `linking` is true when there is already a session, and the caller MUST pass it back to
 * confirmPhoneCode. It is returned even on failure so a caller holding it in state does not
 * keep a stale value from a previous attempt.
 *
 * `where` only labels the console line, so two screens using this are told apart when somebody
 * is debugging a Twilio problem at 11pm.
 */
export async function sendPhoneCode(
  supabase: SupabaseClient,
  e164: string,
  where: string,
): Promise<PhoneSend> {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  const linking = Boolean(session);

  const { error } = linking
    ? await supabase.auth.updateUser({ phone: e164 })
    : await supabase.auth.signInWithOtp({ phone: e164, options: { channel: "sms" } });

  if (!error) return { ok: true, linking };

  // The provider's own reason, which this used to drop on the floor.
  //
  // Phone verification goes out through Supabase Auth's Twilio settings, NOT the TWILIO_*
  // variables this app uses for dispatch -- two separate configurations that fail in
  // indistinguishable ways from the screen. The useful detail is all in here: Twilio 21212
  // (invalid From, usually a phone number pasted where the Messaging Service SID goes), 21608
  // (trial account, number not verified), 21610 (recipient replied STOP).
  console.error(`[${where}] sending the code failed`, {
    linking,
    status: error.status,
    code: error.code,
    message: error.message,
  });

  // A number already on somebody else's account is a different problem from a failed send, and
  // telling the member "try again" would have them retry forever. Moving it instead would be
  // the account-takeover version of this feature.
  return {
    ok: false,
    error: error.code === "phone_exists" ? "phone_taken" : "otp_send_failed",
    linking,
  };
}

/**
 * Confirm the code.
 *
 * `linking` must be the value sendPhoneCode returned. Getting the two out of step is the whole
 * bug, which is why it is a required parameter rather than something looked up again here.
 */
export async function confirmPhoneCode(
  supabase: SupabaseClient,
  e164: string,
  code: string,
  linking: boolean,
  where: string,
): Promise<{ ok: true } | { ok: false; error: PhoneLinkError }> {
  const { error } = await supabase.auth.verifyOtp({
    phone: e164,
    token: code.trim(),
    type: linking ? "phone_change" : "sms",
  });

  if (!error) return { ok: true };

  console.error(`[${where}] verify failed`, {
    linking,
    status: error.status,
    code: error.code,
    message: error.message,
  });

  return { ok: false, error: error.code === "phone_exists" ? "phone_taken" : "bad_code" };
}
