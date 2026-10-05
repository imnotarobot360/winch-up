import { setRequestLocale } from "next-intl/server";

import { AdminAlerts } from "@/components/admin/admin-alerts";

export const dynamic = "force-dynamic";

export default async function AdminAlertsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminAlerts />;
}
