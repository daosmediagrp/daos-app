-- ============================================================================
-- DAOS app — Social layer (profiles, likes, comments, follows, reposts,
-- rankings) — supabase/social-layer.sql
-- Project: daos-app (Supabase) — https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
--
-- HOW TO RUN (Jake / Chat — do this in the Supabase dashboard, NOT in the site):
--   1. Run supabase-schema.sql first if the posts table does not exist yet,
--      then supabase/fighter-profiles.sql (the fighter build), then this file.
--      Each file is idempotent (safe to re-run).
--   2. Supabase dashboard > SQL Editor > New query > paste this WHOLE file
--      and click Run.
--   3. Create the avatar bucket (SQL cannot create buckets):
--        Storage > New bucket > name: avatars > Public bucket: ON > Create.
--        The storage policies below are created by this file, so once the
--        bucket exists the policies apply immediately.
--   4. Confirm: Table Editor should show profiles, post_likes,
--      post_comments, follows, reposts — and Storage > Policies should
--      list the avatars policies.
--
-- WHAT THIS CREATES
--   profiles       : one row per member (id = auth user id). display_name,
--     bio, avatar_url (uploaded to the avatars bucket). Public to read.
--   post_likes     : one row per like. UNIQUE (post_id, user_id) enforces
--     one like per user per post.
--   post_comments  : comments on posts. One row per comment.
--   follows        : one row per follow. UNIQUE (follower_id, following_id)
--     enforces one follow per pair; a check blocks self-follow.
--   reposts        : one row per repost. UNIQUE (post_id, user_id) enforces
--     one repost per user per post. The repost itself is a row in posts
--     with repost_of pointing at the original (the site creates both).
--   Counters kept in sync by triggers (SECURITY DEFINER functions, same
--   pattern as fighter-profiles.sql):
--     posts.like_count / comment_count / repost_count
--     profiles.followers_count / following_count / likes_received
--
-- APPROVAL: there is no admin login in the app. Member profiles go live
--   immediately when created (they are the member's own public profile);
--   fighter profiles still need dashboard approval (see
--   supabase/fighter-profiles.sql). Jake can remove a member profile or a
--   post from the dashboard Table Editor if ever needed.
--
-- SECURITY NOTES
--   - Never paste the service_role key anywhere in the site code or GitHub.
--     The site uses only the public anon key; RLS does the protecting.
--   - App users CANNOT change their own profile counters: a trigger blocks
--     changes to followers_count / following_count / likes_received from
--     the anon/authenticated roles. The counter triggers run as SECURITY
--     DEFINER (postgres), so they are exempt — same pattern as the fighter
--     vote-count trigger.
--   - Avatar uploads are capped at 5 MB in the page code; only image files
--     are accepted by the file picker. Uploads go into a folder named
--     after the user's own id; only the owner can upload/replace/delete
--     their own avatar.
-- ============================================================================

-- --------------------------------------------------------------------------
-- Member profiles
-- --------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 100),
  bio text not null default '' check (char_length(bio) <= 2000),
  avatar_url text check (avatar_url is null or char_length(avatar_url) <= 1000),
  followers_count integer not null default 0 check (followers_count >= 0),
  following_count integer not null default 0 check (following_count >= 0),
  likes_received integer not null default 0 check (likes_received >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_followers_idx
  on public.profiles (followers_count desc, created_at desc);
create index if not exists profiles_created_idx
  on public.profiles (created_at desc);

-- Keep updated_at fresh on every edit. (Also defined in
-- fighter-profiles.sql; create or replace keeps this file standalone.)
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- App users may never change their own counter columns. The dashboard
-- (postgres role) is exempt, and the counter triggers below run as
-- SECURITY DEFINER (postgres), so they are exempt too.
create or replace function public.block_profile_count_change()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated')
     and (new.followers_count is distinct from old.followers_count
       or new.following_count is distinct from old.following_count
       or new.likes_received is distinct from old.likes_received) then
    raise exception 'Profile counters are maintained by DAOS, not by the app.';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_count_guard on public.profiles;
create trigger profiles_count_guard
  before update on public.profiles
  for each row execute function public.block_profile_count_change();

-- --------------------------------------------------------------------------
-- Posts: extend the existing public.posts table (from supabase-schema.sql)
-- --------------------------------------------------------------------------
alter table public.posts
  add column if not exists repost_of bigint references public.posts (id) on delete set null;
alter table public.posts
  add column if not exists like_count integer not null default 0 check (like_count >= 0);
alter table public.posts
  add column if not exists comment_count integer not null default 0 check (comment_count >= 0);
alter table public.posts
  add column if not exists repost_count integer not null default 0 check (repost_count >= 0);

create index if not exists posts_repost_of_idx
  on public.posts (repost_of);

-- --------------------------------------------------------------------------
-- Likes / comments / follows / reposts
-- --------------------------------------------------------------------------
create table if not exists public.post_likes (
  id uuid primary key default gen_random_uuid(),
  post_id bigint not null references public.posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (post_id, user_id)
);
create index if not exists post_likes_post_idx
  on public.post_likes (post_id);

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id bigint not null references public.posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists post_comments_post_idx
  on public.post_comments (post_id, created_at);

create table if not exists public.follows (
  id uuid primary key default gen_random_uuid(),
  follower_id uuid not null references auth.users (id) on delete cascade,
  following_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (follower_id, following_id),
  check (follower_id <> following_id)
);
create index if not exists follows_follower_idx
  on public.follows (follower_id);
create index if not exists follows_following_idx
  on public.follows (following_id);

create table if not exists public.reposts (
  id uuid primary key default gen_random_uuid(),
  post_id bigint not null references public.posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (post_id, user_id)
);
create index if not exists reposts_post_idx
  on public.reposts (post_id);

-- --------------------------------------------------------------------------
-- Counter triggers (SECURITY DEFINER, same pattern as fighter-profiles.sql)
-- --------------------------------------------------------------------------
create or replace function public.sync_post_like_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set like_count = like_count + 1 where id = new.post_id;
    update public.profiles set likes_received = likes_received + 1
     where id = (select user_id from public.posts where id = new.post_id);
    return new;
  else
    update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id;
    update public.profiles set likes_received = greatest(likes_received - 1, 0)
     where id = (select user_id from public.posts where id = old.post_id);
    return old;
  end if;
end;
$$;
drop trigger if exists post_likes_count_sync on public.post_likes;
create trigger post_likes_count_sync
  after insert or delete on public.post_likes
  for each row execute function public.sync_post_like_count();

create or replace function public.sync_post_comment_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set comment_count = comment_count + 1 where id = new.post_id;
    return new;
  else
    update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id;
    return old;
  end if;
end;
$$;
drop trigger if exists post_comments_count_sync on public.post_comments;
create trigger post_comments_count_sync
  after insert or delete on public.post_comments
  for each row execute function public.sync_post_comment_count();

create or replace function public.sync_post_repost_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set repost_count = repost_count + 1 where id = new.post_id;
    return new;
  else
    update public.posts set repost_count = greatest(repost_count - 1, 0) where id = old.post_id;
    return old;
  end if;
end;
$$;
drop trigger if exists reposts_count_sync on public.reposts;
create trigger reposts_count_sync
  after insert or delete on public.reposts
  for each row execute function public.sync_post_repost_count();

create or replace function public.sync_follow_counts()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set followers_count = followers_count + 1 where id = new.following_id;
    update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    return new;
  else
    update public.profiles set followers_count = greatest(followers_count - 1, 0) where id = old.following_id;
    update public.profiles set following_count = greatest(following_count - 1, 0) where id = old.follower_id;
    return old;
  end if;
end;
$$;
drop trigger if exists follows_count_sync on public.follows;
create trigger follows_count_sync
  after insert or delete on public.follows
  for each row execute function public.sync_follow_counts();

-- --------------------------------------------------------------------------
-- Row Level Security
-- --------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.follows enable row level security;
alter table public.reposts enable row level security;

-- profiles: anyone reads member profiles; members create/edit only their own.
drop policy if exists "Anyone can read member profiles" on public.profiles;
create policy "Anyone can read member profiles"
  on public.profiles for select using (true);

drop policy if exists "Members can create their own profile" on public.profiles;
create policy "Members can create their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

drop policy if exists "Members can edit their own profile" on public.profiles;
create policy "Members can edit their own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- profiles: nobody deletes profiles from the app. (No DELETE policy:
-- deletes are dashboard-only, if ever.)

