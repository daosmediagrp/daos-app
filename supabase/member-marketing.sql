-- Member phone + marketing opt-ins (Jake, Nov 19, 2026): a phone
-- number is required to sign up, and Supabase feeds Shopify so
-- DAOS can run SMS and email blasts.
-- The account phone is a PRIVATE field (profiles.phone) — it is
-- NOT the public contact_phone a member may choose to show on
-- their DAOS Card. Opt-ins are explicit checkboxes from the
-- sign-up form, timestamped; SMS marketing is opt-in only, and
-- the shopify-sync Edge Function sends Shopify marketing consent
-- only for members who opted in. Every app member syncs to
-- Shopify as a customer tagged 'daos-app' (account relationship);
-- Jake's old ~30K list is NOT part of this — app sign-ups only.
-- Additive only — safe to re-run.

alter table public.profiles
  add column if not exists phone text
    check (phone is null or char_length(phone) <= 40);
alter table public.profiles
  add column if not exists email_opt_in boolean not null default false;
alter table public.profiles
  add column if not exists email_opt_in_at timestamptz;
alter table public.profiles
  add column if not exists sms_opt_in boolean not null default false;
alter table public.profiles
  add column if not exists sms_opt_in_at timestamptz;
alter table public.profiles
  add column if not exists shopify_customer_id text;
alter table public.profiles
  add column if not exists shopify_synced_at timestamptz;

-- The sync reads with the service role (bypasses RLS). Members
-- keep using the existing profile policies for their own rows —
-- no new policies needed: phone/opt-in writes go through the
-- member's own upsert, same as the rest of the profile.
