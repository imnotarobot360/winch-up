-- Winch Up :: make account deletion possible
--
-- Seven columns referenced auth.users with no ON DELETE clause, which defaults to NO ACTION.
-- The effect, verified against the database rather than inferred: deleting an account raises
--
--   update or delete on table "users" violates foreign key constraint
--   "audit_log_actor_user_id_fkey" on table "audit_log"
--
-- for any admin who has ever acted, and via request_events.actor_user_id for any volunteer who
-- has ever accepted a job. Phase 3 requires account deletion and Phase 14 requires it again; a
-- delete button that fails on exactly the users most likely to press it is not a delete button.
--
-- SET NULL rather than CASCADE, deliberately. These are attribution columns on history: the
-- audit row, the dispatch event and the blocklist entry are records of things that happened and
-- must survive. What gets erased is the link to the person, not the fact of the action.
-- Everything identifying stays out of these rows already, so a null actor plus the retained
-- action, entity, timestamp and IP is still a usable audit trail.
--
-- Rows the person owns rather than merely touched are handled elsewhere and unchanged:
-- profiles and user_roles cascade, responders.user_id and requests.requester_user_id set null.

set search_path = public, extensions;

alter table app_settings   drop constraint app_settings_updated_by_fkey,
  add constraint app_settings_updated_by_fkey
  foreign key (updated_by) references auth.users (id) on delete set null;

alter table audit_log      drop constraint audit_log_actor_user_id_fkey,
  add constraint audit_log_actor_user_id_fkey
  foreign key (actor_user_id) references auth.users (id) on delete set null;

alter table blocklist      drop constraint blocklist_created_by_fkey,
  add constraint blocklist_created_by_fkey
  foreign key (created_by) references auth.users (id) on delete set null;

alter table request_events drop constraint request_events_actor_user_id_fkey,
  add constraint request_events_actor_user_id_fkey
  foreign key (actor_user_id) references auth.users (id) on delete set null;

alter table requests       drop constraint requests_created_by_fkey,
  add constraint requests_created_by_fkey
  foreign key (created_by) references auth.users (id) on delete set null;

alter table responders     drop constraint responders_approved_by_fkey,
  add constraint responders_approved_by_fkey
  foreign key (approved_by) references auth.users (id) on delete set null;

alter table user_roles     drop constraint user_roles_granted_by_fkey,
  add constraint user_roles_granted_by_fkey
  foreign key (granted_by) references auth.users (id) on delete set null;
