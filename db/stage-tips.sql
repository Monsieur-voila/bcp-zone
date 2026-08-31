-- ═══════════════════════════════════════════════════════════════
--  CONTACT / TIPS — private inbox
--  Paste into Supabase: SQL Editor → New query → Run
--
--  Anyone (signed in or not) can SEND a tip.
--  Only admins can READ them. Nobody else, ever.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.tips (
  id         uuid primary key default gen_random_uuid(),
  name       text,                    -- optional
  email      text,                    -- optional, for replies
  message    text not null,
  is_read    boolean not null default false,
  is_archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists tips_recent_idx on public.tips(created_at desc);

alter table public.tips enable row level security;

-- Anyone may submit. No account required — a neighbour with a tip
-- shouldn't have to sign up first.
drop policy if exists "anyone may send a tip" on public.tips;
create policy "anyone may send a tip"
  on public.tips for insert
  with check (
    length(coalesce(message, '')) between 2 and 5000
    and length(coalesce(name, '')) <= 120
    and length(coalesce(email, '')) <= 200
  );

-- Only admins may read. This is a private inbox.
drop policy if exists "admins may read tips" on public.tips;
create policy "admins may read tips"
  on public.tips for select
  using (public.is_admin());

-- Only admins may mark read / archive.
drop policy if exists "admins may update tips" on public.tips;
create policy "admins may update tips"
  on public.tips for update
  using (public.is_admin());

drop policy if exists "admins may delete tips" on public.tips;
create policy "admins may delete tips"
  on public.tips for delete
  using (public.is_admin());
