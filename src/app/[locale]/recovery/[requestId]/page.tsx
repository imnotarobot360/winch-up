import { notFound, redirect } from "next/navigation";
import { setRequestLocale } from "next-intl/server";

import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/**
 * Where a team notification lands.
 *
 * Notifications about a recovery carry `/recovery/<request_id>` rather than the status token.
 * This turns one into the other, for a participant, and refuses everybody else.
 *
 * The id is not a capability. It is already in the status payload, and `recovery_link()` decides
 * access by asking who the caller is — not by whether they knew an id. Somebody who guesses one
 * gets the same 404 as somebody who invents one, so ids cannot be walked to discover which
 * recoveries exist.
 *
 * There is deliberately no "sign in to see this" branch. A signed-out visitor following a stale
 * link learns nothing about whether the recovery is real, which is the same stance the private
 * thread takes.
 */
export default async function RecoveryDeepLink({
  params,
}: {
  params: Promise<{ locale: string; requestId: string }>;
}) {
  const { locale, requestId } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("recovery_link", { p_request_id: requestId });

  if (error) notFound();

  const result = data as { ok?: boolean; token?: string } | null;
  if (!result?.ok || !result.token) notFound();

  redirect(`/${locale}/r/${result.token}`);
}
