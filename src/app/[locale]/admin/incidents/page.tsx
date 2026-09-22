import { setRequestLocale } from "next-intl/server";

import { AdminIncidents } from "@/components/admin/admin-incidents";

export const dynamic = "force-dynamic";

export default async function AdminIncidentsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminIncidents />;
}
