"use client";

import { useEffect } from "react";

/**
 * Registers the service worker, and nothing else.
 *
 * No install prompt, no "add to home screen" banner. Someone who is stuck does not need a
 * dialog in the way, and a volunteer who wants it installed will use the browser menu.
 */
export function RegisterServiceWorker() {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") return;
    if (!("serviceWorker" in navigator)) return;

    const register = () => {
      navigator.serviceWorker.register("/sw.js").catch((error) => {
        console.warn("[pwa] service worker registration failed", error);
      });
    };

    // Wait for load: registering during hydration competes with the first paint on exactly the
    // slow phones this is meant to help.
    if (document.readyState === "complete") {
      register();
    } else {
      window.addEventListener("load", register, { once: true });
      return () => window.removeEventListener("load", register);
    }
  }, []);

  return null;
}
