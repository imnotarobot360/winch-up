import { getTranslations, setRequestLocale } from "next-intl/server";

import { AuthForm } from "@/components/auth/auth-form";
import { Card } from "@/components/ui/primitives";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "auth" });
  return { title: t("createAccount") };
}

export default async function SignUpPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("auth");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("signUpTitle")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("signUpBody")}</p>
      <Card className="mt-6">
        <AuthForm mode="signup" />
      </Card>
    </main>
  );
}
