"use client";

import { useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { cn } from "@/lib/utils";

import {
  fromStored,
  TargetingEditor,
  type StoredTarget,
  type Target,
} from "./targeting-editor";
import { adminAction, useAdminData } from "./use-admin";

type Announcement = {
  id: string;
  title: string;
  body: string;
  category: string;
  status: string;
  link_url: string | null;
  link_label: string | null;
  starts_at: string | null;
  ends_at: string | null;
  pinned: boolean;
  targets?: StoredTarget[];
  audience?: number;
  dismissed_count?: number;
};

type AdminEvent = {
  id: string;
  title: string;
  description: string | null;
  event_type: string;
  status: string;
  starts_at: string;
  ends_at: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  address_line: string | null;
  organizer_name: string | null;
  registration_url: string | null;
  website_url: string | null;
  is_official: boolean;
  targets?: StoredTarget[];
  audience?: number;
  going_count?: number;
};

type Campaign = {
  id: string;
  name: string;
  status: string;
  phase: string;
  surfaces: string[];
  starts_on: string;
  ends_on: string | null;
  business_name: string;
  archived_at: string | null;
  targets?: StoredTarget[];
  audience?: number;
  creative_count?: number;
  live_creatives?: number;
};

const SECTIONS = ["announcements", "events", "campaigns"] as const;
type Section = (typeof SECTIONS)[number];

/**
 * Content & Marketing (spec sections 1, 14 and 16).
 *
 * THREE SURFACES IN THE EXISTING ADMIN, not a separate application. The owner's spec says so
 * explicitly, and it is also the only arrangement that works: the admin shell already holds the gate,
 * the MFA requirement and the audit trail, and every RPC behind this screen checks app.is_admin() for
 * itself. This component contains no permission logic at all — a non-admin reaching it gets a 42501
 * from Postgres rather than a hidden button.
 *
 * WHY THE TARGETING EDITOR IS SHARED. One table, one matching rule, one editor. Three would be three
 * places for "a ZIP code is text, not a number" to be wrong independently.
 *
 * WHAT IS DELIBERATELY ABSENT. Creating a campaign: that is the advertiser's own job on /business, and
 * duplicating it here would mean two forms writing the same row with different validation. This screen
 * reviews, targets and manages the lifecycle of campaigns that already exist.
 */
export function AdminContent() {
  const t = useTranslations("adminContent");
  const [section, setSection] = useState<Section>("announcements");

  return (
    <div className="space-y-5">
      <nav className="flex flex-wrap gap-2">
        {SECTIONS.map((name) => (
          <button
            key={name}
            type="button"
            onClick={() => setSection(name)}
            className={cn(
              "rounded-field border-2 px-3 py-2 text-base font-semibold",
              section === name
                ? "border-brand bg-brand-tint text-ink"
                : "border-line text-ink-soft",
            )}
          >
            {t(`tab_${name}`)}
          </button>
        ))}
      </nav>

      {section === "announcements" ? <Announcements /> : null}
      {section === "events" ? <Events /> : null}
      {section === "campaigns" ? <Campaigns /> : null}
    </div>
  );
}

/* ------------------------------------------------------------------------- */
/* Announcements                                                              */
/* ------------------------------------------------------------------------- */

function Announcements() {
  const t = useTranslations("adminContent");
  const { data, loading, reload } = useAdminData<{ ok: boolean; announcements?: Announcement[] }>(
    "admin_announcements",
    {},
  );

  const [editing, setEditing] = useState<Announcement | null>(null);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [category, setCategory] = useState("operational");
  const [linkUrl, setLinkUrl] = useState("");
  const [linkLabel, setLinkLabel] = useState("");
  const [targets, setTargets] = useState<Target[]>([]);
  const [targetsTouched, setTargetsTouched] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  function startNew() {
    setEditing(null);
    setTitle("");
    setBody("");
    setCategory("operational");
    setLinkUrl("");
    setLinkLabel("");
    setTargets([]);
    setTargetsTouched(true);
    setProblem(null);
  }

  function startEdit(item: Announcement) {
    setEditing(item);
    setTitle(item.title);
    setBody(item.body);
    setCategory(item.category);
    setLinkUrl(item.link_url ?? "");
    setLinkLabel(item.link_label ?? "");
    setTargets(fromStored(item.targets));
    // NOT TOUCHED YET, and this is the safe default rather than a nicety. The writer replaces targeting
    // wholesale when `targets` is present and leaves it alone when the key is absent. Sending the
    // editor's idea of the targeting on every save would mean a status change silently rewriting it.
    setTargetsTouched(false);
    setProblem(null);
  }

  async function save(status: string) {
    setBusy(true);
    setProblem(null);

    const payload: Record<string, unknown> = {
      title,
      body,
      category,
      status,
      link_url: linkUrl.trim() || null,
      link_label: linkLabel.trim() || null,
    };

    if (editing) payload.id = editing.id;
    if (targetsTouched) payload.targets = targets;

    const result = await adminAction("admin_save_announcement", { p_payload: payload });
    setBusy(false);

    if (!result.ok) {
      setProblem(t(`err_${result.error ?? "invalid"}`));
      return;
    }

    setEditing(null);
    setTitle("");
    setBody("");
    setTargets([]);
    setTargetsTouched(false);
    await reload();
  }

  const items = data?.announcements ?? [];

  return (
    <div className="space-y-4">
      {problem ? <Callout tone="danger">{problem}</Callout> : null}

      <Card className="space-y-4 p-4">
        <h2 className="text-lg font-semibold text-ink">
          {editing ? t("editAnnouncement") : t("newAnnouncement")}
        </h2>

        <Field label={t("titleLabel")}>
          <TextInput value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} />
        </Field>

        <Field label={t("bodyLabel")}>
          <TextArea value={body} maxLength={2000} onChange={(e) => setBody(e.target.value)} />
        </Field>

        <Field label={t("categoryLabel")} hint={t("categoryHint")}>
          <select
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
          >
            <option value="operational">{t("categoryOperational")}</option>
            <option value="marketing">{t("categoryMarketing")}</option>
          </select>
        </Field>

        <Field label={t("linkLabel")} hint={t("linkHint")}>
          <TextInput value={linkUrl} onChange={(e) => setLinkUrl(e.target.value)} />
        </Field>

        <Field label={t("linkLabelLabel")}>
          <TextInput value={linkLabel} maxLength={60} onChange={(e) => setLinkLabel(e.target.value)} />
        </Field>

        <TargetingEditor
          targets={targets}
          onChange={(next) => {
            setTargets(next);
            setTargetsTouched(true);
          }}
          audience={editing?.audience ?? null}
        />

        <Button onClick={() => save("draft")} disabled={busy || !title.trim() || !body.trim()}>
          {t("saveDraft")}
        </Button>
        <Button
          variant="secondary"
          onClick={() => save("published")}
          disabled={busy || !title.trim() || !body.trim()}
        >
          {t("publish")}
        </Button>
        {editing ? (
          <Button variant="quiet" onClick={startNew}>
            {t("cancelEdit")}
          </Button>
        ) : null}
      </Card>

      {loading ? <p className="text-ink-soft">{t("loading")}</p> : null}

      {items.map((item) => (
        <Card key={item.id} className="space-y-2 p-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge>{t(`status_${item.status}`)}</Badge>
            <Badge>{t(`category_${item.category}`)}</Badge>
            {item.pinned ? <Badge>{t("pinned")}</Badge> : null}
          </div>
          <h3 className="text-base font-semibold text-ink">{item.title}</h3>
          <p className="text-sm text-ink-soft">{item.body}</p>
          <p className="text-sm text-ink-faint">
            {t("reachSummary", {
              audience: item.audience ?? 0,
              places: item.targets?.length ?? 0,
            })}
          </p>
          {typeof item.dismissed_count === "number" && item.dismissed_count > 0 ? (
            <p className="text-sm text-ink-faint">
              {t("dismissedCount", { count: item.dismissed_count })}
            </p>
          ) : null}
          <Button variant="secondary" onClick={() => startEdit(item)}>
            {t("edit")}
          </Button>
          {item.status === "published" ? (
            <Button
              variant="quiet"
              onClick={async () => {
                await adminAction("admin_save_announcement", {
                  p_payload: { id: item.id, status: "archived" },
                });
                await reload();
              }}
            >
              {t("archive")}
            </Button>
          ) : null}
        </Card>
      ))}
    </div>
  );
}

