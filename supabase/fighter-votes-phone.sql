-- ============================================================================
-- fighter-votes-phone.sql — votes now require a PHONE NUMBER as well as an
-- email (Jake, Nov 7, 2026). One vote per email AND one vote per phone number,
-- per fighter.
--
-- RUN ORDER: run AFTER supabase/fighter-profiles.sql (the base migration).
-- The site change that goes with this (phone input + p_voter_phone in the
-- RPC call) must be pushed only AFTER this migration has run in Supabase —
-- the old 2-argument cast_fighter_vote() is dropped here, so the old site
-- code would fail against the new function signature.
--
-- What changes:
--   1. fighter_votes gains a nullable voter_phone column. Nullable so the
--      3 existing votes (Jorge 2, Aker 1 — no phone numbers on file) stay
--      valid.
--   2. A partial unique index (fighter_id, voter_phone) WHERE voter_phone
--      IS NOT NULL: one vote per phone number, per fighter.
--   3. cast_fighter_vote() is replaced with a 3-argument version
--      (p_fighter_id, p_voter_email, p_voter_phone). It validates the email
--      exactly as before, PLUS validates the phone (digits only, 7–15
--      digits after stripping non-digits). Duplicate email and duplicate
--      phone are rejected with distinct messages, which the site shows
--      as-is.
--   4. Nothing else changes: SECURITY DEFINER, set search_path = public,
--      live-fighter checks, and the votes_count trigger are all as before.
--      Voter phones are stored only in fighter_votes, which has no public
--      SELECT policy — same privacy as voter emails.
-- ============================================================================

-- 1) Phone column (nullable — existing votes have no phone on file).
alter table public.fighter_votes
  add column if not exists voter_phone text;

-- 2) One vote per phone number, per fighter (only where a phone is present).
create unique index if not exists fighter_votes_phone_unique
  on public.fighter_votes (fighter_id, voter_phone)
  where voter_phone is not null;

-- 3) Replace the vote function with the 3-argument version.
--    CREATE OR REPLACE cannot change the argument list, so drop the old
--    2-argument function first.
drop function if exists public.cast_fighter_vote(uuid, text);

create or replace function public.cast_fighter_vote(
  p_fighter_id uuid,
  p_voter_email text,
  p_voter_phone text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_phone text;
  v_constraint text;
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

  select status into v_status
    from public.fighter_profiles
   where id = p_fighter_id;

  if v_status is null then
    raise exception 'Fighter not found.';
  end if;
  if v_status <> 'live' then
    raise exception 'Voting is only open for live profiles.';
  end if;

  begin
    insert into public.fighter_votes (fighter_id, voter_email, voter_phone)
    values (p_fighter_id, lower(trim(p_voter_email)), v_phone);
  exception when unique_violation then
    -- Tell the voter which rule they hit: the phone index is named
    -- fighter_votes_phone_unique; anything else is the email unique.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'fighter_votes_phone_unique' then
      raise exception 'This phone number has already voted for this fighter.';
    else
      raise exception 'This email has already voted for this fighter.';
    end if;
  end;
end;
$$;
