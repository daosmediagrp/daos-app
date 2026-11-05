-- DAOS app — Supabase schema. Run this in the Supabase dashboard:
-- SQL Editor > New query > paste > Run.
-- Public front page, gated member area: anyone can read posts,
-- only signed-in members can create their own posts.

create table if not exists public.posts (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete cascade,
  content text not null check (char_length(content) <= 1000),
  created_at timestamptz not null default now()
);

alter table public.posts enable row level security;

drop policy if exists "Anyone can read posts" on public.posts;
create policy "Anyone can read posts"
  on public.posts for select using (true);

drop policy if exists "Members can post" on public.posts;
create policy "Members can post"
  on public.posts for insert
  with check (auth.uid() = user_id);

-- Auth: in the Supabase dashboard, Authentication > Providers > Email
-- must be ON (it is by default on new projects). No other setup needed
-- for v1. Do NOT paste the service_role key anywhere in the site code —
-- the site uses only the public anon key.
