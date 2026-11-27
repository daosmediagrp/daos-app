-- Add Mandella Eskia (Mandela Brathwaite) to Top Artists — DAOS Party performer
-- Application received Nov 27, 2026 (daos@ inbox, 10:31 AM): mandellaeskia@gmail.com, 9176456048
-- Run in Supabase SQL Editor (project hsgbmrtpwnyqkmfnveaz). Safe to re-run: guarded by NOT EXISTS.

insert into public.song_submissions (artist_name, song_title, stream_url, status, payer_email)
select 'Mandella Eskia', 'DAOS Party — Dec 5', 'https://youtu.be/ScEbLV_MJZI', 'selected', 'mandellaeskia@gmail.com'
where not exists (
  select 1 from public.song_submissions
  where artist_name = 'Mandella Eskia' and status = 'selected'
);

-- Verify:
-- select artist_name, song_title, stream_url, status from public.song_submissions where artist_name = 'Mandella Eskia';
