"use client";

import { useEffect, useRef } from "react";

import { recordEventViewAction } from "@/app/actions/events";

/**
 * Records one view, once, and renders nothing.
 *
 * It exists as a component rather than a line in the page because the page is a server component,
 * and a view has to be counted from the BROWSER -- Next prefetches routes on hover and on scroll,
 * so counting during the server render would count people who never opened it.
 *
 * THE REF IS NOT DECORATION. React runs effects twice in development under StrictMode, and a
 * counter that double-fires locally is a counter nobody trusts in production either -- the first
 * person to compare it against RSVPs would find it roughly double and have no way to tell which
 * half was real.
 */
export function EventViewCounter({ eventId }: { eventId: string }) {
  const counted = useRef(false);

  useEffect(() => {
    if (counted.current) return;
    counted.current = true;
    void recordEventViewAction(eventId);
  }, [eventId]);

  return null;
}
