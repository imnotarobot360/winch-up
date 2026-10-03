import { getTranslations, setRequestLocale } from "next-intl/server";

import { AnnouncementBanner } from "@/components/announcements/announcement-banner";
import { CommunityFeed } from "@/components/community/community-feed";
import { IconBoards, IconPeople } from "@/components/ui/icons";
import { MenuList } from "@/components/ui/menu-list";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "community" });
  // Members-only, so it stays out of search results. /board is the public surface and it is
  // deliberately thin: no names, no phones, a blurred pin.
  return { title: t("title"), robots: { index: false, follow: false } };
}

export default async function CommunityPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // See the note in account/page.tsx: this is a client navigation, not a 307, because the head
  // has already flushed. Verify it in a browser, not with curl.
  if (!user) redirect({ href: "/signin", locale });

  const tMembers = await getTranslations({ locale, namespace: "members" });
  const tGroups = await getTranslations({ locale, namespace: "groups" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-8">
      {/* THE WAY INTO /members, which until now was reachable from nothing at all.
          The screen has existed since 20260924000100 -- search, filters, distance, equipment,
          the lot -- and no page in the app linked to it, so nobody could find the one list of
          people in a product about people. Third time this has happened here after /welcome
          and /account, and the owner found this one too, by comparing the app against the
          design reference rather than by any test noticing.

          On /community because that is the members-only, people-shaped part of the app, and
          because the bottom nav is full: five tabs that each lead somewhere, which is the rule
          that keeps it honest. */}
      {/* Section 1. Renders nothing when there is nothing, so this is free on most visits. */}
      <AnnouncementBanner />

      <MenuList
        items={[
          {
            href: "/members",
            label: tMembers("title"),
            hint: tMembers("subtitle"),
            icon: <IconPeople size={22} />,
          },
          {
            href: "/groups",
            label: tGroups("title"),
            hint: tGroups("subtitle"),
            icon: <IconBoards size={22} />,
          },
        ]}
      />

      <CommunityFeed />
    </main>
  );
}
