import { getTranslations, setRequestLocale } from "next-intl/server";

import { AdvertiserDashboard } from "@/components/ads/advertiser-dashboard";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "business" });
  return { title: t("title"), robots: { index: false, follow: false } };
}

/**
 * Any signed-in person can reach this and register a business — the business_owner role is
 * granted when an admin approves one, not before, so requiring the role here would mean nobody
 * could ever get it.
 */
export default async function BusinessPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect({ href: "/signin", locale });

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <AdvertiserDashboard />
    </main>
  );
}
