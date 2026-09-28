# The membership agreement: what is built, and what only a lawyer can finish

Written 2026-09-28.

## The state of play

Everything the spec asked for is built and tested **except the agreement itself**, which is not
mine to write.

The machinery ships **switched off**. `membership.required` is `false`, no agreement is
published, and with no agreement published the gate cannot close even if the setting is turned
on. Today the app behaves exactly as it did before any of this existed: nobody is prompted,
nobody is blocked, and `/agreement` says the agreement has not been published yet.

That is deliberate, and it is what requirement 9 describes — *"once the approved agreement
becomes effective."*

## Why there is no agreement text in here

The spec calls for an attorney-approved Membership, Assumption of Risk and Release of Liability
Agreement. There is no such text. Every legal document in this database still reads
`PLACEHOLDER - REVIEW WITH LAWYER`, and `legal.review_status` says so publicly.

Writing one would have been easy and wrong. A release of liability for a service where
volunteers drive to strangers at night and put a loaded winch line on someone else's vehicle is
exactly the document that has to be written by somebody who can be held responsible for it. A
release that does not hold up is **worse than having none**, because people rely on it — the
volunteer who goes out believing they are covered is the person a bad release hurts.

So: the versioning, hashing, signing, records, admin screens and gate are all real and all
tested. The words are a blank you fill in.

## What to hand the lawyer

They need to know what the product actually does, or the agreement will describe something else:

- **Volunteers, not a service.** Nobody is dispatched, nobody is obliged to go, and nobody is
  vetted or licensed. A member choosing to help is the only qualification.
- **Every member is both.** There is no separate "requester" and "volunteer" account. One
  agreement covers asking for help and offering it, because one person does both.
- **Winch Up does not supervise a recovery** and does not guarantee anyone will come.
- **Texas**, and specifically the Houston area to begin with.
- **Minors.** The app has no age gate today. Ask them whether one is needed, and what happens
  for a member under 18. This is an open question, not a solved one.
- **Two languages.** English and Spanish, both binding, both stored. Ask which governs if they
  disagree.

## Publishing it, once you have it

1. Sign in as an admin and open **Admin → Agreement**.
2. Paste the English and the Spanish. Both are required; each must be at least 20 characters.
3. Leave **"Members who signed an earlier version must sign this one"** ticked for the first
   version and for any material change. Untick it only for a correction that does not change
   what somebody is agreeing to — a typo, a formatting fix. Getting this wrong in the safe
   direction just asks people to re-sign; getting it wrong in the other direction means members
   are bound by words they never saw.
4. Press **Publish**. The version number is assigned by the database, the previous version is
   retired, and a SHA-256 of both language bodies together is computed and stored.

Publishing does **not** turn on the gate. Members will start seeing the prompt and can sign, but
nobody is blocked yet. That is usually what you want for a week or two.

## Turning the gate on

**Admin → Settings**, set `membership.required` to `true`.

From that moment an unsigned member cannot file a recovery request or offer to help. They can
still sign in, read the community, and change their settings — and the refusal, in both flows,
links straight to the agreement.

Before you do this, check **Admin → Agreement** and confirm a version is in force. Turning the
setting on with nothing published does nothing at all, by design, but it is worth knowing which
of the two you are looking at.

## What the record keeps

Per signature: the member's account, their typed legal name, their typed signature, the version,
**the hash of the exact document they signed**, the timestamp, the IP address, the user agent,
the language, and which client it came from.

The hash is the point. A signed agreement's text cannot be edited or deleted — a database
trigger refuses it — so the hash on the signature and the hash on the document must always
match. The admin screen shows `hash_intact` per version and will say so loudly if they ever
diverge. They should not be able to.

## Things that are deliberately not here

- **No unpublish and no delete.** Requirement 13 keeps historical versions. A version somebody
  signed is theirs forever; superseding it is the only move.
- **The agreement is not emailed in full.** The confirmation carries the version, the date, the
  name signed and a hash prefix, and links to the exact version. A second copy in an inbox is a
  copy that can drift from the signed one, and nobody reads a liability release in an email.
- **Signing does not change how anyone is contacted.** SMS, email and push consent are separate
  and stay separate — requirement 15. This is stated on the signing page and again in the
  confirmation email, because the whole point of separating them is that people are told.
- **No age gate.** See above; it is a question for the lawyer.

## If you need to check the state from SQL

```sql
select version, is_current, effective_at, requires_resignature,
       left(body_hash, 16) as hash,
       (select count(*) from membership_signatures s where s.agreement_version = a.version) as signed
  from membership_agreements a
 order by version desc;

select value as gate_on from app_settings where key = 'membership.required';
```
