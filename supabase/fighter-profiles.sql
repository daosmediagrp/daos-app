-- ============================================================================
-- DAOS app — Self-serve Martial Artist Profiles (fighter_profiles)
-- Project: daos-app (Supabase) — https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
--
-- HOW TO RUN (Jake / Chat — do this in the Supabase dashboard, NOT in the site):
--   1. Supabase dashboard > SQL Editor > New query.
--   2. Paste this WHOLE file and click Run. It is idempotent (safe to re-run).
--   3. Then run supabase/fighter-profiles-seed.sql the same way (seeds the
--      7 existing fighters as LIVE profiles).
--   4. Create the photo bucket (SQL cannot create buckets):
--        Storage > New bucket > name: profile-photos > Public bucket: ON > Create.
--        The storage policies below are created by this file, so once the
--        bucket exists the policies apply immediately.
--   5. Confirm: Table Editor should show fighter_profiles + fighter_votes,
--      and Storage > Policies should list profile-photos policies.
--
-- WHAT THIS CREATES
--   fighter_profiles : one row per martial artist. status flow:
--     submitted -> in_review -> live   (or rejected)
--     A profile is visible to the public ONLY when status = 'live'.
--   fighter_votes    : one row per vote. UNIQUE (fighter_id, voter_email)
--     enforces one vote per email per fighter. Voter emails are never
--     shown to the public (no SELECT policy on this table at all).
--   cast_fighter_vote() : the ONLY way the public votes. It is a
--     SECURITY DEFINER function, so anonymous visitors can vote by email
--     without any direct write access to the tables (no anon writes).
--   A trigger keeps fighter_profiles.votes_count in sync with fighter_votes.
--
-- APPROVAL (no admin login is built):
--   Jake approves in the dashboard: Table Editor > fighter_profiles >
--   open the row > set status to 'live' (or 'rejected') > Save.
--   To re-check an edited live profile: Table Editor > fighter_profiles >
--   filter needs_review = true, review the changes, then set
--   needs_review = false.
--
-- SECURITY NOTES
--   - Never paste the service_role key anywhere in the site code or GitHub.
--     The site uses only the public anon key; RLS does the protecting.
--   - App users CANNOT change their own profile status: a trigger blocks
--     status changes from the anon/authenticated roles. Jake changes status
--     from the dashboard (postgres role), which the trigger allows.
--   - Seeded profiles (the 7 existing fighters) have user_id NULL and
--     is_seeded = true, so no app user can edit them.
-- ============================================================================

-- Required for citext (case-insensitive voter emails: A@x.com == a@x.com).
create extension if not exists citext;

-- --------------------------------------------------------------------------
-- Tables
-- --------------------------------------------------------------------------
create table if not exists public.fighter_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  slug text not null unique
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  display_name text not null check (char_length(display_name) between 1 and 100),
  style_rank text not null default '' check (char_length(style_rank) <= 200),
  bio text not null default '' check (char_length(bio) <= 2000),
  photo_url text check (photo_url is null or char_length(photo_url) <= 1000),
  status text not null default 'submitted'
    check (status in ('submitted', 'in_review', 'live', 'rejected')),
  needs_review boolean not null default false,
  is_seeded boolean not null default false,
  votes_count integer not null default 0 check (votes_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fighter_votes (
  id uuid primary key default gen_random_uuid(),
  fighter_id uuid not null references public.fighter_profiles (id) on delete cascade,
  voter_email citext not null check (char_length(voter_email) between 3 and 254),
  created_at timestamptz not null default now(),
  unique (fighter_id, voter_email)
);

create index if not exists fighter_votes_fighter_idx
  on public.fighter_votes (fighter_id);
create index if not exists fighter_profiles_live_idx
  on public.fighter_profiles (status, votes_count desc);

-- Keep updated_at fresh on every edit.
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists fighter_profiles_updated_at on public.fighter_profiles;
create trigger fighter_profiles_updated_at
  before update on public.fighter_profiles
  for each row execute function public.set_updated_at();

-- --------------------------------------------------------------------------
-- Guard rails (triggers)
-- --------------------------------------------------------------------------
-- 1) App users may never change a profile's status themselves.
--    The dashboard (postgres role) is exempt, so Jake can still approve.
create or replace function public.block_profile_status_change()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.status is distinct from old.status then
    raise exception 'Profile status can only be changed by DAOS (approval in the dashboard).';
  end if;
  return new;
end;
$$;
drop trigger if exists fighter_profiles_status_guard on public.fighter_profiles;
create trigger fighter_profiles_status_guard
  before update on public.fighter_profiles
  for each row execute function public.block_profile_status_change();

-- 2) Editing a LIVE profile keeps it live but flags it for re-review.
--    (Edits to submitted/in_review profiles do not set the flag.)
create or replace function public.flag_live_profile_edit()
returns trigger language plpgsql as $$
begin
  if old.status = 'live'
     and (new.display_name is distinct from old.display_name
       or new.style_rank is distinct from old.style_rank
       or new.bio is distinct from old.bio
       or new.photo_url is distinct from old.photo_url) then
    new.needs_review = true;
  end if;
  return new;
