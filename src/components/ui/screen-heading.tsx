import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

/** Shared page furniture. Icons are decorative; the title remains the accessible heading. */
export function ScreenHeading({
  title,
  description,
  icon,
  aside,
  className,
}: {
  title: string;
  description?: string;
  icon?: ReactNode;
  aside?: ReactNode;
  className?: string;
}) {
  return (
    <header className={cn("winch-screen-heading", className)}>
      {icon ? <span aria-hidden="true" className="winch-heading-icon">{icon}</span> : null}
      <div className="min-w-0 flex-1">
        <h1 className="winch-heading text-ink">{title}</h1>
        {description ? <p className="mt-2 max-w-prose text-base text-ink-soft">{description}</p> : null}
      </div>
      {aside ? <div className="shrink-0">{aside}</div> : null}
    </header>
  );
}
