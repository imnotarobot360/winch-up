import { APP_NAME } from "@/config/app";

/**
 * The compact lockup: WINCH-UP set in the display face, with the tail in Recovery Orange.
 *
 * This exists because the illustrated logo does not survive small sizes. In a 44px header the
 * artwork's own wordmark renders around 12px tall and reads as a smudge, so interior pages get
 * this and the landing hero gets the artwork.
 *
 * The hyphen is styling: it is derived from APP_NAME rather than written down, so the name still
 * lives in one place, and it never reaches an SMS, a page title or a screen reader.
 *
 * Orange on Trail Green is 5.19:1. On a light surface it would be 2.87:1 -- use
 * --color-brand-text there instead.
 */
export function Wordmark({ className }: { className?: string }) {
  const [first, ...rest] = APP_NAME.split(" ");
  const tail = rest.join(" ");

  return (
    <span className={className} role="img" aria-label={APP_NAME}>
      <span aria-hidden="true">{first}</span>
      {tail ? <span aria-hidden="true" className="text-brand">{`-${tail}`}</span> : null}
    </span>
  );
}