-- posts: owners can delete their own posts (read/insert policies live in
-- supabase-schema.sql and are unchanged).
drop policy if exists "Owners can delete their own posts" on public.posts;
create policy "Owners can delete their own posts"
  on public.posts for delete
  using (auth.uid() = user_id);

-- post_likes: anyone reads; members like/unlike only as themselves.
drop policy if exists "Anyone can read post likes" on public.post_likes;
create policy "Anyone can read post likes"
  on public.post_likes for select using (true);

drop policy if exists "Members can like posts" on public.post_likes;
create policy "Members can like posts"
  on public.post_likes for insert
  with check (auth.uid() = user_id);

drop policy if exists "Members can unlike their own likes" on public.post_likes;
create policy "Members can unlike their own likes"
  on public.post_likes for delete
  using (auth.uid() = user_id);

-- post_comments: anyone reads; members comment/delete only their own.
drop policy if exists "Anyone can read post comments" on public.post_comments;
create policy "Anyone can read post comments"
  on public.post_comments for select using (true);

drop policy if exists "Members can comment on posts" on public.post_comments;
create policy "Members can comment on posts"
  on public.post_comments for insert
  with check (auth.uid() = user_id);

drop policy if exists "Members can delete their own comments" on public.post_comments;
create policy "Members can delete their own comments"
  on public.post_comments for delete
  using (auth.uid() = user_id);

