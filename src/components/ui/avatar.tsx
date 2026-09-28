/**
 * Initials, not a photograph.
 *
 * `profiles.avatar_path` exists and points into a PRIVATE storage bucket, so rendering a real
 * picture needs a signed URL per member per page load. That is a real feature with a real cost
 * and it has not been built; initials on the brand green read fine and never 404 into a
 * broken-image icon.
 *
 * Lifted out of members-list.tsx when the profile screen needed the same thing. Two copies would
 * have drifted -- and the interesting part of this component is the comment above, which is the
 * kind of reasoning that gets lost when somebody writes the second one from scratch.
 *
 * `aria-hidden` because the name is always rendered beside it. A screen reader announcing "JS"
 * before "Juan Serra" is noise.
 */
export function Avatar({
  name,
  size = "md",
}: {
  name: string | null;
  /** md is the list row; lg is the profile header. */
  size?: "md" | "lg";
}) {
  const initials =
    (name ?? "")
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((word) => word[0]?.toUpperCase() ?? "")
      .join("") || "?";

  const dimensions =
    size === "lg" ? "size-20 text-2xl" : "size-12 text-base";

  return (
    <span
      aria-hidden
      className={`flex ${dimensions} shrink-0 items-center justify-center rounded-full border-2 border-line bg-trail font-bold text-ink`}
    >
      {initials}
    </span>
  );
}
