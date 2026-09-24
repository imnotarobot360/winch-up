// @vitest-environment happy-dom
import { beforeEach, describe, expect, it, vi } from "vitest";

import { dequeue, enqueue, flush, listQueued, type QueuedMessage, type SendResult } from "./outbox";

/**
 * The offline queue, tested as the thing it is: the part of the app that decides whether somebody
 * standing in a field gets heard once, twice, or not at all.
 *
 * The scenario behind every case here is the same. A phone with one bar sends "at the gate". The
 * request leaves, the reply does not come back, and the browser cannot tell whether the message
 * landed. Both obvious answers are wrong -- give up and the team never hears it, retry blindly
 * and the team hears it twice -- so the queue holds it and every attempt carries the same key.
 */

beforeEach(() => {
  window.localStorage.clear();
});

/** A send that never answers, like a request into a dead zone. */
const unreachable = async (): Promise<SendResult> => ({ kind: "unreachable" });
const sent = async (): Promise<SendResult> => ({ kind: "sent" });

describe("holding what could not be sent", () => {
  it("keeps a message that got no answer, so it is not lost", async () => {
    enqueue("req-1", "at the gate");
    await flush("req-1", unreachable);

    expect(listQueued("req-1")).toHaveLength(1);
    expect(listQueued("req-1")[0].body).toBe("at the gate");
  });

  it("drops it once the server confirms, so it is not sent again", async () => {
    enqueue("req-1", "at the gate");
    const outcome = await flush("req-1", sent);

    expect(outcome.sent).toBe(1);
    expect(listQueued("req-1")).toHaveLength(0);
  });

  it("survives the tab closing, which is the point of not keeping it in memory", () => {
    enqueue("req-1", "winch is on the tree");
    // A fresh read of storage is what a reload does.
    expect(listQueued("req-1")[0].body).toBe("winch is on the tree");
  });

  it("gives every message its own key, so two identical lines stay two messages", () => {
    const a = enqueue("req-1", "on my way");
    const b = enqueue("req-1", "on my way");
    expect(a.clientId).not.toBe(b.clientId);
  });

  it("keeps the key stable across retries, which is what stops the duplicate", async () => {
    const item = enqueue("req-1", "at the gate");
    const keys: string[] = [];

    await flush("req-1", async (m) => {
      keys.push(m.clientId);
      return { kind: "unreachable" };
    });
    await flush("req-1", async (m) => {
      keys.push(m.clientId);
      return { kind: "unreachable" };
    });

    expect(keys).toEqual([item.clientId, item.clientId]);
  });
});

describe("what it does not retry", () => {
  it("drops a message the server refused for a reason retrying cannot fix", async () => {
    enqueue("req-1", "x".repeat(3000));
    const outcome = await flush("req-1", async () => ({ kind: "rejected", error: "too_long" }));

    expect(outcome.rejected).toEqual([{ clientId: expect.any(String), error: "too_long" }]);
    expect(listQueued("req-1")).toHaveLength(0);
  });

  it("but keeps one that merely got no answer -- the two must not be confused", async () => {
    enqueue("req-1", "at the gate");
    await flush("req-1", unreachable);
    expect(listQueued("req-1")).toHaveLength(1);
  });
});

describe("order", () => {
  it("sends oldest first", async () => {
    enqueue("req-1", "first");
    enqueue("req-1", "second");
    const order: string[] = [];

    await flush("req-1", async (m) => {
      order.push(m.body);
      return { kind: "sent" };
    });

    expect(order).toEqual(["first", "second"]);
  });

  it("stops at the first one that cannot get through, so the thread cannot be reordered", async () => {
    enqueue("req-1", "on my way");
    enqueue("req-1", "just arrived");
    const tried: string[] = [];

    const outcome = await flush("req-1", async (m) => {
      tried.push(m.body);
      return { kind: "unreachable" };
    });

    // "just arrived" is never attempted while "on my way" is still stuck behind it. Sending it
    // anyway would put the team's messages out of order in a conversation where the order is the
    // information.
    expect(tried).toEqual(["on my way"]);
    expect(outcome.stalled).toBe(2);
  });
});

describe("keeping recoveries apart", () => {
  it("a queued message belongs to one recovery and is not flushed by another", async () => {
    enqueue("req-1", "for the first job");
    enqueue("req-2", "for the second job");

    await flush("req-1", sent);

    expect(listQueued("req-1")).toHaveLength(0);
    expect(listQueued("req-2")).toHaveLength(1);
  });
});

describe("the failures that are not the network", () => {
  it("renders an empty queue rather than throwing when storage is unavailable", () => {
    const spy = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("The operation is insecure.");
    });

    // A private window on some browsers throws on access rather than returning null. A chat that
    // cannot draw because a preference store is unavailable is a far worse failure than a queue
    // that does not survive a reload.
    expect(() => listQueued("req-1")).not.toThrow();
    expect(listQueued("req-1")).toEqual([]);

    spy.mockRestore();
  });

  it("survives a storage value that is not what it wrote", () => {
    window.localStorage.setItem("winchup.outbox.v1", "{not json");
    expect(listQueued("req-1")).toEqual([]);
  });

  it("ignores entries that are the wrong shape rather than rendering undefined", () => {
    window.localStorage.setItem("winchup.outbox.v1", JSON.stringify([{ nonsense: true }, null]));
    expect(listQueued("req-1")).toEqual([]);
  });

  it("gives up on a message older than a day instead of retrying it forever", () => {
    const old: QueuedMessage = {
      clientId: "11111111-1111-4111-8111-111111111111",
      requestId: "req-1",
      body: "sent from a car park last week",
      queuedAt: Date.now() - 25 * 60 * 60 * 1000,
      attempts: 40,
    };
    window.localStorage.setItem("winchup.outbox.v1", JSON.stringify([old]));

    // A day-old "I'm five minutes away" is not worth delivering, and a queue that never empties
    // is a queue that eventually sends something absurd.
    expect(listQueued("req-1")).toEqual([]);
  });
});

describe("counting attempts", () => {
  it("counts them, so the screen can stop saying this looks like a blip", async () => {
    enqueue("req-1", "at the gate");
    await flush("req-1", unreachable);
    await flush("req-1", unreachable);
    await flush("req-1", unreachable);

    expect(listQueued("req-1")[0].attempts).toBe(3);
  });
});

describe("removing one by hand", () => {
  it("dequeue takes out exactly the one named", () => {
    const a = enqueue("req-1", "first");
    enqueue("req-1", "second");

    dequeue(a.clientId);

    expect(listQueued("req-1").map((m) => m.body)).toEqual(["second"]);
  });
});
