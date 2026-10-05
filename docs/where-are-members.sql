-- Winch Up :: where every member is, and how far they are from you
--
-- READ ONLY. One statement, no writes, nothing queued. Safe to run on production.
-- Paste the whole thing into the Supabase SQL editor.
--
-- THE POSITION EACH ROW REPORTS IS THE ONE DISPATCH WOULD USE, resolved exactly the way
-- app.candidates() resolves it, so this answers "who would my alerts actually reach" and not
-- merely "what did somebody type in". In order of preference:
--
--   1. a shared live position, but ONLY if share_location is on and the fix is fresher than
--      dispatch.location_freshness_minutes (default 120) -- a stale fix is deliberately ignored,
--      because a volunteer who was downtown three days ago is not downtown now;
--   2. the home point set when they turned availability on;
--   3. the centre of the ZIP they typed on /account/location.
--
-- THE JOIN TO responders IS LEFT ON PURPOSE. Most members have never turned availability on and
-- have no responders row at all; an inner join hides every one of them and the answer is then
-- quietly wrong in the direction of "we have hardly any members".
--
-- IF EVERY DISTANCE COMES BACK BLANK, read your own row first. The distances are measured from
-- your point, so if it says NO LOCATION there is nothing to measure from -- and if no row at all
-- says "you" in the alertable column, the email on the next line is not the one on your account.

with me as (
  select id as user_id from auth.users where lower(email) = 'jj.serram@gmail.com'
),
fresh as (
  select app.setting_int('dispatch.location_freshness_minutes', 120) as minutes
),
pt as (
  select
    p.user_id,
    coalesce(nullif(p.display_name, ''), r.first_name, '(no name)')   as who,
    nullif(concat_ws(', ', p.city, p.state), '')                     as stated_area,
    p.postal_code,
    case
      when r.share_location and r.last_location is not null
       and r.last_location_at > now() - make_interval(mins => f.minutes) then 'shared fix, live'
      when r.share_location and r.last_location is not null            then 'home point (shared fix too old)'
      when r.home_location is not null                                 then 'home point'
      when p.postal_center is not null                                 then 'ZIP centre'
      else 'NO LOCATION'
    end                                                              as position_from,
    case
      when r.share_location and r.last_location is not null
       and r.last_location_at > now() - make_interval(mins => f.minutes) then r.last_location
      when r.home_location is not null                                 then r.home_location
      else p.postal_center
    end                                                              as point,
    r.last_location_at,
    r.radius_miles,
    coalesce(p.available_to_help, false)                             as available_to_help,
    p.suspended_at,
    r.availability::text                                             as availability,
    r.approval::text                                                 as approval,
    coalesce(r.sms_opt_in, false)                                    as sms_opt_in,
    r.sms_opt_out_at,
    r.phone is not null                                              as has_phone,
    u.email is not null                                              as has_email
  from public.profiles p
  left join public.responders r on r.user_id = p.user_id
  left join auth.users u        on u.id      = p.user_id
  cross join fresh f
),
origin as (
  select point from pt where user_id = (select user_id from me)
)
select
  pt.who,
  pt.stated_area,
  pt.postal_code,
  pt.position_from,
  case
    when pt.point is null or o.point is null then null
    else round((extensions.st_distance(pt.point, o.point) / 1609.344)::numeric, 1)
  end                                                                as miles_from_you,
  pt.radius_miles                                                    as their_radius,
  -- Would a recovery of yours reach them at all? Distance is only the last of five gates.
  case
    when pt.user_id = (select user_id from me)      then 'you'
    when pt.suspended_at is not null                then 'no - suspended'
    when not pt.available_to_help                   then 'no - not available to help'
    when pt.availability is null                    then 'no - no recovery profile'
    when pt.availability <> 'active'                then 'no - paused'
    when pt.point is null                           then 'no - no location to match on'
    else 'yes'
  end                                                                as alertable,
  case
    when pt.sms_opt_out_at is not null then 'STOPPED'
    when not pt.has_phone              then 'no phone'
    when not pt.sms_opt_in             then 'not opted in'
    else 'text ok'
  end                                                                as sms,
  case when pt.has_email then 'email ok' else 'no email' end         as email,
  -- NOT a gate: app.candidates() has not checked approval since universal membership, only
  -- availability. Shown because it still drives the admin screens -- reading it as a dispatch
  -- gate sends you off approving members who were never blocked.
  pt.approval                                                        as approval_fyi,
  pt.last_location_at                                                as position_taken_at
from pt
left join origin o on true
order by miles_from_you nulls last, pt.who;
