import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { MembersList } from "@/components/members/members-list";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("members");
  // Members opted into being seen by other members, not into being indexed by search engines.
  return { title: t("title"), description: t("subtitle"), robots: { index: false, follow: false } };
}

export default async function MembersPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("members");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-6">
      <header className="mb-5">
        <h1 className="text-3xl font-bold text-ink">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("subtitle")}</p>
      </header>

      <MembersList />
    </main>
  );
}
