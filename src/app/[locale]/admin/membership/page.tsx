import { setRequestLocale } from "next-intl/server";

import { AdminMembership } from "@/components/admin/admin-membership";

export const dynamic = "force-dynamic";

export default async function AdminMembershipPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <AdminMembership />;
}
