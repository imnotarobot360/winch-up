-- Winch Up :: /terms stops shouting PLACEHOLDER at anyone who opens it
--
-- The `rules` waiver body was real ground rules wrapped in scaffolding:
--
--     PLACEHOLDER - REVIEW WITH LAWYER.
--     GROUND RULES
--     - Call 911 first if anyone is hurt, in water, or in traffic.
--     ... five more, all finished and correct ...
--     >>> REVIEW WITH LAWYER <<<
--
-- The rules themselves were done. The wrapper was left over from seeding and is what renders on
-- https://www.winch-up.com/terms today.
--
-- WHY THIS IS WORTH A MIGRATION
--
-- The A2P 10DLC campaign links to /terms and a reviewer opens it. docs/a2p-registration.md
-- called this before submission: "They currently say PLACEHOLDER TEXT - REVIEW WITH LAWYER. A
-- reviewer who opens that may well reject the campaign, and they would be right to. This is the
-- one prerequisite that is not a form field." Until SMS works, volunteers are only reachable by
-- push, which on iPhone needs the PWA installed.
--
-- WHAT THIS DOES NOT DO
--
-- It does not invent legal terms. There is no limitation of liability here, no indemnity, no
-- warranty disclaimer, no governing law and no arbitration clause -- those are the attorney's
-- and are not the sort of thing to guess at for a service where volunteers winch strangers'
-- vehicles out of creeks. What it adds is two paragraphs of plain fact about what Winch Up is,
-- which a reviewer needs in order to understand the rules underneath them, and which say
-- nothing that is not already true and already on /privacy.
--
-- The page keeps a banner saying the wording has not been through a lawyer. It is just the
-- measured one /privacy already uses rather than a red PLACEHOLDER warning.
--
-- NO ACCEPTANCE IS ORPHANED BY THIS
--
-- 20260920001000's comment warns that publishing a new waiver version makes existing
-- acceptances point at superseded text. That is true of `requester_waiver`, which requests
-- reference by id through requests.waiver_id. It is NOT true of `rules`: acceptance of the
-- ground rules is recorded as requests.rules_accepted, a boolean, with no version pointer
-- anywhere. Checked before writing this.

-- Explicit, because psql on Windows has already mangled one non-ASCII character in this project
-- (an em dash became 0x97 and the server rejected the byte sequence). The Spanish below has
-- accents in it and this is what makes them arrive intact regardless of the client's default.
set client_encoding = 'UTF8';

set search_path = public, extensions;

-- RE-RUNNABLE, AND THE OBVIOUS WAY OF DOING THAT DOES NOT WORK.
--
-- First attempt used `on conflict (slug, version) do nothing`. That guards nothing: the version
-- is computed as max+1, so every run asks for a version number that does not exist yet, never
-- conflicts, and publishes again. Three local runs produced v2, v3 and v4 of identical text.
--
-- The real test is whether the CURRENT TEXT already matches, so that is what is checked. The
-- bodies are declared once as variables rather than repeated in a comparison and an insert,
-- because two copies of a legal document in one file is a diff waiting to go wrong.
do $rules$
declare
  v_en text := $en$WINCH UP - TERMS OF USE

Winch Up is a free service operated by Winch Up LLC. It connects off-roaders in Texas who need
help getting a vehicle unstuck with nearby volunteers who choose to offer it.

Winch Up is not an emergency service and not a towing company. The people who respond are
volunteers, not employees and not contractors. Nobody is dispatched, nobody is obliged to come,
and no money changes hands through Winch Up.

Everyone who uses Winch Up agrees to the ground rules below.

GROUND RULES

- Call 911 first if anyone is hurt, in water, or in traffic.
- Volunteers are not a tow service. Nobody is obligated to come.
- No money changes hands. If someone asks you to pay, report them.
- Do not post phone numbers or links in the public description.
- Stay with your vehicle if it is safe to do so.
- Mark the job recovered when you are out, so volunteers stop driving toward you.

An account that breaks these rules can be suspended.

CONTACT

Winch Up LLC
help@winch-up.com$en$;

  v_es text := $es$WINCH UP - CONDICIONES DE USO

Winch Up es un servicio gratuito operado por Winch Up LLC. Conecta a conductores todoterreno de
Texas que necesitan ayuda para sacar un vehículo atascado con voluntarios cercanos que deciden
ofrecerla.

Winch Up no es un servicio de emergencia ni una compañía de grúas. Quienes responden son
voluntarios, no empleados ni contratistas. A nadie se le despacha, nadie está obligado a ir, y
por Winch Up no se paga dinero.

Toda persona que usa Winch Up acepta las reglas básicas siguientes.

REGLAS BÁSICAS

- Llame primero al 911 si hay heridos, si alguien está en el agua o en el tráfico.
- Los voluntarios no son un servicio de grúa. Nadie está obligado a venir.
- No se paga dinero. Si alguien le pide pago, repórtelo.
- No publique números de teléfono ni enlaces en la descripción pública.
- Quédese con su vehículo si es seguro hacerlo.
- Marque el trabajo como rescatado cuando salga, para que los voluntarios dejen de conducir
  hacia usted.

Una cuenta que incumpla estas reglas puede ser suspendida.

CONTACTO

Winch Up LLC
help@winch-up.com$es$;

  v_next integer;
begin
  if exists (
    select 1 from public.waivers
     where slug = 'rules' and is_current and body_en = v_en and body_es = v_es
  ) then
    raise notice 'rules waiver is already current at this text; nothing to do.';
    return;
  end if;

  select coalesce(max(version), 0) + 1 into v_next
    from public.waivers where slug = 'rules';

  -- Retire the old one FIRST: waivers_one_current_per_slug is a partial unique index, so two
  -- current rows for this slug cannot exist even for the duration of a statement.
  update public.waivers set is_current = false where slug = 'rules' and is_current;

  insert into public.waivers (slug, version, body_en, body_es, is_current)
  values ('rules', v_next, v_en, v_es, true);

  raise notice 'published rules waiver v%', v_next;
end
$rules$;
