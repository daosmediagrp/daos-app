-- Proof-of-attendance stamps for the DAOS app (Jake, Nov 19, 2026).
-- A stamp IS a door check-in: public.check_ins already holds one
-- row per member per event, written only by the check-ticket Edge
-- Function (service role) after staff verify the member at the
-- door — so attendance can't be self-awarded from the app.
-- This file adds the one missing piece: check_ins shipped with RLS
-- on and NO policies, so members couldn't read their own stamps.
-- Members can now read their own check-ins; staff can read all.
-- Writes still go through the check-ticket function only.
-- Additive only — safe to re-run.

drop policy if exists "Members can read their own check-ins" on public.check_ins;
create policy "Members can read their own check-ins"
  on public.check_ins for select
  using (auth.uid() = profile_id);

drop policy if exists "Staff can read all check-ins" on public.check_ins;
create policy "Staff can read all check-ins"
  on public.check_ins for select
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

-- Stamp catalog (kept in the app, facebook-index.html DAOS_STAMPS):
--   daos-party-2026-12-05  -> DAOS Party stamp
--   daos-con-7-2027-03-07  -> DAOS CON 7 stamp
-- When a future event's check-in ships, give its check-ticket
-- function an EVENT slug in the same pattern (daos-<name>-<date>)
-- and add the slug to DAOS_STAMPS. Any check-in whose slug is not
-- in the catalog still renders as its own stamp in the app.
