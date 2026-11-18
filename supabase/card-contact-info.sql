-- DAOS Card contact info (Nov 18, 2026, Jake): HiHello-style cards show
-- the member's own contact rows. Members may OPTIONALLY publish a
-- contact email and a public phone on their DAOS Card; both default to
-- unset (nothing shown). The QR still encodes only the card URL.
-- Additive only — safe to run before the site code that reads them.

alter table public.profiles
  add column if not exists contact_email text
    check (contact_email is null or char_length(contact_email) <= 200);
alter table public.profiles
  add column if not exists contact_phone text
    check (contact_phone is null or char_length(contact_phone) <= 40);
