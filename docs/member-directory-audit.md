# Member directory: what is already there, and what the spec changes

Audit done before any change, per §5 of the owner's spec ("Audit the existing database and Row
Level Security policies"). Read from the **live database** — `pg_policies`, `pg_proc.prosrc`,
`information_schema.columns` — not from the migration files, because several of these functions
have been redefined and the older copies are stale.

## The part that is already right

**No table is exposed.** RLS on the three tables a directory would want is self-only:

| table | policies |
|---|---|
| `profiles` | `profiles_self_read` (SELECT), `profiles_self_update` (UPDATE) — both `authenticated`, both own-row |
| `responders` | self read / insert / update |
| `vehicles` | owner read / insert / update / delete |

On top of that, `profiles` has **column-level grants**: `authenticated` may select only
`available_to_help, notify_chat, notify_recovery_status` and update only the last two. So a member
cannot reach another member's row by any direct API request, which is what §5 asks for, and it is
already true.

The directory therefore works the way §5 wants it to: through `security definer` RPCs that return
a hand-written whitelist of fields. `nearby_members()` and `member_profile()` both do this, and
neither returns coordinates — distance is computed server-side and rounded by
`app.coarse_miles()`, measured from `home_location` (the coarse signup location) and never from
`last_location` (the live position). No phone, no email, no pin.

That design does not need replacing. The changes below are to **who is listed**, not to how.

## What the spec changes

### 1. Two opt-in gates have to go

`nearby_members()` and `member_profile()` both require:

```sql
where p.profile_public        -- "other members may see my profile"
  and p.available_to_help     -- "ring me when somebody near me is stuck"
```

- `profile_public` is the toggle §1 removes. UI at `account-form.tsx:291`, copy at
  `messages/{en,es}.json` → `account.profilePublic`.
- `available_to_help` must stop being a **filter** and become a **field**. §2: "Display the
  member's availability to help only when they have enabled that feature" — shown when on, not a
  condition of appearing at all.

### 2. The join is the real bug

```sql
from public.profiles p
join public.responders r on r.user_id = p.user_id
```

An **inner** join. `app.ensure_recovery_profile()` only runs when a member turns availability on,
so a member who never did that has no `responders` row and is invisible to the directory — even
after both gates are removed. "Every active member appears in the member directory" is false until
this is a `left join`, and it would have been the first thing to fail §7 with no obvious cause.

### 3. Gaps that need building, not unblocking

| § | needed | state today |
|---|---|---|
| 2 | search by name | no search at all; **no username/handle column exists** anywhere in `profiles` — searching by one would mean inventing handles |
| 2, 3 | vehicle photographs "marked for community display" | `vehicles` has `photo_path` and `is_primary` but **no community-display flag**; `member_profile()` returns only the primary rig's path |
| 2, 3 | community participation | `community_posts` / `community_comments` / `community_reactions` exist; nothing is surfaced on a profile |
| 6 | report a member | `content_reports.target_kind` is constrained to `('post','comment','trail_condition')` — a member cannot be reported |
| 6 | suspend an abusive account | **no suspension state exists.** `/rules` already tells members "An account that breaks these rules can be suspended", which is currently a promise the schema cannot keep |
| 2 | "send messages where messaging is enabled" | member-to-member messaging does not exist. Recovery threads are per-recovery and participant-scoped. Conditional in the spec's own wording, so nothing is invented here |

### 4. Tests that encode the OLD policy and will have to change

- `supabase/tests/auth_roles_test.sql:102` asserts `profile_public` defaults to false, described as
  "profiles are private until someone chooses otherwise". That is the rule being reversed.
- `supabase/tests/directory_test.sql` is built entirely on the two gates (members named `Bothsy`,
  `Publicity`, `Availa`, `Neither`).
- `supabase/tests/rig_photos_test.sql:54` sets both gates to make its member visible.

Deleting those assertions is not enough — each one existed to protect something. What replaces them
has to protect the same thing under the new rule: that the directory still cannot leak a phone
number, an email address or a coordinate.

### 5. Live functions touching the gate columns

From `pg_proc`, so this is the real list and not a grep of the migrations:

- `profile_public` → `public.member_profile`, `public.nearby_members`. (`app.notify` selects
  `profiles%rowtype`, so it depends on the table's shape but names no column.)
- `available_to_help` → `app.candidates`, `app.may_see_request_photos`, `public.member_profile`,
  `public.nearby_members`, `public.set_available_to_help`, `public.system_health_summary`.

The dispatch uses of `available_to_help` — `app.candidates` and `app.may_see_request_photos` — are
**correct and stay**. §4 is explicit that profile visibility and location-based alerting are
separate concerns: being listed in a directory must not make somebody reachable by the dispatcher,
and turning off availability must still remove them from the ring and from the photographs.

`member_profile()` is defined twice in the migration history; the live one is
`20260928001000_member_rig_photo.sql`, not `20260924000100_nearby_members.sql`. Any change builds
on that one.
