-- Winch Up :: somewhere to put a member's photograph
--
-- `profiles.avatar_path` has existed since phase 3 and nothing has ever written to it. The column
-- was granted for UPDATE to `authenticated` all along; what was missing was a bucket, an upload
-- route and a way to render it, so the Avatar component drew initials and said so in a comment.
-- The owner asked for the picture on 2026-10-04.
--
-- A SEPARATE BUCKET, not a prefix inside `vehicle-photos`. Reusing that one would have saved this
-- migration and a hand-apply, and it would be wrong in a way that costs later: a bucket named for
-- rigs holding members' faces is a thing the next person has to discover, and anything that ever
-- sweeps, retains or deletes by bucket would treat a photograph of a person as a photograph of a
-- truck.
--
-- PRIVATE, like the other two. There is no anon policy and there must not be one: the directory is
-- members-only, and a public bucket would put every member's face on a guessable URL that outlives
-- their account. Reads go through a short-lived signed URL minted server-side, exactly as rig
-- photos and recovery photos do.

set search_path = public, extensions;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'member-avatars',
  'member-avatars',
  false,
  -- 5 MB. A phone camera photo is bigger than this, and the browser downscales before upload --
  -- the limit is here so a hand-rolled request cannot park something enormous in the bucket.
  5 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

-- No policies on storage.objects for this bucket, deliberately.
--
-- Uploads are signed by the server (/api/photos/avatar/sign-upload), which derives the path from
-- the SESSION rather than from anything the browser sent -- so one member cannot write into
-- another's folder. Reads are signed server-side too. A policy granting `authenticated` direct
-- access to the bucket would hand every member every other member's object path, which is the one
-- thing the signed-URL approach exists to avoid.

notify pgrst, 'reload schema';