/* ------------------------------------------------------------------------- */
/* Events                                                                     */
/* ------------------------------------------------------------------------- */

const EVENT_TYPES = [
  "trail_ride",
  "training",
  "meetup",
  "cleanup",
  "fundraiser",
  "show",
  "other",
] as const;

function Events() {
  const t = useTranslations("adminContent");
  const format = useFormatter();
  const { data, loading, reload } = useAdminData<{ ok: boolean; events?: AdminEvent[] }>(
    "admin_events",
    {},
  );

  const [editing, setEditing] = useState<AdminEvent | null>(null);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [eventType, setEventType] = useState<string>("other");
  const [startsAt, setStartsAt] = useState("");
  const [city, setCity] = useState("");
  const [state, setState] = useState("");
  const [postal, setPostal] = useState("");
  const [organizer, setOrganizer] = useState("");
  const [registration, setRegistration] = useState("");
  const [targets, setTargets] = useState<Target[]>([]);
  const [targetsTouched, setTargetsTouched] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  function startEdit(item: AdminEvent) {
    setEditing(item);
    setTitle(item.title);
    setDescription(item.description ?? "");
    setEventType(item.event_type);
    // datetime-local wants "YYYY-MM-DDTHH:mm" and the RPC returns an ISO string with a zone. Slicing
    // is the right tool here rather than a date library: the value is already in the browser's own
    // rendering of that instant by the time it reaches this input.
    setStartsAt(item.starts_at.slice(0, 16));
    setCity(item.city ?? "");
    setState(item.state ?? "");
    setPostal(item.postal_code ?? "");
    setOrganizer(item.organizer_name ?? "");
    setRegistration(item.registration_url ?? "");
    setTargets(fromStored(item.targets));
    setTargetsTouched(false);
    setProblem(null);
  }

  async function save(status: string) {
    setBusy(true);
    setProblem(null);

    const payload: Record<string, unknown> = {
      title,
      description: description.trim() || null,
      event_type: eventType,
      starts_at: startsAt ? new Date(startsAt).toISOString() : "",
      city: city.trim() || null,
      state: state.trim() || null,
      postal_code: postal.trim() || null,
      organizer_name: organizer.trim() || null,
      registration_url: registration.trim() || null,
      status,
    };

    if (editing) payload.id = editing.id;
    if (targetsTouched) payload.targets = targets;

    const result = await adminAction("admin_save_event", { p_payload: payload });
    setBusy(false);

    if (!result.ok) {
      setProblem(t(`err_${result.error ?? "invalid"}`));
      return;
    }

    setEditing(null);
    setTitle("");
    setDescription("");
    setTargets([]);
    setTargetsTouched(false);
    await reload();
  }

  const items = data?.events ?? [];

  return (
    <div className="space-y-4">
      {problem ? <Callout tone="danger">{problem}</Callout> : null}

      <Card className="space-y-4 p-4">
        <h2 className="text-lg font-semibold text-ink">
          {editing ? t("editEvent") : t("newEvent")}
        </h2>

        {/* The promotional fields below are only writable from here. A CHECK on the table keys them to
            is_official, which admin_save_event sets and create_event never touches — so a member
            publishing an event cannot attach an organiser, a website or a phone number. */}
        <Callout tone="neutral">{t("officialNote")}</Callout>

        <Field label={t("titleLabel")}>
          <TextInput value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} />
        </Field>

        <Field label={t("startsLabel")}>
          <TextInput
            type="datetime-local"
            value={startsAt}
            onChange={(e) => setStartsAt(e.target.value)}
          />
        </Field>

        <Field label={t("eventTypeLabel")}>
          <select
            value={eventType}
            onChange={(e) => setEventType(e.target.value)}
            className="tap-target w-full rounded-field border-2 border-line bg-surface px-4 text-lg text-ink"
          >
            {EVENT_TYPES.map((value) => (
              <option key={value} value={value}>
                {t(`eventType_${value}`)}
              </option>
            ))}
          </select>
        </Field>

        <Field label={t("descriptionLabel")}>
          <TextArea
            value={description}
            maxLength={2000}
            onChange={(e) => setDescription(e.target.value)}
          />
        </Field>

        <Field label={t("cityLabel")}>
          <TextInput value={city} maxLength={80} onChange={(e) => setCity(e.target.value)} />
        </Field>

        <Field label={t("stateLabel")}>
          <TextInput
            value={state}
            maxLength={2}
            onChange={(e) => setState(e.target.value.toUpperCase().slice(0, 2))}
          />
        </Field>

        <Field label={t("postalLabel")}>
          <TextInput
            value={postal}
            inputMode="numeric"
            maxLength={5}
            onChange={(e) => setPostal(e.target.value.replace(/[^0-9]/g, "").slice(0, 5))}
          />
        </Field>

        <Field label={t("organizerLabel")}>
          <TextInput value={organizer} maxLength={120} onChange={(e) => setOrganizer(e.target.value)} />
        </Field>

        <Field label={t("registrationLabel")}>
          <TextInput value={registration} onChange={(e) => setRegistration(e.target.value)} />
        </Field>

        <TargetingEditor
          targets={targets}
          onChange={(next) => {
            setTargets(next);
            setTargetsTouched(true);
          }}
          audience={editing?.audience ?? null}
        />

        {/* Targeting an event does NOT hide it from anybody — the directory stays complete and the
            flag only marks what is near a member. Said on the screen, because an admin choosing a ZIP
            code here would otherwise reasonably believe they were restricting who can see it. */}
        <Callout tone="neutral">{t("eventTargetingNote")}</Callout>

        <Button onClick={() => save("draft")} disabled={busy || !title.trim() || !startsAt}>
          {t("saveDraft")}
        </Button>
        <Button
          variant="secondary"
          onClick={() => save("published")}
          disabled={busy || !title.trim() || !startsAt}
        >
          {t("publish")}
        </Button>
        {editing ? (
          <Button variant="quiet" onClick={() => setEditing(null)}>
            {t("cancelEdit")}
          </Button>
        ) : null}
      </Card>

      {loading ? <p className="text-ink-soft">{t("loading")}</p> : null}

      {items.map((item) => (
        <Card key={item.id} className="space-y-2 p-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge>{t(`status_${item.status}`)}</Badge>
            {item.is_official ? <Badge>{t("official")}</Badge> : <Badge>{t("memberMade")}</Badge>}
          </div>
          <h3 className="text-base font-semibold text-ink">{item.title}</h3>
          <p className="text-sm text-ink-soft">
            {format.dateTime(new Date(item.starts_at), {
              day: "numeric",
              month: "short",
              hour: "numeric",
              minute: "2-digit",
            })}
            {item.city && item.state ? ` · ${item.city}, ${item.state}` : ""}
          </p>
          <p className="text-sm text-ink-faint">
            {t("reachSummary", {
              audience: item.audience ?? 0,
              places: item.targets?.length ?? 0,
            })}
          </p>
          <Button variant="secondary" onClick={() => startEdit(item)}>
            {t("edit")}
          </Button>
        </Card>
      ))}

      <EventReport />
    </div>
  );
}

