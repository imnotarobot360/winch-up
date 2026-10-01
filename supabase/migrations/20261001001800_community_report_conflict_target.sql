-- Winch Up :: community_report names the index it is actually inferring
--
-- 20261001001700 replaced the blanket unique constraint on content_reports with two partial unique
-- indexes, so that a member can be reported again after a decision while a post still cannot. That
-- broke community_report(), which infers the conflict target by column list:
--
--   on conflict (target_kind, target_id, reporter_user_id) do nothing
--
-- A column list only matches a NON-partial index. With the blanket constraint gone, every call raised
--
--   there is no unique or exclusion constraint matching the ON CONFLICT specification
--
-- Reporting a post was broken, by a migration about reporting people.
--
-- WHAT CAUGHT IT, and what did not. Not the new suite, and not any assertion: community_test and
-- trails_test ABORTED, which pgTAP reports as zero failing assertions and a dubious exit 3. The
-- totals line read "928 passed, 0 failed" on a run where two whole suites never finished. Counting
-- exit codes is the only reason this was seen at all -- CLAUDE.md says so because of an earlier
-- instance of exactly this, and it has now paid for itself twice.
--
-- The fix is the predicate. `where target_kind <> 'member'` matches
-- content_reports_one_per_reporter_content exactly, which is the index this statement always meant.
-- community_report only ever handles post, comment and trail_condition -- it returns bad_kind for
-- anything else -- so the predicate is true for every row it inserts and the behaviour is unchanged.
--
-- Rebuilt from the live definition out of pg_proc. Nothing else is touched.

set search_path = public, extensions;

create or replace function public.community_report(
  p_kind   text,
  p_id     uuid,
  p_reason text,
  p_note   text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_reason report_reason;
  v_exists boolean;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_kind = 'post' then
    select exists (select 1 from community_posts where id = p_id) into v_exists;
  elsif p_kind = 'comment' then
    select exists (select 1 from community_comments where id = p_id) into v_exists;
  elsif p_kind = 'trail_condition' then
    select exists (select 1 from trail_conditions where id = p_id) into v_exists;
  else
    -- A MEMBER IS NOT REPORTED HERE. report_member() does that, because a report about a person needs
    -- a different queue and a different action -- suspension rather than hiding a body of text.
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  if not v_exists then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  begin
    v_reason := p_reason::report_reason;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_reason');
  end;

  if not app.check_rate_limit('content_report:' || v_me::text, 20, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into content_reports (target_kind, target_id, reporter_user_id, reason, note)
  values (p_kind, p_id, v_me, v_reason, nullif(btrim(coalesce(p_note, '')), ''))
  -- The predicate is what makes this match content_reports_one_per_reporter_content, which is the
  -- index this statement has always meant. A bare column list matches only a non-partial index, and
  -- the non-partial one stopped existing in 20261001001700.
  on conflict (target_kind, target_id, reporter_user_id)
    where target_kind <> 'member'
    do nothing;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.community_report(text, uuid, text, text) from public, anon;
grant execute on function public.community_report(text, uuid, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
