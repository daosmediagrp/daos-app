-- DAOS video submissions (Jake, Nov 19, 2026): members submit a
-- YouTube/Vimeo link or an uploaded file; nothing is public until
-- DAOS staff approve it in the app's review queue. Creators confirm
-- rights at submit time (rights_confirmed + rights_agreed_at).
-- Additive only; safe to re-run.

create table if not exists public.video_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  creator_name text not null default '',
  title text not null,
  category text not null default 'Other',
  description text not null default '',
  source_type text not null default 'link' check (source_type in ('link','upload')),
  video_url text not null default '',
  storage_path text,
  website text,
  social text,
  rights_confirmed boolean not null default false,
  rights_agreed_at timestamptz,
  status text not null default 'pending' check (status in ('pending','approved','rejected','edits')),
  review_note text,
  published_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists video_submissions_status_idx on public.video_submissions (status, created_at desc);
create index if not exists video_submissions_user_idx on public.video_submissions (user_id, created_at desc);

alter table public.video_submissions enable row level security;

-- Creators can submit their own videos.
drop policy if exists "videos insert own" on public.video_submissions;
create policy "videos insert own" on public.video_submissions
  for insert to authenticated
  with check (auth.uid() = user_id and rights_confirmed = true);

-- Creators can see all of their own submissions (any status).
drop policy if exists "videos select own" on public.video_submissions;
create policy "videos select own" on public.video_submissions
  for select to authenticated
  using (auth.uid() = user_id);

-- Anyone (including signed-out web visitors) can see approved videos.
drop policy if exists "videos select approved" on public.video_submissions;
create policy "videos select approved" on public.video_submissions
  for select to anon, authenticated
  using (status = 'approved');

-- DAOS staff (profiles.is_staff) can see the full review queue.
drop policy if exists "videos staff select" on public.video_submissions;
create policy "videos staff select" on public.video_submissions
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_staff));

-- DAOS staff can approve / reject / request edits.
drop policy if exists "videos staff update" on public.video_submissions;
create policy "videos staff update" on public.video_submissions
  for update to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_staff))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_staff));

-- Storage: a public 'videos' bucket for uploaded files (200 MB cap).
insert into storage.buckets (id, name, public, file_size_limit)
values ('videos', 'videos', true, 209715200)
on conflict (id) do nothing;

drop policy if exists "videos storage read" on storage.objects;
create policy "videos storage read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'videos');

drop policy if exists "videos storage insert own" on storage.objects;
create policy "videos storage insert own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "videos storage delete own" on storage.objects;
create policy "videos storage delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);
