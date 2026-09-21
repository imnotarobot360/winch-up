-- Winch Up M1 :: storage
--
-- One private bucket for recovery photos.
--
-- There is deliberately NO anon policy. The browser never talks to Storage with the anon key:
--   upload   -> the server mints a short-lived signed upload URL (rate-limited, per request draft)
--   download -> the server mints a short-lived signed download URL, and only for someone the
--               RPC layer already decided may see the photo
-- Photos are compressed and EXIF-stripped client-side before they ever leave the phone.

set search_path = public, extensions;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'request-photos',
  'request-photos',
  false,
  5242880,                                            -- 5 MB, post-compression
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Admins can browse photos directly in the console. Everyone else goes through signed URLs.
drop policy if exists request_photos_admin_read on storage.objects;
create policy request_photos_admin_read on storage.objects
  for select to authenticated
  using (bucket_id = 'request-photos' and app.is_admin());

-- Path convention (enforced by the server, documented here so it stays stable):
--   request-photos/<request_id>/<n>.jpg          once the request row exists
--   request-photos/incoming/<draft_id>/<n>.jpg   while the form is still being filled in
-- `incoming/` is swept by the cleanup job for anything older than 24 h with no request.
