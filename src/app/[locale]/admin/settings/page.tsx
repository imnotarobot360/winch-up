import { AdminSettings } from "@/components/admin/admin-settings";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/**
 * Read through the session client, not the service role.
 *
 * Next renders layouts and pages in parallel, so this runs even when the admin layout is about
 * to replace it with the sign-in screen. The `pro_options` policy already says the right thing —
 * active rows for anyone, every row for an admin — so letting RLS decide means an unauthenticated
 * request does no privileged work at all.
 */
export default async function AdminSettingsPage() {
  const supabase = await supabaseServer();

  const { data } = await supabase
    .from("pro_options")
    .select("id, name, phone, url, blurb_en, blurb_es, is_active, sort_order")
    .order("sort_order");

  return <AdminSettings proOptions={data ?? []} />;
}
