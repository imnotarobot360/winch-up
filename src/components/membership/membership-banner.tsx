import { getTranslations } from "next-intl/server";

import { Button, Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

/**
 * "You need to sign the membership agreement."
 *
 * Requirement 10 asks that existing members be made to review and sign at their next login.
 * This is that prompt, on the screen a signed-in member lands on.
 *
 * It is a banner and not a redirect or a modal, deliberately. This app's one job is to get help
 * to somebody whose truck is in a ditch, and standing a compliance wall in front of the map is
 * the kind of thing that is defensible in a meeting and indefensible at 2am in the rain. The
 * hard stop already exists where it belongs: the gate refuses the request itself, with an error
 * that explains itself and a link here.
 *
 * PRESENTATIONAL ONLY, and that is load-bearing. Whether it is needed is decided by the caller,
 * so a caller that does not need it renders no element at all. If this component did its own
 * fetch and returned null, the caller would still be holding a truthy React element and would
 * still render whatever wrapper it puts around it -- an empty positioned div over the map, on
 * every page load, for every member who has nothing to sign.
 */
export async function MembershipBanner() {
  const t = await getTranslations("membership");

  return (
    <Callout tone="brand" className="flex flex-col gap-3 sm:flex-row sm:items-center">
      <p className="flex-1 leading-relaxed">{t("requiredBanner")}</p>
      <Link href="/agreement" className="shrink-0">
        <Button size="md" className="w-auto">
          {t("requiredBannerCta")}
        </Button>
      </Link>
    </Callout>
  );
}
