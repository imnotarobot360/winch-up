-- Winch Up :: what kind of event this is
--
-- Section 2 of the owner's spec asks for an event type. Its own migration, containing one statement,
-- for the reason that has already cost a split this week: a new enum label cannot be USED in the
-- transaction that adds it, and `supabase db push` wraps each migration file in a transaction. The
-- column that defaults to 'other' therefore cannot live in this file.
--
-- WHY THESE SEVEN. They are what the Facebook groups actually post: a run out somewhere, somebody
-- teaching recovery technique, a meet in a car park, a trail clean-up, raising money for a member
-- who needs it, a show, and the one that stops the list being a straitjacket. `other` is the default
-- precisely so that nobody has to pick wrongly to publish, and so that an event created before this
-- column existed does not silently claim to be a trail ride.

set search_path = public, extensions;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'event_type') then
    create type event_type as enum (
      'trail_ride',
      'training',
      'meetup',
      'cleanup',
      'fundraiser',
      'show',
      'other'
    );
  end if;
end
$$;

notify pgrst, 'reload schema';
