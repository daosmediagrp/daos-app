-- ============================================================================
-- DAOS app — Paid submissions: $5 community events / seminars / tournaments
-- and $5 song submissions (DAOS Radio WPAT 930 AM)
-- Project: daos-app (Supabase) — https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
--
-- HOW TO RUN (Jake / Chat — do this in the Supabase dashboard, NOT in the site):
--   1. Run supabase-schema.sql, supabase/fighter-profiles.sql and
--      supabase/social-layer.sql first if they have not been run yet,
--      then this file. Each file is idempotent (safe to re-run).
--   2. Supabase dashboard > SQL Editor > New query > paste this WHOLE
--      file and click Run.
--   3. Confirm: Table Editor should show community_events and
--      song_submissions.
--
-- WHAT THIS CREATES
--   community_events : one row per $5 listing. type is 'event',
--     'seminar', or 'tournament'. status flow:
--       submitted -> live   (or rejected)
--     A listing is visible to the public ONLY when status = 'live'.
--     Live tournaments also show in the Tournaments tab.
--   song_submissions : one row per $5 song. status flow:
--       submitted -> selected   (or rejected)
--     A song is visible to the public ONLY when status = 'selected'.
--     Best songs (clean versions only) may get placed on
--     DAOS Radio WPAT 930 AM.
--   payer_email / payment_ref : who paid and (once Stripe is wired up)
--     the Stripe reference. v1 has NO webhook — the site saves the
--     listing as 'submitted' after the member says they paid, and Jake
--     matches payer_email against Stripe when approving. See
--     PAID-SUBMISSIONS.md.
--
-- APPROVAL (no admin login is built):
--   Jake approves in the dashboard: Table Editor > community_events >
--   open the row > set status to 'live' (or 'rejected') > Save.
--   Table Editor > song_submissions > set status to 'selected'
--   (or 'rejected') > Save.
--
-- SECURITY NOTES
--   - Never paste the service_role key anywhere in the site code or GitHub.
--     The site uses only the public anon key; RLS does the protecting.
--   - App users CANNOT change their own listing status: a trigger blocks
--     status changes from the anon/authenticated roles. Jake changes status
--     from the dashboard (postgres role), which the trigger allows.
--   - Owners can only edit their own listing while it is still
--     'submitted' (the RLS update policy enforces this).
-- ============================================================================

