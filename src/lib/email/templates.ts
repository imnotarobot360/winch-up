import en from "../../../messages/en.json";
import es from "../../../messages/es.json";

import { APP_NAME } from "@/config/app";

/**
 * Account email copy lives here, next to the SMS templates and for the same reasons.
 *
 * The caller passes a template key plus params; this renders it in the recipient's own language.
 * Nothing about the wording needs a migration, and Spanish is written here rather than bolted on.
 *
 * Rules for writing these:
 *  - The product name comes from APP_NAME. It is never typed out. The brand stylises it as
 *    WINCH-UP in the mockups, so the wordmark applies `text-transform` rather than storing a
 *    second spelling -- see the rule at the top of CLAUDE.md.
 *  - The motto is `app.motto` from the message catalogues, which already has both languages.
 *  - Every email is sent as HTML AND plain text. Some people read mail in a terminal, and a
 *    text/plain part is also what keeps a message out of the spam folder.
 *  - No remote images. Mail clients block them by default, so an email that needs one to make
 *    sense is an email that arrives broken. The wordmark is text.
 *  - No secrets, no tokens beyond the single-use link, no coordinates, no phone numbers. An
 *    inbox is not a place to put where somebody is stuck.
 */

export type EmailTemplateKey =
  | "auth.verify"
  | "auth.welcome"
  | "auth.reset"
  | "security.password_changed"
  | "security.email_changed"
  | "security.account_deleted";

export type EmailParams = Record<string, string | number | null | undefined>;

export type RenderedEmail = { subject: string; html: string; text: string };

type Catalogue = typeof en;
const CATALOGUES: Record<string, Catalogue> = { en, es: es as unknown as Catalogue };

function motto(locale: string): string {
  return (CATALOGUES[locale] ?? en).app.motto.toUpperCase();
}

/* ------------------------------------------------------------------ shell */

/**
 * Brand colours, copied as literals because an email cannot read a CSS custom property.
 *
 * `ON_BRAND` is charcoal rather than white deliberately: globals.css records that white on this
 * orange is 2.87:1 and unusable. That does not stop being true inside an inbox.
 */
const SURFACE = "#08150f";
const CARD = "#0b2d1f";
const LINE = "#1e4d38";
const BRAND = "#ff6a00";
const ON_BRAND = "#1a1a1a";
const INK = "#f4f7f5";
const INK_SOFT = "#b6c7bd";

