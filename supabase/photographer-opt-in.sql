-- Photographer/videographer opt-in for the Party Vault
-- (Jake, Nov 27, 2026). Fully automatic — no approval step: a
-- signed-in member fills the opt-in form on daosmedia.com, agrees
-- to the terms, and the opt_in_photographer RPC instantly sets
-- profiles.is_photographer = true so they can upload right away.
-- Additive only — safe to re-run.

create table if not exists public.photographer_applications (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references auth.users (id) on delete cascade,
  display_name text,
  phone text,
  portfolio_url text,
  media_types text,
  terms_agreed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (member_id)
);

-- ---- RLS ----
alter table public.photographer_applications enable row level security;

drop policy if exists "Members can apply as photographers" on public.photographer_applications;
create policy "Members can apply as photographers"
  on public.photographer_applications for insert
  with check (auth.uid() = member_id);

drop policy if exists "Members can read their own photographer application" on public.photographer_applications;
create policy "Members can read their own photographer application"
  on public.photographer_applications for select
  using (auth.uid() = member_id);

drop policy if exists "Staff can read all photographer applications" on public.photographer_applications;
create policy "Staff can read all photographer applications"
  on public.photographer_applications for select
  using (exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_staff));

-- ---- Opt-in RPC (fully automatic, no approval step) ----
create or replace function public.opt_in_photographer(
  p_display_name text,
  p_phone text,
  p_portfolio_url text,
  p_media_types text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to opt in as a photographer.';
  end if;

  insert into public.photographer_applications
    (member_id, display_name, phone, portfolio_url, media_types, terms_agreed_at)
  values
    (auth.uid(), p_display_name, p_phone, p_portfolio_url, p_media_types, now())
  on conflict (member_id) do update
    set display_name = excluded.display_name,
        phone = excluded.phone,
        portfolio_url = excluded.portfolio_url,
        media_types = excluded.media_types,
        terms_agreed_at = now();

  update public.profiles set is_photographer = true where id = auth.uid();

  return true;
end;
$$;

grant execute on function public.opt_in_photographer(text, text, text, text) to authenticated;
