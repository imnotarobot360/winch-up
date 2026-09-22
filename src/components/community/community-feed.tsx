"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { AdSlot } from "@/components/ads/ad-slot";
import { Button, Callout, Card, ChoiceList, TextArea } from "@/components/ui/primitives";
import { IconCheck } from "@/components/ui/icons";
import { supabaseBrowser } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";

type Post = {
  id: string;
  body: string;
  comment_count: number;
  reaction_count: number;
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

  const load = useCallback(async (before?: string) => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("community_feed", {
      p_before: before ?? null,
      p_limit: PAGE,
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
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || posting) return;

    setPosting(true);
    const result = await call("community_post", { p_body: text, p_photo_path: null });
    setPosting(false);

    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setBody("");
    setError(null);
    await load();
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("intro")}</p>
      </div>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

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
          {/* Said before they press, not after it is refused. The rule is the group's own. */}
          <p className="text-sm text-ink-faint">{t("noContactNote")}</p>
          <Button type="submit" disabled={posting || body.trim().length === 0}>
            {posting ? t("posting") : t("post")}
          </Button>
        </form>
      </Card>

      {posts === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : posts.length === 0 ? (
        <Card>
          <p className="text-base text-ink-soft">{t("empty")}</p>
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
