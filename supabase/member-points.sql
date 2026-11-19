-- DAOS Points for the DAOS app (Jake's spec, Nov 19, 2026 —
-- see daos-points-spec.md in the app goal files).
-- EARNED points: 1 per verified action (post, like, comment,
-- share). Likes capped at 5/day in the database trigger below;
-- posts, comments, shares uncapped. One award per member +
-- action + item per day (unique index). Referral points pay only
-- when the friend joins or buys — the 'referral' action exists
-- here for the server to write when attribution lands; the app
-- never self-awards it.
-- BOUGHT points ($1 = 10, Shopify gift cards) are a separate
-- balance and are NOT stored in point_events — they can never
-- count toward the ladder.
-- THE LADDER (earned only), claimed into point_reward_claims for
-- DAOS staff to fulfill (nothing auto-publishes):
--   100 song_exposure / 500 blog_feature / 5000 magazine_feature.
-- Additive only — safe to re-run.

create table if not exists public.point_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  action text not null check (action in
    ('post','like','comment','share','referral')),
  points int not null check (points > 0 and points <= 100),
  ref_key text,
  created_at timestamptz not null default now()
);

create index if not exists point_events_user_idx
  on public.point_events (user_id, created_at desc);

-- One award per member + action + item per day.
create unique index if not exists point_events_daily_unique
  on public.point_events (user_id, action, coalesce(ref_key, ''), ((created_at)::date));

-- Server-side cap: at most 5 like points per member per day;
-- inserts beyond the cap are silently skipped. All other earned
-- actions are uncapped (the per-item-per-day index above is the
-- anti-farming guard).
create or replace function public.enforce_point_like_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  today_count int;
begin
  if new.action = 'like' then
    select count(*) into today_count from public.point_events
      where user_id = new.user_id and action = 'like'
        and created_at::date = now()::date;
    if today_count >= 5 then
      return null;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_point_daily_caps on public.point_events;
drop trigger if exists trg_point_like_cap on public.point_events;
create trigger trg_point_like_cap
  before insert on public.point_events
  for each row execute function public.enforce_point_like_cap();

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
  user_id uuid not null references auth.users (id) on delete cascade,
  reward text not null default 'blog_feature'
    check (reward in ('song_exposure','blog_feature','magazine_feature')),
  points_at_claim int,
  status text not null default 'pending'
    check (status in ('pending','fulfilled','declined')),
  created_at timestamptz not null default now()
);

-- One claim per member per ladder reward.
create unique index if not exists point_reward_claims_user_reward_unique
  on public.point_reward_claims (user_id, reward);

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
