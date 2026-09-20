import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { BoardList, type BoardRow } from "@/components/board/board-list";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "board" });
  return { title: t("title"), description: t("subtitle") };
}

export default async function BoardPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const { data } = await supabase.rpc("board_requests", { p_limit: 100 });

  return <BoardList initial={(data as BoardRow[] | null) ?? []} />;
}
