"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { ReportForm } from "@/components/incident/report-form";
import { RequestThread } from "@/components/messages/request-thread";
import { LocationShare } from "@/components/responder/location-share";
import { Link } from "@/i18n/navigation";
import { mapAppUrl } from "@/lib/geo";
import { supabaseBrowser } from "@/lib/supabase/client";
import { formatUsPhone } from "@/lib/utils";

type Profile = {
  id: string;
  first_name: string;
  phone: string;
  radius_miles: number;
  equipment: string[];
  vehicle_class: string;
  vehicle_desc: string | null;
  approval: "pending" | "approved" | "rejected" | "banned";
  availability: "active" | "paused";
  share_location: boolean;
  last_location_at: string | null;
  recoveries_count: number;
  current_job: {
    request_id: string;
    short_code: string;
    status: string;
    eta_minutes: number | null;
  } | null;
  history: {
    short_code: string;
    status: string;
    recovered_at: string | null;
    stuck_type: string;
    thank_you: string | null;
  }[];
};

type FeedRow = {
  request_id: string;
  short_code: string;
  status: string;
  dispatch_state: string;
  ring: number;
  distance_miles: number;
  lat: number;
  lng: number;
  is_approximate: boolean;
  vehicle_class: string;
  stuck_type: string;
  stuck_depth: string | null;
  needs_tractor: boolean;
  needs_second_truck: boolean;
  notes: string | null;
  is_mine: boolean;
};

type JobContact = {
  requester_name: string;
  requester_phone: string;
  lat: number;
  lng: number;
  location_note: string | null;
};

const OPEN_STATES = ["queued", "sent", "delivered"];

/**
 * The volunteer's dashboard.
 *
 * Everything here goes through the browser Supabase client, because every action is a
 * `security definer` RPC that works out who you are from `auth.uid()`. The requester's phone and
 * exact pin arrive through `get_job_contact`, which only answers for the job you actually took.
 */
