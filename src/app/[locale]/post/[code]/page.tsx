import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";

import { CopyBlock } from "@/components/board/copy-block";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { buildFacebookPost } from "@/lib/facebook-post";
import { loadStatus } from "@/lib/status";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  robots: { index: false, follow: false },
};

/**
 * `[code]` is the request's own status token. Whoever can open the status page can generate the
 * post for it, which is exactly the set of people who should: the requester and an admin.
 */
export default async function PostPage({
  params,
}: {
  params: Promise<{ locale: string; code: string }>;
}) {
  const { locale, code } = await params;
  setRequestLocale(locale);

  const status = await loadStatus(code);
  if (!status) notFound();

  const t = await getTranslations("post");
  const tEnum = await getTranslations("enum");

  const siteUrl = (process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "");
  const statusUrl = `${siteUrl}/r/${code}`;

  const text = buildFacebookPost(
    status,
    {
      needed: t("headerNeeded"),
      recovered: t("headerRecovered"),
      cancelled: t("headerCancelled"),
      location: t("location"),
      vehicle: t("vehicle"),
      situation: t("situation"),
      needs: t("needs"),
      notes: t("notes"),
      status: t("statusLink"),
      helper: t("helper"),
      postedVia: t("postedVia"),
      photos: t("photos"),
    },
    (group, value) => tEnum(`${group}.${value}`),
    statusUrl,
  );

  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 px-4 py-6">
      <header>
        <p className="font-mono text-base text-ink-faint">{status.short_code}</p>
        <h1 className="text-3xl font-bold leading-tight">{t("title")}</h1>
        <p className="mt-2 text-base text-ink-soft">{t("intro")}</p>
      </header>

      <Callout tone="neutral">{t("noAutoPost")}</Callout>

      <CopyBlock text={text} />

      {status.photos.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-xl font-semibold">{t("attachPhotos")}</h2>
          <p className="text-base text-ink-soft">{t("attachPhotosHint")}</p>
          <ul className="grid grid-cols-3 gap-2">
            {status.photo_urls.map((url) => (
              <li key={url}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={url}
                  alt=""
                  className="aspect-square w-full rounded-field border border-line object-cover"
                />
              </li>
            ))}
          </ul>
          <p className="text-sm text-ink-faint">{t("photoLinksExpire")}</p>
        </section>
      ) : null}

      <Link href={`/r/${code}`} className="inline-block text-base underline underline-offset-4">
        {t("backToStatus")}
      </Link>
    </main>
  );
}
