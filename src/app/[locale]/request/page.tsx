import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { RequestWizard } from "@/components/request/request-wizard";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "request" });
  return { title: t("pageTitle") };
}

export default async function RequestPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return <RequestWizard />;
}
