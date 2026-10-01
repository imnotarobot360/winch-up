# Built but unreachable — a sweep, 2026-10-01

Three screens in this project were built, deployed, and then left reachable from nothing:
`/welcome`, `/account`, and `/members`. Two whole features — **events** and **groups** — had
tables, RPCs and pgTAP coverage for a week with no UI at all, while CLAUDE.md called them
"deferred". Every one of those was found by a person comparing the app against the design
reference, never by a test.

So this is the sweep, done mechanically rather than by reading. It is worth repeating whenever
"deferred" appears in a planning note.

## How it was done

Three questions, each answered by a script rather than by judgement:

1. **Which member-callable RPCs does the app never call?** Every function in `public` granted to
   `authenticated` or `anon`, grepped against `src/` and `supabase/functions/`.
2. **Which routes does nothing link to?** Every `page.tsx` under `[locale]`, grepped for an
   inbound `href="/x"`, `href: "/x"` or `push("/x")`.
3. **Which tables can nothing in the app reach?** Every table, mapped to the database functions
   whose body names it, then checked for at least one that the app calls.

**Each sweep got a wrong answer first, and a control is what caught it:**

- The RPC sweep listed all 96 functions as uncalled. The names came from psql with CRLF line
  endings, so every pattern carried a trailing `\r` and matched nothing.
- The route sweep listed `/groups` and `/account/security`, both of which had just been linked
  by hand. It only matched JSX `href="…"`, not the `href: "…"` form the menus use.
- The table sweep reported all 45 tables orphaned, then 5, depending on how "called" was
  defined — `.rpc("x")` misses the `call("x")` helper this codebase uses.

A sweep that reports everything, or nothing, is lying. Give it a case you already know the
answer to before believing any of it. The final run asserts `requests` is reachable and refuses
to print results if it is not.

## What it found

### A member can block somebody and never undo it

`community_block(p_user_id, p_on)` takes a boolean, and the only call in the app passes
`p_on: true`. `community_blocked_list()` has no caller at all. So there is no screen listing who
you have blocked, and the only route to unblocking is finding a post by that person — which
blocking is specifically designed to stop you seeing.

An accidental block is therefore permanent. Both halves already exist in the database; this is
a screen, not a feature.

### Moderators have no way in

`/moderation` appears nowhere in `src` — no link, no redirect, nothing. A moderator has to know
and type the URL. The page and `app.is_moderator()` work; nothing points at them.

Not the same as the admin pages, which are linked from the admin shell.

### Three more RPCs with no caller

| RPC | What it is | Consequence |
|---|---|---|
| `my_unread_counts` | "Unread, for the bell and the tab badge" | Per-recovery unread badges are not shown |
| `admin_email_deliveries` | The email log, admin-gated | No screen shows whether mail went out |
| `admin_request_detail` | The private columns an admin legitimately needs | Admins work from the queue only |

### Tables nothing reaches

`email_deliveries` and `notification_deliveries` — the two delivery logs, each written by the
system and read by nobody, because the screens that would read them do not exist.

`invoices`, `payments` and `stripe_webhook_events` are expected: Stripe is not wired, which
CLAUDE.md already says. `rate_limit_hits` is internal and wants no screen.

## What is NOT a finding

`/recovery/[requestId]` has no inbound link and is correct: it is where a **push notification**
lands, built by `src/lib/push/send.ts`. A route can be reachable from outside the app.

## Doing it again

The commands are in this file's history; the shape is:

```sql
-- the RPCs anyone signed in can call
select distinct p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (has_function_privilege('authenticated', p.oid, 'execute')
        or has_function_privilege('anon', p.oid, 'execute'));
```

then grep each name against `src/` and `supabase/functions/` — remembering that this codebase
invokes RPCs three ways: `supabase.rpc("x")`, a local `call("x")` helper, and string constants.

**Strip CRLF from anything psql writes before matching on it**, and start with a control.
