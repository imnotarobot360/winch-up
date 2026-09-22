"use server";

import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export type IncidentResult = { ok: true } | { ok: false; error: string };

const CATEGORIES = [
  "asked_for_money",
  "unsafe_behavior",
  "no_show",
  "property_damage",
  "injury",
  "harassment",
  "impersonation",
  "other",
] as const;

export type IncidentCategory = (typeof CATEGORIES)[number];

function validate(category: string, description: string): string | null {
  if (!CATEGORIES.includes(category as IncidentCategory)) return "invalid_category";
  const text = description.trim();
  if (text.length < 10) return "description_too_short";
  if (text.length > 2000) return "description_too_long";
  return null;
}

/**
 * A requester reporting what happened, holding their status link.
 *
 * report_incident_by_token() is granted to service_role only -- deliberately not to
 * `authenticated` -- so this action is the sole way in. If the browser could call it directly,
 * any signed-in person who was forwarded a status link could file reports against the volunteer
 * who took that job.
 *
 * The token is the credential, the same as cancelling or marking recovered. Somebody pulled out
 * of a ditch an hour ago should not need to remember a password to say what went wrong.
 */
export async function reportIncidentByToken(
  token: string,
  category: string,
  description: string,
): Promise<IncidentResult> {
  const invalid = validate(category, description);
  if (invalid) return { ok: false, error: invalid };

  const { data, error } = await supabaseAdmin().rpc("report_incident_by_token", {
    p_token: token,
    p_payload: { category, description: description.trim() },
  });

  if (error) {
    console.error("[report_incident_by_token] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  const result = data as { ok: boolean; error?: string };
  return result.ok ? { ok: true } : { ok: false, error: result.error ?? "server_error" };
}

/**
 * A signed-in volunteer or member reporting something.
 *
 * Goes through the user's own session rather than the service role, so report_incident() reads
 * the reporter from auth.uid(). Nothing here can name a reporter other than whoever is signed
 * in.
 */
export async function reportIncident(
  category: string,
  description: string,
  requestId?: string,
): Promise<IncidentResult> {
  const invalid = validate(category, description);
  if (invalid) return { ok: false, error: invalid };

  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { ok: false, error: "not_signed_in" };

  const { data, error } = await supabase.rpc("report_incident", {
    p_payload: {
      category,
      description: description.trim(),
      ...(requestId ? { request_id: requestId } : {}),
    },
  });

  if (error) {
    console.error("[report_incident] rpc failed", error);
    return { ok: false, error: "server_error" };
  }

  const result = data as { ok: boolean; error?: string };
  return result.ok ? { ok: true } : { ok: false, error: result.error ?? "server_error" };
}
