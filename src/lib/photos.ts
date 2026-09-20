/**
 * Client-side photo handling.
 *
 * Two jobs, both of which have to happen on the phone and not on the server:
 *
 *  1. Shrink. A modern phone camera produces 4-8 MB per shot. On one bar of signal that is the
 *     difference between a request that sends and one that does not.
 *  2. Strip EXIF. A camera photo carries GPS coordinates, the exact time, and often the device
 *     serial. Drawing the image to a canvas and re-encoding it keeps only the pixels — every
 *     metadata block is dropped, because the encoder writes a fresh file. `imageOrientation:
 *     "from-image"` bakes the EXIF rotation into those pixels first, so stripping the metadata
 *     does not leave the photo sideways.
 */

export type PreparedPhoto = {
  blob: Blob;
  width: number;
  height: number;
  contentType: "image/jpeg";
  previewUrl: string;
};

const MAX_EDGE = 1600;
const QUALITY = 0.72;

export async function preparePhoto(file: File): Promise<PreparedPhoto> {
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });

  const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  const context = canvas.getContext("2d");
  if (!context) {
    bitmap.close();
    throw new Error("canvas_unavailable");
  }

  context.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", QUALITY),
  );

  if (!blob) throw new Error("encode_failed");

  return {
    blob,
    width,
    height,
    contentType: "image/jpeg",
    previewUrl: URL.createObjectURL(blob),
  };
}

export type UploadedPhoto = {
  path: string;
  contentType: "image/jpeg";
  bytes: number;
  width: number;
  height: number;
  previewUrl: string;
};

/**
 * Ask the server for a signed upload URL, then PUT straight to Storage.
 *
 * The browser never holds a Storage credential, and the file never passes through the Next.js
 * server, so a big photo does not eat a serverless function's memory or time budget.
 */
export async function uploadPhoto(
  photo: PreparedPhoto,
  draftId: string,
  index: number,
): Promise<UploadedPhoto> {
  const signResponse = await fetch("/api/photos/sign-upload", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ draftId, index, contentType: photo.contentType }),
  });

  if (!signResponse.ok) {
    const payload = await signResponse.json().catch(() => null);
    throw new Error(payload?.error ?? "sign_failed");
  }

  const { path, signedUrl } = (await signResponse.json()) as {
    path: string;
    signedUrl: string;
  };

  const uploadResponse = await fetch(signedUrl, {
    method: "PUT",
    headers: { "content-type": photo.contentType, "x-upsert": "true" },
    body: photo.blob,
  });

  if (!uploadResponse.ok) {
    throw new Error("upload_failed");
  }

  return {
    path,
    contentType: photo.contentType,
    bytes: photo.blob.size,
    width: photo.width,
    height: photo.height,
    previewUrl: photo.previewUrl,
  };
}
