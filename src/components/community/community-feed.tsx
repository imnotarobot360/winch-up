"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { AdSlot } from "@/components/ads/ad-slot";
import { Button, Callout, Card, ChoiceList, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { IconCheck } from "@/components/ui/icons";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

/**
 * The feed's tabs.
 *
 * Closer to the design reference's Recent / Trails / Events / Tips than it was, and still not
 * the same list. TIPS arrived on 2026-10-01 (20261001000200) because a tip is just a post with
 * a label -- no table, no dates, nothing to build -- and it fills the same way Gear and
 * Recoveries did: with whatever the first person files under it.
 *
 * EVENTS IS NOT A POST TOPIC. It is a tab over a different table.
 *
 * The events feature was built in phase 12 -- a table with a start, a meeting note, an optional
 * trail or group, capacity and RSVPs, plus create_event, events_upcoming and event_rsvp -- and
 * never got a screen, which is why CLAUDE.md called events "deferred" and why this tab did not
 * exist. "Deferred" meant the UI.
 *
 * So the Events tab reads events_upcoming() rather than the feed: published only, soonest
 * first, and nothing that finished more than six hours ago. It is not a filter over posts and
 * cannot be made into one.
 *
 * NO RSVP CONTROLS, by the owner's decision (2026-10-01). event_rsvp exists and is left alone;
 * create_event still marks the organiser as going, which is the table's own behaviour and not
 * something this screen asks for or shows.
 */
const TOPICS = ["all", "trail_conditions", "gear", "recoveries", "tips", "events"] as const;
type Topic = (typeof TOPICS)[number];

/** What the composer can file a post under. "all" is a filter, not a topic. */
const POST_TOPICS = ["general", "trail_conditions", "gear", "recoveries", "tips"] as const;

/** What events_upcoming() returns. Fields this screen does not show are left out. */
type EventRow = {
  id: string;
  title: string;
  description: string | null;
  starts_at: string;
  meet_note: string | null;
  trail_name: string | null;
};

type Post = {
  id: string;
  body: string;
  comment_count: number;
  reaction_count: number;
  // Optional: the app deploys on a push and migrations go across by hand, so there is a window
  // where this RPC has not started returning it yet.
  topic?: string;
  created_at: string;
  mine: boolean;
  author_user_id: string;
  author_name: string;
  reacted: boolean;
};

type Comment = {
  id: string;
  body: string;
  created_at: string;
  mine: boolean;
  author_user_id: string;
  author_name: string;
};

type Result = { ok: boolean; error?: string };

const REASONS = ["soliciting_payment", "spam", "harassment", "impersonation", "unsafe_advice", "other"] as const;
type Reason = (typeof REASONS)[number];

const PAGE = 20;

async function call(fn: string, args: Record<string, unknown>): Promise<Result> {
  const { data, error } = await supabaseBrowser().rpc(fn, args);
  if (error) return { ok: false, error: "failed" };
  return (data as Result | null) ?? { ok: false, error: "failed" };
}

/**
 * The community feed.
 *
 * Every rule this screen appears to enforce is actually enforced in Postgres: blocking, the ban
 * on posting phone numbers and links, who may delete what, and what a hidden post looks like.
 * Nothing here is a permission check -- the controls are shown or hidden to save people from
 * pressing something that will fail, and pressing it anyway gets an error from the database.
 *
 * The one thing worth saying out loud: a blocked person is never told. There is no "you have been
 * blocked" state, no error that differs from an ordinary missing post. Their posts simply stop
 * appearing to the person who blocked them, and vice versa.
 */
export function CommunityFeed() {
  const t = useTranslations("community");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  // useNow only ticks once a minute, so a post made seconds ago can be newer than the clock this
  // renders against, and next-intl then honestly reports it as "in 49 seconds". Nobody wants to
  // read that about the thing they just wrote. Measuring from whichever is later gives "now".
  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [more, setMore] = useState(false);

  const [body, setBody] = useState("");
  const [posting, setPosting] = useState(false);
  const [topic, setTopic] = useState<Topic>("all");
  const [postTopic, setPostTopic] = useState<string>("general");

  // The Events tab: its own list, and its own small form. Deliberately separate from the post
  // composer -- an event has a title, a time and a meeting point, and folding four fields into
  // the box people use for "gate is locked" would make the common case worse.
  const [events, setEvents] = useState<EventRow[] | null>(null);
  const [evTitle, setEvTitle] = useState("");
  const [evWhen, setEvWhen] = useState("");
  const [evPlace, setEvPlace] = useState("");
  const [evAbout, setEvAbout] = useState("");
  const [evOpen, setEvOpen] = useState(false);

  const loadEvents = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("events_upcoming", {});

    if (rpcError) {
      setError("failed");
      return;
    }

    const result = data as { ok: boolean; error?: string; events?: EventRow[] };
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setError(null);
    // ?? [] because a build can reach production before its migration does, and a tab that
    // renders empty beats one that throws on .length.
    setEvents(result.events ?? []);
  }, []);

  const load = useCallback(async (before?: string, forTopic?: Topic) => {
    const active = forTopic ?? topic;

    if (active === "events") {
      await loadEvents();
      return;
    }
    const { data, error: rpcError } = await supabaseBrowser().rpc("community_feed", {
      p_before: before ?? null,
      p_limit: PAGE,
      p_topic: active === "all" ? null : active,
    });

    if (rpcError) {
      setError("failed");
      return;
    }

    const result = data as { ok: boolean; error?: string; posts?: Post[] };

    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    const page = result.posts ?? [];
    setError(null);
    setMore(page.length === PAGE);
    setPosts((prev) => (before ? [...(prev ?? []), ...page] : page));
  }, [topic, loadEvents]);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || posting) return;

    setPosting(true);
    const result = await call("community_post", {
      p_body: text,
      p_photo_path: null,
      p_topic: postTopic,
    });
    setPosting(false);

    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setBody("");
    setError(null);
    await load();
  }

  async function submitEvent(event: React.FormEvent) {
    event.preventDefault();
    if (posting || !evTitle.trim() || !evWhen || !evPlace.trim()) return;

    setPosting(true);
    const result = await call("create_event", {
      p_payload: {
        title: evTitle.trim(),
        description: evAbout.trim() || null,
        meet_note: evPlace.trim(),
        // datetime-local carries no zone, so the browser's own is the right reading: somebody
        // typing 9am means 9am where the trail is, which is where they are.
        starts_at: new Date(evWhen).toISOString(),
        // Published, by the owner's decision (2026-10-01). create_event defaults to 'draft'
        // and events_upcoming only lists published ones, so without this every event posted
        // from here would vanish into a queue nothing in this app can see.
        status: "published",
      },
    });
    setPosting(false);

    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setEvTitle("");
    setEvWhen("");
    setEvPlace("");
    setEvAbout("");
    setEvOpen(false);
    setError(null);
    await loadEvents();
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("intro")}</p>
      </div>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {/* The post composer belongs to the post tabs. On Events it would be a box that files
          something the Events tab cannot show, which is the same trap as a tab with nothing
          behind it, one level in. */}
      {topic === "events" ? null : (
      <Card className="space-y-3">
        <form onSubmit={submit} className="space-y-3">
          <TextArea
            aria-label={t("composeLabel")}
            placeholder={t("placeholder")}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            maxLength={2000}
            rows={3}
          />
          {/* What it is about. Defaults to general, so posting is still one field and a button
              for anybody who does not care. */}
          <div className="flex flex-wrap gap-2">
            {POST_TOPICS.map((value) => (
              <button
                key={value}
                type="button"
                aria-pressed={postTopic === value}
                onClick={() => setPostTopic(value)}
                className={`tap-target rounded-full border-2 px-4 text-sm font-semibold ${
                  postTopic === value
                    ? "border-brand bg-brand text-on-brand"
                    : "border-line text-ink-soft"
                }`}
              >
                {t(`topics.${value}`)}
              </button>
            ))}
          </div>

          {/* Said before they press, not after it is refused. The rule is the group's own. */}
          <p className="text-sm text-ink-faint">{t("noContactNote")}</p>
          <Button type="submit" disabled={posting || body.trim().length === 0}>
            {posting ? t("posting") : t("post")}
          </Button>
        </form>
      </Card>
      )}

      {/* Screen 9's tabs. A tablist rather than a row of buttons, so a screen reader announces
          it as one control with a selected item and arrow keys move between them. */}
      <div role="tablist" aria-label={t("topicsLabel")} className="flex gap-2 overflow-x-auto pb-1">
        {TOPICS.map((value) => (
          <button
            key={value}
            role="tab"
            type="button"
            aria-selected={topic === value}
            onClick={() => {
              if (value === topic) return;
              setTopic(value);
              setPosts(null);
              void load(undefined, value);
            }}
            className={`tap-target shrink-0 rounded-full border-2 px-4 text-sm font-semibold ${
              topic === value
                ? "border-brand bg-brand text-on-brand"
                : "border-line text-ink-soft"
            }`}
          >
            {t(`topics.${value}`)}
          </button>
        ))}
      </div>

      {topic === "events" ? (
        <>
          {/* Folded away until asked for: most people open this tab to read what is coming
              up, not to organise something. */}
          {evOpen ? (
            <Card className="space-y-3">
              <form onSubmit={submitEvent} className="space-y-3">
                <Field label={t("eventTitle")}>
                  <TextInput
                    value={evTitle}
                    onChange={(e) => setEvTitle(e.target.value)}
                    maxLength={120}
                  />
                </Field>

                <div className="grid gap-3 sm:grid-cols-2">
                  <Field label={t("eventWhen")}>
                    <input
                      type="datetime-local"
                      value={evWhen}
                      onChange={(e) => setEvWhen(e.target.value)}
                      className="tap-target w-full rounded-field border-2 border-line bg-surface-sunk px-4 text-base text-ink"
                    />
                  </Field>
                  <Field label={t("eventPlace")} hint={t("eventPlaceHint")}>
                    <TextInput
                      value={evPlace}
                      onChange={(e) => setEvPlace(e.target.value)}
                      maxLength={300}
                    />
                  </Field>
                </div>

                <Field label={t("eventAbout")}>
                  <TextArea
                    value={evAbout}
                    onChange={(e) => setEvAbout(e.target.value)}
                    maxLength={2000}
                    rows={3}
                  />
                </Field>

                <p className="text-sm text-ink-faint">{t("noContactNote")}</p>

                <div className="flex flex-wrap gap-2">
                  <Button
                    type="submit"
                    disabled={posting || !evTitle.trim() || !evWhen || !evPlace.trim()}
                  >
                    {posting ? t("posting") : t("eventPost")}
                  </Button>
                  <Button type="button" variant="secondary" onClick={() => setEvOpen(false)}>
                    {t("eventCancel")}
                  </Button>
                </div>
              </form>
            </Card>
          ) : (
            <Button variant="secondary" onClick={() => setEvOpen(true)}>
              {t("eventAdd")}
            </Button>
          )}

          {events === null ? (
            <p className="text-base text-ink-soft">{t("loading")}</p>
          ) : events.length === 0 ? (
            <Card>
              <p className="text-base text-ink-soft">{t("eventsEmpty")}</p>
            </Card>
          ) : (
            <ul className="space-y-3">
              {events.map((e) => (
                <li key={e.id}>
                  <Card className="space-y-2">
                    <p className="text-sm font-semibold uppercase tracking-wide text-brand">
                      {format.dateTime(new Date(e.starts_at), {
                        weekday: "short",
                        day: "numeric",
                        month: "short",
                        hour: "numeric",
                        minute: "2-digit",
                      })}
                    </p>
                    <h2 className="text-xl font-semibold text-ink">{e.title}</h2>
                    {e.meet_note ? (
                      <p className="text-base text-ink">{t("eventMeet", { place: e.meet_note })}</p>
                    ) : null}
                    {e.trail_name ? (
                      <p className="text-sm text-ink-soft">{e.trail_name}</p>
                    ) : null}
                    {e.description ? (
                      <p className="whitespace-pre-wrap text-base text-ink-soft">{e.description}</p>
                    ) : null}
                  </Card>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : posts === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : posts.length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">
            {topic === "all" ? t("empty") : t("emptyTopic")}
          </p>
        </Card>
      ) : (
        <ul className="space-y-4">
          {posts.map((post, index) => (
            <li key={post.id}>
              {/* One slot, a few posts down, never at the top. Whether it renders at all is the
                  database's decision -- the component asks and gets nothing when there is
                  nothing to show. */}
              {index === Math.min(3, posts.length - 1) ? (
                <AdSlot surface="community_feed" className="mb-4" />
              ) : null}
              <PostCard
                post={post}
                onChanged={() => void load()}
                t={t}
                relative={relative}
              />
            </li>
          ))}
        </ul>
      )}

      {more ? (
        <Button
          variant="secondary"
          onClick={() => void load(posts?.[posts.length - 1]?.created_at)}
        >
          {t("loadMore")}
        </Button>
      ) : null}
    </div>
  );
}

function PostCard({
  post,
  onChanged,
  t,
  relative,
}: {
  post: Post;
  onChanged: () => void;
  t: ReturnType<typeof useTranslations<"community">>;
  relative: (iso: string) => string;
}) {
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [menu, setMenu] = useState(false);
  const [reporting, setReporting] = useState(false);
  const [reason, setReason] = useState<Reason | null>(null);
  const [reported, setReported] = useState(false);

  const loadThread = useCallback(async () => {
    const { data } = await supabaseBrowser().rpc("community_post_thread", { p_post_id: post.id });
    const result = data as { ok: boolean; comments?: Comment[] } | null;
    setComments(result?.ok ? (result.comments ?? []) : []);
  }, [post.id]);

  async function toggleThread() {
    const next = !open;
    setOpen(next);
    if (next && comments === null) await loadThread();
  }

  async function act(fn: string, args: Record<string, unknown>, reload = true) {
    setBusy(true);
    setProblem(null);
    const result = await call(fn, args);
    setBusy(false);

    if (!result.ok) {
      setProblem(result.error ?? "failed");
      return false;
    }

    if (reload) onChanged();
    return true;
  }

  async function comment(event: React.FormEvent) {
    event.preventDefault();
    const text = draft.trim();
    if (!text || busy) return;

    setBusy(true);
    setProblem(null);
    const result = await call("community_comment", { p_post_id: post.id, p_body: text });
    setBusy(false);

    if (!result.ok) {
      setProblem(result.error ?? "failed");
      return;
    }

    setDraft("");
    await loadThread();
    onChanged();
  }

  async function sendReport() {
    if (!reason) return;
    const ok = await act(
      "community_report",
      { p_kind: "post", p_id: post.id, p_reason: reason, p_note: null },
      false,
    );
    if (ok) {
      setReporting(false);
      setMenu(false);
      setReported(true);
    }
  }

  return (
    <Card className="space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="text-base font-semibold">{post.author_name || t("someone")}</p>
          <p className="text-sm text-ink-faint">{relative(post.created_at)}</p>
        </div>
        <Button
          variant="quiet"
          size="md"
          className="w-auto px-2"
          aria-expanded={menu}
          onClick={() => setMenu((v) => !v)}
        >
          {t("moreActions")}
        </Button>
      </div>

      <p className="whitespace-pre-wrap text-base leading-relaxed">{post.body}</p>

      {problem ? <Callout tone="danger">{t(`errors.${problem}`)}</Callout> : null}
      {reported ? <Callout tone="good">{t("reportThanks")}</Callout> : null}

      <div className="flex flex-wrap gap-2">
        <Button
          variant={post.reacted ? "primary" : "secondary"}
          size="md"
          className="w-auto"
          disabled={busy}
          aria-pressed={post.reacted}
          onClick={() => void act("community_react", { p_post_id: post.id, p_on: !post.reacted })}
        >
          <IconCheck size={18} />
          {t("helpful")}
          {post.reaction_count > 0 ? ` · ${post.reaction_count}` : ""}
        </Button>

        <Button
          variant="secondary"
          size="md"
          className="w-auto"
          aria-expanded={open}
          onClick={() => void toggleThread()}
        >
          {t("comments", { count: post.comment_count })}
        </Button>
      </div>

      {menu ? (
        <div className="space-y-2 rounded-field border-2 border-line bg-surface-sunk p-3">
          {post.mine ? (
            <Button
              variant="danger"
              size="md"
              disabled={busy}
              onClick={() => void act("community_delete_own", { p_kind: "post", p_id: post.id })}
            >
              {t("deletePost")}
            </Button>
          ) : (
            <>
              {reporting ? (
                <div className="space-y-3">
                  <p className="text-base font-semibold">{t("reportTitle")}</p>
                  <ChoiceList
                    name={t("reportTitle")}
                    value={reason}
                    onChange={setReason}
                    options={REASONS.map((r) => ({ value: r, label: t(`reasons.${r}`) }))}
                  />
                  <Button size="md" disabled={busy || !reason} onClick={() => void sendReport()}>
                    {t("reportSend")}
                  </Button>
                  <Button variant="quiet" size="md" onClick={() => setReporting(false)}>
                    {t("cancel")}
                  </Button>
                </div>
              ) : (
                <Button variant="secondary" size="md" onClick={() => setReporting(true)}>
                  {t("report")}
                </Button>
              )}

              <Button
                variant="secondary"
                size="md"
                disabled={busy}
                onClick={() =>
                  void act("community_block", { p_user_id: post.author_user_id, p_on: true })
                }
              >
                {t("block", { name: post.author_name || t("someone") })}
              </Button>
              <p className="text-sm text-ink-faint">{t("blockNote")}</p>
            </>
          )}
        </div>
      ) : null}

      {open ? (
        <div className="space-y-3 border-t border-line pt-3">
          {comments === null ? (
            <p className="text-sm text-ink-soft">{t("loading")}</p>
          ) : comments.length === 0 ? (
            <p className="text-sm text-ink-soft">{t("noComments")}</p>
          ) : (
            <ul className="space-y-3">
              {comments.map((c) => (
                <li key={c.id} className={cn("rounded-field bg-surface-sunk p-3")}>
                  <p className="text-sm font-semibold">{c.author_name || t("someone")}</p>
                  <p className="mt-1 whitespace-pre-wrap text-base">{c.body}</p>
                  <div className="mt-1 flex items-center gap-3">
                    <span className="text-xs text-ink-faint">{relative(c.created_at)}</span>
                    {c.mine ? (
                      <button
                        type="button"
                        className="text-xs font-semibold text-danger underline underline-offset-4"
                        onClick={async () => {
                          const ok = await act(
                            "community_delete_own",
                            { p_kind: "comment", p_id: c.id },
                            false,
                          );
                          if (ok) {
                            await loadThread();
                            onChanged();
                          }
                        }}
                      >
                        {t("delete")}
                      </button>
                    ) : null}
                  </div>
                </li>
              ))}
            </ul>
          )}

          <form onSubmit={comment} className="space-y-2">
            <TextArea
              aria-label={t("commentLabel")}
              placeholder={t("commentPlaceholder")}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              maxLength={1000}
              rows={2}
            />
            <Button type="submit" size="md" disabled={busy || draft.trim().length === 0}>
              {t("reply")}
            </Button>
          </form>
        </div>
      ) : null}
    </Card>
  );
}
