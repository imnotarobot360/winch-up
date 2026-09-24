/**
 * The contour pattern behind the splash and onboarding.
 *
 * Drawn rather than shipped as an image: it is a handful of paths, it tiles, it costs nothing on
 * a phone with one bar, and it recolours with the theme instead of baking a green into a PNG. The
 * reference calls for "subtle topographic contour patterns" and subtle is the operative word --
 * at 6% it reads as texture on a dark green field and never competes with the logo.
 *
 * aria-hidden throughout. It carries no meaning; a screen reader announcing decorative contour
 * lines would be noise in front of the one thing on the page that matters.
 */
export function TopoBackdrop({ className = "" }: { className?: string }) {
  return (
    <div aria-hidden className={`pointer-events-none absolute inset-0 overflow-hidden ${className}`}>
      <svg
        className="h-full w-full"
        preserveAspectRatio="xMidYMid slice"
        viewBox="0 0 400 400"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <pattern id="winchup-topo" width="400" height="400" patternUnits="userSpaceOnUse">
            <g
              stroke="currentColor"
              strokeWidth="1.1"
              fill="none"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              {/* Nested closed curves, the way a hill reads on an ordnance map. Hand-placed rather
                  than generated: evenly spaced rings look like a target, not terrain. */}
              <path d="M40 120c30-34 84-40 118-16s44 70 16 104-86 38-120 10-14-64-14-98z" />
              <path d="M62 128c24-26 66-31 92-12s34 54 12 80-67 29-93 8-11-50-11-76z" />
              <path d="M84 137c17-19 47-22 66-9s25 39 9 58-48 21-67 6-8-36-8-55z" />
              <path d="M106 146c10-11 28-13 39-5s15 23 5 34-28 12-39 4-5-22-5-33z" />

              <path d="M236 22c40-18 96 6 112 48s-8 92-52 106-96-10-108-54 8-82 48-100z" />
              <path d="M252 46c28-13 68 4 79 34s-6 65-37 75-68-7-76-38 6-58 34-71z" />
              <path d="M268 70c17-8 41 2 48 20s-4 39-22 45-41-4-46-23 3-34 20-42z" />

              <path d="M20 300c34-28 92-24 122 8s26 86-8 112-92 20-120-14-28-78 6-106z" />
              <path d="M46 312c24-20 66-17 87 6s18 61-6 79-65 14-85-10-20-55 4-75z" />
              <path d="M72 324c14-12 40-10 52 4s11 36-4 47-39 8-51-6-11-33 3-45z" />

              {/* A couple of open contours running off the edges, so the tile does not read as
                  three blobs floating in the middle of nothing. */}
              <path d="M-20 214c60 18 120-10 180 4s118 52 178 34" />
              <path d="M-20 244c58 16 116-8 176 6s120 50 180 32" />
              <path d="M-20 60c46 22 92 6 138 22" />
            </g>
          </pattern>
        </defs>
        <rect width="400" height="400" fill="url(#winchup-topo)" className="text-ink opacity-[0.06]" />
      </svg>
    </div>
  );
}
