# Social Layer — daosmedia.com

Members-only community on top of the existing fighter-profiles build.
Built Nov 6–7, 2026. **Not pushed to GitHub yet** — push only on Jake's
go-ahead after review. Nothing here runs against Supabase until Jake
runs the SQL below; nothing is live until the push.

## What was built

- **Login gate**: the whole app is members-only. Logged-out visitors see
  a login / create-account screen only (Supabase email auth, already
  wired). No tab, feed, event, blog post, or fighter leaderboard is
  visible until you log in. After first login, members are prompted to
  create a profile before they can post.
- **Member profiles**: every member gets a profile — display name, bio,
  and a photo or logo upload (new `avatars` bucket, separate from the
  fighter `profile-photos` bucket). Tap any name or avatar to open that
  member's profile: photo, bio, follower / following / likes counts,
  Follow button, and their posts. Editing your own profile is in the
  Network tab ("My Profile").
- **Posts**: text posts to the feed (builds on the existing `posts`
  table). Each post shows the author's name and avatar, and Like,
  Comment, Share, and Repost buttons with live counts.
- **Likes**: one like per user per post (database-enforced). Tap again
  to unlike. Counts update live.
- **Comments**: tap Comment to see the thread and add your own. Counts
  update live.
- **Share**: uses the phone's share sheet where available (Web Share API),
  otherwise copies the post link (`daosmedia.com/#post/<id>`).
- **Repost**: reposts a post into your own feed, attributed to the
  original author, with a repost count. Tap again to remove your repost.
- **Connect / Network**: Follow / Unfollow members from any post,
  profile, suggestion, or ranking. Follows are stored in a `follows`
  table (one follow per pair, no self-follow — enforced in the database).
- **Suggestions**: "People to connect with" — newest members plus
  most-followed members, excluding people you already follow and
  yourself. Shown as a section in the Network tab, a "Newest members"
  directory below it, and a compact rail in the desktop sidebar.
- **Rankings**: a Rankings tab with two leaderboards — Top Fighters by
  votes (reuses the existing fighter leaderboard) and Top Members by
  followers (with likes received shown).

## Files

| File | What it is |
| --- | --- |
| `facebook-index.html` | App source — gate, Network + Rankings tabs, feed actions |
| `index.html` | Built page (regenerated with `build-facebook.py`) |
| `supabase/social-layer.sql` | Migration: profiles, likes, comments, follows, reposts, counters, RLS, avatar storage policies |
| `SOCIAL-LAYER.md` | This file |

Existing tabs (Feed, Events, Tournaments, Community, Magazine, Photos,
Blog, Music, Profile, Fighters) are untouched in behavior — the Fighters
tab, vote flow, and My Fighter Profile work exactly as before. One
existing bug was fixed along the way: posting previously inserted a post
without `user_id`, which the database would have rejected — posts now
insert with the signed-in user's id.

## What Jake still needs to do (in order)

### 1. Run the SQL (Supabase dashboard — nothing is live until this runs)
1. Open https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
2. SQL Editor > New query > paste the whole of
   `supabase/social-layer.sql` > Run. (Safe to re-run.)
   - This assumes `supabase-schema.sql` (posts table) and
     `supabase/fighter-profiles.sql` have already been run. If the
     fighter SQL has not been run yet, run it first, then this file.
3. Verify: Table Editor shows `profiles`, `post_likes`,
   `post_comments`, `follows`, `reposts`, and `posts` has the new
   columns `repost_of`, `like_count`, `comment_count`, `repost_count`.
   Sanity query is at the bottom of the SQL file.

### 2. Create the avatar bucket (SQL cannot create buckets)
Storage > New bucket > name `avatars` > **Public bucket: ON** >
Create. The storage policies are already in the migration file, so
they apply as soon as the bucket exists. (The fighter `profile-photos`
bucket is still needed separately for fighter photos.)

### 3. Approve the GitHub push
Say the word and the updated site goes to `daosmediagrp/daos-app` (main)
via the normal push path; GitHub Pages rebuilds daosmedia.com.

