import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { HelpList, type HelpRow } from "@/components/help/help-list";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "help" });
  return {
    title: t("title"),
    description: t("subtitle"),
    // Open requests, even blurred, are not something to leave in a search index. /board is the
    // public surface and it is deliberately thinner than this one.
    robots: { index: false, follow: false },
  };
}

/**
 * Help Someone (spec section 3).
 *
 * Members only, which is the one place this differs from /board. /board is the public window
 * onto what the Facebook group feed was; this is the working surface, where somebody can act,
 * and acting means being an account that can be reported and blocked.
 *
 * The first render has no browser position, so distances are missing and the list is ordered by
 * recency. The client asks for geolocation and refetches. That is deliberate: a page that waits
 * for a location fix before rendering anything shows a spinner to somebody on one bar of signal
 * who could have been reading the list.
 */
export default async function HelpPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/help`)}`);
  }

  const { data } = await supabase.rpc("nearby_requests", {
    p_lat: null,
    p_lng: null,
    p_radius_miles: 60,
    p_limit: 50,
  });

  return <HelpList initial={(data as HelpRow[] | null) ?? []} />;
}
