/*
 * Winch Up service worker.
 *
 * The job here is narrow and the restraint is the point: this app exists for people with one bar
 * of signal, and a cache that serves a stale recovery status is worse than no cache at all.
 *
 * What is cached:
 *   - the built static assets under /_next/static, which are content-hashed and immutable
 *   - the offline shell, so a dead connection still shows "call 911" and a way back
 *
 * What is never cached, ever:
 *   - anything under /api/ — that is live dispatch state
 *   - /r/ status pages — private, token-scoped, and stale by the second
 *   - /me and /admin — private
 *   - Supabase and Twilio calls
 */

const VERSION = "winchup-v1";
const SHELL_CACHE = `${VERSION}-shell`;
const STATIC_CACHE = `${VERSION}-static`;
const OFFLINE_URL = "/offline.html";

const NEVER_CACHE = [/^\/api\//, /^\/r\//, /^\/post\//, /^\/me\b/, /^\/admin\b/];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll([OFFLINE_URL]))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => !key.startsWith(VERSION))
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;

  if (request.method !== "GET") return;

  const url = new URL(request.url);

  // Only handle our own origin. Supabase, Twilio and Mapbox go straight to the network.
  if (url.origin !== self.location.origin) return;

  if (NEVER_CACHE.some((pattern) => pattern.test(url.pathname))) return;

  // Immutable build output: cache first, it can never go stale.
  if (url.pathname.startsWith("/_next/static/")) {
    event.respondWith(
      caches.match(request).then(
        (hit) =>
          hit ||
          fetch(request).then((response) => {
            const copy = response.clone();
            caches.open(STATIC_CACHE).then((cache) => cache.put(request, copy));
            return response;
          }),
      ),
    );
    return;
  }

  // Page loads: always try the network, fall back to the offline shell. Never serve a cached
  // page — someone reloading mid-recovery needs the real state or an honest "you are offline".
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() =>
        caches.match(OFFLINE_URL).then((hit) => hit || Response.error()),
      ),
    );
  }
});
