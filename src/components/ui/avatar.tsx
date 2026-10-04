"use client";

/* eslint-disable @next/next/no-img-element */

/**
 * A member's photograph, or their initials.
 *
 * `profiles.avatar_path` points into a PRIVATE bucket, so a real picture needs a signed URL minted
 * server-side per page load. That is why this drew initials only until 2026-10-04: the column had
 * existed since phase 3 with nothing able to write it.
 *
 * INITIALS ARE STILL THE FALLBACK, and not just for members who have not uploaded one. A signed
 * URL expires, an object can be deleted, and Storage can be having a bad minute -- in every one of
 * those cases this renders initials rather than a broken-image icon. `onError` covers the ones the
 * server could not predict, because a URL that signs correctly can still fail to load.
 *
 * Lifted out of members-list.tsx when the profile screen needed the same thing. Two copies would
 * have drifted -- and the interesting part of this component is the reasoning above, which is what
 * gets lost when somebody writes the second one from scratch.
 *
 * `aria-hidden` because the name is always rendered beside it. A screen reader announcing "JS"
 * before "Juan Serra" is noise, and so is announcing "photograph of Juan Serra".
 */

import { useState } from "react";

export function Avatar({
  name,
  src,
  size = "md",
}: {
  name: string | null;
  /** A SIGNED url. Never a raw storage path -- the bucket is private and a path renders nothing. */
  src?: string | null;
  /** md is the list row; lg is the profile header. */
  size?: "md" | "lg";
}) {
  const [failed, setFailed] = useState(false);

  const initials =
    (name ?? "")
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((word) => word[0]?.toUpperCase() ?? "")
      .join("") || "?";

  const dimensions = size === "lg" ? "size-20 text-2xl" : "size-12 text-base";

  if (src && !failed) {
    return (
      // A plain img, not next/image. The URL is signed and short-lived, so the optimizer would
      // cache a variant that outlives it and then serve a 403 from its own cache.
      <img
        src={src}
        alt=""
        aria-hidden
        onError={() => setFailed(true)}
        className={`${dimensions} shrink-0 rounded-full border-2 border-line object-cover`}
      />
    );
  }

  return (
    <span
      aria-hidden
      className={`flex ${dimensions} shrink-0 items-center justify-center rounded-full border-2 border-line bg-trail font-bold text-ink`}
    >
      {initials}
    </span>
  );
}
