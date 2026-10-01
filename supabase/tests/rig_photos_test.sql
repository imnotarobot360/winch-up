-- Winch Up :: a photo of your rig
--
-- Run with:  supabase test db
--
-- The owner asked that everybody put a picture of their rig on their profile, and chose the
-- gentle enforcement: new members provide one at signup, existing members are prompted, and
-- asking for a recovery is never blocked by it. So there is no gate to test. What there IS to
-- test is that the PROMPT is honest, because a prompt that fires when it should not is a nag
-- over the map somebody opens with their truck in a creek, and one that stays silent when it
-- should fire means the feature does nothing at all.
--
-- The case that actually matters is the third one: a photo on a rig that is NOT the primary.
-- A naive "does this member have any photo anywhere" check passes that and stops asking, while
-- the profile banner -- which shows the PRIMARY rig -- is still blank.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: one member with rigs, one with none.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('e1000000-0000-4000-8000-00000000000e'::uuid, 'rig-owner@example.invalid'),
  ('e2000000-0000-4000-8000-00000000000e'::uuid, 'rig-none@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

insert into public.responders (
  id, user_id, phone, first_name, home_location, radius_miles, equipment,
  approval, availability, vehicle_desc, recoveries_count, redacted_at
) values
  ('e1000000-1111-4111-8111-00000000000e', 'e1000000-0000-4000-8000-00000000000e',
   '+15125559001', 'Rigowner',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Owner Rig', 0, null),
  ('e2000000-1111-4111-8111-00000000000e', 'e2000000-0000-4000-8000-00000000000e',
   '+15125559002', 'Noneowner',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'No Rig', 0, null)
on conflict (id) do nothing;

-- available_to_help is set because this member is a volunteer, not because it is needed to be
-- seen: since 20261001001100 every active member is in the directory either way.
update public.profiles set available_to_help = true,
                           display_name = 'Rigowner'
 where user_id = 'e1000000-0000-4000-8000-00000000000e';

-- ---------------------------------------------------------------------------
-- No vehicles at all
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-00000000000e","role":"authenticated"}';

select ok(
  (public.my_rig_photo_status() ->> 'needs_photo')::boolean,
  'a member with no vehicles is prompted'
);

select is(
  (public.my_rig_photo_status() ->> 'vehicle_count')::integer,
  0,
  'and the count tells the banner to say "add your rig" rather than "add a photo"'
);

reset role;

-- ---------------------------------------------------------------------------
-- A rig, no photo
-- ---------------------------------------------------------------------------

insert into public.vehicles (id, user_id, make, model, is_primary, created_at)
values ('e1aa0000-0000-4000-8000-00000000000e', 'e1000000-0000-4000-8000-00000000000e',
        'Jeep', 'Wrangler', true, now() - interval '2 days');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e1000000-0000-4000-8000-00000000000e","role":"authenticated"}';

select ok(
  (public.my_rig_photo_status() ->> 'needs_photo')::boolean,
  'a member whose rig has no photo is prompted'
);

select is(
  (public.my_rig_photo_status() ->> 'vehicle_count')::integer,
  1,
  'and is asked for a photo rather than for a rig'
);

reset role;

-- ---------------------------------------------------------------------------
-- THE ONE THAT MATTERS: a photo, but on the wrong rig
-- ---------------------------------------------------------------------------

insert into public.vehicles (id, user_id, make, model, is_primary, photo_path, created_at)
values ('e1bb0000-0000-4000-8000-00000000000e', 'e1000000-0000-4000-8000-00000000000e',
        'Toyota', '4Runner', false,
        'e1000000-0000-4000-8000-00000000000e/secondary.jpg', now() - interval '1 day');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e1000000-0000-4000-8000-00000000000e","role":"authenticated"}';

select ok(
  (public.my_rig_photo_status() ->> 'needs_photo')::boolean,
  'a photo on a NON-primary rig does not satisfy it: the profile banner shows the primary one, '
  'so stopping the prompt here would leave that banner blank forever'
);

reset role;

-- ---------------------------------------------------------------------------
-- A photo on the primary rig
-- ---------------------------------------------------------------------------

update public.vehicles
   set photo_path = 'e1000000-0000-4000-8000-00000000000e/primary.jpg'
 where id = 'e1aa0000-0000-4000-8000-00000000000e';

set local role authenticated;
set local request.jwt.claims = '{"sub":"e1000000-0000-4000-8000-00000000000e","role":"authenticated"}';

select ok(
  not (public.my_rig_photo_status() ->> 'needs_photo')::boolean,
  'and a photo on the primary rig stops the prompt'
);

select is(
  public.member_profile('e1000000-0000-4000-8000-00000000000e')
    -> 'member' ->> 'rig_photo_path',
  'e1000000-0000-4000-8000-00000000000e/primary.jpg',
  'the profile carries the PRIMARY rig''s photo, not the other one'
);

reset role;

-- ---------------------------------------------------------------------------
-- No primary flag set at all
--
-- Nothing forces is_primary to be true for anybody, so a member can own two rigs and have
-- flagged neither. Falling back to the oldest keeps the prompt and the profile agreeing;
-- picking nothing would report them complete with no photo anywhere.
-- ---------------------------------------------------------------------------

update public.vehicles set is_primary = false
 where user_id = 'e1000000-0000-4000-8000-00000000000e';
update public.vehicles set photo_path = null
 where id = 'e1aa0000-0000-4000-8000-00000000000e';

set local role authenticated;
set local request.jwt.claims = '{"sub":"e1000000-0000-4000-8000-00000000000e","role":"authenticated"}';

select ok(
  (public.my_rig_photo_status() ->> 'needs_photo')::boolean,
  'with no primary flagged it falls back to the oldest rig, which has no photo, and still asks'
);

reset role;

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------

select ok(
  exists (select 1 from storage.buckets where id = 'vehicle-photos' and not public),
  'the rig photo bucket exists and is PRIVATE: a member''s truck is not on the open internet'
);

select ok(
  exists (
    select 1 from pg_policies
     where tablename = 'objects' and policyname = 'vehicle_photos_owner_read'
  ),
  'a member can read their own rig photos, which is what lets the garage screen preview them'
);

select is(
  (select count(*)::integer from pg_policies
    where tablename = 'objects' and policyname like 'vehicle_photos%'),
  2,
  'and exactly two policies touch this bucket -- owner read and admin read, nothing wider'
);

select ok(
  not has_function_privilege('anon', 'public.my_rig_photo_status()', 'execute'),
  'anon cannot ask whether somebody has a rig photo'
);

select * from finish();
rollback;
