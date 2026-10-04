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
  // AN ERROR CODE, TRANSLATED AT RENDER, not a translated string in state. Keeping `t` out of the
  // load callback is what lets its dependency list be empty: next-intl does not promise a stable
  // identity for `t`, so a callback depending on it can be rebuilt every render, and an effect keyed
  // on that callback then re-runs every render. The sibling notification screen is written this way
  // for the same reason.
  const [errorCode, setErrorCode] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    // One string literal, not a concatenation -- supabase-js infers the row type from the select
    // text and a joined expression degrades to GenericStringError.
    // BY user_id. profiles_self_read is "own row OR app.is_admin()", so an admin reads every
    // profile row and maybeSingle() fails on five of them -- this screen sat on "Loading..." for
    // exactly one person, the owner, and worked for everybody else. Every test signs in as an
    // ordinary member, which is why nothing caught it.
    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setErrorCode("readFailed");
      setLoaded(true);
      return;
    }

    const { data, error: readError } = await supabase
      .from("profiles")
      .select("city, state, postal_code")
      .eq("user_id", user.id)
      .maybeSingle();

    if (readError) {
      // A read that fails here is almost always a missing COLUMN grant rather than a policy:
      // `profiles` has an enumerated column grant list, so a column added by a later migration
      // than the one the database has makes the WHOLE select fail rather than just that column.
      // Showing defaults silently is how a whole settings screen lied for a day.
      setErrorCode("readFailed");
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
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty =
    value.city !== saved.city ||
    value.state !== saved.state ||
    value.postal_code !== saved.postal_code;

  async function save() {
    setBusy(true);
    setErrorCode(null);
    setDone(false);

    const result = await setMyLocationAction({
      city: value.city.trim() || null,
      state: value.state.trim() || null,
      postalCode: value.postal_code.trim() || null,
    });

    setBusy(false);

    if (!result.ok) {
      // The database names which field it refused, and saying which one is the difference between a
      // form somebody can fix and a form they abandon. An unrecognised code falls back rather than
      // asking for a message that does not exist.
      setErrorCode(
        result.error === "bad_postal_code" ||
          result.error === "bad_state" ||
          result.error === "contact_info"
          ? result.error
          : "saveFailed",
      );
      return;
    }

    setSaved(value);
    setDone(true);
  }

  async function clear() {
    setBusy(true);
    setErrorCode(null);
    setDone(false);

    const result = await setMyLocationAction({ city: null, state: null, postalCode: null });

    setBusy(false);

    if (!result.ok) {
      setErrorCode("saveFailed");
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
      {errorCode ? <Callout tone="danger">{errorMessage(t, errorCode)}</Callout> : null}
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

/**
 * An error code to a sentence.
 *
 * Explicit keys rather than a template string: next-intl types `t` to the literal keys in the
 * namespace, and a code this file has never heard of -- from a server that is ahead of this bundle --
 * would otherwise ask for a message that does not exist and throw on a form somebody is in the middle
 * of using. Unknown falls back to the generic failure.
 */
function errorMessage(t: ReturnType<typeof useTranslations<"locationSettings">>, code: string) {
  switch (code) {
    case "bad_postal_code":
      return t("badPostalCode");
    case "bad_state":
      return t("badState");
    case "contact_info":
      return t("contactInfo");
    case "readFailed":
      return t("readFailed");
    default:
      return t("saveFailed");
  }
}