end;
$$;
drop trigger if exists fighter_profiles_edit_flag on public.fighter_profiles;
create trigger fighter_profiles_edit_flag
  before update on public.fighter_profiles
  for each row execute function public.flag_live_profile_edit();

-- 3) Keep votes_count in sync: every new vote row adds 1. (Votes are
--    never deleted by the app, so no decrement path is needed.)
create or replace function public.bump_votes_count()
returns trigger language plpgsql as $$
begin
  update public.fighter_profiles
     set votes_count = votes_count + 1
   where id = new.fighter_id;
  return new;
end;
$$;
drop trigger if exists fighter_votes_count_bump on public.fighter_votes;
create trigger fighter_votes_count_bump
  after insert on public.fighter_votes
  for each row execute function public.bump_votes_count();

-- --------------------------------------------------------------------------
-- Voting — the only public write path (SECURITY DEFINER function)
-- --------------------------------------------------------------------------
-- Anonymous visitors vote with an email address; they never touch the
-- tables directly. Duplicate votes raise a unique-violation error that
-- the site shows as "You have already voted for this fighter."
create or replace function public.cast_fighter_vote(
  p_fighter_id uuid,
  p_voter_email text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if p_voter_email is null
     or p_voter_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'A valid email address is required to vote.';
  end if;

  select status into v_status
    from public.fighter_profiles
   where id = p_fighter_id;

  if v_status is null then
    raise exception 'Fighter not found.';
  end if;
  if v_status <> 'live' then
    raise exception 'Voting is only open for live profiles.';
  end if;

  insert into public.fighter_votes (fighter_id, voter_email)
  values (p_fighter_id, lower(trim(p_voter_email)));
end;
$$;

-- --------------------------------------------------------------------------
-- Row Level Security
-- --------------------------------------------------------------------------
alter table public.fighter_profiles enable row level security;
alter table public.fighter_votes enable row level security;

-- fighter_profiles: public reads LIVE profiles only.
drop policy if exists "Anyone can read live fighter profiles" on public.fighter_profiles;
create policy "Anyone can read live fighter profiles"
  on public.fighter_profiles for select
  using (status = 'live');

-- fighter_profiles: signed-in users can also read their OWN profile,
-- whatever its status (so they can see Submitted / In review / Live).
drop policy if exists "Owners can read their own fighter profile" on public.fighter_profiles;
create policy "Owners can read their own fighter profile"
  on public.fighter_profiles for select
  using (auth.uid() = user_id);

-- fighter_profiles: signed-in users create ONE profile, always 'submitted'.
drop policy if exists "Members can create their own fighter profile" on public.fighter_profiles;
create policy "Members can create their own fighter profile"
  on public.fighter_profiles for insert
  with check (auth.uid() = user_id and status = 'submitted');

-- fighter_profiles: owners edit only their own, non-seeded profile.
-- (Status changes are blocked by the trigger above; the policy only
--  gates which rows can be touched.)
drop policy if exists "Owners can edit their own fighter profile" on public.fighter_profiles;
create policy "Owners can edit their own fighter profile"
  on public.fighter_profiles for update
  using (auth.uid() = user_id and is_seeded = false)
  with check (auth.uid() = user_id and is_seeded = false);

-- fighter_profiles: nobody deletes profiles from the app.
-- (No DELETE policy: deletes are dashboard-only, if ever.)

-- fighter_votes: NO direct SELECT / INSERT / UPDATE / DELETE policies.
-- Voter emails stay private, and the only write path is cast_fighter_vote().
-- (With RLS enabled and no policies, all direct access is denied.)

-- --------------------------------------------------------------------------
-- Photo storage policies (bucket 'profile-photos' must be created first:
-- Storage > New bucket > profile-photos > Public bucket ON > Create.
-- If the bucket does not exist yet, these policies still create fine and
-- apply as soon as the bucket is made.)
-- --------------------------------------------------------------------------
drop policy if exists "Anyone can view profile photos" on storage.objects;
create policy "Anyone can view profile photos"
  on storage.objects for select
  using (bucket_id = 'profile-photos');

drop policy if exists "Members can upload their own profile photo" on storage.objects;
create policy "Members can upload their own profile photo"
  on storage.objects for insert
  with check (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Members can replace their own profile photo" on storage.objects;
create policy "Members can replace their own profile photo"
  on storage.objects for update
  using (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Members can delete their own profile photo" on storage.objects;
create policy "Members can delete their own profile photo"
  on storage.objects for delete
  using (
    bucket_id = 'profile-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================================
-- Done. Next: run supabase/fighter-profiles-seed.sql, then create the
-- profile-photos bucket if you have not already.
-- ============================================================================
