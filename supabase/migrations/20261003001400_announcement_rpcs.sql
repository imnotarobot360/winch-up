-- Winch Up :: reading and writing announcements
--
-- Section 1 of the owner's spec, and section 14's "estimated audience before publishing".
--
-- NOTHING HERE SENDS A NOTIFICATION, AND THAT IS A DECISION.
--
-- An announcement appears in the app and nowhere else for now. Three reasons, in order of weight:
--
--   1. CLAUDE.md's rule -- "notifications do not send SMS for anything the dispatch path already texts
--      about, because paying per message to say something already on the screen is waste" -- applies
--      doubly to marketing. `sms.enabled_templates` is an allowlist and nothing would be added to it.
--   2. `notify_marketing` ships FALSE, so a marketing announcement would reach almost nobody by push
--      anyway, and routing it through the consent flag correctly is more work than this phase can
--      verify. The `category` column records the distinction so that work is already decided.
--   3. notification_kind would need a new label, which needs its own migration, and a producer -- and
--      CLAUDE.md is firm that producers are TRIGGERS over rows that already exist, never calls bolted
--      into an existing function. That is a phase, not a line.
--
-- So: in-app, dismissible, targeted. An honest small feature rather than a notification pipeline that
-- half works.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. What a member sees
-- ---------------------------------------------------------------------------

