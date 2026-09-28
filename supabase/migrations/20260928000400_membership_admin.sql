-- Winch Up :: the Super Admin surface for the membership agreement
--
-- Requirement 12: manage versions and review signature records. Modelled on
-- admin_publish_waiver, which is the house pattern -- app.require_admin() first, app.audit()
-- on every write, both languages required, version numbers assigned by the database rather
-- than by whoever is typing.
--
-- Two differences from the waiver version, both forced by this being a legal record:
--
--  * Publishing RETIRES the previous version explicitly. admin_publish_waiver inserts a row
--    with is_current = true and leaves the old one set too; this table has a partial unique
--    index on is_current, so that would fail here. Being forced to be explicit is the better
--    behaviour anyway -- exactly one agreement is in force at a time, and the database says so.
--
--  * Reading signatures is itself audited. They carry legal names and IP addresses, so who
--    looked at them is worth knowing.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Publish a version
-- ---------------------------------------------------------------------------

create or replace function public.admin_publish_membership_agreement(
  p_body_en              text,
  p_body_es              text,
  p_requires_resignature boolean default true,
  p_effective_at         timestamptz default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_version integer;
  v_id      uuid;
  v_when    timestamptz := coalesce(p_effective_at, now());
begin
  perform app.require_admin();

  -- Same floor as admin_publish_waiver. It will not catch bad legal text, but it does catch the
  -- empty textarea and the version published with one language filled in.
  if length(btrim(coalesce(p_body_en, ''))) < 20 or length(btrim(coalesce(p_body_es, ''))) < 20 then
    return jsonb_build_object('ok', false, 'error', 'both_languages_required');
  end if;

  select coalesce(max(version), 0) + 1 into v_version from public.membership_agreements;

  -- Explicit, because of the partial unique index. Done before the insert so the two never
  -- overlap, and inside the same transaction so a failure leaves the old one in force rather
  -- than leaving no agreement at all.
  update public.membership_agreements set is_current = false where is_current;

  insert into public.membership_agreements
    (version, body_en, body_es, is_current, effective_at, requires_resignature, published_by)
  values (v_version, p_body_en, p_body_es, true, v_when, coalesce(p_requires_resignature, true),
          auth.uid())
  returning id into v_id;

  perform app.audit('membership_agreement.publish', 'membership_agreements', v_id::text,
                    jsonb_build_object(
                      'version', v_version,
                      'requires_resignature', coalesce(p_requires_resignature, true),
                      'effective_at', v_when,
                      'body_hash', (select body_hash from public.membership_agreements where id = v_id)
                    ));

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'version', v_version,
    'body_hash', (select body_hash from public.membership_agreements where id = v_id),
    'effective_at', v_when
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- The versions, with how many people signed each
-- ---------------------------------------------------------------------------

create or replace function public.admin_membership_agreements()
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

  select coalesce(jsonb_agg(row order by version desc), '[]'::jsonb) into v_rows
    from (
      select a.version,
             jsonb_build_object(
               'id', a.id,
               'version', a.version,
               'is_current', a.is_current,
               'effective_at', a.effective_at,
               'created_at', a.created_at,
               'requires_resignature', a.requires_resignature,
               'body_hash', a.body_hash,
               'body_en', a.body_en,
               'body_es', a.body_es,
               'signature_count', (
                 select count(*) from public.membership_signatures s
                  where s.agreement_version = a.version
               ),
               -- If this ever comes back false, the stored text was altered after somebody
               -- signed it. The trigger should make that impossible; this reports it anyway,
               -- because a guarantee nobody checks is a guarantee nobody notices breaking.
               'hash_intact', not exists (
                 select 1 from public.membership_signatures s
                  where s.agreement_version = a.version and s.body_hash <> a.body_hash
               )
             ) as row
        from public.membership_agreements a
    ) t;

  return jsonb_build_object(
    'ok', true,
    'required', coalesce((select (value #>> '{}')::boolean
                            from public.app_settings where key = 'membership.required'), false),
    'agreements', v_rows,
    'total_signatures', (select count(*) from public.membership_signatures)
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- The signature records
-- ---------------------------------------------------------------------------

create or replace function public.admin_membership_signatures(
  p_version integer default null,
  p_search  text    default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows  jsonb;
  v_total integer;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_q     text    := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform app.require_admin();

  select count(*) into v_total
    from public.membership_signatures s
   where (p_version is null or s.agreement_version = p_version)
     and (v_q is null or s.legal_name ilike '%' || v_q || '%');

  select coalesce(jsonb_agg(row order by signed_at desc), '[]'::jsonb) into v_rows
    from (
      select s.signed_at,
             jsonb_build_object(
               'id', s.id,
               'user_id', s.user_id,
               'legal_name', s.legal_name,
               'signature_text', s.signature_text,
               'version', s.agreement_version,
               'body_hash', s.body_hash,
               'signed_at', s.signed_at,
               'signed_ip', host(s.signed_ip),
               'signed_user_agent', s.signed_user_agent,
               'signed_via', s.signed_via,
               'locale', s.locale,
               'email', u.email
             ) as row
        from public.membership_signatures s
        left join auth.users u on u.id = s.user_id
       where (p_version is null or s.agreement_version = p_version)
         and (v_q is null or s.legal_name ilike '%' || v_q || '%')
       order by s.signed_at desc
       limit v_limit offset greatest(coalesce(p_offset, 0), 0)
    ) t;

  -- These rows are legal names, email addresses and IP addresses. Who read them is worth a
  -- line in the audit log; the search term is recorded, the results are not.
  perform app.audit('membership_signature.read', 'membership_signatures', null,
                    jsonb_build_object('version', p_version, 'search', v_q,
                                       'returned', jsonb_array_length(v_rows)));

  return jsonb_build_object('ok', true, 'total', v_total, 'limit', v_limit,
                            'offset', greatest(coalesce(p_offset, 0), 0),
                            'signatures', v_rows);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- Explicit revokes for the reason spelled out in 20260928000300: Supabase's default privileges
-- hand every new function to anon, and `revoke ... from public` does not take it back.
--
-- These stay reachable by `authenticated` because that is how every other admin_* function in
-- this database works -- app.require_admin() refuses inside, and the 26 existing ones are all
-- built that way. Making these two the exception would be a false kind of tidy: the guard is
-- the guard.
-- ---------------------------------------------------------------------------

revoke all on function public.admin_publish_membership_agreement(text, text, boolean, timestamptz)
  from public, anon;
grant execute on function public.admin_publish_membership_agreement(text, text, boolean, timestamptz)
  to authenticated, service_role;

revoke all on function public.admin_membership_agreements() from public, anon;
grant execute on function public.admin_membership_agreements() to authenticated, service_role;

revoke all on function public.admin_membership_signatures(integer, text, integer, integer)
  from public, anon;
grant execute on function public.admin_membership_signatures(integer, text, integer, integer)
  to authenticated, service_role;

notify pgrst, 'reload schema';
