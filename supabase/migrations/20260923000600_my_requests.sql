-- Winch Up :: a member's own recoveries, from inside the app
--
-- Spec section 2 asks the dashboard to show My Active Requests. It could not, because nothing
-- answered the question "what have I asked for" — and that is a worse gap than a missing panel.
--
-- The status page is reached by an unguessable token, which arrives once, by text. That is right
-- for the link being forwarded to whoever is helping, and it was the ONLY route: a member who
-- deleted the message, or filed from a phone that then died, had no way back to their own live
-- recovery from an account they were signed into. They could not cancel it, could not mark it
-- recovered, and could not file another one, because the schema allows one open request at a
-- time and the app gave them no way to see the one they had.
--
-- Returning the token to the person whose request it is gives nothing away: they filed it, and
-- the token exists so that they can reach it.
--
-- Found while writing the section 12 end-to-end tests, which needed to put an account back into
-- a known state and discovered there was no way to do it through the app.

set search_path = public, extensions;

create or replace function public.my_requests(p_limit integer default 10)
returns table (
  request_id      uuid,
  short_code      text,
  public_token    text,
  status          request_status,
  is_open         boolean,
  created_at      timestamptz,
  accepted_at     timestamptz,
  recovered_at    timestamptz,
  responder_name  text,
  offer_count     integer
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select
    r.id,
    r.short_code,
    r.public_token,
    r.status,
    r.status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site'),
    r.created_at,
    r.accepted_at,
    r.recovered_at,
    -- A first name only, and only once somebody is actually coming. The same rule the status
    -- page follows; this is a list, not a back door around it.
    (select resp.first_name from public.responders resp
      where resp.id = r.accepted_responder_id),
    (select count(*)::integer from public.dispatches d
      where d.request_id = r.id and d.state = 'offered')
  from public.requests r
  where r.requester_user_id = auth.uid()
    -- auth.uid() is null for an anonymous caller and `null = null` is null, so this returns
    -- nothing rather than everything. Spelled out because that is the failure that matters.
    and auth.uid() is not null
  order by
    (r.status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')) desc,
    r.created_at desc
  limit greatest(1, least(coalesce(p_limit, 10), 50));
$fn$;

revoke all on function public.my_requests(integer) from public, anon;
grant execute on function public.my_requests(integer) to authenticated, service_role;

comment on function public.my_requests(integer) is
  'Spec section 2: My Active Requests. Returns the caller''s own requests including the status '
  'token, which is theirs. Never returns anybody else''s: the filter is requester_user_id = '
  'auth.uid() and it refuses a null caller explicitly.';
