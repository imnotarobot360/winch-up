"use server";

import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

/**
 * Count one view of one event (spec section 12).
 *
 * WHY A SERVER ACTION AND NOT THE PAGE ITSELF. The obvious place is the server component that
 * renders the event -- it already runs once per visit. It is the wrong place: Next PREFETCHES a
 * route when a link enters the viewport or is hovered, which renders the page on the server without
 * anybody looking at it. Counting there would inflate the number by however many event cards happen
 * to scroll past, and the inflation would be invisible and unfixable after the fact.
 *
 * A client effect does not run on a prefetch. So the page renders, the browser mounts, and only then
 * is a view recorded.
 *
 * SERVICE ROLE, because `record_event_view` is granted to nobody else. It writes to a table with no
 * viewer column and never will have one -- `event_rsvps` is where a member deliberately says they
 * are going, and a view is not that. The member's identity is used here only to establish that they
 * are signed in; it is not passed on and not stored.
 */
export async function recordEventViewAction(eventId: string): Promise<void> {
  // A signed-out caller counts nothing. Events are members-only, so a view from nobody is either a
  // crawler or a mistake, and either way it is not a reader.
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return;

  try {
    // Refuses anything that is not published, so a draft's id cannot be used to probe for
    // existence by watching a counter.
    await supabaseAdmin().rpc("record_event_view", { p_event_id: eventId });
  } catch (error) {
    // Never throws into the page. A failed count is a missing row in a report; a thrown error is a
    // stranded member looking at a crash on the page that was going to tell them where to meet.
    console.error("[events] could not record a view", error);
  }
}
