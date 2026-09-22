import { setRequestLocale } from "next-intl/server";

import { AdminAds } from "@/components/admin/admin-ads";

export const dynamic = "force-dynamic";

export default async function AdminAdsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminAds />;
}
