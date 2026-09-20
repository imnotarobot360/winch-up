import type { Metadata } from "next";
import { setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";

import { StatusView } from "@/components/status/status-view";
import { loadStatus } from "@/lib/status";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  // This link gets forwarded to friends and family. It must never end up in a search index.
  robots: { index: false, follow: false },
};

export default async function StatusPage({
  params,
}: {
  params: Promise<{ locale: string; token: string }>;
}) {
  const { locale, token } = await params;
  setRequestLocale(locale);

  const status = await loadStatus(token);
  if (!status) notFound();

  return <StatusView token={token} initial={status} />;
}
