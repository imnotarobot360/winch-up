-- Winch Up :: somebody can be reported again
--
-- content_reports has carried a blanket unique constraint since it was created: one report per
-- (target_kind, target_id, reporter_user_id), forever. For a post or a comment that is exactly
-- right -- the words do not change, so reporting them twice is the same report twice.
--
-- A MEMBER IS NOT A POST. A person is a continuing relationship. Somebody who reported harassment in
-- March and is harassed again in September has to be able to say so, and under the blanket rule they
-- could not: the row from March still existed, actioned and closed, and the insert was refused.
--
-- report_member() in 20261001001400 already believed this -- its comment says "once a report has been
-- dealt with, the same member can be reported again, because people reoffend" -- and it checked for
-- an OPEN report before inserting. It was right about the policy and wrong about the schema, so the
-- second report hit the constraint as a raw 23505 and the member saw "that did not go through".
-- Found by e2e/member-directory.spec.ts on its second run, which is the first run where a previous
-- report existed. A single run would never have shown it.
--
-- So: the blanket constraint becomes two indexes with the same force, differing only for members.

set search_path = public, extensions;

alter table public.content_reports
  drop constraint if exists content_reports_target_kind_target_id_reporter_user_id_key;

-- Content: unchanged. One report per reporter per post, comment or condition report, ever.
create unique index if not exists content_reports_one_per_reporter_content
  on public.content_reports (target_kind, target_id, reporter_user_id)
  where target_kind <> 'member';

-- Members: one OPEN report per reporter. A closed one does not block a new complaint, and two
-- open ones about the same person from the same reporter still cannot happen -- which is what the
-- constraint was protecting the moderation queue from in the first place.
create unique index if not exists content_reports_one_open_per_reporter_member
  on public.content_reports (target_id, reporter_user_id)
  where target_kind = 'member' and status in ('new', 'reviewing');

-- ---------------------------------------------------------------------------
-- And the function stops depending on having read the index correctly
-- ---------------------------------------------------------------------------
--
-- The read-then-insert above is still there, because it is what makes a double press of the button
-- return the existing report rather than an error. But two concurrent presses both pass that check,
-- and a reader of this function should not have to know the index definition to know what happens
-- next. Catching the violation by name is the same pattern create_request uses for
-- requests_one_open_per_account, and for the same reason.

create or replace function public.report_member(
  p_user_id uuid,
  p_reason  report_reason,
  p_note    text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_user_id = v_me then
    return jsonb_build_object('ok', false, 'error', 'cannot_report_self');
  end if;

  -- The same not_found a profile read gives, for the same reason: this must not become a way to find
  -- out whether an account exists, is suspended, or has blocked you.
  if not exists (select 1 from public.profiles p where p.user_id = p_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if not app.check_rate_limit('report_member:' || v_me::text, 20, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- One OPEN report per reporter per member. A second press of the button, or a second thought about
  -- the same person this week, should not put two rows in front of a moderator. A report that has
  -- already been dealt with does not block a new one.
  select id into v_id
    from public.content_reports
   where target_kind = 'member'
     and target_id = p_user_id
     and reporter_user_id = v_me
     and status in ('new', 'reviewing')
   limit 1;

  if v_id is not null then
    return jsonb_build_object('ok', true, 'report_id', v_id, 'already_open', true);
  end if;

  begin
    insert into public.content_reports (target_kind, target_id, reporter_user_id, reason, note)
    values ('member', p_user_id, v_me, p_reason, nullif(btrim(p_note), ''))
    returning id into v_id;
  exception
    when unique_violation then
      -- Two presses landed at once. The other one won, and that is a success for this caller: their
      -- report exists and a moderator will see it.
      select id into v_id
        from public.content_reports
       where target_kind = 'member'
         and target_id = p_user_id
         and reporter_user_id = v_me
         and status in ('new', 'reviewing')
       limit 1;

      return jsonb_build_object('ok', true, 'report_id', v_id, 'already_open', true);
  end;

  return jsonb_build_object('ok', true, 'report_id', v_id, 'already_open', false);
end;
$fn$;

revoke all on function public.report_member(uuid, report_reason, text) from public, anon;
grant execute on function public.report_member(uuid, report_reason, text) to authenticated, service_role;

notify pgrst, 'reload schema';
