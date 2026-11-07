# Martial Artist Profiles — Self-Serve on daosmedia.com

Fighters create their own login, build their own profile, upload their own
photo, and share their own page to gather votes. Nothing goes live until
DAOS approves it. Built Nov 5, 2026. **Not pushed to GitHub yet** — push
only on Jake's go-ahead after review.

## What was built

- **Fighters tab** on daosmedia.com (last tab, plus a row in the menu drawer
  and a card in the Magazine tab): public leaderboard of LIVE profiles,
  sorted by votes, each card with photo, name, style/rank, vote count,
  Vote and Share buttons.
- **Shareable profile page**: `https://daosmedia.com/#/fighter/<slug>`
  (e.g. `#/fighter/jorge-borjas`) — photo, bio, vote count, a vote box
  (email address, one vote per email), and a share button that copies the link.
- **My Fighter Profile** (in the Fighters tab, login required): signed-in
  members create or edit their own profile — name, page name (slug),
  style/rank, bio, photo upload. Status is always shown:
  Submitted → In review → Live (or Not approved).
- **Photo upload**: to the `profile-photos` storage bucket, into a folder
  named after the user's own id. Public can view photos; only the owner
  can upload/replace/delete their own.
- **Voting**: public, no login needed — voter enters an email. One vote per
  email per fighter, enforced by a unique constraint plus a
  `cast_fighter_vote()` function (the only public write path; there are no
  anonymous writes to the tables). Voter emails are never shown publicly.
- **Editing a live profile**: the profile stays live, but it is flagged
  `needs_review = true` so DAOS can re-check the changes.
- **Admin approval**: there is NO admin login in the app. Jake approves in
  the Supabase dashboard (see below).
- **Seeded fighters**: the 7 existing Shopify vote fighters are seeded as
  LIVE profiles with their Shopify bios and vote counts (Jorge 2, Aker 1,
  rest 0). They have `user_id = NULL, is_seeded = true`, so no app user
  can edit them.

## Files

| File | What it is |
| --- | --- |
| `facebook-index.html` | App source — Fighters tab, profile view, vote + My Profile code |
| `index.html` | Built page (regenerated with `build-facebook.py`) |
| `supabase/fighter-profiles.sql` | Migration: tables, RLS, triggers, vote function, storage policies |
| `supabase/fighter-profiles-seed.sql` | Seeds the 7 existing fighters as LIVE |
| `FIGHTER-PROFILES.md` | This file |

## What Jake still needs to do (in order)

### 1. Run the SQL (Supabase dashboard — nothing is live until this runs)
1. Open https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
2. SQL Editor > New query > paste the whole of
   `supabase/fighter-profiles.sql` > Run. (Safe to re-run.)
3. SQL Editor > New query > paste the whole of
   `supabase/fighter-profiles-seed.sql` > Run.
4. Verify: Table Editor shows `fighter_profiles` (7 rows, all `live`) and
   `fighter_votes` (empty). Sanity query is at the bottom of the seed file.

### 2. Create the photo bucket (SQL cannot create buckets)
Storage > New bucket > name `profile-photos` > **Public bucket: ON** >
Create. The storage policies are already in the migration file, so they
apply as soon as the bucket exists.

### 3. Approve the GitHub push
Say the word and the updated site goes to `daosmediagrp/daos-app` (main)
via the normal push path; GitHub Pages rebuilds daosmedia.com.

### 4. First live test (after the push)
1. Open https://daosmedia.com/ > Fighters tab — the 7 seeded fighters
   should show, Jorge first with 2 votes.
2. Open `#/fighter/jorge-borjas` — vote with your own email, confirm the
   count goes 2 → 3, then vote again with the same email and confirm it
   says you already voted.
3. Sign up with a test email, create a fighter profile, upload a photo —
   confirm it shows as Submitted, NOT on the public leaderboard.
4. Approve it in the dashboard (below) and confirm it appears on the
   leaderboard.

## Approval flow (Jake, in the Supabase dashboard)

- New profile submitted: Table Editor > `fighter_profiles` > find the row
  (status `submitted`) > set status to `live` (or `rejected`) > Save.
  It appears on the public leaderboard immediately.
- Edited live profile: Table Editor > `fighter_profiles` > filter
  `needs_review = true` > review the changes > set `needs_review = false`.
- Seeded fighter wants to manage their own profile: set that row's
  `user_id` to the fighter's auth user id (Authentication > Users) and
  `is_seeded = false`.

## Vote rule

One vote per email, per fighter. Enforced in the database
(`UNIQUE (fighter_id, voter_email)` on `fighter_votes`), not just in the
page code — so it holds even if someone calls the function directly.
Duplicate votes are rejected with an "already voted" message.

## Two systems until cutover

The Shopify vote pages
(deadlyartofsurvival.com/pages/vote-for-a-martial-artist and the 7
individual pages) are **live and untouched**. Vote counts will live in two
places until Jake decides to cut over to daosmedia.com only:
- Shopify counts: Jorge 2, Aker 1, rest 0 (as of Nov 5, 2026).
- daosmedia.com counts: seeded at those same numbers; new votes there add
  on top. Shopify votes do NOT flow into daosmedia.com.
Do not merge or delete the Shopify counts without Jake's call.

## Security notes

- The site uses only the public anon key (already in the page). Never put
  the service_role key in the site code or GitHub.
- App users cannot change their own profile status — a database trigger
  blocks status changes from the app roles. Jake changes status from the
  dashboard (postgres role), which the trigger allows.
- Voter emails are stored only in `fighter_votes`, which has no public
  read policy.
- Photo uploads are capped at 5 MB in the page code; only image files are
  accepted by the file picker.

## Verification done Nov 5, 2026 (local only — nothing pushed, nothing live)

- `python3 build-facebook.py` — built `index.html` (307,495 bytes).
- Both inline scripts pass `node --check`.
- Both SQL files parse cleanly (pglast: 36 + 1 statements).
- jsdom smoke test (stubbed Supabase, `/tmp/jsdom-test/fighter-smoke-test.js`):
  16/16 pass — 7-card leaderboard in vote order, Jorge 2 / Aker 1,
  profile detail route, vote counted 2 → 3, duplicate vote rejected,
  share URL format, logged-out My Profile prompt, existing tabs still work.
- NOT verified yet (needs the live Supabase project + push): real
  sign-up, real photo upload to the bucket, real vote against the live
  database, and rendering on daosmedia.com itself. That is the first-live-test
  checklist above.
