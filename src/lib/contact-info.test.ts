import { describe, expect, it } from "vitest";

import cases from "./__fixtures__/contact-info-cases.json";
import { containsContactInfo } from "./contact-info";

/**
 * The TypeScript half of the contact-info parity check.
 *
 * `public.contains_contact_info()` is tested against this same fixture file by
 * supabase/tests/contact_info_parity_test.sql, which is generated from it. If somebody changes
 * one implementation and not the other, one of the two suites fails.
 *
 * The database is the enforcement point; this copy exists so a person typing their phone number
 * into the public notes field finds out while they are typing rather than losing the form to a
 * constraint violation on submit. That only helps if the two agree.
 */
describe("containsContactInfo", () => {
  describe("blocks contact details", () => {
    for (const { text, why } of cases.blocked) {
      it(`${why}: ${JSON.stringify(text)}`, () => {
        expect(containsContactInfo(text)).toBe(true);
      });
    }
  });

  describe("allows ordinary description", () => {
    for (const { text, why } of cases.allowed) {
      it(`${why}: ${JSON.stringify(text)}`, () => {
        expect(containsContactInfo(text)).toBe(false);
      });
    }
  });

  describe("nullish input", () => {
    it("treats null as clean", () => {
      expect(containsContactInfo(null)).toBe(false);
    });

    it("treats undefined as clean", () => {
      expect(containsContactInfo(undefined)).toBe(false);
    });
  });
});
