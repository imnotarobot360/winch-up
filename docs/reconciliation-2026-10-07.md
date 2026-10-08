# Reconciling production's migration ledger — 2026-10-07

What was verified, on what evidence, and what is still outstanding. Written because the evidence
otherwise existed only in a terminal scrollback, and the rule for this exercise was that nothing
gets recorded without it.

**Ledger: 139 of 141 recorded. 2 pending.** CI has NOT been re-run — see the last section,
which is now the blocker and is not about the ledger.

## How it started

CI run #185 refused to push: migrations were missing from
`supabase_migrations.schema_migrations`, and `supabase db push` applies every unlisted migration
IN ORDER. `scripts/check-migration-ledger.sh` stopped it. That was the guard working, not a bug --
`20260920000600_rls.sql` opens by revoking every grant in schema public.

The ledger held 73. It now holds 139, and nothing was replayed.

## What each tier of evidence means

| Tier | Count | Evidence |
|---|---|---|
| A | 25 | Every object the migration uniquely creates is present in production |
| B | 30 | A line from its function body found verbatim in `pg_proc.prosrc`, plus its constraints, grants and policies |
| Remainder | 6 | Hand-written checks: column-level grants, an absence, a waiver's text, effects preserved in `app.candidates` |
| Risk decision | 3 | **No catalogue evidence.** Recorded on the owner's explicit decision |
| Applied, then recorded | 2 | Genuinely never applied. Applied by hand, re-verified, then recorded |

Two things were deliberately NOT treated as evidence. `create or replace function` existence: 318
of this repo's statements are those against 52 create-table, so a function existing says nothing
about WHICH migration made it. And any object named by more than one migration, for the same reason.

## A — verified by the objects they create (25)

Production's run emitted 26. Version 20261001000200 is listed under "applied, then
recorded" below instead, since it only joined this tier once it had been applied by hand.

| Version | File |
|---|---|
| `20260922000600` | community.sql |
| `20260923000100` | universal_membership.sql |
| `20260923000150` | offer_states.sql |
| `20260923000200` | assistance_offers.sql |
| `20260923000400` | push.sql |
| `20260923001000` | team_chat_enums.sql |
| `20260923001100` | recovery_participants.sql |
| `20260923001200` | thread_access.sql |
| `20260923001300` | team_membership_sync.sql |
| `20260923001700` | chat_notifications.sql |
| `20260923001900` | sms_suppressed.sql |
| `20260923002100` | message_client_id.sql |
| `20260923002200` | realtime_broadcast.sql |
| `20260923002300` | second_helper.sql |
| `20260924000200` | email_deliveries.sql |
| `20260924000300` | welcome_email.sql |
| `20260927000200` | post_topics.sql |
| `20260928000200` | membership_agreement.sql |
| `20260928000500` | membership_signed_email.sql |
| `20260928000900` | vehicle_photos.sql |
| `20261001001000` | open_directory.sql |
| `20261001001300` | profile_rigs_and_activity.sql |
| `20261001001700` | report_a_member_again.sql |
| `20261001002000` | direct_message_enum.sql |
| `20261001002100` | direct_message_tables.sql |

## B — verified by body markers, grants, policies and constraints (30)

Markers were extracted ONLY where the migration under test is the last thing to touch the function,
counting `pg_get_functiondef` rewrites as touches. Otherwise a later migration having rewritten the
body makes the marker legitimately absent, and its absence would prove nothing.

| Version | File |
|---|---|
| `20260923000250` | inbound_offer.sql |
| `20260923000300` | help_feed.sql |
| `20260923000500` | help_feed_notes.sql |
| `20260923000600` | my_requests.sql |
| `20260923000700` | health_reachable.sql |
| `20260923001400` | participant_actions.sql |
| `20260923001500` | participants_policy_fix.sql |
| `20260923002000` | sms_off.sql |
| `20260923002400` | offers_after_accept.sql |
| `20260923002500` | second_helper_dashboard.sql |
| `20260923002600` | claim_push_url.sql |
| `20260923002700` | thread_location.sql |
| `20260924000100` | nearby_members.sql |
| `20260925000100` | dispatch_sms_on.sql |
| `20260927000100` | signup_name.sql |
| `20260928000300` | membership_rpc.sql |
| `20260928000400` | membership_admin.sql |
| `20260928000600` | membership_gate.sql |
| `20260928000800` | phone_required_again.sql |
| `20260928001000` | member_rig_photo.sql |
| `20260930000100` | security_state.sql |
| `20261001000700` | photos_for_ring.sql |
| `20261001001100` | directory_open_rpcs.sql |
| `20261001001400` | report_and_suspend_members.sql |
| `20261001001500` | content_queue_excludes_members.sql |
| `20261001001600` | reported_members_by_member.sql |
| `20261001001800` | community_report_conflict_target.sql |
| `20261001002200` | notify_direct_message.sql |
| `20261001002300` | direct_message_send.sql |
| `20261001002400` | direct_message_read.sql |

