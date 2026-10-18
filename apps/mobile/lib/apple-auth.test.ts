import { describe, expect, it, vi } from "vitest";

import { displayNameFrom, signInWithApple, type AppleSignInDeps } from "./apple-auth";

function deps(over: Partial<AppleSignInDeps> = {}): AppleSignInDeps {
  return {
    isAvailable: async () => true,
    signInAsync: async () => ({ identityToken: "token", fullName: null }),
    signInWithIdToken: async () => ({ error: null }),
    randomNonce: () => "raw-nonce",
    sha256: async (v) => `sha256(${v})`,
    ...over,
  };
}

describe("signInWithApple", () => {
  it("gives Apple the HASHED nonce and Supabase the RAW one", async () => {
    // The whole reason this module takes injected dependencies. Swapping these is the classic
    // failure of this integration and it fails on a device with a message that never says "nonce".
    const signInAsync = vi.fn(async () => ({ identityToken: "token", fullName: null }));
    const signInWithIdToken = vi.fn(async () => ({ error: null }));

    await signInWithApple(deps({ signInAsync, signInWithIdToken }));

    expect(signInAsync).toHaveBeenCalledWith({ nonce: "sha256(raw-nonce)" });
    expect(signInWithIdToken).toHaveBeenCalledWith({ token: "token", nonce: "raw-nonce" });
  });

  it("never sends the raw nonce to Apple", async () => {
    const signInAsync = vi.fn(async () => ({ identityToken: "token", fullName: null }));
    await signInWithApple(deps({ signInAsync }));
    expect(signInAsync).not.toHaveBeenCalledWith({ nonce: "raw-nonce" });
  });

  it("reports a dismissed sheet as cancelled, not as a failure", async () => {
    // Somebody choosing not to sign in has not hit an error, and telling them they have is a bug.
    const cancelled = Object.assign(new Error("cancelled"), { code: "ERR_REQUEST_CANCELED" });
    const result = await signInWithApple(
      deps({
        signInAsync: async () => {
          throw cancelled;
        },
      }),
    );
    expect(result).toEqual({ status: "cancelled" });
  });

  it("reports a genuine sheet error as a failure", async () => {
    const result = await signInWithApple(
      deps({
        signInAsync: async () => {
          throw new Error("something else");
        },
      }),
    );
    expect(result).toEqual({ status: "failed", reason: "apple_sheet_failed" });
  });

  it("is unavailable on a platform without the sheet, and asks Apple for nothing", async () => {
    const signInAsync = vi.fn(async () => ({ identityToken: "t", fullName: null }));
    const result = await signInWithApple(deps({ isAvailable: async () => false, signInAsync }));
    expect(result).toEqual({ status: "unavailable" });
    expect(signInAsync).not.toHaveBeenCalled();
  });

  it("refuses a credential with no identity token before Supabase sees it", async () => {
    const signInWithIdToken = vi.fn(async () => ({ error: null }));
    const result = await signInWithApple(
      deps({ signInAsync: async () => ({ identityToken: null, fullName: null }), signInWithIdToken }),
    );
    expect(result).toEqual({ status: "failed", reason: "no_identity_token" });
    expect(signInWithIdToken).not.toHaveBeenCalled();
  });

  it("surfaces a token Supabase rejected as its own reason", async () => {
    const result = await signInWithApple(
      deps({ signInWithIdToken: async () => ({ error: new Error("bad audience") }) }),
    );
    expect(result).toEqual({ status: "failed", reason: "supabase_rejected_token" });
  });

  it("carries the name through on the one authorization Apple provides it", async () => {
    const result = await signInWithApple(
      deps({
        signInAsync: async () => ({
          identityToken: "token",
          fullName: { givenName: "Rosa", familyName: "Vega" },
        }),
      }),
    );
    expect(result).toEqual({ status: "signed_in", displayName: "Rosa Vega" });
  });

  it("signs in perfectly well with no name, which is every sign-in after the first", async () => {
    const result = await signInWithApple(deps());
    expect(result).toEqual({ status: "signed_in", displayName: null });
  });
});

describe("displayNameFrom", () => {
  it("joins both parts", () => {
    expect(displayNameFrom({ givenName: "Rosa", familyName: "Vega" })).toBe("Rosa Vega");
  });

  it("accepts either half alone", () => {
    expect(displayNameFrom({ givenName: "Rosa", familyName: null })).toBe("Rosa");
    expect(displayNameFrom({ givenName: null, familyName: "Vega" })).toBe("Vega");
  });

  it("returns null rather than a blank-looking name", () => {
    // " " would read as a name that is set, and the profile screen would stop asking for one.
    expect(displayNameFrom({ givenName: "  ", familyName: "" })).toBeNull();
    expect(displayNameFrom(null)).toBeNull();
    expect(displayNameFrom(undefined)).toBeNull();
  });
});