### 4. First live test (after the push)
1. Open https://daosmedia.com/ logged out — you should see only the
   login screen, nothing else.
2. Sign up with a test email, confirm it, log in — you should be asked
   to create your profile.
3. Create the profile (name, bio, photo) — confirm the setup prompt
   goes away and your name shows in the Network tab.
4. Post something — confirm it appears in the feed with Like / Comment /
   Share / Repost.
5. With a second test account: follow the first account, like and
   comment on its post, repost it — confirm counts move and the
   Rankings tab shows the first account.
6. Log out — confirm the login screen comes back.

### 5. New Capacitor build + TestFlight build 2
The app in TestFlight right now (v1.0 build 1) is the OLD site without
this social layer. After the push, the Capacitor wrapper needs a fresh
`npx cap sync` + archive + upload so TestFlight gets v1.0 build 2 with
the social layer inside.

## Important consequence of the login gate (Jake's call)

The gate hides **everything** until login — including the Events page,
the Blog, and the Fighters leaderboard on daosmedia.com. That is what
Jake asked for ("people have to login"), but it means the public
fighter-vote pages on daosmedia.com are no longer browsable without an
account. The Shopify vote pages
(deadlyartofsurvival.com/pages/vote-for-a-martial-artist) are untouched
and stay public. If Jake wants the Fighters leaderboard public while
the rest stays gated, that is a small change — say the word.

## Interpretation choices (made while building)

- **Suggestions** = newest members + most-followed members, merged,
  excluding yourself and anyone you already follow. No algorithm beyond
  that — no mutual-follow or interest matching yet.
- **Rankings** = two separate leaderboards on one screen. Top Members
  is ranked by follower count; likes received is shown next to each
  name but does not change the order.
- **Repost** = a new post row pointing at the original (`repost_of`),
  plus a `reposts` row that enforces one repost per user per post.
  Removing your repost deletes both rows.
- **Avatars** = a new `avatars` bucket, not the fighter
  `profile-photos` bucket, so member photos and fighter photos have
  separate policies and never collide.
- **Member profiles go live immediately** when created (they are the
  member's own public profile). Fighter profiles still need dashboard
  approval before going live — that rule is unchanged.

## Security notes

- The site uses only the public anon key (already in the page). Never
  put the service_role key in the site code or GitHub.
- App users cannot change their own profile counters
  (followers/following/likes) — a database trigger blocks it, same
  pattern as the fighter status guard. Counters are maintained by
  triggers only.
- Avatar uploads are capped at 5 MB in the page code; only image files
  are accepted by the file picker; uploads go into a folder named after
  the user's own id.

## Verification done Nov 7, 2026 (local only — nothing pushed, nothing live)

- `python3 build-facebook.py` — built `index.html` (367,196 bytes).
- Both inline scripts pass `node --check`.
- `supabase/social-layer.sql` parses cleanly (pglast: 80 statements).
- jsdom smoke test (stubbed Supabase,
  `/tmp/jsdom-test/social-smoke-test.js`): **37/37 pass** — gate shows
  logged out and hides the feed; sign-in ungates; profile setup prompt
  appears for new users and posting is blocked until the profile exists;
  profile save hides the prompt; post renders with all four action
  buttons; like/unlike counts 1/0; comment lists and counts; repost
  appears attributed and un-repost removes it; follow flips to
  Following and suggestions exclude the followed member and yourself;
  rankings show Jorge first (2 votes) and most-followed member first;
  member view opens with stats and posts; share fallback runs; deep
  links `#post/<id>` and `#/member/<id>` work; fighters leaderboard
  still renders 7 fighters; existing tabs still switch; sign-out
  returns to the gate; no service_role key in the built file.
- NOT verified yet (needs the live Supabase project + push): real
  sign-up, real avatar upload to the bucket, real like/comment/follow
  against the live database, and rendering on daosmedia.com itself.
  That is the first-live-test checklist above.