-- --------------------------------------------------------------------------
-- Tables
-- --------------------------------------------------------------------------
create table if not exists public.community_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  type text not null
    check (type in ('event', 'seminar', 'tournament')),
  title text not null check (char_length(title) between 1 and 100),
  event_date timestamptz not null,
  location text not null default '' check (char_length(location) <= 300),
  description text not null default '' check (char_length(description) <= 2000),
  link text check (link is null or char_length(link) <= 1000),
  status text not null default 'submitted'
    check (status in ('submitted', 'live', 'rejected')),
  payer_email text check (payer_email is null or char_length(payer_email) between 3 and 254),
  payment_ref text check (payment_ref is null or char_length(payment_ref) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.song_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  song_title text not null check (char_length(song_title) between 1 and 100),
  artist_name text not null check (char_length(artist_name) between 1 and 100),
  stream_url text not null check (char_length(stream_url) <= 1000),
  status text not null default 'submitted'
    check (status in ('submitted', 'selected', 'rejected')),
  payer_email text check (payer_email is null or char_length(payer_email) between 3 and 254),
  payment_ref text check (payment_ref is null or char_length(payment_ref) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists community_events_status_date_idx
  on public.community_events (status, event_date);
create index if not exists community_events_type_date_idx
  on public.community_events (type, event_date);
create index if not exists song_submissions_status_created_idx
  on public.song_submissions (status, created_at desc);

-- Keep updated_at fresh on every edit. (Also defined in
-- fighter-profiles.sql and social-layer.sql; create or replace keeps
-- this file standalone.)
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists community_events_updated_at on public.community_events;
create trigger community_events_updated_at
  before update on public.community_events
  for each row execute function public.set_updated_at();
drop trigger if exists song_submissions_updated_at on public.song_submissions;
create trigger song_submissions_updated_at
  before update on public.song_submissions
  for each row execute function public.set_updated_at();

-- --------------------------------------------------------------------------
-- Guard rails (triggers)
-- --------------------------------------------------------------------------
-- App users may never change a listing's status themselves.
-- The dashboard (postgres role) is exempt, so Jake can still approve.
create or replace function public.block_event_status_change()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.status is distinct from old.status then
    raise exception 'Listing status can only be changed by DAOS (approval in the dashboard).';
  end if;
  return new;
end;
$$;
drop trigger if exists community_events_status_guard on public.community_events;
create trigger community_events_status_guard
  before update on public.community_events
  for each row execute function public.block_event_status_change();

create or replace function public.block_song_status_change()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.status is distinct from old.status then
    raise exception 'Song status can only be changed by DAOS (approval in the dashboard).';
  end if;
  return new;
end;
$$;
drop trigger if exists song_submissions_status_guard on public.song_submissions;
create trigger song_submissions_status_guard
  before update on public.song_submissions
  for each row execute function public.block_song_status_change();

-- --------------------------------------------------------------------------
-- Row Level Security
-- --------------------------------------------------------------------------
alter table public.community_events enable row level security;
alter table public.song_submissions enable row level security;

-- community_events: public reads LIVE listings only.
drop policy if exists "Anyone can read live community events" on public.community_events;
create policy "Anyone can read live community events"
  on public.community_events for select
  using (status = 'live');

-- community_events: signed-in users can also read their OWN listings,
-- whatever the status (so they can see Submitted / Live / Rejected).
drop policy if exists "Owners can read their own community events" on public.community_events;
create policy "Owners can read their own community events"
  on public.community_events for select
  using (auth.uid() = user_id);

-- community_events: signed-in users submit their own listing, always 'submitted'.
drop policy if exists "Members can submit their own event" on public.community_events;
create policy "Members can submit their own event"
  on public.community_events for insert
  with check (auth.uid() = user_id and status = 'submitted');

-- community_events: owners edit only their own listing while it is still
-- 'submitted'. (Status changes are blocked by the trigger above.)
drop policy if exists "Owners can edit their own submitted event" on public.community_events;
create policy "Owners can edit their own submitted event"
  on public.community_events for update
  using (auth.uid() = user_id and status = 'submitted')
  with check (auth.uid() = user_id and status = 'submitted');

-- community_events: nobody deletes listings from the app.
-- (No DELETE policy: deletes are dashboard-only, if ever.)

-- song_submissions: public reads SELECTED songs only.
drop policy if exists "Anyone can read selected songs" on public.song_submissions;
create policy "Anyone can read selected songs"
  on public.song_submissions for select
  using (status = 'selected');

-- song_submissions: signed-in users can also read their OWN submissions,
-- whatever the status.
drop policy if exists "Owners can read their own song submissions" on public.song_submissions;
create policy "Owners can read their own song submissions"
  on public.song_submissions for select
  using (auth.uid() = user_id);

-- song_submissions: signed-in users submit their own song, always 'submitted'.
drop policy if exists "Members can submit their own song" on public.song_submissions;
create policy "Members can submit their own song"
  on public.song_submissions for insert
  with check (auth.uid() = user_id and status = 'submitted');

-- song_submissions: owners edit only their own submission while it is still
-- 'submitted'. (Status changes are blocked by the trigger above.)
drop policy if exists "Owners can edit their own submitted song" on public.song_submissions;
create policy "Owners can edit their own submitted song"
  on public.song_submissions for update
  using (auth.uid() = user_id and status = 'submitted')
  with check (auth.uid() = user_id and status = 'submitted');

-- song_submissions: nobody deletes submissions from the app.
-- (No DELETE policy: deletes are dashboard-only, if ever.)

-- ============================================================================
-- Done. Next: fill in the Stripe payment links in the site code
-- (STRIPE_EVENT_PAYMENT_LINK / STRIPE_SONG_PAYMENT_LINK in
-- facebook-index.html) once Stripe is connected, then approve the
-- GitHub push so the paid-submission buttons go live with the site.
-- Sanity check (run separately if you want to verify):
--   select count(*) from public.community_events;
--   select count(*) from public.song_submissions;
-- ============================================================================