/** Escapes text interpolated into the HTML part. A display name is user-controlled. */
function esc(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function button(href: string, label: string): string {
  // A table, not a styled <a>: Outlook ignores padding on inline elements.
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:28px 0;">
  <tr><td align="center" bgcolor="${BRAND}" style="border-radius:10px;">
    <a href="${esc(href)}" style="display:inline-block;padding:16px 32px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:${ON_BRAND};text-decoration:none;border-radius:10px;">${esc(label)}</a>
  </td></tr>
</table>`;
}

function shell(locale: string, bodyHtml: string, siteUrl: string, supportEmail: string): string {
  const name = APP_NAME.toUpperCase();
  return `<!doctype html>
<html lang="${locale}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
</head>
<body style="margin:0;padding:0;background:${SURFACE};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${SURFACE};padding:24px 12px;">
<tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background:${CARD};border:1px solid ${LINE};border-radius:16px;">
    <tr><td style="padding:28px 28px 8px 28px;font-family:Arial,Helvetica,sans-serif;">
      <div style="font-size:24px;font-weight:bold;letter-spacing:2px;color:${INK};">${esc(name.split(" ").join("-"))}</div>
    </td></tr>
    <tr><td style="padding:8px 28px 28px 28px;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.6;color:${INK};">
${bodyHtml}
    </td></tr>
    <tr><td style="padding:20px 28px;border-top:1px solid ${LINE};font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:1.6;color:${INK_SOFT};">
      <div style="letter-spacing:1px;color:${INK};font-weight:bold;">${esc(motto(locale))}</div>
      <div style="margin-top:8px;">${esc(name.split(" ").join("-"))} &middot;
        <a href="mailto:${esc(supportEmail)}" style="color:${INK_SOFT};">${esc(supportEmail)}</a> &middot;
        <a href="${esc(siteUrl)}" style="color:${INK_SOFT};">${esc(siteUrl.replace(/^https?:\/\//, ""))}</a>
      </div>
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}

function p(text: string): string {
  return `<p style="margin:0 0 14px 0;">${esc(text)}</p>`;
}

function list(items: string[]): string {
  return `<ol style="margin:0 0 14px 0;padding-left:22px;">${items
    .map((i) => `<li style="margin-bottom:8px;">${esc(i)}</li>`)
    .join("")}</ol>`;
}

/* --------------------------------------------------------------- content */

type Copy = {
  subject: string;
  /** Paragraphs and lists, in order. A string is a paragraph; an array is a numbered list. */
  blocks: (string | string[])[];
  cta?: string;
  /** Closing lines below the button, e.g. the "if you did not ask for this" note. */
  after?: string[];
  tagline?: string;
};

type Renderer = (p: EmailParams) => Copy;

const TEMPLATES: Record<EmailTemplateKey, { en: Renderer; es: Renderer }> = {
  /* ---------------------------------------------------------------- §4 */
  "auth.verify": {
    en: () => ({
      subject: `Verify your email — welcome to ${APP_NAME}`,
      blocks: [
        "Welcome to the brotherhood.",
        `Thank you for joining ${APP_NAME}, the off-road recovery community where members help each other.`,
        "Please verify your email address to complete your registration.",
      ],
      cta: "Verify my email",
      after: [
        "Once your email is verified you can complete your profile, add your vehicle, request recovery assistance, and help fellow off-roaders.",
        `If you did not create a ${APP_NAME} account you can ignore this email — nothing will happen until the link above is opened.`,
      ],
      tagline: "Different trails. Same brotherhood.",
    }),
    es: () => ({
      subject: `Verifique su correo — bienvenido a ${APP_NAME}`,
      blocks: [
        "Bienvenido a la hermandad.",
        `Gracias por unirse a ${APP_NAME}, la comunidad de rescate todoterreno donde los miembros se ayudan entre sí.`,
        "Verifique su dirección de correo para completar su registro.",
      ],
      cta: "Verificar mi correo",
      after: [
        "Una vez verificado su correo podrá completar su perfil, agregar su vehículo, pedir ayuda y ayudar a otros todoterreneros.",
        `Si usted no creó una cuenta en ${APP_NAME}, ignore este mensaje: no pasará nada hasta que se abra el enlace de arriba.`,
      ],
      tagline: "Distintos caminos. La misma hermandad.",
    }),
  },

  /* ---------------------------------------------------------------- §5 */
  "auth.welcome": {
    en: () => ({
      subject: `You're in — welcome to the ${APP_NAME} brotherhood`,
      blocks: [
        `Welcome to ${APP_NAME}.`,
        "Your account is verified, and you are now part of a community of off-roaders helping off-roaders.",
        "Here is how to get started:",
        [
          "Complete your member profile.",
          "Add your Jeep, truck or 4x4.",
          "Add the recovery equipment you have available.",
          "Turn on nearby recovery notifications if you want alerts.",
          "Look at nearby recovery requests and offer help when you can.",
        ],
        `Every ${APP_NAME} member can both ask for help and offer it. There is no separate volunteer account.`,
      ],
      cta: `Open ${APP_NAME}`,
      tagline: "Different trails. Same brotherhood.",
    }),
    es: () => ({
      subject: `Ya está dentro — bienvenido a la hermandad de ${APP_NAME}`,
      blocks: [
        `Bienvenido a ${APP_NAME}.`,
        "Su cuenta está verificada y ya forma parte de una comunidad de todoterreneros que se ayudan entre sí.",
        "Así puede empezar:",
        [
          "Complete su perfil de miembro.",
          "Agregue su Jeep, camioneta o 4x4.",
          "Agregue el equipo de rescate que tiene disponible.",
          "Active las notificaciones de rescates cercanos si quiere recibir avisos.",
          "Vea las solicitudes cercanas y ofrezca ayuda cuando pueda.",
        ],
        `Todo miembro de ${APP_NAME} puede pedir ayuda y ofrecerla. No hay una cuenta aparte de voluntario.`,
      ],
      cta: `Abrir ${APP_NAME}`,
      tagline: "Distintos caminos. La misma hermandad.",
    }),
  },

  /* ---------------------------------------------------------------- §6 */
  "auth.reset": {
    en: () => ({
      subject: `Reset your ${APP_NAME} password`,
      blocks: [
        "We received a request to reset the password on this account.",
        "Use the button below to choose a new one. The link works once and expires shortly.",
      ],
      cta: "Choose a new password",
      after: [
        "If you did not ask for this you can ignore this email. Your password stays as it is, and nobody was told that this address has an account.",
      ],
    }),
    es: () => ({
      subject: `Restablezca su contraseña de ${APP_NAME}`,
      blocks: [
        "Recibimos una solicitud para restablecer la contraseña de esta cuenta.",
        "Use el botón de abajo para elegir una nueva. El enlace sirve una sola vez y vence pronto.",
      ],
      cta: "Elegir una contraseña nueva",
      after: [
        "Si usted no pidió esto, ignore el mensaje. Su contraseña queda igual y a nadie se le dijo que esta dirección tiene una cuenta.",
      ],
    }),
  },

  /* ---------------------------------------------------------------- §7 */
  "security.password_changed": {
    en: () => ({
      subject: `Your ${APP_NAME} password was changed`,
      blocks: [
        "The password on your account was just changed.",
        "If that was you, there is nothing to do.",
      ],
      after: [
        "If it was not you, reset your password immediately and then contact us. Whoever changed it may still have access.",
      ],
    }),
    es: () => ({
      subject: `Se cambió su contraseña de ${APP_NAME}`,
      blocks: [
        "Se acaba de cambiar la contraseña de su cuenta.",
        "Si fue usted, no hay nada que hacer.",
      ],
      after: [
        "Si no fue usted, restablezca su contraseña de inmediato y luego comuníquese con nosotros. Quien la cambió podría seguir teniendo acceso.",
      ],
    }),
  },

  "security.email_changed": {
    en: (params) => ({
      subject: `The email on your ${APP_NAME} account was changed`,
      blocks: [
        `The address on your account was changed to ${params.new_email ?? "a new address"}.`,
        "This message goes to the old address so that a change you did not make cannot happen quietly.",
      ],
      after: ["If it was not you, contact us straight away."],
    }),
    es: (params) => ({
      subject: `Se cambió el correo de su cuenta de ${APP_NAME}`,
      blocks: [
        `La dirección de su cuenta se cambió a ${params.new_email ?? "una dirección nueva"}.`,
        "Este aviso llega a la dirección anterior para que un cambio que usted no hizo no pase en silencio.",
      ],
      after: ["Si no fue usted, comuníquese con nosotros de inmediato."],
    }),
  },

  "security.account_deleted": {
    en: () => ({
      subject: `Your ${APP_NAME} account has been deleted`,
      blocks: [
        "Your account is gone, along with your phone number, your name, your saved locations and any recovery still open.",
        "Nothing is kept for you to come back to. If you want to use the app again you would start a new account.",
      ],
      after: ["If you did not ask for this, contact us — but be aware the data is already gone."],
    }),
    es: () => ({
      subject: `Su cuenta de ${APP_NAME} fue eliminada`,
      blocks: [
        "Su cuenta ya no existe, junto con su teléfono, su nombre, sus ubicaciones guardadas y cualquier rescate abierto.",
        "No se guarda nada para que regrese. Si quiere volver a usar la aplicación, sería una cuenta nueva.",
      ],
      after: ["Si usted no pidió esto, comuníquese con nosotros, pero los datos ya fueron borrados."],
    }),
  },
};

/* --------------------------------------------------------------- render */

export type RenderOptions = {
  locale?: string;
  /** The single-use link. Required by every template that has a button. */
  actionUrl?: string;
  siteUrl: string;
  supportEmail: string;
  params?: EmailParams;
};

/**
 * Renders one email in one language.
 *
 * Throws when a template has a button and no `actionUrl`. §4 is explicit that the button must
 * carry the real verification URL and that a homepage link is not a substitute -- silently
 * falling back to the site root would produce an email that looks right and verifies nobody.
 */
export function renderEmail(key: EmailTemplateKey, options: RenderOptions): RenderedEmail {
  const locale = options.locale === "es" ? "es" : "en";
  const copy = TEMPLATES[key][locale](options.params ?? {});

  if (copy.cta && !options.actionUrl) {
    throw new Error(`renderEmail: "${key}" has a button but no actionUrl was given`);
  }

  const htmlBlocks = copy.blocks
    .map((block) => (Array.isArray(block) ? list(block) : p(block)))
    .join("\n");

  const cta = copy.cta && options.actionUrl ? button(options.actionUrl, copy.cta) : "";
  const after = (copy.after ?? []).map(p).join("\n");
  const tagline = copy.tagline
    ? `<p style="margin:20px 0 0 0;color:${INK_SOFT};font-style:italic;">${esc(copy.tagline)}</p>`
    : "";

  const html = shell(
    locale,
    [htmlBlocks, cta, after, tagline].filter(Boolean).join("\n"),
    options.siteUrl,
    options.supportEmail,
  );

  // The plain-text part is written from the same copy rather than stripped out of the HTML, so
  // it reads like something a person wrote instead of like a flattened table.
  const textBlocks = copy.blocks.map((block) =>
    Array.isArray(block) ? block.map((i, n) => `  ${n + 1}. ${i}`).join("\n") : block,
  );

  const text = [
    APP_NAME.toUpperCase().split(" ").join("-"),
    "",
    ...textBlocks,
    ...(copy.cta && options.actionUrl ? ["", `${copy.cta}: ${options.actionUrl}`] : []),
    ...(copy.after?.length ? ["", ...copy.after] : []),
    ...(copy.tagline ? ["", copy.tagline] : []),
    "",
    motto(locale),
    `${options.supportEmail} · ${options.siteUrl}`,
  ].join("\n");

  return { subject: copy.subject, html, text };
}

/** Every key, for tests that assert both languages render. */
export const EMAIL_TEMPLATE_KEYS = Object.keys(TEMPLATES) as EmailTemplateKey[];
