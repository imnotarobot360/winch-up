import en from "../../../messages/en.json";
import es from "../../../messages/es.json";

import { APP_SHORT_NAME } from "@/config/app";
import { formatUsPhone } from "@/lib/utils";

/**
 * SMS copy lives here, not in SQL.
 *
 * The database queues a `template_key` plus params; the sender renders it in the recipient's own
 * language. That keeps Spanish a first-class path instead of something bolted on later, and it
 * means changing wording never needs a migration.
 *
 * Rules for writing these:
 *  - Lead with the short code. It is what people read out over a bad phone connection.
 *  - Keep any link last. Some phones mangle text that follows a URL.
 *  - Spanish keeps its accents. That pushes the message into UCS-2 (70 characters a segment
 *    instead of 160), which costs a fraction of a cent more. Correct Spanish is worth that.
 *  - Anything that asks a volunteer to do something carries STOP instructions. Carriers require
 *    it, and A2P 10DLC registration is checked against what we actually send.
 */

export type SmsTemplateKey =
  | "requester.created"
  | "requester.accepted"
  | "requester.on_site"
  | "requester.unmatched"
  | "requester.recovered_by_responder"
  | "responder.offer"
  | "responder.assigned"
  | "responder.already_covered"
  | "responder.declined_ack"
  | "responder.job_cancelled"
  | "responder.recovered"
  | "responder.thanks"
  | "responder.on_site_ack"
  | "responder.complete_ack"
  | "responder.no_open_job"
  | "responder.started"
  | "responder.help"
  | "unknown.no_account"
  | "admin.unmatched_alert";

export type SmsParams = Record<string, string | number | boolean | null | undefined>;

type Catalogue = typeof en;
type EnumGroup = keyof Catalogue["enum"];

const CATALOGUES: Record<string, Catalogue> = { en, es: es as unknown as Catalogue };

/**
 * Look an enum label up in the same message catalogue the UI uses, so a volunteer's text says
 * "to the frame" and "hasta el chasis" without a second copy of those words living here.
 */
function label(locale: string, group: EnumGroup, value: unknown): string {
  if (value == null || value === "") return "";
  const catalogue = CATALOGUES[locale] ?? en;
  const groupLabels = catalogue.enum[group] as Record<string, string> | undefined;
  return groupLabels?.[String(value)] ?? String(value);
}

function mapLink(lat: unknown, lng: unknown): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}

/** Joins the parts of a summary, dropping the empty ones, so no message has ", , ". */
function join(parts: (string | null | undefined | false)[], separator = ", "): string {
  return parts.filter((part): part is string => Boolean(part && part.length)).join(separator);
}

type Renderer = (p: SmsParams) => string;

