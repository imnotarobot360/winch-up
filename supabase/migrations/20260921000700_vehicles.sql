-- Winch Up :: vehicles
--
-- Phase 4: a member may register several rigs. Until now a volunteer had exactly one, described
-- by three columns on `responders` (vehicle_class, vehicle_desc, drivetrain), which cannot say
-- "the Jeep has the winch, the F-250 has the gooseneck".
--
-- Those three columns stay where they are and keep doing their job. app.candidates() reads
-- responders.equipment to match, and rewriting the matching path to aggregate across vehicles
-- is a change to the one function that owns dispatch -- not something to do in the same
-- migration that introduces the table it would read from. responders.equipment remains the
-- declared "what I can bring"; vehicles are the detail behind that claim.
--
-- Everything here is self-reported. Nothing in this table is verified, and the schema does not
-- pretend otherwise: there is no `verified` column to be quietly assumed true by a later query.

set search_path = public, extensions;

create type recovery_points as enum ('none', 'front', 'rear', 'both', 'unknown');

create table vehicles (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,

  make              text check (make is null or length(btrim(make)) between 1 and 40),
  model             text check (model is null or length(btrim(model)) between 1 and 40),
  -- No upper bound of "this year": people register next year's truck, and a hard cap would
  -- reject it every January.
  year              smallint check (year is null or year between 1900 and 2100),

  vehicle_class     vehicle_class not null default 'truck',
  drivetrain        drivetrain not null default '4wd',
  tire_size         text check (tire_size is null or length(btrim(tire_size)) <= 30),

  recovery_points   recovery_points not null default 'unknown',
  has_winch         boolean not null default false,
  winch_capacity_lb integer check (winch_capacity_lb is null
                                   or winch_capacity_lb between 1000 and 60000),

  equipment         equipment_type[] not null default '{}',

  -- Private bucket, signed URLs only, like every other image here.
  photo_path        text,

  -- Free text for anything the enum cannot say. Same contact-info check as every other field a
  -- human types, so a phone number cannot be smuggled in through a vehicle note.
  notes             text check (
                      notes is null
                      or (length(notes) <= 280 and not public.contains_contact_info(notes))
                    ),

  is_primary        boolean not null default false,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index vehicles_user_idx on vehicles (user_id, created_at desc);

-- One primary per person, enforced by the database rather than by whichever screen wrote last.
create unique index vehicles_one_primary_per_user on vehicles (user_id) where is_primary;

create trigger vehicles_set_updated_at
  before update on vehicles
  for each row execute function app.set_updated_at();

-- A cap, so a compromised or careless session cannot fill the table. Ten rigs is more than
-- anybody in these groups actually owns.
create or replace function app.vehicles_limit()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if (select count(*) from vehicles where user_id = new.user_id) >= 10 then
    raise exception 'vehicle_limit' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger vehicles_limit
  before insert on vehicles
  for each row execute function app.vehicles_limit();

-- ---------------------------------------------------------------------------
-- RLS: your own rigs, and nobody else's.
--
-- Not public. Phase 8 may publish some of this on a member profile; that will be a decision with
-- a policy change behind it, not something that leaks because the default was permissive.
-- ---------------------------------------------------------------------------

alter table vehicles enable row level security;
revoke all on vehicles from anon, authenticated;

grant select, insert, update, delete on vehicles to authenticated;

create policy vehicles_owner_read on vehicles
  for select to authenticated
  using (user_id = auth.uid() or app.is_admin());

create policy vehicles_owner_insert on vehicles
  for insert to authenticated
  with check (user_id = auth.uid());

create policy vehicles_owner_update on vehicles
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy vehicles_owner_delete on vehicles
  for delete to authenticated
  using (user_id = auth.uid());
