import { defineRouting } from "next-intl/routing";

import { DEFAULT_LOCALE, SUPPORTED_LOCALES } from "@/config/app";

export const routing = defineRouting({
  locales: SUPPORTED_LOCALES,
  defaultLocale: DEFAULT_LOCALE,
  // English lives at /request, Spanish at /es/request. Shorter links matter: these get texted.
  localePrefix: "as-needed",
});
