-- Winch Up :: required reference data
--
-- This is data the app cannot run without, so it is a migration and not a seed.
--
-- `create_request` raises if there is no current `requester_waiver` row: `requests.waiver_id` is
-- NOT NULL, because a request has to record the exact text the person agreed to. A project with
-- the schema applied but no waiver row accepts nothing and fails on the submit button. That is
-- not a seeding convenience, it is part of a working install, and `supabase db push` has to
-- deliver it on its own.
--
-- (It used to live only in supabase/seed.sql. `db push --include-seed` skips the seed step when no
-- migrations are pending, so a project could sit schema-complete and permanently unable to take a
-- request, with the push command reporting success. It did.)
--
-- Both inserts defer to whatever is already there: settings an admin has tuned keep their values,
-- and a slug that already has any waiver version is left completely alone.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Tunable settings. Code reads these; it does not hard-code the numbers.
-- `is_public` rows are readable by the browser through get_public_settings().
-- `do nothing`, not `do update`: production values are the admin's, not ours.
-- ---------------------------------------------------------------------------

insert into app_settings (key, value, description, is_public) values
  ('dispatch.ring_radii_miles',       '[15, 30, 60]'::jsonb,
   'Search radius for ring 1, 2 and 3, in miles.', true),
  ('dispatch.ring_wait_minutes',      '7'::jsonb,
   'Minutes to wait for an acceptance before widening to the next ring.', true),
  ('dispatch.max_per_ring',           '10'::jsonb,
   'Maximum volunteers texted per ring.', false),
  ('dispatch.unmatched_after_minutes','25'::jsonb,
   'Minutes with no acceptance before alerting admins and showing paid options.', true),
  ('dispatch.expire_after_hours',     '24'::jsonb,
   'Hours before an untouched request is auto-expired.', false),
  ('dispatch.tick_seconds',           '60'::jsonb,
   'How often the scheduled job advances the state machine.', false),
  ('board.reveal_exact_after_accept', 'false'::jsonb,
   'When true, /board shows the exact pin once a volunteer accepts. Default false: the board always shows the ~1 mile blurred pin.', true),
  ('board.blur_miles',                '1'::jsonb,
   'Approximate blur radius advertised on the public board.', true),
  ('limits.max_requests_per_phone_per_day', '3'::jsonb,
   'Rate limit on request creation, per phone number.', false),
  ('limits.max_requests_per_ip_per_hour',   '5'::jsonb,
   'Rate limit on request creation, per IP address.', false),
  ('limits.max_photos',               '3'::jsonb,
   'Photos allowed per request.', true),
  ('legal.review_status',             '"PLACEHOLDER - REVIEW WITH LAWYER"'::jsonb,
   'Set to "reviewed" only after a Texas attorney has signed off on /terms, /waiver and /privacy.', true)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Legal copy, version 1.
--
-- >>> PLACEHOLDER TEXT - REVIEW WITH LAWYER BEFORE LAUNCH <<<
--
-- Do not edit these rows in place once anyone has accepted them. Publish a new version instead
-- (/admin does this): `requests.waiver_id` points at the exact text a person agreed to, and that
-- has to stay true.
--
-- Guarded per slug rather than per (slug, version). `waivers_one_current_per_slug` is a partial
-- unique index on (slug) where is_current, so re-inserting v1 with is_current = true against a
-- project where an admin has already published v2 would raise a unique violation, which an
-- `on conflict (slug, version)` clause does not catch.
-- ---------------------------------------------------------------------------

