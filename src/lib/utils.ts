import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** Digits in, E.164 out. Returns null when it is not a plausible US number. */
export function toE164Us(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}

/** (281) 555-0101 — for display and for tel: links we show to a human. */
export function formatUsPhone(e164: string): string {
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(e164);
  if (!m) return e164;
  return `(${m[1]}) ${m[2]}-${m[3]}`;
}

export function metersToFeet(m: number): number {
  return m * 3.280839895;
}

/** Signal is bad and the screen is in the sun: short strings only. */
export function formatAccuracy(meters: number | null | undefined, locale: string): string {
  if (meters == null || !Number.isFinite(meters)) return "—";
  const feet = Math.round(metersToFeet(meters));
  if (feet < 1000) return locale === "es" ? `${feet} pies` : `${feet} ft`;
  const miles = (feet / 5280).toFixed(1);
  return locale === "es" ? `${miles} mi` : `${miles} mi`;
}

export function minutesSince(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return null;
  return Math.max(0, Math.round((Date.now() - then) / 60000));
}
