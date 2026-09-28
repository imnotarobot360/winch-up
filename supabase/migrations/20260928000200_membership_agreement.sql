-- Winch Up :: the membership agreement, and proof of who signed which words
--
-- There is already a `waivers` table, versioned by slug, and a request records which waiver row
-- it accepted. That is per-RECOVERY consent and it stays. This is a different thing: one
-- agreement, signed once per MEMBER, covering asking for help and offering it alike.
--
-- Why a separate table rather than a fourth slug in `waivers`:
--
--  * A waiver acceptance is a column on the request that triggered it. A membership signature
--    belongs to the person and outlives every request they ever file.
--  * The spec requires a document hash, a legal name, a signature and an audit trail. None of
--    those fit on the waivers row, and bolting them on would leave the per-request waiver
--    carrying five columns it never populates.
--  * "Do not hide them inside general Terms of Service" is a requirement about presentation, and
--    a distinct table is what keeps it a distinct document rather than one slug among four.
--
-- NO AGREEMENT TEXT IS SHIPPED IN THIS MIGRATION, DELIBERATELY
--
-- The spec calls for an attorney-approved agreement. There is not one: every waiver in this
-- database still says PLACEHOLDER - REVIEW WITH LAWYER. Inventing a release of liability for a
-- service where volunteers drive to strangers and winch vehicles out of water would produce
-- something that looks binding and is not, which is worse than having none -- people rely on it.
--
-- So this ships the machinery with the gate OFF. An admin publishes the real text, then flips
-- `membership.required`. That is what requirement 9's "once the approved agreement becomes
-- effective" describes, and it is the only honest way to build this ahead of the lawyer.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- The versioned agreement
-- ---------------------------------------------------------------------------

create table if not exists public.membership_agreements (
  id            uuid primary key default gen_random_uuid(),
  version       integer not null unique,

  body_en       text not null check (length(btrim(body_en)) > 0),
  body_es       text not null check (length(btrim(body_es)) > 0),

  -- Over both languages, because a member signs the document, not one translation of it. If the
  -- Spanish is corrected the hash changes and that is correct: it is not the same document.
  -- Generated, so it cannot drift from the text it describes -- a hash somebody has to remember
  -- to recompute is a hash that eventually lies.
  body_hash     text not null generated always as (
                  encode(extensions.digest(body_en || E'\n--\n' || body_es, 'sha256'), 'hex')
                ) stored,

  -- Whether members who signed an earlier version must sign this one. A typo fix does not
  -- invalidate consent; a change to what somebody is releasing does. Requirement 14 is a
  -- judgement an admin makes, so it is a field rather than something inferred from a diff.
  requires_resignature boolean not null default true,

  is_current    boolean not null default false,
  effective_at  timestamptz,

  published_by  uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now()
);

comment on table public.membership_agreements is
  'Versioned membership agreement. Append-only once signed: a row with signatures cannot have '
  'its text changed, because the hash on each signature is what proves what that person agreed '
  'to. Separate from `waivers`, which is per-recovery consent.';

-- At most one current version. A partial unique index rather than a trigger, so two admins
-- publishing at once cannot both win.
create unique index if not exists membership_agreements_one_current_idx
  on public.membership_agreements (is_current) where is_current;

create index if not exists membership_agreements_version_idx
  on public.membership_agreements (version desc);

-- Every FK column in this database is the leading column of some index; schema_audit_test
-- enforces it and caught this one missing.
create index if not exists membership_agreements_published_by_idx
  on public.membership_agreements (published_by);

-- ---------------------------------------------------------------------------
-- The signatures
-- ---------------------------------------------------------------------------

