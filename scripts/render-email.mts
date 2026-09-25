/**
 * Render an account email to a file, for pasting into the Supabase Auth template editor.
 *
 * Supabase sends the verification and password-reset emails itself, so their copy has to be
 * pasted into its dashboard rather than imported from here. That is the one place this app's
 * email design can drift from the two emails most members will actually see, so the copy is
 * generated from the same module the app uses instead of being written twice.
 *
 *   npm run email:render                      # all of them, to .tmp/email/
 *   npm run email:render -- auth.verify es    # one, to stdout
 *
 * SUPABASE'S PLACEHOLDERS ARE PASSED THROUGH UNTOUCHED. `{{ .ConfirmationURL }}` is the
 * single-use link Supabase substitutes at send time; anything else in that slot produces an
 * email that looks correct and verifies nobody.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { EMAIL_TEMPLATE_KEYS, renderEmail, type EmailTemplateKey } from "../src/lib/email/templates";

const PRODUCTION = "https://www.winch-up.com";

/**
 * Deliberately NOT just `process.env.NEXT_PUBLIC_SITE_URL`.
 *
 * That variable is http://127.0.0.1:3100 in .env.local, and vite-node loads .env files, so the
 * first run of this script rendered a footer pointing at localhost. The output of this script
 * gets pasted into the production Supabase dashboard, where a localhost link is a dead link in
 * every member's inbox and nothing would catch it -- the template editor does not validate URLs
 * and the email would look perfectly fine in review.
 *
 * So a local URL is refused rather than used, loudly. Override with EMAIL_RENDER_SITE_URL when
 * rendering for a staging project on purpose.
 */
function siteUrl(): string {
  const override = process.env.EMAIL_RENDER_SITE_URL;
  if (override) return override.replace(/\/$/, "");

  const fromEnv = process.env.NEXT_PUBLIC_SITE_URL;
  if (fromEnv && !/localhost|127\.0\.0\.1|0\.0\.0\.0/.test(fromEnv)) {
    return fromEnv.replace(/\/$/, "");
  }

  if (fromEnv) {
    console.warn(
      `  note: ignoring NEXT_PUBLIC_SITE_URL=${fromEnv} (local) and using ${PRODUCTION}.\n` +
        "        Set EMAIL_RENDER_SITE_URL to render for somewhere else.\n",
    );
  }
  return PRODUCTION;
}

const SITE = siteUrl();
const SUPPORT = process.env.EMAIL_SUPPORT_ADDRESS || "help@winch-up.com";

/** What each template's button points at when Supabase is the one sending it. */
const ACTION: Partial<Record<EmailTemplateKey, string>> = {
  "auth.verify": "{{ .ConfirmationURL }}",
  "auth.reset": "{{ .ConfirmationURL }}",
  "auth.welcome": SITE,
};

function render(key: EmailTemplateKey, locale: string) {
  return renderEmail(key, {
    locale,
    siteUrl: SITE,
    supportEmail: SUPPORT,
    actionUrl: ACTION[key] ?? SITE,
    params: { new_email: "the new address" },
  });
}

const [wantKey, wantLocale] = process.argv.slice(2);

if (wantKey) {
  if (!EMAIL_TEMPLATE_KEYS.includes(wantKey as EmailTemplateKey)) {
    console.error(`unknown template "${wantKey}". Known: ${EMAIL_TEMPLATE_KEYS.join(", ")}`);
    process.exit(1);
  }
  const mail = render(wantKey as EmailTemplateKey, wantLocale ?? "en");
  console.log(`Subject: ${mail.subject}\n`);
  console.log(mail.html);
  process.exit(0);
}

const outDir = join(process.cwd(), ".tmp", "email");
let written = 0;

for (const key of EMAIL_TEMPLATE_KEYS) {
  for (const locale of ["en", "es"]) {
    const mail = render(key, locale);
    const base = join(outDir, `${key}.${locale}`);
    mkdirSync(dirname(base), { recursive: true });
    writeFileSync(`${base}.html`, mail.html, "utf8");
    writeFileSync(`${base}.txt`, `Subject: ${mail.subject}\n\n${mail.text}`, "utf8");
    written += 2;
  }
}

console.log(`Wrote ${written} files to .tmp/email/`);
console.log("");
console.log("For Supabase (Authentication -> Email Templates), paste:");
console.log("  Confirm signup   <- auth.verify.en.html");
console.log("  Reset password   <- auth.reset.en.html");
console.log("");
console.log("Its editor holds ONE template per type, so those two go out in English whatever");
console.log("language the member reads the site in. The .es files are there for whenever that");
console.log("changes; the welcome and security emails this app sends are already bilingual.");
