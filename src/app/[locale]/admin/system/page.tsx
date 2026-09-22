import { setRequestLocale } from "next-intl/server";

import { AdminSystem } from "@/components/admin/admin-system";

export const dynamic = "force-dynamic";

export default async function AdminSystemPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminSystem />;
}
