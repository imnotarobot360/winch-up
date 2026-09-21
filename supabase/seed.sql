-- Winch Up :: optional reference seed
--
-- Safe to run against any environment, including production. Idempotent.
--
-- Data the app genuinely cannot run without -- app_settings and the versioned waiver text -- is
-- NOT here. It lives in supabase/migrations/20260921000100_reference_data.sql, so that a plain
-- `supabase db push` produces a working install with no second step to forget. Do not move it
-- back: `db push --include-seed` silently skips the seed when no migrations are pending.
--
-- What is left is genuinely optional. The app renders correctly without it.
-- Demo volunteers and demo requests live in supabase/seeds/demo.sql (local dev only).

set search_path = public, extensions;

-- ===========================================================================
-- Paid recovery / tow fallback list.
--
-- Intentionally seeded with a single INACTIVE placeholder: we are not inventing real businesses.
-- The owner fills this in from /admin with operators they actually trust.
-- ===========================================================================

insert into pro_options (name, phone, url, blurb_en, blurb_es, counties, is_active, sort_order)
select
  'PLACEHOLDER - add real operators in /admin',
  null,
  null,
  'Replace this entry with tow and recovery operators you trust. Shown to a requester only when no volunteer has accepted after the full escalation window.',
  'Reemplace esta entrada con operadores de grua y rescate de su confianza. Se muestra al solicitante solo cuando ningun voluntario ha aceptado despues de la ventana completa de escalamiento.',
  '{}',
  false,
  999
where not exists (select 1 from pro_options);
