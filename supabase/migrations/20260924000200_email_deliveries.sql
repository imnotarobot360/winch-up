-- Winch Up :: a record of every account email, and the index that makes "send it once" true
--
-- Section 8 of the email brief asks for delivery records. The reason to want them is narrower
-- than "logging": when somebody says they never got the welcome email, the only useful question
-- is whether we tried, and today there is nothing that could answer it. The SMS outbox already
-- works this way and for the same reason -- a suppressed message still gets a row, because "why
-- did nobody get told" needs an answer.
--
-- WHAT IS DELIBERATELY NOT STORED
--
-- Not the subject, not the body, not the rendered HTML, and not the action URL. Two reasons.
-- The action URL in a verification or reset email IS a credential: anybody who can read this
-- table could take over the account it belongs to, which would make a log of emails a more
-- valuable target than the thing it is logging. And the body is reproducible -- the template key
-- plus the locale regenerate it exactly, because the copy lives in TypeScript rather than being
-- pasted per send.
--
-- The recipient address is not stored either. It is already on auth.users, reachable through
-- user_id, and a second copy is a second thing account deletion has to remember to scrub. Rows
-- for an address with no account (there are none today) carry a null user_id and identify
-- nothing, which is the safer failure.
--
-- IDEMPOTENCY
--
-- The unique index is the feature, not a safety net. §5 says the welcome email goes once per
-- verified account; a read-then-write cannot promise that when two verifications land together,
-- and "did we already send this" is exactly the question a unique index answers for free.

set search_path = public, extensions;

create table if not exists public.email_deliveries (
  id uuid primary key default gen_random_uuid(),

  -- No ON DELETE CASCADE by design: a deleted account's send history is anonymous once the user
  -- is gone (this table holds no address), and keeping the row means deleting an account cannot
  -- be used to erase evidence that mail went out. SET NULL rather than RESTRICT so deletion is
  -- never blocked by a log row -- account deletion must always be able to complete.
  user_id uuid references auth.users (id) on delete set null,

  template_key text not null,
  locale text not null default 'en' check (locale in ('en', 'es')),

  status text not null default 'queued'
    check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),

  provider text,
  provider_message_id text,

  -- Null means "not deduplicated": security notices can legitimately repeat, and two password
  -- changes should produce two emails. Only the sends that must happen once carry a key.
  idempotency_key text,

  failure_reason text,
  attempts integer not null default 1 check (attempts >= 0),

  created_at timestamptz not null default now(),
  completed_at timestamptz
);

comment on table public.email_deliveries is
  'One row per account email attempted. Holds no address, no subject, no body and no action URL: '
  'the template key and locale reproduce the content, and the action URL is a credential.';

-- The point of the whole table. Partial, so the many rows with no key do not collide with
-- each other -- in Postgres nulls are distinct in a unique index anyway, but saying so here
-- makes the intent explicit and keeps the index small.
create unique index if not exists email_deliveries_idempotency_idx
  on public.email_deliveries (idempotency_key)
  where idempotency_key is not null;

-- schema_audit_test requires an index on every foreign key.
create index if not exists email_deliveries_user_idx
  on public.email_deliveries (user_id);

-- For "what happened in the last hour", which is the query an operator actually runs.
create index if not exists email_deliveries_created_idx
  on public.email_deliveries (created_at desc);

-- ---------------------------------------------------------------------------
-- RLS
--
-- Deny by default and stay that way. Nobody reads this from the browser: it is written by the
-- service role from server code and read by an admin through an RPC, the same shape the rest of
-- the app uses. A member has no business enumerating their own delivery log, and giving them a
-- policy would mean a policy mistake could expose which addresses have accounts.
-- ---------------------------------------------------------------------------

alter table public.email_deliveries enable row level security;

revoke all on public.email_deliveries from anon, authenticated;

-- ---------------------------------------------------------------------------
-- admin_email_deliveries
--
-- The read path, gated on app.require_admin() like every other admin RPC, and granted to
-- `authenticated` rather than to the service role so there is no shared key that grants admin.
-- ---------------------------------------------------------------------------

create or replace function public.admin_email_deliveries(p_limit integer default 100)
returns table (
  id uuid,
  template_key text,
  locale text,
  status text,
  provider text,
  provider_message_id text,
  failure_reason text,
  attempts integer,
  created_at timestamptz,
  completed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  perform app.require_admin();

  return query
    select d.id, d.template_key, d.locale, d.status, d.provider, d.provider_message_id,
           d.failure_reason, d.attempts, d.created_at, d.completed_at
    from public.email_deliveries d
    order by d.created_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

revoke all on function public.admin_email_deliveries(integer) from public, anon;
grant execute on function public.admin_email_deliveries(integer) to authenticated;
