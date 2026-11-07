# Paid Submissions — $5 Events, Tournaments & Songs

Members pay $5 to list an event, seminar, or tournament, or to submit a
song. Nothing goes live until DAOS approves it. Built Nov 7, 2026.
**Not pushed to GitHub yet** — push only on Jake's go-ahead after review.
Nothing here runs against Supabase until Jake runs the SQL below.

## What was built

- **"Post your event" button — $5** (Events tab): opens a form — title,
  type picker (Event / Seminar / Tournament), date & time, location,
  description, link. Members only (login + member profile required,
  same guards as posting).
- **"Post your tournament" button — $5** (Tournaments tab): opens the
  same form with the type preset to Tournament.
- **Community Events section** (Events tab): LIVE community listings
  ordered by date. Live tournaments also show in a **Community
  Tournaments** section on the Tournaments tab.
- **"Add your song" button — $5** (Music section): opens a form — song
  title, artist name, streaming link (Spotify, YouTube, or SoundCloud).
  The exact quote sits next to the button:

  > "Best songs (clean versions only) may get placed on DAOS Radio WPAT 930 AM"

  Selected songs show in a **Selected songs** section on the Music tab.
- **Payment flow (v1)**: after the form is filled in, a $5 pay step
  opens the Stripe payment link in a new tab. The member comes back,
  enters the email they paid with, and confirms — the row is then saved
  with status `submitted`. See "Payment verification (v1 limitation)"
  below: **there is no webhook and the site cannot verify a payment.**

## Files

| File | What it is |
| --- | --- |
| `facebook-index.html` | App source — buttons, forms, pay steps, live lists |
| `index.html` | Built page (regenerated with `build-facebook.py`) |
| `supabase/paid-submissions.sql` | Migration: `community_events` + `song_submissions`, RLS, status-guard triggers |
| `PAID-SUBMISSIONS.md` | This file |

## What Jake still needs to do (in order)

### 1. Connect Stripe and fill in the two payment links
Stripe is NOT connected yet, so no real payment links exist. Once it is:
1. In Stripe, create two $5 one-time payment links (or one $5 product
   with two links — one for event listings, one for song submissions).
2. In `facebook-index.html`, paste the links into the two placeholder
   constants near the top of the paid-submissions code:

   ```js
   var STRIPE_EVENT_PAYMENT_LINK = 'https://buy.stripe.com/...'; // $5 event / seminar / tournament listing
   var STRIPE_SONG_PAYMENT_LINK = 'https://buy.stripe.com/...';  // $5 song submission
   ```

   They are empty strings (`''`) until then. While empty, the pay
   buttons show "Payments open soon — DAOS is still setting up the $5
   payment link" and open nothing, so nobody can submit a listing they
   cannot pay for.
3. Rebuild (`python3 build-facebook.py`) and push.

### 2. Run the SQL (Supabase dashboard — nothing is live until this runs)
1. Open https://supabase.com/dashboard/project/hsgbmrtpwnyqkmfnveaz
2. SQL Editor > New query > paste the whole of
   `supabase/paid-submissions.sql` > Run. (Safe to re-run.)
   - Run AFTER `supabase-schema.sql`, `supabase/fighter-profiles.sql`,
     and `supabase/social-layer.sql` (they should already be run).
3. Verify: Table Editor shows `community_events` and `song_submissions`.
   Sanity query is at the bottom of the SQL file.

### 3. Approve the GitHub push
Say the word and the updated site goes to `daosmediagrp/daos-app` (main)
via the normal push path; GitHub Pages rebuilds daosmedia.com.

### 4. First live test (after the push)
1. Open https://daosmedia.com/ > Events tab — the "Post your event — $5"
   button is there; Tournaments tab has "Post your tournament — $5";
   Music has "Add your song — $5" with the DAOS Radio WPAT 930 AM quote.
2. Log in as a test member with a profile. Open the event form, fill it
   in, continue to the pay step — confirm it says payments open soon
   (until the Stripe links are filled in).
3. Once the Stripe links are in: pay $5 with a test card, come back,
   enter the payer email, submit — confirm the message says DAOS will
   review it, and the listing does NOT appear in Community Events yet.
4. In the dashboard, set that `community_events` row to `live` — confirm
   it appears in Community Events (and in Community Tournaments if its
   type is Tournament).
5. Same flow for a song: submit, confirm it does not appear in Selected
   songs, set the `song_submissions` row to `selected` in the dashboard,
   confirm it appears with a working Listen link.

### 5. New Capacitor build + TestFlight build 2
The app in TestFlight (v1.0 build 1) is the OLD site without the social
layer or these buttons. After the push, the Capacitor wrapper needs a
fresh `npx cap sync` + archive + upload so TestFlight gets the build
with everything inside.

