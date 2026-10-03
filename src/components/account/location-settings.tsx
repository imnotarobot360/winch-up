"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { setMyLocationAction } from "@/app/actions/location";
import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

type Location = {
  city: string;
  state: string;
  postal_code: string;
};

const EMPTY: Location = { city: "", state: "", postal_code: "" };

/**
 * Where a member says they are (spec section 11).
 *
 * A FORM WITH A SAVE BUTTON, unlike the notification switches next door, and deliberately so.
 * Those are independent booleans where each flip is a complete intention; a city, a state and a
 * postal code are one statement, and saving each keystroke would hand the geocoder a half-typed
 * ZIP five times and store a centroid for "774".
 *
 * WHAT THIS IS NOT. It is not where a recovery goes. The group's volunteers are matched from a
 * position shared at the time or from the home location on a volunteer profile, and neither is
 * touched here -- the copy has to say that plainly, because a member who believes this is how
 * help finds them has been misled by a form.
 */
export function LocationSettings() {
  const t = useTranslations("locationSettings");

  const [value, setValue] = useState<Location>(EMPTY);
  const [saved, setSaved] = useState<Location>(EMPTY);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    // One string literal, not a concatenation -- supabase-js infers the row type from the select
    // text and a joined expression degrades to GenericStringError.
    const { data, error: readError } = await supabase
      .from("profiles")
      .select("city, state, postal_code")
      .maybeSingle();

    if (readError) {
      // A read that fails here is almost always a missing COLUMN grant rather than a policy:
      // `profiles` has an enumerated column grant list, so a column added by a later migration
      // than the one the database has makes the WHOLE select fail rather than just that column.
      // Showing defaults silently is how a whole settings screen lied for a day.
      setError(t("readFailed"));
      setLoaded(true);
      return;
    }

    const next: Location = {
      city: data?.city ?? "",
      state: data?.state ?? "",
      postal_code: data?.postal_code ?? "",
    };

    setValue(next);
    setSaved(next);
    setLoaded(true);
  }, [t]);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty =
    value.city !== saved.city ||
    value.state !== saved.state ||
    value.postal_code !== saved.postal_code;

  async function save() {
    setBusy(true);
    setError(null);
    setDone(false);

    const result = await setMyLocationAction({
      city: value.city.trim() || null,
      state: value.state.trim() || null,
      postalCode: value.postal_code.trim() || null,
    });

    setBusy(false);

    if (!result.ok) {
      // The database names which field it refused, and saying which one is the difference between
      // a form somebody can fix and a form they abandon.
      setError(
        result.error === "bad_postal_code"
          ? t("badPostalCode")
          : result.error === "bad_state"
            ? t("badState")
            : result.error === "contact_info"
              ? t("contactInfo")
              : t("saveFailed"),
      );
      return;
    }

    setSaved(value);
    setDone(true);
  }

  async function clear() {
    setBusy(true);
    setError(null);
    setDone(false);

    const result = await setMyLocationAction({ city: null, state: null, postalCode: null });

    setBusy(false);

    if (!result.ok) {
      setError(t("saveFailed"));
      return;
    }

    setValue(EMPTY);
    setSaved(EMPTY);
    setDone(true);
  }

  if (!loaded) {
    return (
      <Card className="p-4">
        <p className="text-ink-soft">{t("loading")}</p>
      </Card>
    );
  }

  const hasSaved = saved.city !== "" || saved.state !== "" || saved.postal_code !== "";

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{error}</Callout> : null}
      {done && !dirty ? <Callout tone="good">{t("saved")}</Callout> : null}

      <Card className="space-y-4 p-4">
        <Field label={t("cityLabel")} hint={t("cityHint")}>
          <TextInput
            value={value.city}
            onChange={(event) => setValue({ ...value, city: event.target.value })}
            autoComplete="address-level2"
            maxLength={80}
            disabled={busy}
          />
        </Field>

        <Field label={t("stateLabel")} hint={t("stateHint")}>
          <TextInput
            value={value.state}
            // Upper-cased as it is typed: the column is constrained to two capitals, so somebody
            // typing "tx" would otherwise be refused by the database for being right.
            onChange={(event) =>
              setValue({ ...value, state: event.target.value.toUpperCase().slice(0, 2) })
            }
            autoComplete="address-level1"
            maxLength={2}
            disabled={busy}
          />
        </Field>

        <Field label={t("postalLabel")} hint={t("postalHint")}>
          <TextInput
            value={value.postal_code}
            onChange={(event) =>
              setValue({ ...value, postal_code: event.target.value.replace(/[^0-9]/g, "").slice(0, 5) })
            }
            // A numeric keypad on a phone, without `type="number"` -- that brings spinners and
            // strips leading zeros, and a Massachusetts ZIP starts with one.
            inputMode="numeric"
            autoComplete="postal-code"
            maxLength={5}
            disabled={busy}
          />
        </Field>

        {/* Stacked, not side by side: Button is unconditionally w-full in this design system, and
            a phone held one-handed wants a column anyway. */}
        <Button onClick={save} disabled={busy || !dirty}>
          {busy ? t("saving") : t("save")}
        </Button>

        {hasSaved ? (
          <Button variant="secondary" onClick={clear} disabled={busy}>
            {t("clear")}
          </Button>
        ) : null}
      </Card>

      <Callout tone="neutral">{t("notRecovery")}</Callout>
    </div>
  );
}
