import Image from "next/image";

import { APP_NAME } from "@/config/app";

/**
 * The splash from the brand mockups, used as the route-level loading state.
 *
 * A PWA's cold-start splash is drawn by the platform from the manifest -- Trail Green background,
 * the emblem icon, the app name -- not by this file. This is what shows while a route loads,
 * and matching it to the platform splash means the two are indistinguishable to someone opening
 * the app on a bad connection in a field.
 *
 * No spinner on purpose: a stuck driver does not need to be told to wait, and the logo already
 * says the app is alive.
 */
export default function Loading() {
  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center justify-center gap-6 bg-trail px-6">
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
  );
}
