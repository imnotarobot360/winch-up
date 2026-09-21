import type { Metadata, Viewport } from "next";
import { Bebas_Neue, Inter } from "next/font/google";
import { hasLocale, NextIntlClientProvider } from "next-intl";
import { getTranslations, setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";
import type { ReactNode } from "react";

import { AppHeader } from "@/components/chrome/app-header";
import { BottomNav } from "@/components/chrome/bottom-nav";
import { RegisterServiceWorker } from "@/components/pwa/register-sw";
import { APP_NAME } from "@/config/app";
import { routing } from "@/i18n/routing";

// Self-hosted by next/font at build time: no request to Google at runtime, no layout shift, and
// latin-ext so Spanish accents and inverted punctuation are present in both faces.
const inter = Inter({
  subsets: ["latin", "latin-ext"],
  variable: "--font-inter",
  display: "swap",
});

const bebas = Bebas_Neue({
  subsets: ["latin", "latin-ext"],
  weight: "400",
  variable: "--font-bebas",
  display: "swap",
});

import "../globals.css";

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "app" });

  return {
    title: { default: APP_NAME, template: `%s · ${APP_NAME}` },
    description: t("tagline"),
    applicationName: APP_NAME,
    manifest: "/manifest.webmanifest",
    appleWebApp: { capable: true, title: APP_NAME, statusBarStyle: "default" },
  };
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  // The form is full of large tap targets; pinch-zoom still has to work for anyone who needs it.
  maximumScale: 5,
  themeColor: "#0b2d1f",
};

export default async function LocaleLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!hasLocale(routing.locales, locale)) {
    notFound();
  }

  setRequestLocale(locale);

  return (
    <html lang={locale} className={`${inter.variable} ${bebas.variable}`}>
      <body className="min-h-dvh bg-surface text-ink antialiased">
        <NextIntlClientProvider>
          <AppHeader />
          {children}
          <BottomNav />
        </NextIntlClientProvider>
        <RegisterServiceWorker />
      </body>
    </html>
  );
}