create or replace function public.my_announcements(p_limit integer default 10)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_rows   jsonb;
  v_city   text;
  v_state  text;
  v_postal text;
  v_center extensions.geography;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- The member's STATED area. Four scalars and nothing else from the row, so that no function in this
  -- path is able to reach for the recovery position on a volunteer record.
  select p.city, p.state, p.postal_code, p.postal_center
    into v_city, v_state, v_postal, v_center
    from public.profiles p
   where p.user_id = v_me;

  select coalesce(jsonb_agg(to_jsonb(a) order by a.pinned desc, a.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select an.id, an.title, an.body, an.category::text as category,
           an.link_url, an.link_label, an.pinned, an.created_at
      from public.announcements an
     where an.status = 'published'
       -- The window. A null start means "as soon as it was published".
       and (an.starts_at is null or an.starts_at <= now())
       and (an.ends_at is null or an.ends_at >= now())
       -- Not already closed by this member. Permanent, by design.
       and not exists (
         select 1 from public.announcement_dismissals d
          where d.announcement_id = an.id and d.user_id = v_me
       )
       -- TARGETING FILTERS HERE, unlike events_upcoming(). The reasoning is in 20261003001300: an
       -- announcement is pushed at somebody who did not ask for it and there is no directory of them
       -- to browse, so one about a gate four hundred miles away is pure noise. No targeting rows means
       -- everybody.
       and app.member_matches_target('announcement', an.id, v_state, v_city, v_postal, v_center)
     order by an.pinned desc, an.created_at desc
     limit greatest(1, least(coalesce(p_limit, 10), 50))
  ) a;

  return jsonb_build_object('ok', true, 'announcements', v_rows);
end;
$fn$;

revoke all on function public.my_announcements(integer) from public, anon;
grant execute on function public.my_announcements(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Closing one
-- ---------------------------------------------------------------------------

create or replace function public.dismiss_announcement(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- Published only. Dismissing an id that is not a live announcement would otherwise tell a caller
  -- which ids exist, and a draft is somebody's unfinished words.
  if not exists (
    select 1 from public.announcements where id = p_id and status = 'published'
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Idempotent. A second tap over one bar of signal is the same intention as the first, and this is
  -- the kind of button that gets double-tapped.
  insert into public.announcement_dismissals (announcement_id, user_id)
  values (p_id, v_me)
  on conflict (announcement_id, user_id) do nothing;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.dismiss_announcement(uuid) from public, anon;
grant execute on function public.dismiss_announcement(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Writing one
-- ---------------------------------------------------------------------------

create or replace function public.admin_save_announcement(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me      uuid := auth.uid();
  v_id      uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_targets jsonb := coalesce(p_payload -> 'targets', '[]'::jsonb);
  v_target  jsonb;
  v_new     boolean := v_id is null;
begin
  -- Raises 'forbidden', or 'mfa_required' when security.require_admin_mfa is on and this session has
  -- not been challenged. app.require_admin() returns void -- it raises or it does not.
  perform app.require_admin();

  if v_new then
    insert into public.announcements (
      title, body, category, status, link_url, link_label, starts_at, ends_at, pinned, created_by
    ) values (
      btrim(coalesce(p_payload ->> 'title', '')),
      btrim(coalesce(p_payload ->> 'body', '')),
      coalesce(nullif(p_payload ->> 'category', ''), 'operational')::announcement_category,
      coalesce(nullif(p_payload ->> 'status', ''), 'draft')::announcement_status,
      nullif(btrim(coalesce(p_payload ->> 'link_url', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'link_label', '')), ''),
      nullif(p_payload ->> 'starts_at', '')::timestamptz,
      nullif(p_payload ->> 'ends_at', '')::timestamptz,
      coalesce((p_payload ->> 'pinned')::boolean, false),
      v_me
    )
    returning id into v_id;
  else
    update public.announcements set
      title      = btrim(coalesce(p_payload ->> 'title', title)),
      body       = btrim(coalesce(p_payload ->> 'body', body)),
      category   = coalesce(nullif(p_payload ->> 'category', ''), category::text)::announcement_category,
      status     = coalesce(nullif(p_payload ->> 'status', ''), status::text)::announcement_status,
      link_url   = nullif(btrim(coalesce(p_payload ->> 'link_url', '')), ''),
      link_label = nullif(btrim(coalesce(p_payload ->> 'link_label', '')), ''),
      starts_at  = nullif(p_payload ->> 'starts_at', '')::timestamptz,
      ends_at    = nullif(p_payload ->> 'ends_at', '')::timestamptz,
      pinned     = coalesce((p_payload ->> 'pinned')::boolean, pinned),
      updated_at = now()
    where id = v_id;

    if not found then
      return jsonb_build_object('ok', false, 'error', 'no_such_announcement');
    end if;
  end if;

  -- Replaced wholesale when `targets` is present, left alone when the key is absent. Those are
  -- different intentions: an empty array means "everybody now", while a call that omits the key -- a
  -- status change, say -- must not silently widen an announcement to the whole membership.
  if p_payload ? 'targets' then
    delete from public.target_locations where scope = 'announcement' and target_id = v_id;

    for v_target in select * from jsonb_array_elements(v_targets) loop
      insert into public.target_locations (scope, target_id, kind, state, city, postal_code,
                                           center, radius_miles)
      values (
        'announcement', v_id,
        (v_target ->> 'kind')::target_kind,
        nullif(upper(btrim(coalesce(v_target ->> 'state', ''))), ''),
        nullif(btrim(coalesce(v_target ->> 'city', '')), ''),
        nullif(btrim(coalesce(v_target ->> 'postal_code', '')), ''),
        case
          when (v_target ->> 'lng') is not null and (v_target ->> 'lat') is not null
            then extensions.st_setsrid(
                   extensions.st_point((v_target ->> 'lng')::double precision,
                                       (v_target ->> 'lat')::double precision),
                   4326)::extensions.geography
        end,
        nullif(v_target ->> 'radius_miles', '')::integer
      )
      on conflict do nothing;
    end loop;
  end if;

  perform app.audit(
    case when v_new then 'announcement.create' else 'announcement.update' end,
    'announcement', v_id::text,
    jsonb_build_object('status', p_payload ->> 'status',
                       'category', p_payload ->> 'category',
                       'targets', jsonb_array_length(v_targets))
  );

  return jsonb_build_object('ok', true, 'id', v_id,
                            'audience', app.target_audience_count('announcement', v_id));
exception
  when check_violation then
    return jsonb_build_object('ok', false, 'error',
      case
        when sqlerrm like '%announcements_link_is_web%'       then 'bad_url'
        when sqlerrm like '%announcements_title_sane%'        then 'bad_title'
        when sqlerrm like '%announcements_body_sane%'         then 'bad_body'
        when sqlerrm like '%announcements_label_needs_link%'  then 'label_without_link'
        when sqlerrm like '%announcements_window_makes_sense%' then 'bad_window'
        else 'invalid'
      end);
end;
$fn$;

revoke all on function public.admin_save_announcement(jsonb) from public, anon;
grant execute on function public.admin_save_announcement(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The admin list
-- ---------------------------------------------------------------------------

create or replace function public.admin_announcements(
  p_status text default null,
  p_limit  integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc), '[]'::jsonb) into v_rows
  from (
    select an.id, an.title, an.body, an.category::text as category, an.status::text as status,
           an.link_url, an.link_label, an.starts_at, an.ends_at, an.pinned, an.created_at,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'kind', t.kind::text, 'state', t.state, 'city', t.city,
                      'postal_code', t.postal_code, 'radius_miles', t.radius_miles)
                    order by t.kind, t.state, t.city, t.postal_code)
               from public.target_locations t
              where t.scope = 'announcement' and t.target_id = an.id
           ), '[]'::jsonb) as targets,
           -- Section 14: the number an admin needs BEFORE publishing. "Is this aimed at anybody at
           -- all" is the decision being made on this screen.
           app.target_audience_count('announcement', an.id) as audience,
           (select count(*)::integer from public.announcement_dismissals d
             where d.announcement_id = an.id) as dismissed_count
      from public.announcements an
     where (p_status is null or an.status::text = p_status)
     order by an.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) a;

  return jsonb_build_object('ok', true, 'announcements', v_rows);
end;
$fn$;

revoke all on function public.admin_announcements(text, integer) from public, anon;
grant execute on function public.admin_announcements(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Orphaned targeting
-- ---------------------------------------------------------------------------
--
-- The price of one polymorphic targeting table is no foreign key, paid by a trigger per parent. Ad
-- campaigns and events already have one; announcements needs its own or deleting one leaves rows that
-- nothing counts and that would come back to life if a new announcement were ever issued the same
-- uuid.

drop trigger if exists announcements_sweep_targets on public.announcements;
create trigger announcements_sweep_targets
  after delete on public.announcements
  for each row execute function app.sweep_target_locations('announcement');

notify pgrst, 'reload schema';
