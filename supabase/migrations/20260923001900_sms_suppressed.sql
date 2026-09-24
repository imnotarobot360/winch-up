-- Winch Up :: a word for an outbound message that was deliberately not sent
--
-- ALTER TYPE ... ADD VALUE only, and therefore its own file: the label cannot be USED in the
-- transaction that adds it, and 20260923002000 uses it in every branch of app.queue_sms.
--
-- WHY A STATE RATHER THAN NOT WRITING THE ROW
--
-- Recovery SMS is being switched off (the phase spec's section 4). The tempting version of that
-- is for app.queue_sms to return null and write nothing, which leaves no trace of the messages
-- the system decided not to send -- and "why did nobody get told" is exactly the question
-- somebody will ask at 11pm.
--
-- 'suppressed' is terminal and the drain never looks at it. Turning SMS back on affects messages
-- queued after the flip and does not release a backlog, which is the behaviour you want from a
-- switch that might be off for a month: nobody gets a text about a recovery that finished in
-- August.
--
-- The existing states are all Twilio's view of a message that was actually handed over. This one
-- is ours, and it is the only state that means the outbox worked correctly by staying quiet.

set search_path = public, extensions;

alter type sms_state add value if not exists 'suppressed';