-- follows: anyone reads (follower lists are public); members follow/unfollow
-- only as themselves. Self-follow is blocked by the table check too.
drop policy if exists "Anyone can read follows" on public.follows;
create policy "Anyone can read follows"
  on public.follows for select using (true);

drop policy if exists "Members can follow" on public.follows;
create policy "Members can follow"
  on public.follows for insert
  with check (auth.uid() = follower_id);

drop policy if exists "Members can unfollow" on public.follows;
create policy "Members can unfollow"
  on public.follows for delete
  using (auth.uid() = follower_id);

-- reposts: anyone reads; members repost/un-repost only as themselves.
drop policy if exists "Anyone can read reposts" on public.reposts;
create policy "Anyone can read reposts"
  on public.reposts for select using (true);

drop policy if exists "Members can repost" on public.reposts;
create policy "Members can repost"
  on public.reposts for insert
  with check (auth.uid() = user_id);

drop policy if exists "Members can remove their own reposts" on public.reposts;
create policy "Members can remove their own reposts"
  on public.reposts for delete
  using (auth.uid() = user_id);

-- --------------------------------------------------------------------------
-- Avatar storage policies (bucket 'avatars' must be created first:
-- Storage > New bucket > avatars > Public bucket ON > Create.
-- If the bucket does not exist yet, these policies still create fine and
-- apply as soon as the bucket is made.)
-- --------------------------------------------------------------------------
drop policy if exists "Anyone can view avatars" on storage.objects;
create policy "Anyone can view avatars"
  on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists "Members can upload their own avatar" on storage.objects;
create policy "Members can upload their own avatar"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Members can replace their own avatar" on storage.objects;
create policy "Members can replace their own avatar"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Members can delete their own avatar" on storage.objects;
create policy "Members can delete their own avatar"
  on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================================
-- Done. Next: create the avatars bucket (see above), then approve the
-- GitHub push so the social layer goes live with the site.
-- Sanity check (run separately if you want to verify):
--   select count(*) from public.profiles;
--   select column_name from information_schema.columns
--    where table_schema = 'public' and table_name = 'posts'
--    and column_name in ('repost_of','like_count','comment_count','repost_count');
-- ============================================================================
