-- Winch Up :: a member's profile carries a photo of their rig
--
-- member_profile() already reports vehicle_desc and vehicle_class -- the words. The design puts
-- the PICTURE at the top of that screen, and it is the thing somebody actually looks at when
-- deciding whether the person driving toward them is who they say they are.
--
-- THE PRIMARY VEHICLE, and only that one. A member with three trucks gets one banner, the same
-- rig my_rig_photo_status() asks them for. is_primary first then oldest, identical ordering, so
-- the photo they are prompted to add is the photo that appears.
--
-- The path only. Signing it is the caller's job, because the bucket is private and a signed URL
-- expires: baking one into an RPC result would produce a link that is already stale by the time
-- anything caches the row.
--
-- NOT added to nearby_members. The directory renders up to fifty members at once, and fifty
-- signed URLs per page load is a real cost for a list whose design shows initials anyway. The
-- photo is on the profile, which is one member at a time.

set search_path = public, extensions;

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
           'user_id',      p.user_id,
           'display_name', coalesce(p.display_name, r.first_name),
           'avatar_path',  p.avatar_path,
           'home_region',  p.home_region,
           'vehicle_desc', r.vehicle_desc,
           'vehicle_class', r.vehicle_class,
           'equipment',    r.equipment,
           'available',    r.availability = 'active',
           'verified',     r.approval = 'approved',
           -- Maintained by the dispatch path on completion. The one metric that is real.
           'recoveries',   r.recoveries_count,
           'member_since', p.created_at,
           -- The path, not a URL. See the header.
           'rig_photo_path', (
             select v.photo_path
               from public.vehicles v
              where v.user_id = p.user_id
              order by v.is_primary desc, v.created_at
              limit 1
           ),
           'miles',        case
                             when me.home_location is null or r.home_location is null then null
                             else app.coarse_miles(
                                    extensions.st_distance(me.home_location, r.home_location))
                           end
         ) into v_row
    from public.profiles p
    join public.responders r on r.user_id = p.user_id
    left join public.responders me on me.user_id = v_me and me.redacted_at is null
   where p.user_id = p_user_id
     and p.profile_public
     and p.available_to_help
     and r.redacted_at is null;

  if v_row is null then
    -- The same answer for "no such member", "not public" and "not available", so the directory
    -- cannot be used to test whether a given account exists.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'member', v_row);
end;
$fn$;

-- Supabase's default privileges re-grant execute to anon on every CREATE. See 20260928000300.
revoke all on function public.member_profile(uuid) from public, anon;
grant execute on function public.member_profile(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
