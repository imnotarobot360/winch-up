-- Winch Up :: safety incidents
--
-- Phase 5 asks participants to be able to report incidents; Phase 14 asks again, alongside abuse
-- reporting and account blocking. Until now the rules text told people "if someone asks you to
-- pay, report them" with nowhere to report it.
--
-- The rule this table exists to protect:
--
--   THE PERSON BEING REPORTED NEVER SEES THE REPORT.
--
-- Not through the table, not through an RPC, not by joining something else. A volunteer who
-- learns that the person they just winched out reported them knows exactly where that person
-- was, what they drive, and often their phone number. Getting this wrong does not leak data, it
-- puts someone in danger. So there are no table grants at all -- not even select -- and every
-- path in and out is a security definer function that decides what the caller may see.
--
-- Deliberately NOT applying contains_contact_info() to the description. Everywhere else that
-- check stops a phone number reaching a public surface. Here the opposite is true: "he called me
-- from 512-555-0134 afterwards" is the most useful sentence in the report, and this text is only
-- ever read by an admin.

set search_path = public, extensions;

create type incident_category as enum (
  'asked_for_money',      -- the rule the whole product rests on
  'unsafe_behavior',
  'no_show',
  'property_damage',
  'injury',
  'harassment',
  'impersonation',
  'other'
);

create type incident_status as enum ('new', 'reviewing', 'actioned', 'dismissed');

create table safety_incidents (
  id              uuid primary key default gen_random_uuid(),

  -- What it happened on. Null is allowed: somebody may need to report a volunteer who contacted
  -- them outside any request at all.
  request_id      uuid references requests (id) on delete set null,

  reporter_kind   actor_kind not null,
  reporter_user_id uuid references auth.users (id) on delete set null,

  -- Who it is about. Both nullable, because the reporter may not know, and because a requester
  -- has no responder row.
  subject_responder_id uuid references responders (id) on delete set null,
  subject_user_id      uuid references auth.users (id) on delete set null,

  category        incident_category not null,
  description     text not null check (length(btrim(description)) between 10 and 2000),

  status          incident_status not null default 'new',
  admin_notes     text,
  reviewed_by     uuid references auth.users (id) on delete set null,
  reviewed_at     timestamptz,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index safety_incidents_triage_idx on safety_incidents (status, created_at desc);
create index safety_incidents_subject_idx on safety_incidents (subject_responder_id)
  where subject_responder_id is not null;

create trigger safety_incidents_set_updated_at
  before update on safety_incidents
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- No table access for anybody. Every read and write goes through a function.
-- ---------------------------------------------------------------------------

alter table safety_incidents enable row level security;
revoke all on safety_incidents from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reporting: a signed-in member or volunteer
-- ---------------------------------------------------------------------------

create or replace function public.report_incident(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user        uuid := auth.uid();
  v_category    incident_category;
  v_description text := btrim(p_payload ->> 'description');
  v_request_id  uuid := nullif(p_payload ->> 'request_id', '')::uuid;
  v_subject     uuid := nullif(p_payload ->> 'subject_responder_id', '')::uuid;
  v_kind        actor_kind;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_description is null or length(v_description) < 10 then
    return jsonb_build_object('ok', false, 'error', 'description_too_short');
  end if;

  begin
    v_category := (p_payload ->> 'category')::incident_category;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid_category');
  end;

  -- Generous, because somebody with a genuinely bad night may file several. Tight enough that a
  -- script cannot bury the queue.
  if not app.check_rate_limit('incident:user:' || v_user::text, 10, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  v_kind := case
              when exists (select 1 from responders r where r.user_id = v_user)
                then 'responder'::actor_kind
              else 'requester'::actor_kind
            end;

  insert into safety_incidents (
    request_id, reporter_kind, reporter_user_id, subject_responder_id, category, description
  ) values (
    v_request_id, v_kind, v_user, v_subject, v_category, v_description
  );

  -- Audited without the description: the audit log is read far more casually than the report is,
  -- and the substance belongs in one place.
  perform app.audit('incident.reported', 'safety_incident', null,
                    jsonb_build_object('category', v_category));

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Reporting: a requester holding their status link
--
-- The token is the credential, the same as cancelling or marking recovered. Somebody who was
-- pulled out an hour ago should not have to remember a password to report what happened.
-- ---------------------------------------------------------------------------

create or replace function public.report_incident_by_token(p_token text, p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_request     public.requests%rowtype;
  v_category    incident_category;
  v_description text := btrim(p_payload ->> 'description');
begin
  select * into v_request from public.requests where public_token = p_token;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_description is null or length(v_description) < 10 then
    return jsonb_build_object('ok', false, 'error', 'description_too_short');
  end if;

  begin
    v_category := (p_payload ->> 'category')::incident_category;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid_category');
  end;

  if not app.check_rate_limit('incident:token:' || p_token, 5, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into safety_incidents (
    request_id, reporter_kind, reporter_user_id,
    subject_responder_id, category, description
  ) values (
    v_request.id, 'requester', v_request.requester_user_id,
    -- The subject is whoever actually took the job. Not taken from the payload: a token holder
    -- should not be able to file a report against a volunteer who was never sent to them.
    v_request.accepted_responder_id, v_category, v_description
  );

  perform app.audit('incident.reported_by_token', 'safety_incident', null,
                    jsonb_build_object('category', v_category, 'request', v_request.short_code));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.report_incident(jsonb) from public, anon;
grant execute on function public.report_incident(jsonb) to authenticated;

-- Not granted to anon either: the requester's page calls this through the server, the same as
-- every other token action, so the IP behind a report is one we derived.
revoke all on function public.report_incident_by_token(text, jsonb) from public, anon, authenticated;

comment on table safety_incidents is
  'Safety and abuse reports. No table grants: every path is a security definer function. The '
  'subject of a report must never be able to read it, directly or through any join.';