export function MeDashboard() {
  const t = useTranslations("me");
  const tEnum = useTranslations("enum");

  const [loading, setLoading] = useState(true);
  const [signedIn, setSignedIn] = useState(false);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [feed, setFeed] = useState<FeedRow[]>([]);
  const [contact, setContact] = useState<JobContact | null>(null);
  // Keyed by request: a volunteer holding two offers must not see the ETA they typed for one
  // pre-filled into the other, or accept the second with the first ones number.
  const [etas, setEtas] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();
    const { data: session } = await supabase.auth.getUser();

    if (!session.user) {
      setSignedIn(false);
      setLoading(false);
      return;
    }

    setSignedIn(true);

    const [{ data: profileData }, { data: feedData }] = await Promise.all([
      supabase.rpc("my_responder_profile"),
      supabase.rpc("responder_feed"),
    ]);

    const nextProfile = (profileData as Profile | null) ?? null;
    setProfile(nextProfile);
    setFeed((feedData as FeedRow[] | null) ?? []);

    if (nextProfile?.current_job) {
      const { data: contactData } = await supabase.rpc("get_job_contact", {
        p_request_id: nextProfile.current_job.request_id,
      });
      setContact((contactData as JobContact | null) ?? null);
    } else {
      setContact(null);
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function run(fn: string, args: Record<string, unknown>) {
    setBusy(true);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc(fn, args);

    if (rpcError) {
      setError("server_error");
    } else {
      const result = data as { ok: boolean; error?: string } | null;
      if (!result?.ok) setError(result?.error ?? "server_error");
    }

    await load();
    setBusy(false);
  }

  if (loading) {
    return <p className="p-8 text-center text-ink-faint">{t("loading")}</p>;
  }

  if (!signedIn || !profile) {
    return (
      <main className="mx-auto w-full max-w-xl space-y-4 px-4 py-10 text-center">
        <h1 className="text-2xl font-bold">{t("signedOutTitle")}</h1>
        <p className="text-lg text-ink-soft">{t("signedOutBody")}</p>
        <Link
          href="/join"
          className="tap-target inline-flex w-full items-center justify-center rounded-field text-center bg-brand px-6 text-lg font-bold text-on-brand"
        >
          {t("goJoin")}
        </Link>
      </main>
    );
  }

  const openOffers = feed.filter(
    (row) => OPEN_STATES.includes(row.dispatch_state) && !row.is_mine,
  );

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold leading-tight">
            {t("greeting", { name: profile.first_name })}
          </h1>
          <p className="text-base text-ink-soft">
            {t("stats", { count: profile.recoveries_count })}
          </p>
        </div>
      </header>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {profile.approval === "pending" ? (
        <Callout tone="brand">
          <p className="font-bold">{t("pendingTitle")}</p>
          <p className="mt-1">{t("pendingBody")}</p>
        </Callout>
      ) : null}

      {profile.approval === "rejected" || profile.approval === "banned" ? (
        <Callout tone="danger">{t("notApproved")}</Callout>
      ) : null}

      {profile.approval === "approved" ? (
        <Card className="space-y-3">
          <p className="text-lg font-semibold">
            {profile.availability === "active" ? t("onCall") : t("paused")}
          </p>
          <p className="text-base text-ink-soft">
            {profile.availability === "active" ? t("onCallHint") : t("pausedHint")}
          </p>
          <Button
            type="button"
            variant={profile.availability === "active" ? "secondary" : "primary"}
            disabled={busy}
            onClick={() =>
              run("set_my_availability", {
                p_availability: profile.availability === "active" ? "paused" : "active",
              })
            }
          >
            {profile.availability === "active" ? t("pauseMe") : t("resumeMe")}
          </Button>
        </Card>
      ) : null}

      {profile.current_job ? (
        <Card className="space-y-3 border-good">
          <div>
            <p className="font-mono text-sm text-ink-faint">{profile.current_job.short_code}</p>
            <h2 className="text-xl font-bold">{t("currentJob")}</h2>
            <p className="text-base text-ink-soft">
              {tEnum(`requestStatus.${profile.current_job.status}`)}
            </p>
          </div>

          {contact ? (
            <>
              <p className="text-lg font-semibold">{contact.requester_name}</p>
              {contact.location_note ? (
                <p className="text-base text-ink-soft">{contact.location_note}</p>
              ) : null}
              <a
                href={`tel:${contact.requester_phone}`}
                className="tap-target flex w-full items-center justify-center rounded-field text-center bg-brand text-lg font-bold text-on-brand"
              >
                {t("callRequester", { phone: formatUsPhone(contact.requester_phone) })}
              </a>
              <a
                href={mapAppUrl(contact.lat, contact.lng)}
                target="_blank"
                rel="noreferrer"
                className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-line text-lg font-semibold"
              >
                {t("navigate")}
              </a>
            </>
          ) : null}

          {profile.current_job.status === "accepted" ? (
            <Button
              type="button"
              variant="secondary"
              disabled={busy}
              onClick={() =>
                run("report_on_site", { p_request_id: profile.current_job!.request_id })
              }
            >
              {t("imOnSite")}
            </Button>
          ) : null}

          <Button
            type="button"
            disabled={busy}
            onClick={() =>
              run("report_complete", { p_request_id: profile.current_job!.request_id })
            }
          >
            {t("theyreOut")}
          </Button>
        </Card>
      ) : null}

      {openOffers.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-xl font-semibold">{t("offersTitle")}</h2>
          {openOffers.map((row) => (
            <Card key={row.request_id} className="space-y-3">
              <div>
                <p className="font-mono text-sm text-ink-faint">{row.short_code}</p>
                <p className="text-lg font-semibold">
                  {tEnum(`vehicleClass.${row.vehicle_class}`)} ·{" "}
                  {tEnum(`stuckType.${row.stuck_type}`)}
                  {row.stuck_depth ? ` · ${tEnum(`stuckDepth.${row.stuck_depth}`)}` : ""}
                </p>
                <p className="text-base text-ink-soft">
                  {t("milesAway", { miles: row.distance_miles })}
                  {row.is_approximate ? ` · ${t("approximate")}` : ""}
                </p>
                {row.needs_tractor ? (
                  <p className="text-base font-medium">{t("needsTractor")}</p>
                ) : null}
                {row.needs_second_truck ? (
                  <p className="text-base font-medium">{t("needsSecondTruck")}</p>
                ) : null}
                {row.notes ? <p className="mt-1 text-base">{row.notes}</p> : null}
              </div>

              <Field label={t("etaLabel")} hint={t("etaHint")} htmlFor={`eta-${row.request_id}`}>
                <TextInput
                  id={`eta-${row.request_id}`}
                  inputMode="numeric"
                  value={etas[row.request_id] ?? ""}
                  maxLength={3}
                  placeholder="40"
                  onChange={(event) =>
                    setEtas((current) => ({
                      ...current,
                      [row.request_id]: event.target.value.replace(/\D/g, ""),
                    }))
                  }
                />
              </Field>

              <Button
                type="button"
                disabled={busy || profile.approval !== "approved"}
                onClick={() =>
                  run("accept_request", {
                    p_request_id: row.request_id,
                    p_eta_minutes: etas[row.request_id] ? Number(etas[row.request_id]) : null,
                  })
                }
              >
                {t("takeIt")}
              </Button>
              <Button
                type="button"
                variant="secondary"
                disabled={busy}
                onClick={() => run("decline_request", { p_request_id: row.request_id })}
              >
                {t("pass")}
              </Button>
            </Card>
          ))}
        </section>
      ) : null}

      {profile.history.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-xl font-semibold">{t("historyTitle")}</h2>
          <ul className="space-y-2">
            {profile.history.map((row) => (
              <li key={row.short_code} className="rounded-field border border-line p-3">
                <p className="font-mono text-sm text-ink-faint">{row.short_code}</p>
                <p className="text-base">
                  {tEnum(`stuckType.${row.stuck_type}`)} ·{" "}
                  {tEnum(`requestStatus.${row.status}`)}
                </p>
                {row.thank_you ? (
                  <p className="mt-1 text-base italic text-ink-soft">&ldquo;{row.thank_you}&rdquo;</p>
                ) : null}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <Card className="space-y-2">
        <h2 className="text-xl font-semibold">{t("profileTitle")}</h2>
        <p className="text-base">{formatUsPhone(profile.phone)}</p>
        <p className="text-base">{t("radius", { miles: profile.radius_miles })}</p>
        <p className="text-base text-ink-soft">
          {profile.equipment.map((item) => tEnum(`equipment.${item}`)).join(", ")}
        </p>
        <Link href="/join" className="text-base underline underline-offset-4">
          {t("editProfile")}
        </Link>
      </Card>

      <Button
        type="button"
        variant="quiet"
        onClick={async () => {
          await supabaseBrowser().auth.signOut();
          await load();
        }}
      >
        {t("signOut")}
      </Button>
      {profile.current_job ? (
        <RequestThread requestId={profile.current_job.request_id} />
      ) : null}

      <LocationShare

        sharing={profile.share_location}

        sharedAt={profile.last_location_at}

        onChange={() => void load()}

      />

      

      {/* Quiet, and last. Most volunteers never need it, and a report form sitting open
          reads as an accusation waiting to happen. */}
      <div className="mt-10">
        <ReportForm />
      </div>
    </main>
  );
}
