/**
 * Messages a phone has been asked to send but has not yet got an answer about.
 *
 * The situation this exists for: somebody is standing in a field forty miles out, types "at the
 * gate", and the send goes into a hole. Either it arrived and the reply was lost, or it never
 * left. The browser cannot tell the difference, and both wrong answers are bad -- give up and the
 * team never hears it, retry blindly and the team hears it twice.
 *
 * Every message therefore gets a `clientId` before the first attempt, and every retry of it
 * reuses that key. The server stores the key and will not write a second row for it
 * (`request_messages_sender_client_idx`), so the browser is free to retry as often as it likes.
 * The queue is just the list of keys it has not yet had a confirmation for.
 *
 * It lives in localStorage so that closing the tab, or the browser being killed in the
 * background, does not lose what somebody typed. Every access is wrapped: storage throws outright
 * in a private window on some browsers, and a chat that cannot render because a preference store
 * is unavailable would be a much worse failure than a queue that does not survive a reload.
 */

const KEY = "winchup.outbox.v1";

/** Anything older than this is given up on rather than retried forever. */
const MAX_AGE_MS = 24 * 60 * 60 * 1000;

export type QueuedMessage = {
  clientId: string;
  requestId: string;
  body: string;
  queuedAt: number;
  /** Bumped on every failed attempt. Shown to the member once it stops looking like a blip. */
  attempts: number;
};

function read(): QueuedMessage[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const cutoff = Date.now() - MAX_AGE_MS;
    return (parsed as QueuedMessage[]).filter(
      (m) =>
        m &&
        typeof m.clientId === "string" &&
        typeof m.requestId === "string" &&
        typeof m.body === "string" &&
        typeof m.queuedAt === "number" &&
        m.queuedAt > cutoff,
    );
  } catch {
    return [];
  }
}

function write(items: QueuedMessage[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(KEY, JSON.stringify(items));
  } catch {
    // Full, or blocked. The in-memory copy the caller holds still works for this session; losing
    // the queue on reload is the acceptable half of this failure.
  }
}

export function listQueued(requestId: string): QueuedMessage[] {
  return read()
    .filter((m) => m.requestId === requestId)
    .sort((a, b) => a.queuedAt - b.queuedAt);
}

export function enqueue(requestId: string, body: string): QueuedMessage {
  const item: QueuedMessage = {
    clientId: newClientId(),
    requestId,
    body,
    queuedAt: Date.now(),
    attempts: 0,
  };
  write([...read(), item]);
  return item;
}

export function dequeue(clientId: string): void {
  write(read().filter((m) => m.clientId !== clientId));
}

export function recordAttempt(clientId: string): void {
  write(read().map((m) => (m.clientId === clientId ? { ...m, attempts: m.attempts + 1 } : m)));
}

/** crypto.randomUUID needs a secure context; the fallback keeps an http:// preview working. */
function newClientId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export type SendResult =
  | { kind: "sent" }
  /** The server refused it for a reason retrying will not fix. Drop it and tell the member. */
  | { kind: "rejected"; error: string }
  /** No answer. Keep it and try again. */
  | { kind: "unreachable" };

/**
 * Try every queued message for one recovery, oldest first.
 *
 * Oldest first and stopping at the first unreachable one, so a thread cannot be reordered by a
 * flaky connection: if "on my way" cannot get through, "just arrived" waits behind it.
 */
export async function flush(
  requestId: string,
  send: (item: QueuedMessage) => Promise<SendResult>,
): Promise<{ sent: number; rejected: { clientId: string; error: string }[]; stalled: number }> {
  const items = listQueued(requestId);
  const rejected: { clientId: string; error: string }[] = [];
  let sent = 0;

  for (let i = 0; i < items.length; i += 1) {
    const item = items[i];
    const result = await send(item);

    if (result.kind === "sent") {
      dequeue(item.clientId);
      sent += 1;
      continue;
    }

    if (result.kind === "rejected") {
      dequeue(item.clientId);
      rejected.push({ clientId: item.clientId, error: result.error });
      continue;
    }

    recordAttempt(item.clientId);
    return { sent, rejected, stalled: items.length - i };
  }

  return { sent, rejected, stalled: 0 };
}
