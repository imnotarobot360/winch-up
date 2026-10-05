-- Recovery SMS consent becomes a CHOICE rather than a side effect of proving a phone number.
--
-- The spec: "A verified phone number does NOT automatically mean the member has consented to
-- recovery SMS messages." The separate field it asks for already existed -- responders.sms_opt_in,
-- enforced in app.notify_ring() around the SMS and only the SMS, so a member without it keeps
-- their push and in-app alert. What was wrong was the DEFAULT: `not null default true` meant a row
-- was born consenting, so proving a phone was exactly what granted consent, and the only way to
-- decline was to receive a text and reply STOP. Opting out by being texted is not consent.
--
-- WHY THIS IS SAFE TO DO TODAY AND EXPENSIVE LATER. `sms.outbound_enabled` ships false and no
-- recovery SMS has ever been sent to anybody, so there is no reliance interest and no backlog to
-- reconcile. The same change after the switch is thrown silently mutes members who had been
-- getting alerts.
--
-- "NEVER CHOSE" AND "OPTED OUT" ARE DIFFERENT STATES and this migration keeps them apart.
-- sms_opt_out_at stays null for somebody who simply never answered the question; it is set only by
-- STOP. A trigger from 20260920000500 enforces that an opted-out row cannot also be opted in, so
-- anything turning consent back ON has to clear that timestamp.

set search_path = public, extensions;

-- 1. New rows are born WITHOUT consent.
alter table public.responders alter column sms_opt_in set default false;

-- 2. Existing rows: nobody has ever been asked, so nobody has consented. Rows that said STOP are
--    already false and are left alone -- re-writing them would lose the distinction above.
update public.responders
   set sms_opt_in = false
 where sms_opt_in
   and sms_opt_out_at is null;

comment on column public.responders.sms_opt_in is
  'Explicit consent to receive recovery call-out SMS. Defaults FALSE: a verified phone is not '
  'consent. Set through set_my_recovery_sms() or by texting START; cleared by STOP, which also '
  'stamps sms_opt_out_at.';

-- 3. A member turns it on and off themselves.
--
-- An RPC rather than a column grant: `responders` holds a phone number and a home location, it has
-- `grant select` and NO update grant for authenticated, and every other member-facing write to it
-- goes through a security definer function. Widening table privileges for one boolean would be the
-- odd one out, and the narrow function is also where the opted-out invariant gets maintained.
create or replace function public.set_my_recovery_sms(p_opt_in boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  me      uuid := auth.uid();
  touched integer;
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'signed_out');
  end if;

  update public.responders
     set sms_opt_in = p_opt_in,
         -- Turning consent ON clears the STOP stamp, because the trigger forbids holding both and
         -- because choosing it on this screen is the same statement as texting START. Availability
         -- is deliberately NOT restored: STOP also paused them, and un-pausing somebody because
         -- they ticked an SMS box would put them back on call without their saying so.
         sms_opt_out_at = case when p_opt_in then null else sms_opt_out_at end
   where user_id = me;

  get diagnostics touched = row_count;

  -- A member with no responders row has never turned availability on, so there is nothing to
  -- consent to yet and nothing to write. Said plainly rather than reported as success: a zero-row
  -- update that returns ok is how /account spent a day claiming it had saved.
  if touched = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_recovery_profile');
  end if;

  return jsonb_build_object('ok', true, 'sms_opt_in', p_opt_in);
end;
$fn$;

revoke all on function public.set_my_recovery_sms(boolean) from public, anon;
grant execute on function public.set_my_recovery_sms(boolean) to authenticated;

-- 4. Did it land? Counted rather than assumed -- an `alter column set default` affects no existing
--    row, so the update above is the only thing that could have changed anybody.
select
  (select count(*) from public.responders where sms_opt_in)                         as opted_in,
  (select count(*) from public.responders where not sms_opt_in
                                            and sms_opt_out_at is null)             as never_chose,
  (select count(*) from public.responders where sms_opt_out_at is not null)          as said_stop,
  (select column_default from information_schema.columns
    where table_schema = 'public' and table_name = 'responders'
      and column_name = 'sms_opt_in')                                               as new_default;
