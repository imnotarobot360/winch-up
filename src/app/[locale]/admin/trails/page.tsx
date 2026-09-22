import { setRequestLocale } from "next-intl/server";

import { AdminTrails } from "@/components/admin/admin-trails";

export const dynamic = "force-dynamic";

export default async function AdminTrailsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminTrails />;
}
