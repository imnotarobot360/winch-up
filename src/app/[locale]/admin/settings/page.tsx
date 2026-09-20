import { AdminSettings } from "@/components/admin/admin-settings";
import { supabaseAdmin } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";

/**
 * The paid-recovery list is loaded server-side because it includes rows that are hidden from
 * the public board, which the anon client cannot read.
 */
export default async function AdminSettingsPage() {
  const { data } = await supabaseAdmin()
    .from("pro_options")
    .select("id, name, phone, url, blurb_en, blurb_es, is_active, sort_order")
    .order("sort_order");

  return <AdminSettings proOptions={data ?? []} />;
}
