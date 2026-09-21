-- Winch Up :: expand the role set
--
-- Phase 3 names five roles. Two already exist under different names, and adding synonyms for
-- them would be worse than reusing them -- two enum values meaning "can moderate" is how
-- authorization bugs start. The mapping is therefore:
--
--   spec "Member"            -> member          (new)
--   spec "Recovery Volunteer"-> responder       (existing; the whole dispatch engine keys off it)
--   spec "Business Owner"    -> business_owner  (new)
--   spec "Moderator"         -> moderator       (new)
--   spec "Super Admin"       -> admin           (existing; app.is_admin() already gates every
--                                                admin RPC and writes an audit row)
--
-- `alter type ... add value` cannot be used in the same transaction that uses the new value, so
-- this migration only adds them. Everything that references them is in the next one.

alter type app_role add value if not exists 'member';
alter type app_role add value if not exists 'business_owner';
alter type app_role add value if not exists 'moderator';
