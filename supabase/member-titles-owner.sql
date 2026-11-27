-- Add 'Owner' and 'DAOS STAFF' to member titles (Jake, Nov 26, 2026).
-- Replaces the check constraint from member-titles.sql with the
-- expanded list. Safe to re-run.

alter table public.profiles
  drop constraint if exists profiles_member_title_check;

alter table public.profiles
  add constraint profiles_member_title_check
  check (member_title in ('Owner','DAOS STAFF','Partner','V.I.P','Representative First Class','Representative','Supporter','Vendor','Member'));