insert into waivers (slug, version, is_current, body_en, body_es)
select v.slug, v.version, v.is_current, v.body_en, v.body_es
from (values
(
  'requester_waiver', 1, true,
  'PLACEHOLDER - REVIEW WITH LAWYER.

ASSUMPTION OF RISK AND RELEASE (REQUESTER)

1. This service connects you with unpaid volunteers. It is not an emergency service, a towing
   company, or a licensed recovery operator. If anyone is hurt or in danger, hang up and call 911.
2. Volunteers are not screened, licensed, bonded or insured by us. We do not supervise, train,
   direct or guarantee any volunteer.
3. Vehicle recovery is dangerous. Ropes, straps, chains and winch lines fail and can kill. Your
   vehicle, other vehicles, and the surrounding property may be damaged.
4. You accept all risk of loss, damage, injury or death arising from any recovery attempt, and you
   release the operators of this service from all claims to the fullest extent Texas law allows.
5. You confirm you have the right to be where you are, and permission from the landowner if the
   location is private property.
6. You agree that your phone number will be shared with the volunteer who accepts your request.

>>> REVIEW WITH LAWYER <<<',
  'TEXTO PROVISIONAL - REVISAR CON ABOGADO.

ASUNCION DE RIESGO Y EXONERACION (SOLICITANTE)

1. Este servicio lo conecta con voluntarios no remunerados. No es un servicio de emergencia, ni una
   empresa de gruas, ni un operador de rescate con licencia. Si hay heridos o peligro, cuelgue y
   llame al 911.
2. Nosotros no evaluamos, autorizamos, afianzamos ni aseguramos a los voluntarios. No los
   supervisamos, capacitamos, dirigimos ni garantizamos.
3. El rescate de vehiculos es peligroso. Las cuerdas, correas, cadenas y cables de winche fallan y
   pueden causar la muerte. Su vehiculo, otros vehiculos y la propiedad circundante pueden sufrir
   danos.
4. Usted acepta todo riesgo de perdida, dano, lesion o muerte derivado de cualquier intento de
   rescate, y libera a los operadores de este servicio de toda reclamacion en la maxima medida que
   permita la ley de Texas.
5. Usted confirma que tiene derecho a estar donde esta, y permiso del propietario si el lugar es
   propiedad privada.
6. Usted acepta que su numero de telefono se compartira con el voluntario que acepte su solicitud.

>>> REVISAR CON ABOGADO <<<'
),
(
  'responder_waiver', 1, true,
  'PLACEHOLDER - REVIEW WITH LAWYER.

VOLUNTEER AGREEMENT (RESPONDER)

1. You are an independent volunteer. You are not our employee, agent or contractor, and you are
   not paid by us.
2. You decide whether to accept any request. You may decline any job for any reason, and you may
   stop at any time if the scene is not safe.
3. You are responsible for your own equipment, your own insurance, and your own safety.
4. You will not charge the requester, solicit payment, or use this service to advertise a business.
   Accepting money turns this into a commercial tow, which this service is not.
5. You will not share a requester''s phone number, location or photos with anyone.
6. You release the operators of this service from all claims arising from any recovery you attempt,
   to the fullest extent Texas law allows.

>>> REVIEW WITH LAWYER <<<',
  'TEXTO PROVISIONAL - REVISAR CON ABOGADO.

ACUERDO DEL VOLUNTARIO (RESCATISTA)

1. Usted es un voluntario independiente. No es nuestro empleado, agente ni contratista, y nosotros
   no le pagamos.
2. Usted decide si acepta una solicitud. Puede rechazar cualquier trabajo por cualquier motivo, y
   puede detenerse en cualquier momento si el lugar no es seguro.
3. Usted es responsable de su propio equipo, su propio seguro y su propia seguridad.
4. No cobrara al solicitante, no pedira pago, ni usara este servicio para anunciar un negocio.
   Aceptar dinero convierte esto en un remolque comercial, que no es lo que este servicio ofrece.
5. No compartira el telefono, la ubicacion ni las fotos del solicitante con nadie.
6. Libera a los operadores de este servicio de toda reclamacion derivada de cualquier rescate que
   intente, en la maxima medida que permita la ley de Texas.

>>> REVISAR CON ABOGADO <<<'
),
(
  'rules', 1, true,
  'PLACEHOLDER - REVIEW WITH LAWYER.

GROUND RULES

- Call 911 first if anyone is hurt, in water, or in traffic.
- Volunteers are not a tow service. Nobody is obligated to come.
- No money changes hands. If someone asks you to pay, report them.
- Do not post phone numbers or links in the public description.
- Stay with your vehicle if it is safe to do so.
- Mark the job recovered when you are out, so volunteers stop driving toward you.

>>> REVIEW WITH LAWYER <<<',
  'TEXTO PROVISIONAL - REVISAR CON ABOGADO.

REGLAS BASICAS

- Llame primero al 911 si hay heridos, si alguien esta en el agua o en el trafico.
- Los voluntarios no son un servicio de grua. Nadie esta obligado a venir.
- No se paga dinero. Si alguien le pide pago, reportelo.
- No publique numeros de telefono ni enlaces en la descripcion publica.
- Quedese con su vehiculo si es seguro hacerlo.
- Marque el trabajo como rescatado cuando salga, para que los voluntarios dejen de conducir hacia
  usted.

>>> REVISAR CON ABOGADO <<<'
)
) as v (slug, version, is_current, body_en, body_es)
where not exists (select 1 from waivers w where w.slug = v.slug);
