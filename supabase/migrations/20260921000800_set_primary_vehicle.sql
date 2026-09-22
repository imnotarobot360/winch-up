-- Winch Up :: choosing the primary rig
--
-- `vehicles_one_primary_per_user` is a partial unique index, so promoting a second vehicle means
-- demoting the first in the same breath. Doing that from the browser as two statements leaves a
-- window where the update succeeds, the insert fails, and the member has no primary at all --
-- or, with two tabs open, a unique violation they did nothing to deserve.
--
-- One function, one transaction. Scoped to the caller: p_vehicle_id is checked against
-- auth.uid() rather than trusted, so passing somebody else's vehicle id changes nothing.

set search_path = public, extensions;

create or replace function public.set_primary_vehicle(p_vehicle_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not exists (select 1 from vehicles where id = p_vehicle_id and user_id = v_user) then
    -- Same answer whether the row belongs to someone else or does not exist: a different message
    -- would confirm that an id is real.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  update vehicles set is_primary = false
   where user_id = v_user and is_primary and id <> p_vehicle_id;

  update vehicles set is_primary = true
   where id = p_vehicle_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.set_primary_vehicle(uuid) from public, anon;
grant execute on function public.set_primary_vehicle(uuid) to authenticated;
