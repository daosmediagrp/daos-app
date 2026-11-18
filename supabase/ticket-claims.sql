-- =====================================================================
-- ticket-claims.sql — DAOS Card QR <-> Shopify tickets (Nov 18, 2026)
--
-- Supports the build spec in
-- goals/daos-iphone-app/files/daos-card-qr-shopify-tickets-spec.md:
--
--   ticket_claims — the email-mismatch fallback. A member whose app
--     email differs from their Shopify checkout email claims their
--     ticket by order number. The check-ticket Edge Function verifies
--     the order LIVE in Shopify (paid, not cancelled, Party product)
--     before writing a row, and rejects an order already claimed by a
--     different member. One claim per Shopify order (UNIQUE), one
--     claim per member per event in practice (the function checks).
--
--   ticket_orders — the orders/paid webhook cache. The check-ticket
--     function upserts a row per Party order when Shopify fires the
--     webhook, and reads it ONLY as a fallback when the live Shopify
--     lookup fails (door resilience — e.g. venue connectivity). The
--     live read stays the source of truth; this table can lag and is
--     never used when Shopify answers.
--
-- RLS: ticket_claims — a member can SELECT their own claims (so the
--   card screen can show "claimed order #…"); all writes go through
--   the Edge Function's service role. ticket_orders — no policies at
--   all (same posture as check_ins): service role only.
--
-- Run in the Supabase SQL Editor. Additive only; safe to re-run.
-- =====================================================================

create table if not exists public.ticket_claims (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  shopify_order_id text not null unique,
  order_number text not null,
  event text not null default 'daos-party-2026-12-05',
  claimed_at timestamptz not null default now()
);

create index if not exists ticket_claims_profile_idx
  on public.ticket_claims (profile_id);

alter table public.ticket_claims enable row level security;

drop policy if exists ticket_claims_select_own on public.ticket_claims;
create policy ticket_claims_select_own on public.ticket_claims
  for select using (auth.uid() = profile_id);

create table if not exists public.ticket_orders (
  shopify_order_id text primary key,
  order_number text,
  email text,
  buyer_name text,
  event text not null default 'daos-party-2026-12-05',
  amount numeric,
  status text,
  paid_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists ticket_orders_email_idx
  on public.ticket_orders (lower(email));

alter table public.ticket_orders enable row level security;
-- No policies on purpose: only the service role (Edge Function) reads
-- or writes this cache.