const TEMPLATES: Record<SmsTemplateKey, { en: Renderer; es: Renderer }> = {
  // --- to the requester -----------------------------------------------------

  "requester.created": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: we got it. Texting volunteers near you now. Watch for a call. Status: ${p.url}`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: recibido. Estamos avisando a voluntarios cerca de usted. Esté pendiente de una llamada. Estado: ${p.url}`,
  },

  "requester.accepted": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${p.first_name} is coming${
        p.eta_minutes ? `, about ${p.eta_minutes} min out` : ""
      }. ${join([String(p.vehicle_desc ?? "") || label("en", "vehicleClass", p.vehicle_class)])}. Call ${formatUsPhone(String(p.phone))}.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${p.first_name} va en camino${
        p.eta_minutes ? `, a unos ${p.eta_minutes} min` : ""
      }. ${join([String(p.vehicle_desc ?? "") || label("es", "vehicleClass", p.vehicle_class)])}. Llame al ${formatUsPhone(String(p.phone))}.`,
  },

  "requester.on_site": {
    en: (p) => `${APP_SHORT_NAME} ${p.short_code}: your volunteer says they are on site.`,
    es: (p) => `${APP_SHORT_NAME} ${p.short_code}: su voluntario dice que ya está en el lugar.`,
  },

  "requester.unmatched": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: nobody has been able to take it yet. We are still trying. Your status page now lists paid recovery options.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: todavía nadie ha podido tomarla. Seguimos intentando. Su página de estado ya muestra opciones de rescate de pago.`,
  },

  "requester.recovered_by_responder": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: your volunteer marked this recovered. If that is wrong, open your status page and let us know.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: su voluntario marcó esto como rescatado. Si no es así, abra su página de estado y avísenos.`,
  },

  // --- to volunteers --------------------------------------------------------

  "responder.offer": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${label("en", "vehicleClass", p.vehicle_class)} stuck ${p.miles} mi from you. ${join(
        [
          label("en", "stuckType", p.stuck_type),
          label("en", "stuckDepth", p.stuck_depth),
          p.needs_tractor ? "needs a tractor" : "",
          p.needs_second_truck ? "needs a second truck" : "",
          p.county ? `${p.county} County` : "",
        ],
      )}. Reply 1 to take it, 2 to pass. STOP to opt out.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${label("es", "vehicleClass", p.vehicle_class)} atascado a ${p.miles} mi de usted. ${join(
        [
          label("es", "stuckType", p.stuck_type),
          label("es", "stuckDepth", p.stuck_depth),
          p.needs_tractor ? "necesita tractor" : "",
          p.needs_second_truck ? "necesita segunda troca" : "",
          p.county ? `condado de ${p.county}` : "",
        ],
      )}. Responda 1 para tomarlo, 2 para pasar. STOP para no recibir más.`,
  },

  "responder.assigned": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: it is yours. ${p.requester_name}, ${formatUsPhone(String(p.requester_phone))}.${
        p.location_note ? ` ${p.location_note}.` : ""
      } Text HERE when you arrive, DONE when they are out. Pin: ${mapLink(p.lat, p.lng)}`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: es suyo. ${p.requester_name}, ${formatUsPhone(String(p.requester_phone))}.${
        p.location_note ? ` ${p.location_note}.` : ""
      } Escriba HERE al llegar y DONE cuando salgan. Punto: ${mapLink(p.lat, p.lng)}`,
  },

  "responder.already_covered": {
    en: (p) => `${APP_SHORT_NAME} ${p.short_code}: already covered, thanks for answering.`,
    es: (p) => `${APP_SHORT_NAME} ${p.short_code}: ya está cubierto, gracias por responder.`,
  },

  "responder.declined_ack": {
    en: () => `${APP_SHORT_NAME}: got it, we will pass this one by you.`,
    es: () => `${APP_SHORT_NAME}: entendido, le pasamos esta.`,
  },

  "responder.job_cancelled": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: the driver cancelled. No need to roll. Thanks for stepping up.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: el conductor canceló. No hace falta ir. Gracias por responder.`,
  },

  "responder.recovered": {
    en: (p) => `${APP_SHORT_NAME} ${p.short_code}: marked recovered. Thank you for going out.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: marcado como rescatado. Gracias por salir a ayudar.`,
  },

  "responder.thanks": {
    en: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${p.name ?? "the driver"} says thanks - "${p.note}"`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: ${p.name ?? "el conductor"} le da las gracias - "${p.note}"`,
  },

  "responder.on_site_ack": {
    en: (p) => `${APP_SHORT_NAME} ${p.short_code}: marked on site. Text DONE when they are out.`,
    es: (p) =>
      `${APP_SHORT_NAME} ${p.short_code}: marcado en el lugar. Escriba DONE cuando salgan.`,
  },

  "responder.complete_ack": {
    en: (p) => `${APP_SHORT_NAME} ${p.short_code}: marked recovered. Thank you.`,
    es: (p) => `${APP_SHORT_NAME} ${p.short_code}: marcado como rescatado. Gracias.`,
  },

  "responder.no_open_job": {
    en: () => `${APP_SHORT_NAME}: you have no open job right now. Nothing to reply to.`,
    es: () => `${APP_SHORT_NAME}: ahora mismo no tiene ningún trabajo abierto.`,
  },

  "responder.started": {
    en: () => `${APP_SHORT_NAME}: you are back on the call list. Reply STOP any time to stop.`,
    es: () =>
      `${APP_SHORT_NAME}: está de vuelta en la lista de llamadas. Responda STOP cuando quiera para salir.`,
  },

  "responder.help": {
    en: () =>
      `${APP_SHORT_NAME}: reply 1 to take a job, 2 to pass, HERE when you arrive, DONE when they are out, STOP to opt out.`,
    es: () =>
      `${APP_SHORT_NAME}: responda 1 para tomar un trabajo, 2 para pasar, HERE al llegar, DONE cuando salgan, STOP para no recibir más.`,
  },

  "unknown.no_account": {
    en: () =>
      `${APP_SHORT_NAME}: this number is not registered as a volunteer. Sign up on our site if you want to help.`,
    es: () =>
      `${APP_SHORT_NAME}: este número no está registrado como voluntario. Regístrese en nuestro sitio si quiere ayudar.`,
  },

  // --- to admins ------------------------------------------------------------

  "admin.unmatched_alert": {
    en: (p) =>
      `${APP_SHORT_NAME} ADMIN: ${p.short_code} has had no taker for ${p.minutes} min. ${p.notified} volunteers texted${
        p.county ? `, ${p.county} County` : ""
      }. Needs a manual dispatch.`,
    es: (p) =>
      `${APP_SHORT_NAME} ADMIN: ${p.short_code} lleva ${p.minutes} min sin que nadie la tome. ${p.notified} voluntarios avisados${
        p.county ? `, condado de ${p.county}` : ""
      }. Requiere despacho manual.`,
  },
};

export function isKnownTemplate(key: string): key is SmsTemplateKey {
  return key in TEMPLATES;
}

export function renderSms(key: string, params: SmsParams, locale: string): string | null {
  if (!isKnownTemplate(key)) return null;
  const template = TEMPLATES[key];
  const render = locale === "es" ? template.es : template.en;
  return render(params ?? {});
}

/** Rough segment count, for the admin SMS log and for spotting copy that got too long. */
export function segmentCount(body: string): number {
  const isUnicode = Array.from(body).some((char) => char.charCodeAt(0) > 127);
  const perSegment = isUnicode ? 70 : 160;
  const perSegmentMulti = isUnicode ? 67 : 153;
  if (body.length <= perSegment) return 1;
  return Math.ceil(body.length / perSegmentMulti);
}
