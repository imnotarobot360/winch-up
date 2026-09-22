import { describe, expect, it } from "vitest";

import {
  isKnownTemplate,
  renderLooksBroken,
  renderSms,
  segmentCount,
  type SmsTemplateKey,
} from "./templates";

/**
 * SMS copy is the one part of this product that reaches somebody who is not looking at a screen
 * we control. A template that renders `undefined`, silently falls back to English, or quietly
 * costs three segments is not caught by types, a build, or a screenshot.
 */

const ALL_KEYS: SmsTemplateKey[] = [
  "requester.created",
  "requester.accepted",
  "requester.on_site",
  "requester.unmatched",
  "requester.recovered_by_responder",
  "responder.offer",
  "responder.assigned",
  "responder.already_covered",
  "responder.declined_ack",
  "responder.job_cancelled",
  "responder.recovered",
  "responder.thanks",
  "responder.on_site_ack",
  "responder.complete_ack",
  "responder.no_open_job",
  "responder.started",
  "responder.help",
];

// Every parameter any template reads. Deliberately complete: the point of the sweep below is to
// catch a template that leaks "undefined" into a real text message, and that only means anything
// if the fixture supplies what the templates actually ask for.
const PARAMS = {
  short_code: "TX-AB12",
  url: "https://www.winch-up.com/r/abcd1234",
  name: "Mike",
  first_name: "Mike",
  requester_name: "Dana",
  requester_phone: "+15125550134",
  phone: "+15125550134",
  vehicle_class: "truck",
  vehicle_desc: "White F-250",
  stuck_type: "mud",
  stuck_depth: "frame",
  needs_tractor: false,
  needs_second_truck: true,
  location_note: "past the second gate",
  county: "Travis",
  lat: 30.2672,
  lng: -97.7431,
  miles: 13.3,
  minutes: 25,
  eta_minutes: 40,
  notified: 7,
  note: "Thanks for coming out.",
};

describe("renderSms", () => {
  describe("every template renders in both languages", () => {
    for (const key of ALL_KEYS) {
      for (const locale of ["en", "es"] as const) {
        it(`${key} / ${locale}`, () => {
          const body = renderSms(key, PARAMS, locale);

          expect(body, "should render").not.toBeNull();
          expect(body!.length, "should not be empty").toBeGreaterThan(0);

          // The failure mode that actually reaches a phone: a missing parameter interpolated as
          // the literal string "undefined", or an unreplaced placeholder.
          expect(body, `${key}/${locale} leaked undefined`).not.toMatch(/undefined/);
          expect(body, `${key}/${locale} leaked null`).not.toMatch(/\bnull\b/);
          expect(body, `${key}/${locale} left a placeholder`).not.toMatch(/\{[a-z_]+\}/i);
        });
      }
    }
  });

  it("Spanish differs from English, so nothing silently falls back", () => {
    const differing = ALL_KEYS.filter(
      (key) => renderSms(key, PARAMS, "en") !== renderSms(key, PARAMS, "es"),
    );
    // Every one of them should differ. If a template is identical across languages it is either
    // untranslated or a bug, and both are worth failing on.
    expect(differing).toHaveLength(ALL_KEYS.length);
  });

  it("an unknown locale falls back to English rather than returning nothing", () => {
    expect(renderSms("requester.created", PARAMS, "fr")).toBe(
      renderSms("requester.created", PARAMS, "en"),
    );
  });

  it("an unknown template key returns null rather than throwing", () => {
    expect(renderSms("not.a.template", PARAMS, "en")).toBeNull();
  });
});

describe("isKnownTemplate", () => {
  it("accepts every key the union declares", () => {
    for (const key of ALL_KEYS) expect(isKnownTemplate(key)).toBe(true);
  });

  it("rejects anything else", () => {
    expect(isKnownTemplate("responder.nope")).toBe(false);
    expect(isKnownTemplate("")).toBe(false);
  });
});

