import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { ModerationQueue } from "@/components/community/moderation-queue";
import { ReportedMembers } from "@/components/community/reported-members";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  robots: { index: false, follow: false },
};

/**
 * Deliberately NOT under /admin.
 *
 * The admin shell gates on `role = 'admin'` and its tabs lead to volunteer phone numbers, the
 * waiver text and the audit log. A moderator has none of that. Putting the queue here means the
 * only thing a moderator can reach is the queue, and the RPCs behind it gate on
 * `app.is_moderator()` themselves -- this page decides what renders, not what is permitted.
 */
export default async function ModerationPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("moderation");
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: roles } = user
    ? await supabase
        .from("user_roles")
        .select("role")
        .eq("user_id", user.id)
        .in("role", ["moderator", "admin"])
    : { data: null };

  if (!user || !roles || roles.length === 0) {
    return (
      <main className="mx-auto w-full max-w-xl px-4 py-8">
        <Callout tone="neutral">{user ? t("notModerator") : t("signedOut")}</Callout>
        <p className="mt-4">
          <Link href={user ? "/community" : "/signin"} className="underline underline-offset-4">
            {user ? t("backToFeed") : t("signIn")}
          </Link>
        </p>
      </main>
    );
  }

  // Suspension is an admin action, not a moderator one -- so the page works out which this is
  // and passes it down. It decides what RENDERS and nothing more:
  // admin_suspend_member() calls app.require_admin(), which raises, so a moderator who reached
  // the call another way is refused by the database. The prop is there so nobody is shown a
  // button that can only fail.
  const isAdmin = roles.some((r) => r.role === "admin");

  return (
    <main className="mx-auto w-full max-w-2xl space-y-8 px-4 py-8">
      <ModerationQueue />
      <ReportedMembers isAdmin={isAdmin} />
    </main>
  );
}
