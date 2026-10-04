import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { getFormatter, getTranslations, setRequestLocale } from "next-intl/server";

import { EventViewCounter } from "@/components/events/event-view-counter";
import { Callout, Card } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "eventPage" });
  // noindex, like every members-only page. An event carries an organiser's name and sometimes a
  // phone number, and none of that belongs in a search result.
  return { title: t("title"), robots: { index: false, follow: false } };
}

type EventDetail = {
  id: string;
  title: string;
  description: string | null;
  event_type: string;
  starts_at: string;
  ends_at: string | null;
  meet_note: string | null;
  capacity: number | null;
  address_line: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  is_official: boolean;
  organizer_name: string | null;
  registration_url: string | null;
  website_url: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  group_name: string | null;
  trail_name: string | null;
  going_count: number | null;
  matches_my_area?: boolean | null;
};

const EVENT_TYPE_KEYS = {
  trail_ride: "eventType_trail_ride",
  training: "eventType_training",
  meetup: "eventType_meetup",
  cleanup: "eventType_cleanup",
  fundraiser: "eventType_fundraiser",
  show: "eventType_show",
} as const;

/**
 * One event, on its own page.
 *
 * WHY IT EXISTS. `record_event_view()` and `event_daily_stats` shipped with nothing able to call
 * them, because there was no per-event surface and counting a "view" for every event in a list is
 * not a view. Rather than ship an admin report with a column that could never move, this is the
 * page that makes the number real. It is also where an event's description, organiser and
 * registration link have room to be read, which a card in a list does not.
 *
 * SERVER-RENDERED, so `event_detail()` runs before anything reaches the browser. That RPC answers
 * `not_found` for a draft, a deleted event and an id that never existed alike, so this page cannot
 * be used to find out whether an admin is drafting something.
 *
 * NO RSVP CONTROLS. The owner decided that on 2026-10-01 and it has not changed: `event_rsvp`
 * exists and is left alone. The going count is shown because `create_event` marks the organiser as
 * going and the number is real; a button to join would be a new product decision, not a detail page.
 */
export default async function EventPage({
  params,
}: {
  params: Promise<{ locale: string; eventId: string }>;
}) {
  const { locale, eventId } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/events/${eventId}`)}`);
  }

  const { data, error } = await supabase.rpc("event_detail", { p_event_id: eventId });

  const result = data as { ok: boolean; event?: EventDetail } | null;
  if (error || !result?.ok || !result.event) notFound();

  const event = result.event;
  const t = await getTranslations({ locale, namespace: "eventPage" });
  const tc = await getTranslations({ locale, namespace: "community" });
  const format = await getFormatter({ locale });

  const typeKey = EVENT_TYPE_KEYS[event.event_type as keyof typeof EVENT_TYPE_KEYS] ?? null;

  // Address, assembled from whichever parts are filled in. An event with only a city still reads
  // properly rather than showing a line of commas.
  const place = [event.address_line, event.city, event.state, event.postal_code]
    .filter((part) => part && part.trim())
    .join(", ");

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      {/* Counts from the browser, never from this server render -- a prefetch would otherwise
          count somebody who only scrolled past the link. */}
      <EventViewCounter eventId={event.id} />

      <header>
        <Link href="/community" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToCommunity")}
        </Link>

        <p className="mt-3 text-sm font-semibold uppercase tracking-wide text-brand">
          {format.dateTime(new Date(event.starts_at), {
            weekday: "long",
            day: "numeric",
            month: "long",
            hour: "numeric",
            minute: "2-digit",
          })}
        </p>

        <h1 className="mt-1 font-display text-3xl">{event.title}</h1>

        <p className="mt-1 text-ink-soft">
          {typeKey ? tc(typeKey) : null}
          {typeKey && place ? " · " : null}
          {place}
        </p>
      </header>

      {/* Not a gate, and the page says so. Targeting an event never hides it -- a member four
          hundred miles away can still read this and decide to drive. */}
      {event.matches_my_area === false ? (
        <Callout tone="neutral">{t("notNearYou")}</Callout>
      ) : null}

      {event.description ? (
        <Card className="p-4">
          <p className="whitespace-pre-wrap text-base text-ink">{event.description}</p>
        </Card>
      ) : null}

      <Card className="space-y-3 p-4">
        {event.meet_note ? (
          <Detail label={t("meetLabel")} value={event.meet_note} />
        ) : null}
        {event.organizer_name ? (
          <Detail label={t("organizerLabel")} value={event.organizer_name} />
        ) : null}
        {event.group_name ? <Detail label={t("groupLabel")} value={event.group_name} /> : null}
        {event.trail_name ? <Detail label={t("trailLabel")} value={event.trail_name} /> : null}
        <Detail
          label={t("goingLabel")}
          value={
            event.capacity
              ? t("goingOfCapacity", { going: event.going_count ?? 0, capacity: event.capacity })
              : String(event.going_count ?? 0)
          }
        />
      </Card>

      {/* The promotional fields. A CHECK on the table keys all of these to is_official, which only
          the admin surface sets -- so a member-created event cannot carry any of them, and anything
          rendered here was written by somebody who can already reach every member. */}
      {event.registration_url || event.website_url || event.contact_email || event.contact_phone ? (
        <Card className="space-y-3 p-4">
          {event.registration_url ? (
            <a
              href={event.registration_url}
              target="_blank"
              rel="noopener noreferrer"
              className="block text-base font-semibold text-brand underline underline-offset-4"
            >
              {t("register")}
            </a>
          ) : null}
          {event.website_url ? (
            <a
              href={event.website_url}
              target="_blank"
              rel="noopener noreferrer"
              className="block text-base text-brand underline underline-offset-4"
            >
              {t("website")}
            </a>
          ) : null}
          {event.contact_email ? (
            <a
              href={`mailto:${event.contact_email}`}
              className="block text-base text-brand underline underline-offset-4"
            >
              {event.contact_email}
            </a>
          ) : null}
          {event.contact_phone ? (
            <a
              href={`tel:${event.contact_phone}`}
              className="block text-base text-brand underline underline-offset-4"
            >
              {event.contact_phone}
            </a>
          ) : null}
        </Card>
      ) : null}
    </main>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-sm font-semibold text-ink-faint">{label}</p>
      {/* break-words, or a long meeting note runs off the right edge of a phone: a flex or grid
          child grows past its parent unless told not to. */}
      <p className="break-words text-base text-ink">{value}</p>
    </div>
  );
}
