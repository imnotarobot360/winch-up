-- Winch Up :: somewhere to put a photo of your rig
--
-- `vehicles.photo_path` has existed since the first schema and nothing has ever written to it.
-- This gives it a bucket and a rule.
--
-- WHY A SEPARATE BUCKET FROM request-photos
--
-- Different lifetime and different audience. A recovery photo is evidence of one job, is only
-- ever shown to the people on that job, and is swept when the request is scrubbed. A rig photo
-- is part of a member's profile, is shown to anyone who can see that profile, and lives as long
-- as the vehicle does. Sharing one bucket would mean the retention job that scrubs recoveries
-- has to know not to touch half its own contents.
--
-- PRIVATE, like the other one. No anon policies, no public URL. Reads go through a signed URL
-- minted server-side, which is what keeps a member's rig off the open internet and out of image
-- search. The cost is a signed URL per photo per page load, which is the same cost
-- profiles.avatar_path has always carried and the reason avatars are still initials.
--
-- PATH CONVENTION, enforced by the server and written down here so it stays stable:
--
--   vehicle-photos/<user_id>/<random-uuid>.jpg
--
-- Keyed by the OWNER, not the vehicle. A photo is uploaded before the vehicle row exists --
-- somebody adding their first rig picks the picture and fills the form in one go -- so the
-- vehicle id is not available yet. A fresh uuid per upload also means replacing a photo never
-- overwrites the old object mid-read, and an abandoned upload is identifiable: anything under
-- this bucket not referenced by vehicles.photo_path is sweepable.

set search_path = public, extensions;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'vehicle-photos',
  'vehicle-photos',
  false,
  5242880,                                            -- 5 MB, post-compression
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Admins can browse them in the console, same as request photos.
drop policy if exists vehicle_photos_admin_read on storage.objects;
create policy vehicle_photos_admin_read on storage.objects
  for select to authenticated
  using (bucket_id = 'vehicle-photos' and app.is_admin());

-- A member can read their OWN photos, and only by the path prefix the upload route derives
-- from their session. This is what lets the garage screen show a preview: it is a client
-- component reading under RLS, like the vehicle rows beside it, so it signs its own read URLs
-- rather than needing a privileged round trip.
--
-- Everyone ELSE reaches a rig photo through a server-rendered profile, which signs with the
-- service role. So this policy stays as narrow as it looks: your folder, nobody else's.
--
-- split_part, not storage.foldername(). The helper exists on hosted Supabase and NOT in the
-- local stack's stub storage schema, so a policy using it applies in production and fails to
-- create locally -- which means the thing guarding other members' photos would be the one
-- piece of this never exercised before deploy. split_part is core Postgres and identical here:
-- the first path segment, which the upload route sets to auth.uid() and the browser cannot
-- influence.
drop policy if exists vehicle_photos_owner_read on storage.objects;
create policy vehicle_photos_owner_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'vehicle-photos'
    and split_part(name, '/', 1) = (select auth.uid()::text)
  );

-- ---------------------------------------------------------------------------
-- Does this member have a photo of their rig?
--
-- One function, so the prompt banner, the profile screen and anything that later wants to ask
-- all get the same answer. "Their rig" means the PRIMARY vehicle: a member with three trucks is
-- not asked for three photos.
--
-- Deliberately NOT a gate. The owner's decision was that new members provide one at signup and
-- existing members are prompted -- nobody is blocked, and asking for a recovery always works.
-- ---------------------------------------------------------------------------

create or replace function public.my_rig_photo_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  uid        uuid := auth.uid();
  v_total    integer;
  v_primary  public.vehicles%rowtype;
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select count(*) into v_total from public.vehicles where user_id = uid;

  -- is_primary first, then oldest. A member who never set a primary still has a rig, and
  -- picking none would tell them they are complete when no photo exists anywhere.
  select * into v_primary
    from public.vehicles
   where user_id = uid
   order by is_primary desc, created_at
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'vehicle_count', v_total,
    'primary_vehicle_id', v_primary.id,
    'has_photo', v_primary.photo_path is not null,
    -- The prompt fires for a member with no vehicles at all as well: "add your rig" is the
    -- same ask, one step earlier.
    'needs_photo', v_total = 0 or v_primary.photo_path is null
  );
end;
$fn$;

comment on function public.my_rig_photo_status() is
  'Whether the caller has a photo on their primary rig. One answer shared by the banner and the '
  'profile screen. Not a gate -- see 20260928000900.';

revoke all on function public.my_rig_photo_status() from public, anon;
grant execute on function public.my_rig_photo_status() to authenticated, service_role;

notify pgrst, 'reload schema';
