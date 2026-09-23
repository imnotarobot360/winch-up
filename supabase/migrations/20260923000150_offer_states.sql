-- Winch Up :: the two dispatch states an offer needs
--
-- This file exists only to add enum values, and it is separate for a reason worth keeping.
--
-- Every migration here is applied as one transaction -- that is how the Supabase SQL editor runs
-- a paste, and how the CLI runs a file. Postgres 12 and later will accept `alter type ... add
-- value` inside a transaction, but the new label cannot be USED until that transaction commits.
-- So a single file that adds 'offered' and then writes a check constraint or a default or a
-- backfill mentioning 'offered' fails, with an error that reads like the value was never added.
--
-- Function bodies are safe -- they are text at creation time and are not resolved until they run
-- -- which is why 20260923000200 can reference these freely. Splitting the file anyway means
-- nobody has to remember that distinction the next time a state is added.
--
--   offered      a volunteer has put their hand up and the requester has not decided yet. This is
--                the state that did not exist before: a dispatch used to go straight from 'sent'
--                to 'accepted', because the first volunteer to reply took the job. Now the
--                requester chooses, so there is a waiting room.
--
--   passed_over  the requester picked somebody else. Distinct from 'declined', which is the
--                volunteer saying no, and from 'superseded', which is the system standing down a
--                ring. Who said no matters: it is the difference between "you were not needed"
--                and "you did not answer", and a volunteer's history should not record the first
--                as the second.

set search_path = public, extensions;

alter type dispatch_state add value if not exists 'offered';
alter type dispatch_state add value if not exists 'passed_over';

-- The timeline needs words for the three things that can now happen and could not before.
-- request_event_type is a closed enum on purpose -- the timeline is rendered from it and an
-- unknown value would surface to somebody as a blank row -- so new events are added here rather
-- than by loosening the column.
--
--   responder_offered   a volunteer put their hand up. Private: the requester sees offers in the
--                       offers panel, and a public timeline entry for every offer would turn the
--                       shared status link into a list of who is nearby.
--   responder_withdrew  they took their hand down again before being chosen.
--   offer_declined      the requester passed on this one.

alter type request_event_type add value if not exists 'responder_offered';
alter type request_event_type add value if not exists 'responder_withdrew';
alter type request_event_type add value if not exists 'offer_declined';