describe("segmentCount", () => {
  it("counts a short GSM message as one segment", () => {
    expect(segmentCount("Winch Up TX-AB12: we got it.")).toBe(1);
  });

  it("uses the 160 character boundary for GSM text", () => {
    expect(segmentCount("a".repeat(160))).toBe(1);
    expect(segmentCount("a".repeat(161))).toBe(2);
  });

  // The subtle one, and the reason this function exists. A single accented character switches
  // the whole message to UCS-2 and more than halves what fits -- which is why Spanish copy can
  // cost twice as much to send as its English twin of the same length.
  it("drops to the 70 character boundary as soon as one non-GSM character appears", () => {
    expect(segmentCount("a".repeat(70))).toBe(1);
    expect(segmentCount("á" + "a".repeat(69))).toBe(1);
    expect(segmentCount("á" + "a".repeat(70))).toBe(2);
  });

  it("uses the shorter per-segment length once a message is split", () => {
    // 153 for GSM, not 160, because concatenation headers take the difference.
    expect(segmentCount("a".repeat(306))).toBe(2);
    expect(segmentCount("a".repeat(307))).toBe(3);
  });

  it("treats an empty body as one segment rather than zero", () => {
    expect(segmentCount("")).toBe(1);
  });
});

describe("real Spanish copy", () => {
  it("renders the volunteer offer without leaking English", () => {
    const body = renderSms("responder.offer", PARAMS, "es")!;
    expect(body).toMatch(/Responda/);
    expect(body).not.toMatch(/Reply/);
  });

  it("keeps the volunteer offer to a sane number of segments", () => {
    const en = renderSms("responder.offer", PARAMS, "en")!;
    const es = renderSms("responder.offer", PARAMS, "es")!;
    // Not a hard cost limit, a smell test: an offer text that runs to four segments has
    // probably grown a paragraph it does not need.
    expect(segmentCount(en)).toBeLessThanOrEqual(3);
    expect(segmentCount(es)).toBeLessThanOrEqual(3);
  });
});

describe("renderLooksBroken", () => {
  it("passes a normal message", () => {
    expect(renderLooksBroken(renderSms("responder.offer", PARAMS, "en")!)).toBeNull();
    expect(renderLooksBroken(renderSms("responder.offer", PARAMS, "es")!)).toBeNull();
  });

  // What an incomplete params row actually produced while these tests were being written.
  it("catches a leaked undefined", () => {
    expect(
      renderLooksBroken("Winch Up TX-AB12: es suyo. undefined, undefined. Escriba HERE al llegar."),
    ).toMatch(/undefined/);
  });

  it("catches undefined inside a map link, which is a pin in the ocean", () => {
    expect(
      renderLooksBroken("Punto: https://www.google.com/maps/search/?api=1&query=undefined,undefined"),
    ).not.toBeNull();
  });

  it("catches NaN from arithmetic on a missing number", () => {
    expect(renderLooksBroken("Truck is NaN mi from you.")).toMatch(/NaN/);
  });

  it("catches an unreplaced placeholder", () => {
    expect(renderLooksBroken("Winch Up {short_code}: we got it.")).toMatch(/placeholder/);
  });

  it("does not trip on ordinary words that merely contain the letters", () => {
    expect(renderLooksBroken("The road is undefinedly rough")).toBeNull();
    expect(renderLooksBroken("Bring a NaNny goat")).toBeNull();
  });

  it("does not trip on braces that are not placeholders", () => {
    expect(renderLooksBroken("Gate code is {1234}")).toBeNull();
  });

  // Every template, both languages, with a deliberately empty params object: this is the shape
  // of the failure the guard exists for, and it should be caught rather than sent.
  it("would catch every template rendered with no params at all", () => {
    const leaked = ALL_KEYS.flatMap((key) =>
      (["en", "es"] as const).map((locale) => {
        const body = renderSms(key, {}, locale);
        return body && renderLooksBroken(body) ? null : key;
      }),
    ).filter((key): key is SmsTemplateKey => key !== null);

    // Templates with no parameters at all render fine with none supplied, which is correct.
    // The point is that none of them sneak a broken body past the guard.
    for (const key of leaked) {
      const body = renderSms(key, {}, "en")!;
      expect(body, `${key} rendered something broken the guard missed`).not.toMatch(
        /undefined|NaN|{[a-z_]+}/i,
      );
    }
  });
});
