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

  const ring = Math.round(size * 0.62);
  const stroke = Math.round(size * 0.1);

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
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
            height: Math.round(size * 0.34),
            background: "#ffffff",
            borderRadius: stroke,
            top: Math.round(size * 0.06),
            display: "flex",
          }}
        />
      </div>
    ),
    { width: size, height: size },
  );
}
