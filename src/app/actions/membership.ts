"use server";

import { headers } from "next/headers";
import { revalidatePath } from "next/cache";
import { after } from "next/server";

import { drainEmail } from "@/lib/email/drain";
import { clientIpFrom, supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export type SignMembershipResult =
  | { ok: true; version: number; signedAt: string; replayed: boolean }
  | { ok: false; error: string };

/**
 * Signing the membership agreement.
 *
 * Service-role, like createRequestAction and for the same reason: the IP address and user agent
 * stored against a signature are audit evidence, and evidence the signer hands us about
 * themselves is not evidence. `sign_membership_agreement` is granted to service_role alone, so
 * this action is the only way in -- a browser cannot reach the RPC even holding a valid session.
 *
 * The user id likewise comes from the server's view of the session. If the form supplied it, one
 * signed-in member could sign on another's behalf, and the row is a legal record of who agreed
 * to what.
 */
export async function signMembershipAction(input: {
  legalName: string;
  signatureText: string;
  /** The hash of the text the browser actually rendered. See below. */
  bodyHash: string;
  locale?: string;
}): Promise<SignMembershipResult> {
  const {
    data: { user },
  } = await (await supabaseServer()).auth.getUser();

  if (!user) return { ok: false, error: "account_required" };

  const headerList = await headers();

  const { data, error } = await supabaseAdmin().rpc("sign_membership_agreement", {
    p_payload: {
      user_id: user.id,
      legal_name: input.legalName,
      signature_text: input.signatureText,
      // Echoed back from the page, never recomputed here. The point of the round trip is to
      // prove the member signed the words that were on their screen: if an admin published a
      // new version while the form sat open, this no longer matches and the RPC refuses. A hash
      // computed server-side at submit time would always match and would prove nothing.
      body_hash: input.bodyHash,
      locale: input.locale ?? "en",
      signed_via: "web",
      ip: clientIpFrom(headerList),
      user_agent: headerList.get("user-agent"),
    },
  });

  if (error) {
    console.error("[sign_membership_agreement] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  const result = data as
    | { ok: true; version: number; signed_at: string; replayed: boolean }
    | { ok: false; error: string };

  if (!result?.ok) return { ok: false, error: result?.error ?? "server_error" };

  // Requirement 8: a confirmation goes to the member. Queued by the database trigger; drained
  // after the response, so a slow mail provider cannot make signing feel broken. A replay does
  // not re-queue -- the trigger fires on insert and a replay inserts nothing.
  if (!result.replayed) {
    after(async () => {
      try {
        await drainEmail(5);
      } catch (drainError) {
        console.error("[sign_membership_agreement] email drain failed", drainError);
      }
    });
  }

  // The agreement banner is rendered on these, and it must stop appearing now.
  revalidatePath("/", "layout");

  return {
    ok: true,
    version: result.version,
    signedAt: result.signed_at,
    replayed: result.replayed,
  };
}

export type MembershipAgreement = {
  required: boolean;
  agreement: {
    id: string;
    version: number;
    body_en: string;
    body_es: string;
    body_hash: string;
    effective_at: string;
  } | null;
  /**
   * The version this member signed, which is not always the current one. A member who signed v1
   * under a v2 published as a correction is still bound by v1 and must be shown v1.
   */
  signed_document: {
    version: number;
    body_en: string;
    body_es: string;
    body_hash: string;
    signed_at: string;
    legal_name: string;
  } | null;
  state: {
    has_agreement: boolean;
    version: number | null;
    signed: boolean;
    signed_at: string | null;
    signed_any: boolean;
    needs_signature: boolean;
  };
};

/**
 * The current agreement and where the caller stands with it.
 *
 * Through the session client, not the service role: the RPC reads auth.uid() to decide whose
 * signature status to report, and a service-role call has no session to read. It works signed
 * out too, returning the text with an unsigned status, which is what registration needs.
 */
export async function getMembershipAgreement(): Promise<MembershipAgreement | null> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("membership_agreement");

  if (error) {
    console.error("[membership_agreement] rpc failed", error);
    return null;
  }

  return data as unknown as MembershipAgreement;
}
