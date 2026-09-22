import { setRequestLocale } from "next-intl/server";

import { AdminSecurity } from "@/components/admin/admin-security";

export const dynamic = "force-dynamic";

export default async function AdminSecurityPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminSecurity />;
}
