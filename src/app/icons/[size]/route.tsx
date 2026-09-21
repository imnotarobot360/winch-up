import { ImageResponse } from "next/og";

export const runtime = "nodejs";

const ALLOWED = new Set([180, 192, 512]);

/**
 * App icons, generated rather than committed.
 *
 * No binary assets in the repo, no design tool in the loop, and the mark stays in step with the
 * brand colour in globals.css. Text is avoided on purpose: Satori needs a font file for glyphs,
 * and a ring of rope reads better at 48px than four letters would anyway.
 */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ size: string }> },
) {
  const { size: raw } = await params;
  const size = Number(raw);

  if (!ALLOWED.has(size)) {
    return new Response("not found", { status: 404 });
  }

  // The manifest declares this maskable, and Android crops maskable icons to a circle with a
  // 10% safe margin. Everything below stays inside the middle 80% so nothing is clipped.
  const ring = Math.round(size * 0.5);
  const stroke = Math.round(size * 0.088);

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          // Satori only honours an absolutely positioned child inside a positioned parent.
          position: "relative",
          background: "#e2560f",
        }}
      >
        <div
          style={{
            width: ring,
            height: ring,
            borderRadius: "50%",
            border: `${stroke}px solid #ffffff`,
            display: "flex",
          }}
        />
        <div
          style={{
            position: "absolute",
            width: stroke,
            height: Math.round(size * 0.26),
            background: "#ffffff",
            borderRadius: stroke,
            top: Math.round(size * 0.16),
            display: "flex",
          }}
        />
      </div>
    ),
    { width: size, height: size },
  );
}