## Approval flow (Jake, in the Supabase dashboard)

- New event/seminar/tournament submitted: Table Editor >
  `community_events` > find the row (status `submitted`) > **check the
  `payer_email` against Stripe first** (see below) > set status to
  `live` (or `rejected`) > Save. It appears in Community Events
  immediately (tournaments also in Community Tournaments).
- New song submitted: Table Editor > `song_submissions` > find the row
  (status `submitted`) > **check the `payer_email` against Stripe
  first** > set status to `selected` (or `rejected`) > Save. It appears
  in Selected songs immediately. Clean versions only — reject anything
  explicit; the best clean songs are the ones that may get placed on
  DAOS Radio WPAT 930 AM.

## Payment verification (v1 limitation — read this)

**v1 does NOT verify payment.** There is no Stripe webhook, no server,
and no way for the page to check whether a payment happened. The flow
is honest about that:

- The member pays $5 on Stripe, then types the email they paid with.
- The listing is saved as `submitted` with that `payer_email`.
- **Jake matches the email against Stripe before approving.** In the
  Stripe dashboard: Payments > search the payer email > confirm a $5
  payment exists > then set the row live/selected. If no $5 payment
  matches, set it to `rejected`.
- `payment_ref` is stored as NULL in v1. A later version can fill it
  with the Stripe payment-intent or checkout-session id (via a webhook
  or by reading the `?session_id` Stripe appends to the success URL).
- Until the two `STRIPE_*_PAYMENT_LINK` constants are filled in, the
  pay step cannot be completed and nothing is submitted — nobody can
  get a free listing through the form.

## Interpretation choices (made while building)

- **One form, two buttons**: the Tournaments button opens the same
  event form (in the Events tab) with type preset to Tournament, so
  there is one code path and one table for all three listing types.
- **Community Events shows every live type** (events, seminars,
  tournaments) by date; the Tournaments tab shows only the live
  tournaments, so tournament posters get seen in both places.
- **Songs are "selected", not "live"**: the status word matches Jake's
  language — DAOS *picks* songs. Only `selected` songs are public.
- **No photo upload on listings (v1)**: text + link only, keeping the
  text-only scope Jake set for the app. A flyer/image field can be
  added later with a storage bucket like `profile-photos` / `avatars`.
- **No per-member listing cap (v1)**: the $5 fee is the throttle. A
  daily cap can be added later if spam shows up.

## Security notes

- The site uses only the public anon key (already in the page). Never
  put the service_role key in the site code or GitHub.
- App users cannot change their own listing status — a database trigger
  blocks status changes from the app roles. Jake changes status from
  the dashboard (postgres role), which the trigger allows.
- Owners can only edit their own listing while it is still
  `submitted` (RLS update policy). Once live/selected, only the
  dashboard can change it.
- `payer_email` is stored on the row so Jake can match it in Stripe.
  It is not shown publicly — the public read policies only expose
  `live` / `selected` rows, and the page only renders title, date,
  location, description, and link (never the payer email).

## Verification done Nov 7, 2026 (local only — nothing pushed, nothing live)

- `python3 build-facebook.py` — built `index.html` (383,548 bytes).
- Both inline scripts pass `node --check`.
- `supabase/paid-submissions.sql` parses cleanly (pglast: 34 statements).
- jsdom smoke test (stubbed Supabase,
  `/tmp/jsdom-test/paid-smoke-test.js`): **34/34 pass** — logged-in
  session ungates; all three $5 buttons render; DAOS Radio quote
  present exactly; live community event + live tournament + selected
  song render in the right lists (tournament in both lists, plain
  event not in the tournaments list); both Stripe placeholders are
  empty strings; no service_role key in the built file; event form
  opens with type defaulting to event; empty title blocks the pay
  step; filled form opens the pay step; empty Stripe placeholder opens
  no URL and warns; bad payer email blocks submission; event insert
  saved with status `submitted` and correct type/title/payer email;
  tournament button presets type to tournament and its insert saves
  as tournament; song form opens on the Music tab; empty title and bad
  streaming link block the pay step; filled song form opens the pay
  step; empty song Stripe placeholder opens no URL; song insert saved
  with status `submitted` and correct title/artist/link/payer email;
  logged-out session keeps the login gate.
- NOT verified yet (needs the live Supabase project + Stripe + push):
  real $5 Stripe payment, real insert against the live database,
  dashboard approval flipping a row live/selected, and rendering on
  daosmedia.com itself. That is the first-live-test checklist above.
