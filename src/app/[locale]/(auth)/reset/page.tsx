import { getTranslations, setRequestLocale } from "next-intl/server";

import { ResetForm } from "@/components/auth/reset-form";
import { Card } from "@/components/ui/primitives";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "auth" });
  return { title: t("resetTitle") };
}

export default async function ResetPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("auth");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("resetTitle")}</h1>
      <Card className="mt-6">
        <ResetForm />
      </Card>
    </main>
  );
}
