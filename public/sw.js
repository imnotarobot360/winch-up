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

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------
//
// What arrives here has already been stripped: the sender puts the kind of thing that happened
// and a path in the payload, never a name, a number, a pin or a status token. A push notification
// is rendered on a lock screen that anybody standing nearby can read, and on this app the person
// receiving it is often out with other people. The detail lives behind the sign-in.
//
// Written defensively because a service worker that throws in a push handler shows the browser's
// own "This site has been updated in the background" notice instead, which is worse than nothing.

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    // A push with no body, or a body that is not ours. Still worth waking them: something
    // happened, and the app will say what.
  }

  const title = typeof payload.title === "string" ? payload.title : "Winch Up";
  const url = typeof payload.url === "string" ? payload.url : "/me";
  const urgent = typeof payload.kind === "string" && payload.kind.startsWith("recovery");

  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.body || "",
      icon: "/brand/icon-192.png",
      // No `badge`. Android wants a monochrome silhouette for it and this brand does not have
      // one yet; pointing at the colour icon renders a grey smudge, and pointing at a file that
      // does not exist is worse. The platform default is fine until somebody draws one.
      // Somebody stuck is the one case worth overriding a quiet phone for.
      requireInteraction: urgent,
      // Collapses repeats of the same kind rather than stacking six of them on a lock screen.
      tag: payload.kind || "winch-up",
      renotify: urgent,
      data: { url },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "/me";

  // Focus an open tab rather than opening a second one. Somebody who already has the app open
  // should land on the right screen in it, not end up with two copies of a live recovery.
  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clients) => {
        for (const client of clients) {
          if (client.url.includes(target) && "focus" in client) return client.focus();
        }
        for (const client of clients) {
          if ("navigate" in client && "focus" in client) {
            return client.navigate(target).then(() => client.focus());
          }
        }
        return self.clients.openWindow(target);
      }),
  );
});
