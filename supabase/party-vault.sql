-- Party Vault photo/video marketplace (Jake, Nov 26, 2026).
-- Photographers upload event photos/videos; originals stay in a
-- PRIVATE bucket, watermarked previews are public. Members buy with
-- DAOS Points (photo 10 pts / $10, video 25 pts / $25 — set per row
-- at upload). A purchase row unlocks a signed download of the
-- original via storage RLS. Additive only — safe to re-run.

-- Approved photographers (staff sets this flag, like is_staff).
alter table public.profiles
  add column if not exists is_photographer boolean not null default false;

create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  event_slug text not null default 'daos-party-dec-5',
  media_type text not null default 'photo' check (media_type in ('photo','video')),
  original_key text not null,
  preview_key text not null,
  price_points int not null check (price_points > 0),
  caption text,
  tags text,
  status text not null default 'live' check (status in ('live','pending','hidden')),
  created_at timestamptz not null default now()
);

create index if not exists photos_event_idx
  on public.photos (event_slug, created_at desc);
create index if not exists photos_owner_idx
  on public.photos (owner_id, created_at desc);

create table if not exists public.photo_fingerprints (
  photo_id uuid primary key references public.photos (id) on delete cascade,
  sha256 text,
  phash text
);

create table if not exists public.photo_purchases (
  id bigint generated always as identity primary key,
  photo_id uuid not null references public.photos (id) on delete cascade,
  buyer_id uuid not null references auth.users (id) on delete cascade,
  points_paid int not null check (points_paid > 0),
  created_at timestamptz not null default now(),
  unique (photo_id, buyer_id)
);

create table if not exists public.copyright_reports (
  id bigint generated always as identity primary key,
  photo_id uuid not null references public.photos (id) on delete cascade,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  suspected_url text,
  note text,
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);

-- ---- RLS: photos ----
alter table public.photos enable row level security;

drop policy if exists "Anyone can view live photos" on public.photos;
create policy "Anyone can view live photos"
  on public.photos for select
  using (status = 'live');

drop policy if exists "Photographers can add their own photos" on public.photos;
create policy "Photographers can add their own photos"
  on public.photos for insert
  with check (auth.uid() = owner_id
    and exists (select 1 from public.profiles p
                where p.id = auth.uid() and p.is_photographer));

drop policy if exists "Owners can update their own photos" on public.photos;
create policy "Owners can update their own photos"
  on public.photos for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

drop policy if exists "Owners can delete their own photos" on public.photos;
create policy "Owners can delete their own photos"
  on public.photos for delete
  using (auth.uid() = owner_id);

drop policy if exists "Staff can manage all photos" on public.photos;
create policy "Staff can manage all photos"
  on public.photos for all
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff))
  with check (true);

-- ---- RLS: fingerprints ----
alter table public.photo_fingerprints enable row level security;

drop policy if exists "Photographers can add fingerprints for their photos" on public.photo_fingerprints;
create policy "Photographers can add fingerprints for their photos"
  on public.photo_fingerprints for insert
  with check (exists (select 1 from public.photos ph
                      where ph.id = photo_id and ph.owner_id = auth.uid()));

drop policy if exists "Owners and staff can read fingerprints" on public.photo_fingerprints;
create policy "Owners and staff can read fingerprints"
  on public.photo_fingerprints for select
  using (exists (select 1 from public.photos ph
                 where ph.id = photo_id and ph.owner_id = auth.uid())
      or exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

-- ---- RLS: purchases ----
alter table public.photo_purchases enable row level security;

drop policy if exists "Members can buy photos" on public.photo_purchases;
create policy "Members can buy photos"
  on public.photo_purchases for insert
  with check (auth.uid() = buyer_id);

drop policy if exists "Buyers can read their own purchases" on public.photo_purchases;
create policy "Buyers can read their own purchases"
  on public.photo_purchases for select
  using (auth.uid() = buyer_id);

drop policy if exists "Photographers can read sales of their photos" on public.photo_purchases;
create policy "Photographers can read sales of their photos"
  on public.photo_purchases for select
  using (exists (select 1 from public.photos ph
                 where ph.id = photo_id and ph.owner_id = auth.uid()));

drop policy if exists "Staff can read all purchases" on public.photo_purchases;
create policy "Staff can read all purchases"
  on public.photo_purchases for select
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

-- ---- RLS: copyright reports ----
alter table public.copyright_reports enable row level security;

drop policy if exists "Members can report stolen photos" on public.copyright_reports;
create policy "Members can report stolen photos"
  on public.copyright_reports for insert
  with check (auth.uid() = reporter_id);

drop policy if exists "Reporters can read their own reports" on public.copyright_reports;
create policy "Reporters can read their own reports"
  on public.copyright_reports for select
  using (auth.uid() = reporter_id);

drop policy if exists "Staff can manage all reports" on public.copyright_reports;
create policy "Staff can manage all reports"
  on public.copyright_reports for all
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff))
  with check (true);

-- ---- Storage buckets ----
insert into storage.buckets (id, name, public)
values ('vault-originals', 'vault-originals', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('vault-previews', 'vault-previews', true)
on conflict (id) do nothing;

-- ---- Storage policies ----
-- Previews: public read; photographers upload.
drop policy if exists "Vault previews are public" on storage.objects;
create policy "Vault previews are public"
  on storage.objects for select
  using (bucket_id = 'vault-previews');

drop policy if exists "Photographers can upload previews" on storage.objects;
create policy "Photographers can upload previews"
  on storage.objects for insert
  with check (bucket_id = 'vault-previews'
    and exists (select 1 from public.profiles p
                where p.id = auth.uid() and p.is_photographer));

-- Originals: photographers upload into their own folder
-- (<owner_id>/<photo_id>-<filename>); read allowed for the owner
-- and for members with a purchase row for that photo.
drop policy if exists "Photographers can upload originals" on storage.objects;
create policy "Photographers can upload originals"
  on storage.objects for insert
  with check (bucket_id = 'vault-originals'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles p
                where p.id = auth.uid() and p.is_photographer));

drop policy if exists "Owners and buyers can read originals" on storage.objects;
create policy "Owners and buyers can read originals"
  on storage.objects for select
  using (bucket_id = 'vault-originals'
    and ((storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.photo_purchases pp
                 join public.photos ph on ph.id = pp.photo_id
                 where pp.buyer_id = auth.uid() and ph.original_key = name)
      or exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff)));
