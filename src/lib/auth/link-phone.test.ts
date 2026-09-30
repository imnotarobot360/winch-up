import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";

import { confirmPhoneCode, sendPhoneCode } from "./link-phone";

/**
 * The duplicate-account bug, pinned.
 *
 * These assertions are about WHICH auth primitive gets called, which sounds like testing the
 * implementation rather than the behaviour -- and normally would be. Here the choice IS the
 * behaviour: signInWithOtp hands a signed-in member a second account and updateUser does not,
 * and every other observable (a code arrives, it is accepted, the profile saves) is identical
 * between the two. There is nothing else to assert on.
 */

type Calls = {
  signInWithOtp: ReturnType<typeof vi.fn>;
  updateUser: ReturnType<typeof vi.fn>;
  verifyOtp: ReturnType<typeof vi.fn>;
};

function fakeSupabase(session: object | null, overrides: Partial<Calls> = {}) {
  const calls: Calls = {
    signInWithOtp: vi.fn(async () => ({ error: null })),
    updateUser: vi.fn(async () => ({ error: null })),
    verifyOtp: vi.fn(async () => ({ error: null })),
    ...overrides,
  };

  const client = {
    auth: {
      getSession: async () => ({ data: { session } }),
      ...calls,
    },
  } as unknown as SupabaseClient;

  return { client, calls };
}

beforeEach(() => {
  // These paths log the provider's reason on failure, deliberately. Silence it here so a
  // passing run is quiet, but keep it a spy so the assertions can still see it happened.
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("sendPhoneCode", () => {
  it("LINKS when there is a session -- never signInWithOtp, which would mint a second account", async () => {
    const { client, calls } = fakeSupabase({ user: { id: "abc" } });

    const result = await sendPhoneCode(client, "+15125550123", "test");

    expect(result).toEqual({ ok: true, linking: true });
    expect(calls.updateUser).toHaveBeenCalledWith({ phone: "+15125550123" });
    expect(calls.signInWithOtp).not.toHaveBeenCalled();
  });

  it("signs in when there is no session -- a returning volunteer's way back in", async () => {
    const { client, calls } = fakeSupabase(null);

    const result = await sendPhoneCode(client, "+15125550123", "test");

    expect(result).toEqual({ ok: true, linking: false });
    expect(calls.signInWithOtp).toHaveBeenCalledWith({
      phone: "+15125550123",
      options: { channel: "sms" },
    });
    expect(calls.updateUser).not.toHaveBeenCalled();
  });

  it("reports a number held by another account as phone_taken, not as a failed send", async () => {
    const { client } = fakeSupabase(
      { user: { id: "abc" } },
      {
        updateUser: vi.fn(async () => ({
          error: { code: "phone_exists", status: 422, message: "already registered" },
        })),
      },
    );

    // "Try again" would have them retrying forever; the number belongs to somebody else and
    // no amount of retrying changes that.
    expect(await sendPhoneCode(client, "+15125550123", "test")).toEqual({
      ok: false,
      error: "phone_taken",
      linking: true,
    });
  });

  it("reports anything else as a send failure, and logs the provider's reason", async () => {
    const { client } = fakeSupabase(null, {
      signInWithOtp: vi.fn(async () => ({
        error: { code: "sms_send_failed", status: 500, message: "Twilio 21212" },
      })),
    });

    expect(await sendPhoneCode(client, "+15125550123", "test")).toEqual({
      ok: false,
      error: "otp_send_failed",
      linking: false,
    });

    // The Twilio code is the whole diagnosis when Supabase's SMS settings are wrong, and it is
    // not shown to the member. If it is not logged it exists nowhere.
    expect(console.error).toHaveBeenCalledWith(
      "[test] sending the code failed",
      expect.objectContaining({ message: "Twilio 21212", linking: false }),
    );
  });

  it("returns linking even on failure, so a caller cannot keep a stale value", async () => {
    const { client } = fakeSupabase(
      { user: { id: "abc" } },
      { updateUser: vi.fn(async () => ({ error: { code: "x", status: 500, message: "x" } })) },
    );

    const result = await sendPhoneCode(client, "+15125550123", "test");
    expect(result.linking).toBe(true);
  });
});

describe("confirmPhoneCode", () => {
  it("uses phone_change when linking", async () => {
    const { client, calls } = fakeSupabase({ user: { id: "abc" } });

    await confirmPhoneCode(client, "+15125550123", " 123456 ", true, "test");

    expect(calls.verifyOtp).toHaveBeenCalledWith({
      phone: "+15125550123",
      token: "123456",
      type: "phone_change",
    });
  });

  it("uses sms when signing in", async () => {
    const { client, calls } = fakeSupabase(null);

    await confirmPhoneCode(client, "+15125550123", "123456", false, "test");

    expect(calls.verifyOtp).toHaveBeenCalledWith({
      phone: "+15125550123",
      token: "123456",
      type: "sms",
    });
  });

  it("does not consult the session itself -- the caller carries the decision", async () => {
    // Signing in by phone CREATES a session, so a fresh getSession() here can answer
    // differently from the one that chose how the code was sent. If this function looked it up
    // again, a phone sign-in would verify with type 'phone_change' and fail.
    const { client, calls } = fakeSupabase({ user: { id: "brand-new-from-the-send" } });

    await confirmPhoneCode(client, "+15125550123", "123456", false, "test");

    expect(calls.verifyOtp).toHaveBeenCalledWith(expect.objectContaining({ type: "sms" }));
  });

  it("distinguishes a taken number from a wrong code", async () => {
    const taken = fakeSupabase(null, {
      verifyOtp: vi.fn(async () => ({ error: { code: "phone_exists", status: 422, message: "" } })),
    });
    expect(await confirmPhoneCode(taken.client, "+15125550123", "123456", true, "test")).toEqual({
      ok: false,
      error: "phone_taken",
    });

    const wrong = fakeSupabase(null, {
      verifyOtp: vi.fn(async () => ({ error: { code: "otp_expired", status: 403, message: "" } })),
    });
    expect(await confirmPhoneCode(wrong.client, "+15125550123", "000000", true, "test")).toEqual({
      ok: false,
      error: "bad_code",
    });
  });
});
