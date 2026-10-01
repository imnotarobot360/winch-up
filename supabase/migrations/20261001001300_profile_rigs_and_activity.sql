-- Winch Up :: a member's rigs and their community activity, on their profile
--
-- Spec §2 and §3: a profile shows "vehicle information and photographs marked for community
-- display" and "community activity intended to be public".
--
-- WHY THE FLAG DEFAULTS TO TRUE
--
-- "Marked for community display" sounds like an opt-in, and the first instinct is to default it off
-- and let people turn it on. That is exactly the mistake this whole phase exists to undo: the
-- directory shipped behind two default-off switches and was empty for weeks, which is not privacy,
-- it is a feature nobody could use. §3 lists vehicle information among the things visible to all
-- authenticated members, so the default is visible and the flag is there for the member with one
-- rig they would rather not show -- a work truck with signage, a plate in a photograph.
--
-- A rig photograph is not a recovery photograph. Recovery photographs are the ones taken while
-- somebody is stuck, they carry a location and a bad moment, and they stay behind
-- app.may_see_request_photos with its ring and its freshness window. Nothing here touches them.
--
-- WHAT A COUNT OF POSTS IS AND IS NOT
--
-- posts and comments are counted only where status = 'visible'. A hidden or removed post is a
-- moderation decision, and counting it would leak that the decision happened -- "this member has
-- forty posts" against a feed showing thirty-eight is a moderation log in arithmetic.
--
-- No rating, no reputation, no streak. The design reference shows stars and years of experience and
-- this product has neither; a count of posts is a fact, a score out of five is an invention.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Which rigs a member is happy to show
-- ---------------------------------------------------------------------------

alter table public.vehicles
  add column if not exists show_in_community boolean not null default true;

comment on column public.vehicles.show_in_community is
  'Whether this rig appears on the member''s public profile. Defaults to true: vehicle details are '
  'listed in the spec as visible to other members, and the flag exists for the one rig somebody '
  'would rather keep off it.';

-- ---------------------------------------------------------------------------
-- 2. The rigs, as a separate call
-- ---------------------------------------------------------------------------
--
-- Separate from member_profile() on purpose. A profile is one jsonb object and a member may have
-- several rigs, each with a photo path that the CALLER has to sign -- the bucket is private and a
-- signed URL expires, so baking one into an RPC result produces a link that is stale before
-- anything caches the row. Keeping the rigs in their own call means the page can sign the handful
-- it is about to render and nothing else.
--
-- Same listability rule as everything else, through the same function: a member whose profile is
-- not readable has no readable rigs either, or this is a way round that.

create or replace function public.member_rigs(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not exists (
    select 1
      from public.profiles p
      left join public.responders r on r.user_id = p.user_id
     where p.user_id = p_user_id
       and app.member_is_listable(p, r, v_me)
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select coalesce(jsonb_agg(v order by v.is_primary desc, v.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      veh.id,
      veh.make,
      veh.model,
      veh.year,
      veh.vehicle_class,
      veh.drivetrain,
      veh.tire_size,
      veh.recovery_points,
      veh.has_winch,
      veh.winch_capacity_lb,
      veh.equipment,
      -- The PATH. See the header: signing is the caller's job.
      veh.photo_path,
      veh.is_primary,
      veh.created_at
      -- notes is deliberately absent. It is a free-text field a member wrote for themselves, with
      -- no contains_contact_info CHECK on it, so publishing it here would be a new way to put a
      -- phone number in front of strangers -- the one thing this product keeps private throughout.
      from public.vehicles veh
     where veh.user_id = p_user_id
       and veh.show_in_community
     order by veh.is_primary desc, veh.created_at
     limit 12
  ) v;

  return jsonb_build_object('ok', true, 'rigs', v_rows);
end;
$fn$;

revoke all on function public.member_rigs(uuid) from public, anon;
grant execute on function public.member_rigs(uuid) to authenticated, service_role;

-- The member needs to be able to set the flag on their own rigs. vehicles is owner-scoped under
-- RLS (vehicles_owner_update), so this is a column grant on top of a policy that already restricts
-- the rows to theirs.
grant update (show_in_community) on public.vehicles to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Community activity on the profile
-- ---------------------------------------------------------------------------
--
-- Added to member_profile() rather than given its own call: two counts are cheap, they belong in
-- the same paint as the rest of the header, and a second round trip for two integers is waste.
--
-- Rebuilt from the live definition, which is 20261001001100.

create or replace function public.member_profile(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me  uuid := auth.uid();
  v_row jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select jsonb_build_object(
           'user_id',       p.user_id,
           'display_name',  coalesce(nullif(btrim(p.display_name), ''), r.first_name),
           'avatar_path',   p.avatar_path,
           'home_region',   p.home_region,
           'vehicle_desc',  r.vehicle_desc,
           'vehicle_class', r.vehicle_class,
           'equipment',     coalesce(r.equipment, '{}'::equipment_type[]),
           'available',     (p.available_to_help
                             and coalesce(r.availability, 'paused') = 'active'),
           'verified',      coalesce(r.approval = 'approved', false),
           -- Maintained by the dispatch path on completion. The one metric here that is real: the
           -- design reference also shows a rating and years of experience, and inventing either
           -- would be inventing a reputation for a volunteer.
           'recoveries',    coalesce(r.recoveries_count, 0),
           'member_since',  p.created_at,
           -- Community activity (§2, §3). Visible content only -- counting a hidden post would
           -- publish the moderation decision as arithmetic.
           'posts',         (
              select count(*)
                from public.community_posts cp
               where cp.author_user_id = p.user_id and cp.status = 'visible'
           ),
           'comments',      (
              select count(*)
                from public.community_comments cc
               where cc.author_user_id = p.user_id and cc.status = 'visible'
           ),
           -- How many rigs they are showing, so the page knows whether to fetch them at all.
           'rig_count',     (
              select count(*)
                from public.vehicles v
               where v.user_id = p.user_id and v.show_in_community
           ),
           -- The primary rig, is_primary first then oldest -- the same ordering
           -- my_rig_photo_status() prompts against, so the photo they were asked for is the photo
           -- that appears. The PATH only: the bucket is private and signing it is the caller's job,
           -- because a signed URL baked into an RPC result is stale before anything caches it.
           'rig_photo_path', (
              select v.photo_path
                from public.vehicles v
               where v.user_id = p.user_id and v.photo_path is not null and v.show_in_community
               order by v.is_primary desc, v.created_at asc
               limit 1
           ),
           'miles',         case
                              when me.home_location is null or r.home_location is null then null
                              else app.coarse_miles(
                                     extensions.st_distance(me.home_location, r.home_location))
                            end
         ) into v_row
    from public.profiles p
    left join public.responders r on r.user_id = p.user_id
    left join public.responders me on me.user_id = v_me and me.redacted_at is null
   where p.user_id = p_user_id
     and app.member_is_listable(p, r, v_me);

  if v_row is null then
    -- One answer for "no such member", "suspended" and "blocked", so the profile route cannot be
    -- used to tell those apart.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'member', v_row);
end;
$fn$;

revoke all on function public.member_profile(uuid) from public, anon;
grant execute on function public.member_profile(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
