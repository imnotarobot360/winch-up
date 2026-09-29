import { getTranslations, setRequestLocale } from "next-intl/server";

import { AuthForm } from "@/components/auth/auth-form";
import { SocialButtons } from "@/components/auth/social-buttons";
import { enabledSocialProviders } from "@/lib/auth/social-providers";
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

  // Read from Supabase, not from this repo: a button exists only if its provider is actually
  // configured, so there is never a "Continue with Google" that bounces to an error page.
  // Today this is empty and nothing below it renders.
  const providers = await enabledSocialProviders();

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("signUpTitle")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("signUpBody")}</p>
      <Card className="mt-6 space-y-5">
        <AuthForm mode="signup" />
        {/* Below the form, not above it. Email and password is the path that always works and
            the one every existing member already has; social login is the shortcut. */}
        <SocialButtons providers={providers} />
      </Card>
    </main>
  );
}
