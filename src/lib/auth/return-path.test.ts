import { describe, expect, it } from "vitest";

import { safeReturnPath } from "./return-path";

/**
 * This value reaches a redirect, and it is written by client JavaScript, so it is untrusted in
 * exactly the way a query parameter is. The cases below are the open-redirect shapes that get
 * past a naive `startsWith("/")`.
 */
describe("safeReturnPath", () => {
  it("accepts a same-site path", () => {
    expect(safeReturnPath("/account/security")).toBe("/account/security");
    expect(safeReturnPath("/es/account/security")).toBe("/es/account/security");
    expect(safeReturnPath("/me")).toBe("/me");
  });

  it("decodes what the cookie was written with", () => {
    expect(safeReturnPath(encodeURIComponent("/account/security"))).toBe("/account/security");
  });

  it("refuses another origin", () => {
    expect(safeReturnPath("https://evil.example/pwn")).toBeNull();
    expect(safeReturnPath("http://evil.example")).toBeNull();
  });

  it("refuses a protocol-relative path, which a browser reads as another origin", () => {
    expect(safeReturnPath("//evil.example/pwn")).toBeNull();
    // Encoded, because the attacker writes the cookie and gets to choose the encoding.
    expect(safeReturnPath("%2F%2Fevil.example")).toBeNull();
  });

  it("refuses a backslash path, which several browsers normalise to //", () => {
    expect(safeReturnPath("/\\evil.example")).toBeNull();
  });

  it("refuses control characters and newlines", () => {
    expect(safeReturnPath("/account\nLocation: https://evil.example")).toBeNull();
    expect(safeReturnPath("/account\u0000")).toBeNull();
  });

  it("refuses a malformed escape rather than repairing it", () => {
    expect(safeReturnPath("/%E0%A4%A")).toBeNull();
  });

  it("refuses nothing at all", () => {
    expect(safeReturnPath(null)).toBeNull();
    expect(safeReturnPath(undefined)).toBeNull();
    expect(safeReturnPath("")).toBeNull();
  });

  it("refuses a bare word, which would be read as relative to the callback", () => {
    expect(safeReturnPath("account/security")).toBeNull();
  });
});
