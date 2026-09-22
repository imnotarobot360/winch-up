-- Winch Up :: reading and triaging safety reports
--
-- safety_incidents has no table grants, so this is the only way in. Both functions gate on
-- app.require_admin() first, which raises rather than returning an empty list: an admin screen
-- that silently shows nothing to a non-admin is indistinguishable from one with no reports, and
-- that is exactly the wrong thing to be ambiguous about.

set search_path = public, extensions;

create or replace function public.admin_incidents(
  p_status text default null,
  p_limit  integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_rows
  from (
    select
      i.id,
      i.category,
      i.status,
      i.description,
      i.admin_notes,
      i.created_at,
      i.reviewed_at,
      i.reporter_kind,
      -- Enough to act on, and no more. The reporter's own identity is deliberately not
      -- returned: an admin deciding whether to ban somebody does not need to know which
      -- requester complained, and a screen that shows it will eventually be read aloud.
      r.short_code        as request_code,
      r.status            as request_status,
      resp.id             as subject_responder_id,
      resp.first_name     as subject_first_name,
      resp.phone          as subject_phone,
      resp.approval       as subject_approval,
      (select count(*) from safety_incidents prior
        where prior.subject_responder_id = i.subject_responder_id
          and prior.id <> i.id)          as subject_prior_reports
    from safety_incidents i
    left join requests   r    on r.id = i.request_id
    left join responders resp on resp.id = i.subject_responder_id
    where p_status is null or i.status = p_status::incident_status
    order by
      -- Unreviewed first, then money and injury ahead of the rest: those are the two that stop
      -- being fixable if they sit in a queue.
      (i.status = 'new') desc,
      (i.category in ('asked_for_money', 'injury', 'harassment')) desc,
      i.created_at desc
    limit greatest(1, least(p_limit, 500))
  ) t;

  return jsonb_build_object(
    'ok', true,
    'counts', (
      select jsonb_object_agg(status, n)
        from (select status, count(*) as n from safety_incidents group by status) c
    ),
    'incidents', v_rows
  );
end;
$$;

create or replace function public.admin_review_incident(
  p_id     uuid,
  p_status text,
  p_notes  text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_status incident_status;
  v_row    safety_incidents%rowtype;
begin
  perform app.require_admin();

  begin
    v_status := p_status::incident_status;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end;

  update safety_incidents
     set status      = v_status,
         admin_notes = coalesce(nullif(btrim(p_notes), ''), admin_notes),
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_id
  returning * into v_row;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- The description is not copied into the audit row. The log is read far more casually than a
  -- report is, and the substance belongs in one place.
  perform app.audit('incident.reviewed', 'safety_incident', p_id::text,
                    jsonb_build_object('status', v_status, 'category', v_row.category));

  return jsonb_build_object('ok', true);
end;
$$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'public.admin_incidents(text, integer)',
    'public.admin_review_incident(uuid, text, text)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated, service_role', fn);
  end loop;
end
$$;
