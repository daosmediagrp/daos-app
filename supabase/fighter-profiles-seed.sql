-- ============================================================================
-- DAOS app — Seed the 7 existing Martial Artist Vote fighters as LIVE
-- fighter_profiles on daosmedia.com.
--
-- RUN AFTER supabase/fighter-profiles.sql (same way: SQL Editor > New query
-- > paste > Run). Idempotent: re-running updates the rows in place instead
-- of duplicating them (matched on slug).
--
-- SOURCE OF TRUTH: the Shopify vote pages + their bios, Nov 5, 2026.
--   Jorge Borjas, Aker Ramessu Iyi, Jamie, Stacey Legg, Sendo Tran,
--   Jaiden Graciani, Chris Malarkey.
--   Vote counts below are the SHOPIFY counts as of Nov 5, 2026
--   (Jorge 2, Aker 1, everyone else 0), carried over so the new
--   leaderboard starts where the old one left off.
--
-- IMPORTANT — two systems until cutover:
--   These seeded votes_count values are a starting point, NOT live vote
--   rows. No fighter_votes rows are created here (the Shopify votes were
--   cast by email on Shopify, not by email here), so a seeded fighter's
--   first daosmedia.com vote will take them from e.g. 2 to 3.
--   The Shopify vote pages stay live and untouched. Vote counts will live
--   in two places until Jake decides to cut over to daosmedia.com only.
--
-- Seeded rows have user_id NULL and is_seeded = true, so no app user can
-- edit them through the site. If a seeded fighter later wants to manage
-- their own profile, Jake links it in the dashboard by setting user_id to
-- that fighter's auth user id (and is_seeded = false).
-- ============================================================================

insert into public.fighter_profiles
  (user_id, slug, display_name, style_rank, bio, photo_url, status, needs_review, is_seeded, votes_count)
values
  (null, 'jorge-borjas', 'Jorge Borjas', 'Martial Artist',
   'A U.S. Armed Forces veteran with nearly six decades of martial arts training, Jorge Borjas is the founder of the World Bushido Federation and an author who survived being shot 16 times. He teaches, hosts martial arts events, and lives by his own words: "Always do what you think is right and remember that nothing is impossible in life."',
   null, 'live', false, true, 2),
  (null, 'aker-ramessu-iyi', 'Aker Ramessu Iyi', 'Aha Saki',
   'Aha Saki practitioner. Full bio coming soon.',
   null, 'live', false, true, 1),
  (null, 'jamie', 'Jamie', 'Shotokan Karate · 3rd Dan',
   'Shotokan Karate, 3rd Dan. Full bio coming soon.',
   null, 'live', false, true, 0),
  (null, 'stacey-legg', 'Stacey Legg', 'Kakuto Shin-Ryu 5th Dan · Taekwondo 3rd Dan',
   '35 years in martial arts, UMAHoF inductee, weapons world champion 3 years running. Teaches taekwondo and koryo gumdo at RiverValley Martial Arts in Wilmington, IL.',
   null, 'live', false, true, 0),
  (null, 'sendo-tran', 'Sendo Tran', 'Taekwondo 3rd Dan · Kudo · Judo · Kyokushin Karate · BJJ',
   'Over 25 years of dedication to martial arts. 3rd Dan Taekwondo, green belt Kudo, blue belt Judo, yellow belt Kyokushin Karate, white 3-stripe BJJ. Competing, teaching, and mentoring students in discipline, confidence, and skill.',
   null, 'live', false, true, 0),
  (null, 'jaiden-graciani', 'Jaiden Graciani', 'Taekwondo · 1st Dan · Sport Karate',
   '16 years old from Orlando, Florida. 1st-degree black belt in taekwondo, ISKA World Champion and USA Sport Karate National Champion. Competes in NASKA and Open World Tour circuits, team member of Team Raptor and the US martial arts team. Junior instructor at Global Champs Karate in Sanford, Florida, teaching younger kids CMX forms and sword. Specialty: sword, traditional and CMX.',
   null, 'live', false, true, 0),
  (null, 'chris-malarkey', 'Chris Malarkey', 'Traditional Taekwon-Do · Hap Ki-Do · 7th Dan',
   'Master Chris Malarkey is a 7th Degree Black Belt, U.S. Martial Arts Hall of Fame inductee, nationally recognized martial artist, published author, and founder of Chris Malarkey Taekwon-Do (CMTKD) in Belleville, New Jersey. With over 30 years of martial arts experience, a longtime student of Grandmaster Suk Jun Kim (9th Dan), he specializes in Traditional Taekwon-Do, Hap Ki-Do, Judo, and boxing. Author of three books — Journey from White to Black, Moving Meditation, and Building Young Leaders. Previously featured in DAOS Magazine.',
   null, 'live', false, true, 0)
on conflict (slug) do update set
  display_name = excluded.display_name,
  style_rank = excluded.style_rank,
  bio = excluded.bio,
  status = excluded.status,
  is_seeded = excluded.is_seeded,
  votes_count = excluded.votes_count;

-- Sanity check (run separately if you want to verify):
-- select slug, display_name, status, votes_count, is_seeded
--   from public.fighter_profiles order by votes_count desc, display_name;
-- Expected: 7 rows, all status 'live', Jorge 2, Aker 1, rest 0.