create table if not exists public.membership_signatures (
  id             uuid primary key default gen_random_uuid(),

  -- CASCADE, not SET NULL: a signature is a record ABOUT a person. With the account gone there
  -- is nobody it binds and nobody it protects, and keeping a legal name and IP attached to a
  -- deleted account would be holding identifying data for somebody who asked to be forgotten.
  -- This is the opposite call to email_deliveries, which keeps its rows precisely because they
  -- identify nobody.
  user_id        uuid not null references auth.users (id) on delete cascade,

  agreement_id   uuid not null references public.membership_agreements (id) on delete restrict,
  agreement_version integer not null,

  -- Copied at signing. If it ever stops matching the agreement row, the text was altered after
  -- the fact and every signature on it is suspect -- which is exactly what an audit needs to be
  -- able to detect rather than assume away.
  body_hash      text not null,

  -- Requirement 4: the typed full legal name IS the electronic signature. Kept as two columns
  -- because they are different claims -- who they say they are, and what they typed to sign.
  legal_name     text not null check (length(btrim(legal_name)) between 2 and 120),
  signature_text text not null check (length(btrim(signature_text)) between 2 and 120),

  locale         text not null default 'en' check (locale in ('en', 'es')),

  signed_at      timestamptz not null default now(),
  signed_ip      inet,
  signed_user_agent text,

  -- Which client it came from. Requirement 11: the same records serve web and the future apps,
  -- so the record has to be able to say which one.
  signed_via     text not null default 'web'
);

comment on table public.membership_signatures is
  'One row per member per agreement version signed. body_hash is copied from the agreement at '
  'signing time: a mismatch against the agreement row means the text was altered afterwards.';

-- One signature per member per version. Signing twice is a no-op, not a second row, and two
-- concurrent submits cannot both write.
create unique index if not exists membership_signatures_user_version_idx
  on public.membership_signatures (user_id, agreement_version);

create index if not exists membership_signatures_user_idx
  on public.membership_signatures (user_id);
create index if not exists membership_signatures_agreement_idx
  on public.membership_signatures (agreement_id);
create index if not exists membership_signatures_signed_idx
  on public.membership_signatures (signed_at desc);

-- ---------------------------------------------------------------------------
-- Immutability
--
-- Requirement 7 says store an immutable copy of the exact agreement signed. The agreement row
-- IS that copy; this is what makes "immutable" true rather than aspirational. Without it the
-- stored hash is the only thing standing between a signature and somebody quietly editing what
-- it was a signature FOR.
-- ---------------------------------------------------------------------------

create or replace function app.membership_agreement_is_immutable()
returns trigger
language plpgsql
-- Pinned, like every other function here. A trigger runs as whoever writes the row, and an
-- unpinned search_path lets that caller put their own `membership_signatures` earlier on the
-- path -- an empty one -- so the existence check finds nothing and the text unfreezes.
set search_path = public, extensions, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.membership_signatures s where s.agreement_id = old.id) then
      raise exception 'agreement % has signatures and cannot be deleted', old.version
        using hint = 'Publish a new version instead. History is the point.';
    end if;
    return old;
  end if;

  if exists (select 1 from public.membership_signatures s where s.agreement_id = old.id)
     and (new.body_en is distinct from old.body_en
          or new.body_es is distinct from old.body_es
          or new.version is distinct from old.version)
  then
    raise exception 'agreement % has signatures; its text and version are frozen', old.version
      using hint = 'Publish a new version. Editing signed words would change what people agreed to.';
  end if;

  return new;
end;
$$;

drop trigger if exists membership_agreements_immutable on public.membership_agreements;

create trigger membership_agreements_immutable
  before update or delete on public.membership_agreements
  for each row execute function app.membership_agreement_is_immutable();

-- ---------------------------------------------------------------------------
-- RLS
--
-- Deny by default like everything else. The agreement is served through an RPC so that an
-- unsigned member can read it (they must, to sign it) without being able to enumerate versions;
-- signatures are never readable from the browser at all, because they carry legal names and IPs.
-- ---------------------------------------------------------------------------

alter table public.membership_agreements enable row level security;
alter table public.membership_signatures enable row level security;

revoke all on public.membership_agreements from anon, authenticated;
revoke all on public.membership_signatures from anon, authenticated;

-- ---------------------------------------------------------------------------
-- The gate, off
--
-- Requirement 9 is conditional on the approved agreement becoming effective, and it is not
-- approved. Off means the app behaves exactly as it does today; on means unsigned members
-- cannot file a request or make an offer. Flipping it with no published agreement would lock
-- every member out of the product, so the check that reads this also requires a current
-- agreement to exist.
-- ---------------------------------------------------------------------------

insert into public.app_settings (key, value, description)
values (
  'membership.required',
  'false'::jsonb,
  'Whether a signed membership agreement is required to file a request or offer help. Ships '
  'false: there is no attorney-approved agreement yet. Turning this on without a published '
  'current agreement has no effect, deliberately.'
)
on conflict (key) do nothing;
