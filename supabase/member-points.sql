-- Points + levels for the DAOS app (Jake, Nov 19, 2026).
-- Share = 5 points, Connect = 10 points. Daily caps so it can't
-- be farmed: only 5 shares and 10 connects a day count.
-- Members level up: L1 0 / L2 100 / L3 250 / L4 500 / L5 1,000
-- (names in the app: Rookie / Connector / Networker / Ambassador /
-- DAOS Legend).
-- At 1,000 points (Level 5) a member unlocks a FREE blog post
-- write-up; the claim lands in point_reward_claims for DAOS staff
-- to fulfill (nothing auto-publishes).
-- Points for contacts RECEIVED on a member's card are not stored
-- here — the app counts them live from card_contacts (10 pts each,
-- capped at 10 connects per day).
-- Additive only — safe to re-run.

create table if not exists public.point_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  action text not null check (action in
    ('share_card','share_post','share_page','contact_made')),
  points int not null check (points > 0 and points <= 100),
  ref_key text,
  created_at timestamptz not null default now()
);

create index if not exists point_events_user_idx
  on public.point_events (user_id, created_at desc);

-- Anti-farm: one award per member + action + item per day.
create unique index if not exists point_events_daily_unique
  on public.point_events (user_id, action, coalesce(ref_key, ''), ((created_at)::date));

-- Server-side daily caps: at most 5 share events and 10 connect
-- (contact_made) events per member per day are stored; inserts
-- beyond the cap are silently skipped.
create or replace function public.enforce_point_daily_caps()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  today_count int;
  cap int;
begin
  if new.action = 'contact_made' then
    cap := 10;
    select count(*) into today_count from public.point_events
      where user_id = new.user_id and action = 'contact_made'
        and created_at::date = now()::date;
  else
    cap := 5;
    select count(*) into today_count from public.point_events
      where user_id = new.user_id
        and action in ('share_card','share_post','share_page')
        and created_at::date = now()::date;
  end if;
  if today_count >= cap then
    return null;
  end if;
  return new;
end $$;

drop trigger if exists trg_point_daily_caps on public.point_events;
create trigger trg_point_daily_caps
  before insert on public.point_events
  for each row execute function public.enforce_point_daily_caps();

alter table public.point_events enable row level security;

drop policy if exists "Members can read their own point events" on public.point_events;
create policy "Members can read their own point events"
  on public.point_events for select
  using (auth.uid() = user_id);

drop policy if exists "Members can add their own point events" on public.point_events;
create policy "Members can add their own point events"
  on public.point_events for insert
  with check (auth.uid() = user_id);

drop policy if exists "Staff can read all point events" on public.point_events;
create policy "Staff can read all point events"
  on public.point_events for select
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

create table if not exists public.point_reward_claims (
  id bigint generated always as identity primary key,
  user_id uuid not null unique references auth.users (id) on delete cascade,
  reward text not null default 'blog_writeup',
  points_at_claim int,
  status text not null default 'pending'
    check (status in ('pending','fulfilled','declined')),
  created_at timestamptz not null default now()
);

alter table public.point_reward_claims enable row level security;

drop policy if exists "Members can read their own reward claims" on public.point_reward_claims;
create policy "Members can read their own reward claims"
  on public.point_reward_claims for select
  using (auth.uid() = user_id);

drop policy if exists "Members can claim their own reward" on public.point_reward_claims;
create policy "Members can claim their own reward"
  on public.point_reward_claims for insert
  with check (auth.uid() = user_id);

drop policy if exists "Staff can read all reward claims" on public.point_reward_claims;
create policy "Staff can read all reward claims"
  on public.point_reward_claims for select
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

drop policy if exists "Staff can update reward claims" on public.point_reward_claims;
create policy "Staff can update reward claims"
  on public.point_reward_claims for update
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff))
  with check (true);
