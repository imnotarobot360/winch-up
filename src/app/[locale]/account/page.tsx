import { getTranslations, setRequestLocale } from "next-intl/server";

import { AccountForm } from "@/components/account/account-form";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "account" });
  return { title: t("title") };
}

export default async function AccountPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Checked on the server so the page never renders for a signed-out visitor. Note that this
  // returns a 200 with a client navigation rather than a 307, because the head has already
  // flushed by the time the redirect fires -- curl will show 200 here and the browser will
  // still land on /signin. Test it in a browser, not with curl.
  if (!user) redirect({ href: "/signin", locale });

  /**
   * Can this member moderate?
   *
   * /moderation was linked from nowhere in the entire app -- a moderator had to know the URL
   * and type it, which is a strange thing to require of the person who hides reported content.
   * Found by the sweep in docs/built-but-unreachable.md.
   *
   * Decided here, on the server, rather than by asking the browser: the row simply is not
   * rendered for anybody else. That is presentation, not permission -- /moderation checks
   * app.is_moderator() itself, as it did before this row existed, so hiding a link is never
   * what stops somebody getting in.
   */
  const { data: modRoles } = await supabase
    .from("user_roles")
    .select("role")
    .eq("user_id", user!.id)
    .in("role", ["moderator", "admin"]);

  const canModerate = (modRoles?.length ?? 0) > 0;

  const t = await getTranslations("account");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("body")}</p>
      <div className="mt-6">
        <AccountForm
          userId={user!.id}
          email={user!.email ?? user!.phone ?? ""}
          canModerate={canModerate}
        />
      </div>
    </main>
  );
}
