import Image from "next/image";
import { getTranslations } from "next-intl/server";

import { TopoBackdrop } from "@/components/brand/topo";
import { APP_NAME } from "@/config/app";

/**
 * Screen 1 of the design reference, used as the route-level loading state.
 *
 * A PWA's cold-start splash is drawn by the platform from the manifest -- Trail Green background,
 * the emblem icon, the app name -- not by this file. This is what shows while a route loads, and
 * matching it to the platform splash means the two are indistinguishable to someone opening the
 * app on a bad connection in a field.
 *
 * It is deliberately NOT a route with a timer. The reference shows a splash screen and the spec
 * says not to add a delay that slows access to recovery assistance; both are satisfied by making
 * the splash the thing you see WHILE something loads, rather than a gate in front of it. Nobody
 * stuck in a ditch waits two seconds to admire a logo.
 *
 * No spinner on purpose: a stuck driver does not need to be told to wait, and the logo already
 * says the app is alive.
 */
export default async function Loading() {
  const t = await getTranslations("splash");

  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center justify-center bg-trail px-6">
      <TopoBackdrop />

      <div className="relative flex flex-col items-center gap-5">
        <Image
          src="/brand/logo-lockup.png"
          alt={APP_NAME}
          width={1024}
          height={632}
          sizes="(max-width: 640px) 80vw, 380px"
          className="h-auto w-full max-w-[380px]"
          priority
        />
      </div>

      {/* Set against the bottom as in the reference, rather than stacked under the logo, so the
          emblem keeps the optical centre of the screen. */}
      <p className="absolute inset-x-0 bottom-[max(2.5rem,env(safe-area-inset-bottom))] text-center text-xs font-semibold uppercase tracking-[0.3em] text-ink-faint">
        {t("community")}
      </p>
    </div>
  );
}
