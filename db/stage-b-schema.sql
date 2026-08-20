-- ═══════════════════════════════════════════════════════════════
--  THE TABLE — Stage B schema
--  Paste this whole file into Supabase: SQL Editor → New query → Run
--  Safe to run once. Running twice will error on "already exists".
-- ═══════════════════════════════════════════════════════════════


-- ── PROFILES ──────────────────────────────────────────────────
-- Supabase stores accounts in auth.users (which we don't touch).
-- This table holds the public-facing part: display name, avatar.
-- It's filled automatically when someone signs in (trigger below).

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'neighbor',
  avatar_url  text,
  is_admin    boolean not null default false,
  is_blocked  boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Auto-create a profile the first time someone signs in with Google.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'name',
      split_part(new.email, '@', 1)
    ),
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ── SECTIONS ──────────────────────────────────────────────────
-- The rooms of The Table. Only you (admin) can add or change these.

create table public.sections (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,      -- used in URLs
  label       text not null,             -- shown on screen
  blurb       text,
  sort_order  int not null default 0,
  is_auto     boolean not null default false,  -- true = fed by news posts
  created_at  timestamptz not null default now()
);


-- ── THREADS ───────────────────────────────────────────────────
-- A topic. Either started by a person, or auto-created as the
-- companion thread for a news post (news_slug is set in that case).

create table public.threads (
  id          uuid primary key default gen_random_uuid(),
  section_id  uuid not null references public.sections(id) on delete cascade,
  author_id   uuid references public.profiles(id) on delete set null,
  title       text not null,
  body        text,
  news_slug   text unique,               -- set only for news companion threads
  is_hidden   boolean not null default false,   -- moderation
  created_at  timestamptz not null default now(),
  last_reply_at timestamptz not null default now()
);

create index threads_section_idx on public.threads(section_id);
create index threads_recent_idx  on public.threads(last_reply_at desc);


-- ── REPLIES ───────────────────────────────────────────────────
-- Messages inside a thread. A comment on a news post is a reply
-- to that post's companion thread — same table, shown two places.

create table public.replies (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.threads(id) on delete cascade,
  author_id   uuid references public.profiles(id) on delete set null,
  body        text not null,
  is_hidden   boolean not null default false,   -- moderation
  is_pending  boolean not null default false,   -- first-post-review toggle
  created_at  timestamptz not null default now()
);

create index replies_thread_idx on public.replies(thread_id, created_at);


-- Keep threads.last_reply_at fresh so "recent activity" sorting works.
create function public.touch_thread_on_reply()
returns trigger language plpgsql as $$
begin
  update public.threads
     set last_reply_at = now()
   where id = new.thread_id;
  return new;
end;
$$;

create trigger on_reply_created
  after insert on public.replies
  for each row execute function public.touch_thread_on_reply();


-- ── SETTINGS ──────────────────────────────────────────────────
-- Site-wide toggles you control. Starts with first-post review ON.

create table public.settings (
  key   text primary key,
  value jsonb not null
);

insert into public.settings (key, value) values
  ('hold_first_post_for_review', 'true'::jsonb);


-- ═══════════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
--  Deny by default; each policy below opens exactly one door.
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles enable row level security;
alter table public.sections enable row level security;
alter table public.threads  enable row level security;
alter table public.replies  enable row level security;
alter table public.settings enable row level security;

-- Helper: is the current user an admin?
create function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

-- Helper: is the current user blocked?
create function public.is_blocked()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_blocked from public.profiles where id = auth.uid()),
    false
  );
$$;


-- PROFILES: everyone can read; you can edit your own.
create policy "profiles readable by all"
  on public.profiles for select using (true);

create policy "own profile editable"
  on public.profiles for update using (auth.uid() = id);


-- SECTIONS: everyone can read; only admin can change.
create policy "sections readable by all"
  on public.sections for select using (true);

create policy "sections admin only"
  on public.sections for all using (public.is_admin());


-- THREADS: everyone reads visible ones; signed-in, non-blocked
-- users may create; authors and admin may edit.
create policy "threads readable by all"
  on public.threads for select
  using (is_hidden = false or public.is_admin());

create policy "signed-in may start threads"
  on public.threads for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
  );

create policy "author or admin may edit thread"
  on public.threads for update
  using (auth.uid() = author_id or public.is_admin());

create policy "author or admin may delete thread"
  on public.threads for delete
  using (auth.uid() = author_id or public.is_admin());


-- REPLIES: same shape. Pending replies are visible only to their
-- author and to admin, until approved.
create policy "replies readable by all"
  on public.replies for select
  using (
    (is_hidden = false and is_pending = false)
    or auth.uid() = author_id
    or public.is_admin()
  );

create policy "signed-in may reply"
  on public.replies for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
  );

create policy "author or admin may edit reply"
  on public.replies for update
  using (auth.uid() = author_id or public.is_admin());

create policy "author or admin may delete reply"
  on public.replies for delete
  using (auth.uid() = author_id or public.is_admin());


-- SETTINGS: readable by all (the site needs the toggle), admin writes.
create policy "settings readable by all"
  on public.settings for select using (true);

create policy "settings admin only"
  on public.settings for all using (public.is_admin());


-- ═══════════════════════════════════════════════════════════════
--  SEED THE FIVE SECTIONS
-- ═══════════════════════════════════════════════════════════════

insert into public.sections (slug, label, blurb, sort_order, is_auto) values
  ('preparedness', 'Preparedness',  'Resilience, off-grid, power, gear.',                1, false),
  ('signal-power', 'Signal & Power','Radio, electronics, the things that carry a voice.', 2, false),
  ('land-water',   'Land & Water',  'The valley''s ground and its water.',                3, false),
  ('briefs',       'Briefs',        'Short notices, calls for hands, time-sensitive.',    4, false),
  ('news',         'News',          'Discussion of posts from the front page.',           5, true);
