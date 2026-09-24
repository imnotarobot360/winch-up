/**
 * The icon set.
 *
 * One language, defined once: 24px grid, 1.75 stroke, round caps and joins, no fills, colour
 * inherited from the text it sits beside. That is what makes a set feel like a set -- if a new
 * icon needs a different weight or a fill to read, it is drawn wrong, not special.
 *
 * Shapes are deliberately blunt. These are read at 26px, one-handed, by someone who is stressed
 * and possibly in gloves; a clever silhouette that needs a second look has failed.
 */
import type { SVGProps } from "react";

type IconProps = { size?: number } & Omit<SVGProps<SVGSVGElement>, "children">;

function Svg({ size = 24, children, ...rest }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

/* Navigation ------------------------------------------------------------- */

export const IconHome = (p: IconProps) => (
  <Svg {...p}><path d="M3 10.5 12 3l9 7.5" /><path d="M5.5 9.5V20h13V9.5" /></Svg>
);

export const IconPin = (p: IconProps) => (
  <Svg {...p}><path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Z" /><circle cx="12" cy="10" r="2.5" /></Svg>
);

export const IconTruck = (p: IconProps) => (
  <Svg {...p}><path d="M3 16V7h11v9" /><path d="M14 10h4l3 3.5V16" /><circle cx="7" cy="17.5" r="2" /><circle cx="17" cy="17.5" r="2" /></Svg>
);

export const IconDoc = (p: IconProps) => (
  <Svg {...p}><path d="M5 4h10l4 4v12H5z" /><path d="M15 4v4h4" /><path d="M8.5 12.5h7M8.5 16h5" /></Svg>
);

export const IconPeople = (p: IconProps) => (
  <Svg {...p}><circle cx="9" cy="8.5" r="3" /><path d="M3.5 19c0-3 2.5-4.8 5.5-4.8s5.5 1.8 5.5 4.8" /><path d="M16 6.2a3 3 0 0 1 0 5.6" /><path d="M17.5 14.6c1.9.6 3 2.2 3 4.4" /></Svg>
);

/** The hook. The app's one verb, so it gets the heaviest stroke in the set. */
export const IconHook = (p: IconProps) => (
  <Svg {...p} strokeWidth={2}><path d="M12 3v5" /><path d="M9 8h6l-1.2 4.2a3 3 0 1 1-4.6 0Z" /></Svg>
);

/* Equipment -------------------------------------------------------------- */

export const IconWinch = (p: IconProps) => (
  <Svg {...p}><rect x="3" y="8" width="13" height="8" rx="1.5" /><path d="M16 12h5" /><path d="M6.5 8v8M12.5 8v8" /></Svg>
);

export const IconRope = (p: IconProps) => (
  <Svg {...p}><path d="M3 15c3-5 5 5 8 0s5 5 8 0" /><circle cx="3" cy="15" r="1" /><circle cx="21" cy="15" r="1" /></Svg>
);

export const IconBoards = (p: IconProps) => (
  <Svg {...p}><rect x="3" y="6" width="18" height="5" rx="1.5" /><rect x="3" y="14" width="18" height="5" rx="1.5" /><path d="M8 6v5M14 6v5M8 14v5M14 14v5" /></Svg>
);

export const IconTractor = (p: IconProps) => (
  <Svg {...p}><path d="M4 15V8h6l2 4h4" /><circle cx="7" cy="17" r="3" /><circle cx="18" cy="16" r="3" /></Svg>
);

export const IconTrailer = (p: IconProps) => (
  <Svg {...p}><path d="M2 14h13V9H2z" /><path d="M15 12h4l3 2v2" /><circle cx="9" cy="17" r="2" /></Svg>
);

export const IconLifted = (p: IconProps) => (
  <Svg {...p}><path d="M4 13V9h10l3 4" /><path d="M2 17h20" /><circle cx="8" cy="14" r="2.5" /><circle cx="17" cy="14" r="2.5" /></Svg>
);

export const IconLight = (p: IconProps) => (
  <Svg {...p}><rect x="4" y="9" width="9" height="6" rx="1.5" /><path d="M15 10.5 21 7M15 13.5 21 17M15 12h5" /></Svg>
);

/* Status ----------------------------------------------------------------- */

export const IconSent = (p: IconProps) => (
  <Svg {...p}><path d="M3.5 12 21 4l-7 17-3-7z" /><path d="M11 14 21 4" /></Svg>
);

export const IconRing = (p: IconProps) => (
  <Svg {...p}><circle cx="12" cy="12" r="3" /><path d="M6.5 6.5a8 8 0 0 0 0 11M17.5 17.5a8 8 0 0 0 0-11" /></Svg>
);

export const IconCheck = (p: IconProps) => (
  <Svg {...p}><circle cx="12" cy="12" r="9" /><path d="m8 12.5 2.5 2.5L16 9.5" /></Svg>
);

export const IconAlert = (p: IconProps) => (
  <Svg {...p}><path d="M12 4 2.5 20h19z" /><path d="M12 10v4.5M12 17.5v.01" /></Svg>
);

export const IconClock = (p: IconProps) => (
  <Svg {...p}><circle cx="12" cy="12" r="9" /><path d="M12 7v5.5l3.5 2" /></Svg>
);


export const IconShackle = (p: IconProps) => (
  <Svg {...p}><path d="M8 14a4 4 0 1 0 8 0c0-2.5-2-3.5-2-6a2 2 0 0 0-4 0c0 2.5-2 3.5-2 6Z" /><path d="M10 8h4" /></Svg>
);

export const IconRecoveryPoint = (p: IconProps) => (
  <Svg {...p}><path d="M5 18V9a3 3 0 0 1 3-3h8a3 3 0 0 1 3 3v9" /><circle cx="12" cy="11" r="2.5" /><path d="M3 18h18" /></Svg>
);

export const IconCompressor = (p: IconProps) => (
  <Svg {...p}><rect x="3" y="10" width="11" height="9" rx="2" /><path d="M14 13h3a3 3 0 0 0 3-3V6" /><circle cx="8.5" cy="14.5" r="2" /></Svg>
);

export const IconTireRepair = (p: IconProps) => (
  <Svg {...p}><circle cx="11" cy="13" r="7" /><circle cx="11" cy="13" r="2.5" /><path d="m17 7 4-4M18.5 5.5 20 7" /></Svg>
);

export const IconJack = (p: IconProps) => (
  <Svg {...p}><path d="M4 19h16" /><path d="M12 5 5 12l7 7 7-7z" /><path d="M12 9v6" /></Svg>
);

/** Equipment key -> icon, so a list of enum values can render without a switch at each call. */
export const EQUIPMENT_ICONS = {
  winch: IconWinch,
  kinetic_rope: IconRope,
  traction_boards: IconBoards,
  tractor: IconTractor,
  second_truck: IconTruck,
  trailer: IconTrailer,
  lifted_4x4: IconLifted,
  night_lights: IconLight,
  soft_shackles: IconShackle,
  rated_recovery_points: IconRecoveryPoint,
  air_compressor: IconCompressor,
  tire_repair: IconTireRepair,
  jack_lifting: IconJack,
} as const;

/**
 * Weather, and a chevron.
 *
 * Added for the resources list, where the design reference gives every category a line icon and a
 * chevron saying it goes somewhere. Same grid, same stroke, no fills -- a cloud that needed a fill
 * to read would be drawn wrong, not special.
 */
export const IconCloud = (p: IconProps) => (
  <Svg {...p}>
    <path d="M7 18h9.5a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6-1.2A4 4 0 0 0 7 18Z" />
  </Svg>
);

export const IconChevronRight = (p: IconProps) => (
  <Svg {...p}>
    <path d="M9 5l7 7-7 7" />
  </Svg>
);
