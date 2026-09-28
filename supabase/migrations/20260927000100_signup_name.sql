-- Winch Up :: the name somebody types at signup actually becomes their name
--
-- Screen 3 of the design reference asks for Full Name at signup. The field was never there, so a
-- new member had no display name until they found /account and set one -- which meant the name a
-- volunteer sees when they are matched was blank for everybody who had not been through the
-- settings screen.
--
-- The browser puts it in raw_user_meta_data at signUp, the same way it already does the locale.
-- This is what moves it onto the profile row that the rest of the app reads.
--
-- WHY THE GUARD MATTERS MORE THAN THE FEATURE
--
-- profiles.display_name has a CHECK: one to sixty characters, and not contains_contact_info().
-- That constraint exists because a display name is shown to strangers and is the obvious place to
-- put "call me on 555-1234". But this trigger runs INSIDE the transaction that creates the
-- account, so a name that fails the check would abort the INSERT into auth.users and the signup
-- would fail outright -- with an error about a constraint, on a form whose only fault was that
-- somebody typed their phone number in the name box.
--
-- So the name is validated here and DROPPED if it does not pass. A missing display name is a
-- blank field on a profile page. A failed signup is a member who never joined.

set search_path = public, extensions;

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_name text;
begin
  v_name := btrim(coalesce(new.raw_user_meta_data ->> 'full_name', ''));

  -- Everything the CHECK would reject, rejected here instead, where it costs a null rather than
  -- the whole signup.
  if v_name = ''
     or length(v_name) < 1
     or length(v_name) > 60
     or public.contains_contact_info(v_name)
  then
    v_name := null;
  end if;

  insert into profiles (user_id, display_name) values (new.id, v_name)
  on conflict (user_id) do nothing;

  insert into user_roles (user_id, role) values (new.id, 'member')
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;

comment on function app.handle_new_user() is
  'Creates the profile and member role for a new account. Copies full_name from the signup '
  'form''s metadata into display_name, dropping it if it would fail the display_name CHECK -- a '
  'bad name must cost a blank field, never a failed signup.';
