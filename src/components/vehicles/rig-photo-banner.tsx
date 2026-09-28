import { getTranslations } from "next-intl/server";

import { Button, Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

/**
 * "Add a photo of your rig."
 *
 * The prompt half of the owner's decision: new members provide a photo at signup, existing
 * members are asked. Nobody is blocked, and Send SOS keeps working regardless -- somebody
 * stuck in a creek at 2am is not going to be asked for a photograph first.
 *
 * Presentational, like MembershipBanner and for the same reason: the caller decides whether it
 * is needed, so a member who is already complete causes no element to exist at all rather than
 * an empty positioned div over the map.
 *
 * Two different asks behind one banner. A member with no vehicles is sent to add one; a member
 * whose rig has no picture is sent to the same screen to finish it. Splitting them would be two
 * banners saying "go to your garage".
 */
export async function RigPhotoBanner({ hasVehicle }: { hasVehicle: boolean }) {
  const t = await getTranslations("vehicles.prompt");

  return (
    <Callout tone="brand" className="flex flex-col gap-3 sm:flex-row sm:items-center">
      <p className="flex-1 leading-relaxed">{hasVehicle ? t("addPhoto") : t("addRig")}</p>
      <Link href="/account/vehicles" className="shrink-0">
        <Button size="md" className="w-auto">
          {hasVehicle ? t("addPhotoCta") : t("addRigCta")}
        </Button>
      </Link>
    </Callout>
  );
}
