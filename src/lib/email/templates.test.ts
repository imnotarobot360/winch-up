import { describe, expect, it } from "vitest";

import { APP_NAME } from "@/config/app";

import { EMAIL_TEMPLATE_KEYS, renderEmail, type EmailTemplateKey } from "./templates";

const BASE = {
  siteUrl: "https://www.winch-up.com",
  supportEmail: "help@winch-up.com",
  actionUrl: "https://www.winch-up.com/auth/callback?code=abc123",
};

/** Keys whose copy has a button. The rest are notices with nothing to click. */
const WITH_BUTTON: EmailTemplateKey[] = ["auth.verify", "auth.welcome", "auth.reset"];

describe("every template, in both languages", () => {
  for (const key of EMAIL_TEMPLATE_KEYS) {
    for (const locale of ["en", "es"] as const) {
      it(`${key} renders in ${locale}`, () => {
        const mail = renderEmail(key, { ...BASE, locale });

        expect(mail.subject.length).toBeGreaterThan(0);
        expect(mail.html).toContain("<!doctype html>");
        expect(mail.text.length).toBeGreaterThan(0);

        // A missing interpolation is the failure mode that ships: it renders, it looks fine in
        // review, and it says "undefined" in somebody's inbox.
        expect(mail.subject).not.toMatch(/undefined|null|\[object/i);
        expect(mail.html).not.toMatch(/undefined|null|\[object/i);
        expect(mail.text).not.toMatch(/undefined|\[object/i);
      });
    }
  }

  it("Spanish is actually Spanish, not English wearing a locale", () => {
    const en = renderEmail("auth.welcome", { ...BASE, locale: "en" });
    const es = renderEmail("auth.welcome", { ...BASE, locale: "es" });

    expect(es.subject).not.toBe(en.subject);
    expect(es.text).toContain("Bienvenido");
    expect(es.text).toContain("Ningún vehículo se queda atrás.".toUpperCase());
  });

  it("an unknown locale falls back to English rather than throwing", () => {
    const mail = renderEmail("auth.verify", { ...BASE, locale: "fr" });
    expect(mail.text).toContain("brotherhood");
  });
});

describe("the action link", () => {
  it.each(WITH_BUTTON)("%s puts the real URL in the button, not the homepage", (key) => {
    const mail = renderEmail(key, { ...BASE });

    expect(mail.html).toContain(BASE.actionUrl.replace(/&/g, "&amp;"));
    expect(mail.text).toContain(BASE.actionUrl);
  });

  it.each(WITH_BUTTON)("%s refuses to render without one", (key) => {
    // §4 is explicit that a homepage URL is not a substitute for the verification link. Falling
    // back silently would produce an email that looks right and verifies nobody, so this throws.
    expect(() => renderEmail(key, { ...BASE, actionUrl: undefined })).toThrow(/actionUrl/);
  });

  it("a notice with no button renders fine without one", () => {
    const mail = renderEmail("security.password_changed", {
      siteUrl: BASE.siteUrl,
      supportEmail: BASE.supportEmail,
    });
    expect(mail.html).toContain("<!doctype html>");
  });
});

describe("what must never be in an account email", () => {
  for (const key of EMAIL_TEMPLATE_KEYS) {
    it(`${key} carries no coordinates, phone number or token-looking string`, () => {
      const mail = renderEmail(key, {
        ...BASE,
        params: { new_email: "new@example.com" },
      });
      const body = `${mail.subject}\n${mail.text}`;

      // A recovery pin or a phone number in an inbox is the thing the whole privacy model is
      // about. None of these templates has a reason to interpolate one, and this is what keeps
      // it that way when somebody adds the next template.
      expect(body).not.toMatch(/\b\d{2}\.\d{4,},\s*-?\d{2,3}\.\d{4,}\b/);
      expect(body).not.toMatch(/\+1\d{10}\b/);
      expect(body).not.toMatch(/\/r\/[A-Za-z0-9_-]{8,}/);
    });
  }

  it("escapes a display name rather than interpolating markup", () => {
    const mail = renderEmail("security.email_changed", {
      ...BASE,
      params: { new_email: '<script>alert(1)</script>@x.com' },
    });

    expect(mail.html).not.toContain("<script>");
    expect(mail.html).toContain("&lt;script&gt;");
  });
});

describe("branding", () => {
  it("uses APP_NAME rather than a second hard-coded spelling", () => {
    const mail = renderEmail("auth.verify", { ...BASE });
    // CLAUDE.md's first rule: the product name lives in exactly one place. The brand stylises it
    // as WINCH-UP, which is this transform rather than a stored second name.
    expect(mail.text).toContain(APP_NAME.toUpperCase().split(" ").join("-"));
    expect(mail.subject).toContain(APP_NAME);
  });

  it("puts charcoal on the orange button, never white", () => {
    // globals.css records white on this orange as 2.87:1 and unusable. That is still true in an
    // inbox, where nobody can override it.
    const mail = renderEmail("auth.verify", { ...BASE });
    expect(mail.html).toMatch(/background[^;]*#ff6a00|bgcolor="#ff6a00"/i);
    expect(mail.html).toContain("#1a1a1a");
  });

  it("has exactly one image, the logo, and nothing depends on it loading", () => {
    // Mail clients block images by default. One logo is worth it; a second image, or any part of
    // the message living inside one, is not -- that email arrives blank for most readers.
    for (const key of EMAIL_TEMPLATE_KEYS) {
      const mail = renderEmail(key, { ...BASE });
      const imgs = mail.html.match(/<img\b[^>]*>/gi) ?? [];

      expect(imgs, `${key} should have exactly one image`).toHaveLength(1);
      expect(imgs[0]).toContain("/brand/logo-lockup.png");

      // The alt text is the fallback wordmark. Without it a blocked logo is a broken-image icon
      // where the brand should be.
      expect(imgs[0]).toMatch(/alt="WINCH-UP"/);

      // The text part carries the whole message on its own, logo or no logo.
      expect(mail.text).not.toMatch(/<img|\.png/i);
    }
  });

  it("points the logo at the site it was rendered for, not a hard-coded host", () => {
    const staging = renderEmail("auth.verify", { ...BASE, siteUrl: "https://staging.example.com" });
    expect(staging.html).toContain("https://staging.example.com/brand/logo-lockup.png");
    expect(staging.html).not.toContain("www.winch-up.com/brand");
  });
});
