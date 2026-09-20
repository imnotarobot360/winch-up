import { getTranslations } from "next-intl/server";

import { Link } from "@/i18n/navigation";

export default async function NotFound() {
  const t = await getTranslations("notFound");

  return (
    <main className="mx-auto w-full max-w-xl space-y-4 px-4 py-16 text-center">
      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="text-lg text-ink-soft">{t("body")}</p>
      <Link
        href="/request"
        className="tap-target mt-6 inline-flex w-full items-center justify-center rounded-field bg-brand px-6 text-lg font-bold text-white"
      >
        {t("cta")}
      </Link>
    </main>
  );
}