## Remainder — hand-checked, because the generated verifier could not reach them (6)

Column-level grants were the gap: the generated file checked table and function privileges and not
column ones, and two of these do nothing else. One is verified by an ABSENCE, which a verifier that
only looks for things cannot see.

| Version | File |
|---|---|
| `20260923001800` | notify_column_grants.sql |
| `20260928000700` | rules_v2.sql |
| `20261001000500` | exclude_requester.sql |
| `20261001001200` | dispatch_respects_suspension.sql |
| `20261001001900` | drop_profile_public.sql |
| `20261001002500` | direct_message_column_grants.sql |

## Recorded on an explicit risk decision, with no catalogue evidence (3)

| Version | File |
|---|---|
| `20260923001600` | status_team.sql |
| `20260928000100` | phone_optional.sql |
| `20261001000600` | first_ring_ten_miles.sql |

`20261001000600` is the one where WITHHOLDING was the risk. It rewrites
`dispatch.ring_radii_miles` from `[15,30,60]` to `[10,30,60]` and acts only when the value is
exactly `[15,30,60]` -- which is what it is, because the owner chose the 15-mile first wave
deliberately. Replayed, it would silently narrow wave 1 to 10 miles. Recording it removes that
possibility for good.

The other two cannot be distinguished from state: `20260928000100` made `responders.phone`
nullable, which `20260923000100_universal_membership` had already done; `20260923001600` rewrote a
function later rewritten again, and its behaviour is asserted by pgTAP rather than by the catalogue.

## Found genuinely unapplied, applied by hand, then recorded (2)

| Version | File |
|---|---|
| `20261001000100` | emergency_contacts_guide.sql |
| `20261001000200` | post_topic_tips.sql |

**`20261001000200`** adds the `tips` label to `post_topic`. The frontend offers Tips in
`POST_TOPICS`, and `community_post` catches `invalid_text_representation` and falls back to
`'general'` -- so a member posting under Tips had it silently filed as general and the Tips tab was
permanently empty, with no error anywhere. Verified after applying: the absent-object query returned
zero rows and it reads `applied`.

**`20261001000100`** is the more serious one, and only the marker check found it -- it creates no
object, so object presence could not see it. It adds `'emergency'` to `app.ad_slot_allowed`, which
is the only thing preventing adverts on the emergency-guidance pages. Production had
`('stuck', 'safety')` where the repo has `('stuck', 'safety', 'emergency')`: **the emergency
contacts guide was monetizable.** Applied and re-verified, so that is closed.

The two are adjacent -- `000100` and `000200`, both from 1 October. A small batch of that day was
missed, not a single migration. Worth sweeping the rest of that date with the same markers.

## Pending, and why (2)

| Version | File |
|---|---|
| `20261005001000` | manual_dispatch_needs_approval.sql |
| `20261005001100` | stand_down_tells_everyone.sql |

Left out on purpose: both are NEWER than everything recorded, so they are a forward-only apply and
the guard permits them. Re-applying them is a proved no-op -- every guarded block reports "already"
and their own verification queries still read `t`. The intent was for CI's `db push` to apply and
record them, so the whole path could be seen working end to end.

**That intent is now unsafe, for a reason that has nothing to do with the ledger.**

## Why CI must not run yet

`origin/main` carries seven merged PRs -- "Recovery V2" -- that were not in the local checkout when
this reconciliation was done. Recovery V2 deliberately removes the approval gate restored on
2026-10-05, including from `admin_manual_dispatch`, and refuses to deploy if
`available_to_help` still appears in `app.candidates()`.

And the two collide on a version number:

| | |
|---|---|
| local, unpushed | `20261005001100_stand_down_tells_everyone.sql` |
| `origin/main` | `20261005001100_recovery_v2_universal_members.sql` |

The ledger records 14-digit versions, not filenames. So whichever file wins that number leaves the
other marked applied without ever having run. And because `20261005001100` is deliberately
unrecorded, the next `db push` would apply Recovery V2 to production and strip the gates.

Nothing of Recovery V2 has reached production. The ledger is correct and nothing was replayed. The
open question is which direction is intended, and it is not a ledger question.
