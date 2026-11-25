-- ============================================================================
-- artist-votes.sql — public voting for the Top Artists rankings (Jake,
-- Nov 25, 2026). Mirrors the fighter vote system (fighter-profiles.sql +
-- fighter-votes-phone.sql):
--   * artist_votes: one row per vote, keyed by artist_name (the same key the
--     rankings group selected songs by). UNIQUE (artist_name, voter_email)
--     plus a partial unique index on (artist_name, voter_phone): one vote
--     per email AND one vote per phone number, per artist.
--   * cast_artist_vote(): the ONLY public write path (SECURITY DEFINER).
--     Validates email + phone exactly like cast_fighter_vote(), resolves the
--     canonical artist name from song_submissions (status = 'selected'), and
--     rejects duplicates with distinct messages the site shows as-is.
--   * get_artist_vote_counts(): public vote totals per artist, without
--     exposing voter emails/phones.
--   * artist_votes has RLS enabled with NO policies: voter emails and phones
--     stay private, same as fighter_votes.
--
-- RUN ORDER: run this in the Supabase SQL Editor BEFORE pushing the site
-- change that calls these functions (the new site code calls
-- cast_artist_vote / get_artist_vote_counts, which do not exist until this
-- migration runs). The old site code never calls them, so running this first
-- is safe.
-- ============================================================================

create table if not exists public.artist_votes (
  id uuid primary key default gen_random_uuid(),
  artist_name text not null check (char_length(artist_name) between 1 and 100),
  voter_email text not null check (char_length(voter_email) between 3 and 254),
  voter_phone text,
  created_at timestamptz not null default now(),
  unique (artist_name, voter_email)
);

create unique index if not exists artist_votes_phone_unique
  on public.artist_votes (artist_name, voter_phone)
  where voter_phone is not null;

create index if not exists artist_votes_artist_idx
  on public.artist_votes (artist_name);

alter table public.artist_votes enable row level security;
-- artist_votes: NO direct SELECT / INSERT / UPDATE / DELETE policies.
-- Voter emails and phones stay private; the only write path is
-- cast_artist_vote() and the only read path is get_artist_vote_counts().

create or replace function public.cast_artist_vote(
  p_artist_name text,
  p_voter_email text,
  p_voter_phone text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_constraint text;
  v_name text;
begin
  if p_voter_email is null
     or p_voter_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'A valid email address is required to vote.';
  end if;

  -- Strip everything but digits (lets voters type +1 (555) 123-4567, etc.).
  v_phone := regexp_replace(coalesce(p_voter_phone, ''), '[^0-9]', '', 'g');
  if char_length(v_phone) < 7 or char_length(v_phone) > 15 then
    raise exception 'A valid phone number is required to vote.';
  end if;

  -- Resolve the canonical artist name from the selected songs, so votes
  -- always land on the exact name the rankings display.
  select artist_name into v_name
    from public.song_submissions
   where status = 'selected'
     and lower(artist_name) = lower(trim(coalesce(p_artist_name, '')))
   limit 1;

  if v_name is null then
    raise exception 'Artist not found.';
  end if;

  begin
    insert into public.artist_votes (artist_name, voter_email, voter_phone)
    values (v_name, lower(trim(p_voter_email)), v_phone);
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'artist_votes_phone_unique' then
      raise exception 'This phone number has already voted for this artist.';
    else
      raise exception 'This email has already voted for this artist.';
    end if;
  end;
end;
$$;

create or replace function public.get_artist_vote_counts()
returns table (artist_name text, votes bigint)
language sql
security definer
set search_path = public
as $$
  select artist_name, count(*) as votes
    from public.artist_votes
   group by artist_name;
$$;

grant execute on function public.cast_artist_vote(text, text, text) to anon, authenticated;
grant execute on function public.get_artist_vote_counts() to anon, authenticated;

-- ============================================================================
-- Done. Sanity checks (run separately if you want to verify):
--   select * from public.get_artist_vote_counts();
--   select count(*) from public.artist_votes;
-- ============================================================================
