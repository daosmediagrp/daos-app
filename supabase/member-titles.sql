-- Member titles for the DAOS app (Jake, Nov 19, 2026).
-- Every member shows a title under their DAOS Card. Everyone who
-- joins is a "Member" by default; the higher titles are verified
-- and assigned by DAOS staff only:
--   Partner (shows a verified star), V.I.P, Representative First
--   Class, Representative, Supporter, Vendor, Member.
-- Additive only — safe to re-run.

alter table public.profiles
  add column if not exists member_title text not null default 'Member';

do $$
begin
  alter table public.profiles
    add constraint profiles_member_title_check
    check (member_title in ('Partner','V.I.P','Representative First Class','Representative','Supporter','Vendor','Member'));
exception when duplicate_object then null;
end $$;

-- Guard: only staff can change a title. A member editing their own
-- profile (name, bio, photo...) keeps their existing title; the
-- change is silently reverted. SQL editor / service role (no
-- auth.uid()) can always set titles directly.
create or replace function public.guard_member_title()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.member_title is distinct from old.member_title then
    if auth.uid() is not null
       and not exists (select 1 from public.profiles p
                       where p.id = auth.uid() and p.is_staff) then
      new.member_title := old.member_title;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_member_title on public.profiles;
create trigger trg_guard_member_title
  before update on public.profiles
  for each row execute function public.guard_member_title();

-- Let staff update other members' profiles from the app (the
-- in-app "Set member title" control on a member's card). The
-- trigger above still restricts title changes to staff.
drop policy if exists "Staff can update any profile" on public.profiles;
create policy "Staff can update any profile"
  on public.profiles for update
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff))
  with check (true);