/* ------------------------------------------------------------------------- */
/* Campaigns                                                                  */
/* ------------------------------------------------------------------------- */

function Campaigns() {
  const t = useTranslations("adminContent");
  const [includeArchived, setIncludeArchived] = useState(false);
  const { data, loading, reload } = useAdminData<{ ok: boolean; campaigns?: Campaign[] }>(
    "admin_campaigns",
    { p_include_archived: includeArchived },
  );

  const [editing, setEditing] = useState<Campaign | null>(null);
  const [targets, setTargets] = useState<Target[]>([]);

  const items = data?.campaigns ?? [];

  return (
    <div className="space-y-4">
      <Button variant="secondary" onClick={() => setIncludeArchived((value) => !value)}>
        {includeArchived ? t("hideArchived") : t("showArchived")}
      </Button>

      {loading ? <p className="text-ink-soft">{t("loading")}</p> : null}

      {items.map((item) => (
        <Card key={item.id} className="space-y-2 p-4">
          <div className="flex flex-wrap items-center gap-2">
            {/* The phase, which is derived from the status and the dates by the same function the
                serving query asks — so this word cannot disagree with whether the advert is running. */}
            <Badge>{t(`phase_${item.phase}`)}</Badge>
            {item.surfaces.map((surface) => (
              <Badge key={surface}>{surface}</Badge>
            ))}
          </div>

          <h3 className="text-base font-semibold text-ink">{item.name}</h3>
          <p className="text-sm text-ink-soft">{item.business_name}</p>
          <p className="text-sm text-ink-faint">
            {t("reachSummary", {
              audience: item.audience ?? 0,
              places: item.targets?.length ?? 0,
            })}
          </p>
          <p className="text-sm text-ink-faint">
            {t("creativeSummary", {
              live: item.live_creatives ?? 0,
              total: item.creative_count ?? 0,
            })}
          </p>

          {editing?.id === item.id ? (
            <>
              <TargetingEditor
                targets={targets}
                onChange={setTargets}
                audience={item.audience ?? null}
              />
              <Button
                onClick={async () => {
                  // Only reached because the admin opened this editor, so `targets` is always a
                  // deliberate statement here — there is no untouched case to guard against.
                  await adminAction("admin_save_campaign_targets", {
                    p_campaign_id: item.id,
                    p_targets: targets,
                  });
                  setEditing(null);
                  await reload();
                }}
              >
                {t("saveTargeting")}
              </Button>
              <Button variant="quiet" onClick={() => setEditing(null)}>
                {t("cancelEdit")}
              </Button>
            </>
          ) : (
            <Button
              variant="secondary"
              onClick={() => {
                setEditing(item);
                setTargets(fromStored(item.targets));
              }}
            >
              {t("editTargeting")}
            </Button>
          )}

          {item.phase === "active" ? (
            <Button
              variant="quiet"
              onClick={async () => {
                await adminAction("set_campaign_running", { p_id: item.id, p_running: false });
                await reload();
              }}
            >
              {t("pause")}
            </Button>
          ) : null}

          {item.phase === "paused" ? (
            <Button
              variant="quiet"
              onClick={async () => {
                await adminAction("set_campaign_running", { p_id: item.id, p_running: true });
                await reload();
              }}
            >
              {t("resume")}
            </Button>
          ) : null}

          <Button
            variant="quiet"
            onClick={async () => {
              await adminAction("duplicate_campaign", { p_id: item.id, p_name: null });
              await reload();
            }}
          >
            {t("duplicate")}
          </Button>

          <Button
            variant="quiet"
            onClick={async () => {
              await adminAction("set_campaign_archived", {
                p_id: item.id,
                p_archived: item.archived_at === null,
              });
              await reload();
            }}
          >
            {item.archived_at === null ? t("archive") : t("unarchive")}
          </Button>

          <CampaignReport campaignId={item.id} />
        </Card>
      ))}
    </div>
  );
}

type Report = {
  ok: boolean;
  min_cohort?: number;
  totals?: { impressions: number; clicks: number };
  by_postal_code?: {
    postal_code: string | null;
    impressions: number;
    clicks: number;
    suppressed?: boolean;
    unknown_area?: boolean;
    bucket_count?: number;
  }[];
  estimated_reach?: number;
  note?: string;
};

/**
 * The geographic report for one campaign (spec section 12).
 *
 * LOADED ON DEMAND, not with the list. One report is several aggregate queries over every impression
 * ever recorded, and running them for every campaign on the page to fill in numbers nobody has asked
 * to see yet is the kind of thing that makes an admin screen slow for no reason.
 *
 * The suppressed row is rendered as what it is, never dropped. An admin who cannot see that some areas
 * were combined will reconcile the figures by hand, and the first thing they will ask for is the raw
 * table — which is the thing the suppression exists to avoid handing out.
 */
function CampaignReport({ campaignId }: { campaignId: string }) {
  const t = useTranslations("adminContent");
  const [report, setReport] = useState<Report | null>(null);
  const [open, setOpen] = useState(false);

  async function load() {
    setOpen(true);
    const result = await adminAction("admin_ad_report", {
      p_campaign_id: campaignId,
      p_creative_id: null,
      p_days: 30,
    });
    setReport(result as unknown as Report);
  }

  if (!open) {
    return (
      <Button variant="quiet" onClick={load}>
        {t("showReport")}
      </Button>
    );
  }

  if (!report) return <p className="text-sm text-ink-soft">{t("loading")}</p>;

  return (
    <div className="space-y-2 rounded-field border-2 border-line p-3">
      <p className="text-sm font-semibold text-ink">
        {t("reportTotals", {
          impressions: report.totals?.impressions ?? 0,
          clicks: report.totals?.clicks ?? 0,
        })}
      </p>
      <p className="text-sm text-ink-soft">
        {t("reportReach", { count: report.estimated_reach ?? 0 })}
      </p>

      <ul className="space-y-1">
        {(report.by_postal_code ?? []).map((row, index) => (
          <li key={index} className="text-sm text-ink-soft">
            {row.suppressed
              ? t("reportSuppressed", {
                  areas: row.bucket_count ?? 0,
                  impressions: row.impressions,
                })
              : row.unknown_area
                ? t("reportUnknownArea", { impressions: row.impressions })
                : `${row.postal_code} — ${row.impressions}`}
          </li>
        ))}
      </ul>

      {/* The database sends this sentence with the payload rather than leaving it to a screen to
          remember. Rendered, not hidden: the breakdown is incomplete by design and saying so is the
          difference between a privacy measure and a misleading chart. */}
      {report.note ? <p className="text-xs text-ink-faint">{report.note}</p> : null}
    </div>
  );
}

function Badge({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded-field border-2 border-line px-2 py-1 text-xs font-semibold uppercase tracking-wide text-ink-soft">
      {children}
    </span>
  );
}

type EventReportRow = {
  id: string;
  title: string;
  starts_at: string;
  city: string | null;
  state: string | null;
  views: number;
  going: number;
  estimated_reach: number;
};

/**
 * How events are doing (spec section 12).
 *
 * THIS IS WHY THE EVENT PAGE EXISTS. `admin_event_report` was written, granted, tested and called
 * by nothing -- found by re-running the project's own built-but-unreachable sweep rather than by a
 * failure. Wiring it any earlier would have shipped a views column structurally stuck at zero,
 * because there was no per-event surface and counting a view for every event in a list is not a
 * view. There is a page now, so the number can move, so the column is worth rendering.
 *
 * Loaded with the tab rather than on demand, unlike the campaign report: one query over a small
 * table, and it is the only feedback an organiser gets at all.
 */
function EventReport() {
  const t = useTranslations("adminContent");
  const { data, loading } = useAdminData<{ ok: boolean; events?: EventReportRow[] }>(
    "admin_event_report",
    { p_days: 30 },
  );

  if (loading) return <p className="text-ink-soft">{t("loading")}</p>;

  const rows = data?.events ?? [];
  if (rows.length === 0) return null;

  return (
    <Card className="space-y-3 p-4">
      <h3 className="text-base font-semibold text-ink">{t("eventReportTitle")}</h3>
      <p className="text-sm text-ink-soft">{t("eventReportHint")}</p>
      <ul className="space-y-2">
        {rows.map((row) => (
          <li key={row.id} className="min-w-0">
            <p className="break-words text-base text-ink">{row.title}</p>
            <p className="text-sm text-ink-faint">
              {t("eventReportLine", {
                views: row.views,
                going: row.going,
                reach: row.estimated_reach,
              })}
            </p>
          </li>
        ))}
      </ul>
    </Card>
  );
}
