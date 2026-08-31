#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  THE TABLE — Stage C installer
#  Run from inside ~/site:    bash setup-stagec.sh
#
#  Writes all Stage C files to their correct folders.
#  Then: run db/stage-c-moderation.sql in Supabase SQL Editor.
# ═══════════════════════════════════════════════════════════
set -e

if [ ! -f package.json ]; then
  echo "ERROR: run this from inside ~/site (no package.json here)."; exit 1
fi

echo "Writing Stage C files..."
mkdir -p db src/lib src/styles src/components src/pages/forum

echo "  db/stage-c-moderation.sql"
cat > 'db/stage-c-moderation.sql' << 'STAGEC_EOF'
-- ═══════════════════════════════════════════════════════════════
--  THE TABLE — Stage C: posting + moderation floor
--  Paste into Supabase: SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════


-- ── Has this person posted before? ────────────────────────────
create or replace function public.is_first_post(uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select not exists (
    select 1 from public.replies
     where author_id = uid and is_pending = false
    union all
    select 1 from public.threads
     where author_id = uid
  );
$$;


-- ── Rate limit: max 5 posts per 5 minutes ─────────────────────
create or replace function public.under_rate_limit(uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select (
    (select count(*) from public.replies
      where author_id = uid and created_at > now() - interval '5 minutes')
    +
    (select count(*) from public.threads
      where author_id = uid and created_at > now() - interval '5 minutes')
  ) < 5;
$$;


-- ── Read a boolean setting ────────────────────────────────────
create or replace function public.setting_bool(k text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select (value#>>'{}')::boolean from public.settings where key = k), false);
$$;


-- ── Enforce the floor on writes ───────────────────────────────
drop policy if exists "signed-in may start threads" on public.threads;
create policy "signed-in may start threads"
  on public.threads for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
    and public.under_rate_limit(auth.uid())
  );

drop policy if exists "signed-in may reply" on public.replies;
create policy "signed-in may reply"
  on public.replies for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
    and public.under_rate_limit(auth.uid())
    and (
      public.setting_bool('hold_first_post_for_review') = false
      or public.is_first_post(auth.uid()) = false
      or is_pending = true
    )
  );


-- ── Admin: move a thread between sections ─────────────────────
create or replace function public.move_thread(thread uuid, new_section uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not permitted';
  end if;
  update public.threads set section_id = new_section where id = thread;
end;
$$;


-- ── Admin: approve a pending reply ────────────────────────────
create or replace function public.approve_reply(reply uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not permitted';
  end if;
  update public.replies set is_pending = false where id = reply;
end;
$$;
STAGEC_EOF

echo "  src/lib/forum.ts"
cat > 'src/lib/forum.ts' << 'STAGEC_EOF'
// ─────────────────────────────────────────────────────────────
//  Forum data layer — reads from Supabase.
//
//  The site is static, so all forum data is fetched in the
//  BROWSER at runtime. Pages render instantly, then populate.
// ─────────────────────────────────────────────────────────────

import { supabase } from "./supabase";

// ── HEAT ──────────────────────────────────────────────────────
// "What's hot" — a 0-100 number driving the pulse colour/speed.
//
// Stage B first pass, per the spec's emphasis on RECENCY and VOLUME:
//   recency  — how long since the last reply (decays over 48h)
//   volume   — how many replies exist at all
//
// Stage E will refine this with distinct-participant counts once
// there's real traffic to tune against. Tune the weights here.

export const HEAT = {
  recencyWeight: 65,     // max points from "something happened lately"
  volumeWeight: 35,      // max points from "lots has happened"
  recencyWindowHours: 48, // older than this contributes no recency
  volumeSaturation: 20,   // this many replies = full volume score
};

export function heatFrom(lastActivity: string | null, replyCount: number): number {
  if (!lastActivity) return 0;

  const hoursSince =
    (Date.now() - new Date(lastActivity).getTime()) / (1000 * 60 * 60);

  // Recency: 1.0 at this instant, decaying to 0 across the window.
  const recency = Math.max(0, 1 - hoursSince / HEAT.recencyWindowHours);

  // Volume: climbs toward 1.0, saturating so one loud thread
  // doesn't permanently outrank everything.
  const volume = Math.min(1, replyCount / HEAT.volumeSaturation);

  const score = recency * HEAT.recencyWeight + volume * HEAT.volumeWeight;
  return Math.round(Math.min(100, score));
}

// Bucket a heat score into a state name, used by the CSS.
export function heatState(heat: number): "quiet" | "warm" | "live" | "hot" {
  if (heat >= 70) return "hot";
  if (heat >= 35) return "live";
  if (heat >= 10) return "warm";
  return "quiet";
}

// ── TYPES ─────────────────────────────────────────────────────

export type Section = {
  id: string;
  slug: string;
  label: string;
  blurb: string | null;
  sort_order: number;
  is_auto: boolean;
  threadCount: number;
  replyCount: number;
  lastActivity: string | null;
  heat: number;
};

export type Thread = {
  id: string;
  title: string;
  body: string | null;
  created_at: string;
  last_reply_at: string;
  news_slug: string | null;
  author: string;
  replyCount: number;
  heat: number;
};

// ── QUERIES ───────────────────────────────────────────────────

// All sections, with counts and heat rolled up from their threads.
export async function getSections(): Promise<Section[]> {
  const { data: sections, error } = await supabase
    .from("sections")
    .select("id, slug, label, blurb, sort_order, is_auto")
    .order("sort_order");

  if (error || !sections) {
    console.error("[forum] sections query failed:", error?.message);
    return [];
  }

  // Pull threads once, then roll up per section in JS. Cheaper than
  // one query per section, and fine at community scale.
  const { data: threads } = await supabase
    .from("threads")
    .select("id, section_id, last_reply_at")
    .eq("is_hidden", false);

  const { data: replies } = await supabase
    .from("replies")
    .select("thread_id")
    .eq("is_hidden", false)
    .eq("is_pending", false);

  // thread_id -> reply count
  const repliesByThread = new Map<string, number>();
  (replies ?? []).forEach((r: any) => {
    repliesByThread.set(r.thread_id, (repliesByThread.get(r.thread_id) ?? 0) + 1);
  });

  return sections.map((s: any) => {
    const own = (threads ?? []).filter((t: any) => t.section_id === s.id);
    const replyCount = own.reduce(
      (n, t: any) => n + (repliesByThread.get(t.id) ?? 0),
      0
    );
    const lastActivity = own.reduce<string | null>((latest, t: any) => {
      if (!latest || t.last_reply_at > latest) return t.last_reply_at;
      return latest;
    }, null);

    return {
      ...s,
      threadCount: own.length,
      replyCount,
      lastActivity,
      heat: heatFrom(lastActivity, replyCount),
    } as Section;
  });
}

// One section by slug (for the section page header).
export async function getSection(slug: string) {
  const { data, error } = await supabase
    .from("sections")
    .select("id, slug, label, blurb, is_auto")
    .eq("slug", slug)
    .single();

  if (error) {
    console.error("[forum] section query failed:", error.message);
    return null;
  }
  return data;
}

// Threads in a section, newest activity first.
export async function getThreads(sectionId: string): Promise<Thread[]> {
  const { data, error } = await supabase
    .from("threads")
    .select(
      "id, title, body, created_at, last_reply_at, news_slug, profiles(display_name)"
    )
    .eq("section_id", sectionId)
    .eq("is_hidden", false)
    .order("last_reply_at", { ascending: false });

  if (error || !data) {
    console.error("[forum] threads query failed:", error?.message);
    return [];
  }

  const ids = data.map((t: any) => t.id);
  const counts = new Map<string, number>();
  if (ids.length) {
    const { data: replies } = await supabase
      .from("replies")
      .select("thread_id")
      .in("thread_id", ids)
      .eq("is_hidden", false)
      .eq("is_pending", false);
    (replies ?? []).forEach((r: any) => {
      counts.set(r.thread_id, (counts.get(r.thread_id) ?? 0) + 1);
    });
  }

  return data.map((t: any) => {
    const replyCount = counts.get(t.id) ?? 0;
    return {
      id: t.id,
      title: t.title,
      body: t.body,
      created_at: t.created_at,
      last_reply_at: t.last_reply_at,
      news_slug: t.news_slug,
      author: t.profiles?.display_name ?? "neighbor",
      replyCount,
      heat: heatFrom(t.last_reply_at, replyCount),
    } as Thread;
  });
}

// The hottest / most recent threads across all sections,
// for the homepage rail.
export async function getRecentThreads(limit = 4): Promise<Thread[]> {
  const { data, error } = await supabase
    .from("threads")
    .select(
      "id, title, last_reply_at, created_at, body, news_slug, sections(slug), profiles(display_name)"
    )
    .eq("is_hidden", false)
    .order("last_reply_at", { ascending: false })
    .limit(limit);

  if (error || !data) {
    console.error("[forum] recent threads failed:", error?.message);
    return [];
  }

  const ids = data.map((t: any) => t.id);
  const counts = new Map<string, number>();
  if (ids.length) {
    const { data: replies } = await supabase
      .from("replies")
      .select("thread_id")
      .in("thread_id", ids)
      .eq("is_hidden", false)
      .eq("is_pending", false);
    (replies ?? []).forEach((r: any) => {
      counts.set(r.thread_id, (counts.get(r.thread_id) ?? 0) + 1);
    });
  }

  return data.map((t: any) => {
    const replyCount = counts.get(t.id) ?? 0;
    return {
      id: t.id,
      title: t.title,
      body: t.body,
      created_at: t.created_at,
      last_reply_at: t.last_reply_at,
      news_slug: t.news_slug,
      author: t.profiles?.display_name ?? "neighbor",
      replyCount,
      heat: heatFrom(t.last_reply_at, replyCount),
    } as Thread;
  });
}

// Friendly relative time: "3m", "2h", "4d".
export function ago(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return "now";
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h`;
  const days = Math.floor(hrs / 24);
  if (days < 30) return `${days}d`;
  return `${Math.floor(days / 30)}mo`;
}

// ═══════════════════════════════════════════════════════════════
//  WRITES — Stage C
//  Every write goes through Supabase with RLS enforcing the rules.
//  The client marks first posts pending; the DB policy makes it
//  non-negotiable, so a tampered client can't bypass review.
// ═══════════════════════════════════════════════════════════════

export async function currentUser() {
  const { data } = await supabase.auth.getSession();
  return data.session?.user ?? null;
}

export async function myProfile() {
  const user = await currentUser();
  if (!user) return null;
  const { data } = await supabase
    .from("profiles")
    .select("id, display_name, is_admin, is_blocked")
    .eq("id", user.id)
    .single();
  return data;
}

// Is first-post review switched on, and is this person a first-timer?
export async function needsReview(userId: string): Promise<boolean> {
  const { data: setting } = await supabase
    .from("settings")
    .select("value")
    .eq("key", "hold_first_post_for_review")
    .single();

  if (setting?.value !== true) return false;

  const { data } = await supabase.rpc("is_first_post", { uid: userId });
  return data === true;
}

export async function createThread(
  sectionId: string,
  title: string,
  body: string
) {
  const user = await currentUser();
  if (!user) return { error: "You need to be signed in." };

  const clean = title.trim();
  if (clean.length < 4) return { error: "Give it a title (4+ characters)." };
  if (clean.length > 140) return { error: "Title is too long (140 max)." };

  const { data, error } = await supabase
    .from("threads")
    .insert({
      section_id: sectionId,
      author_id: user.id,
      title: clean,
      body: body.trim() || null,
    })
    .select("id")
    .single();

  if (error) {
    // RLS rejections surface here — usually the rate limit.
    if (error.message.includes("row-level security")) {
      return { error: "Slow down a moment — too many posts just now." };
    }
    return { error: error.message };
  }
  return { id: data.id };
}

export async function createReply(threadId: string, body: string) {
  const user = await currentUser();
  if (!user) return { error: "You need to be signed in." };

  const clean = body.trim();
  if (clean.length < 2) return { error: "Say a little more." };
  if (clean.length > 5000) return { error: "That's too long (5000 max)." };

  const pending = await needsReview(user.id);

  const { error } = await supabase.from("replies").insert({
    thread_id: threadId,
    author_id: user.id,
    body: clean,
    is_pending: pending,
  });

  if (error) {
    if (error.message.includes("row-level security")) {
      return { error: "Slow down a moment — too many posts just now." };
    }
    return { error: error.message };
  }
  return { pending };
}

// One thread with its replies.
export async function getThread(id: string) {
  const { data: thread, error } = await supabase
    .from("threads")
    .select(
      "id, title, body, created_at, section_id, news_slug, sections(slug,label), profiles(display_name)"
    )
    .eq("id", id)
    .single();

  if (error || !thread) return null;

  const { data: replies } = await supabase
    .from("replies")
    .select("id, body, created_at, is_pending, author_id, profiles(display_name)")
    .eq("thread_id", id)
    .eq("is_hidden", false)
    .order("created_at");

  return { thread, replies: replies ?? [] };
}

// ── Admin actions ─────────────────────────────────────────────

export async function moveThread(threadId: string, newSectionId: string) {
  const { error } = await supabase.rpc("move_thread", {
    thread: threadId,
    new_section: newSectionId,
  });
  return error ? { error: error.message } : { ok: true };
}

export async function approveReply(replyId: string) {
  const { error } = await supabase.rpc("approve_reply", { reply: replyId });
  return error ? { error: error.message } : { ok: true };
}

export async function hideThread(threadId: string) {
  const { error } = await supabase
    .from("threads")
    .update({ is_hidden: true })
    .eq("id", threadId);
  return error ? { error: error.message } : { ok: true };
}

export async function hideReply(replyId: string) {
  const { error } = await supabase
    .from("replies")
    .update({ is_hidden: true })
    .eq("id", replyId);
  return error ? { error: error.message } : { ok: true };
}
STAGEC_EOF

echo "  src/styles/forum.css"
cat > 'src/styles/forum.css' << 'STAGEC_EOF'
/* ═══════════════════════════════════════════════════════════════
   FORUM LAYOUT — sections, threads, rails.

   These rules live in a plain .css file ON PURPOSE.
   The section and thread cards are injected by JavaScript at
   runtime, so Astro's scoped <style> blocks never reach them.
   Plain CSS is not scoped, so it applies to everything.

   Tune padding / sizes / spacing here.
   ═══════════════════════════════════════════════════════════════ */

/* ── SECTION CARDS (The Table) ──────────────────────────────── */

.sections { list-style: none; margin: 0 0 2rem; padding: 0; }

.section {
  background: linear-gradient(180deg, var(--basalt-2) 0%, #171b1f 100%);
  margin-bottom: 0.9rem;
  transition: transform 0.2s ease;
}
.section:hover { transform: translateY(-1px); }

.s-link {
  display: flex;
  align-items: center;
  gap: 1.2rem;
  padding: 1.6rem 1.6rem;      /* KNOB: cushion inside the box */
  text-decoration: none;
}

.s-text { display: flex; flex-direction: column; gap: 0.3rem; }

.s-label {
  font-family: var(--display);
  font-size: 1.6rem;           /* KNOB: section name size */
  letter-spacing: 0.02em;
  color: var(--snowmelt);
}

.s-blurb {
  font-family: var(--body);
  font-size: 0.95rem;
  color: var(--sage);
}

.s-count {
  margin-left: auto;
  font-family: var(--mono);
  font-size: 0.68rem;
  color: var(--sage);
  flex: none;
}

/* ── THREAD CARDS (inside a section) ────────────────────────── */

.threads { list-style: none; margin: 0; padding: 0; }

.thread {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 1.3rem 1.4rem;      /* KNOB: cushion inside thread box */
  background: var(--basalt-2);
  margin-bottom: 0.8rem;
  transition: transform 0.2s ease;
}
.thread:hover { transform: translateY(-1px); }

.t-text { display: flex; flex-direction: column; gap: 0.3rem; }

.t-title {
  font-family: var(--body);
  font-size: 1.12rem;
  color: var(--snowmelt);
  line-height: 1.3;
}

.t-meta {
  font-family: var(--mono);
  font-size: 0.64rem;
  letter-spacing: 0.06em;
  color: var(--sage);
}

/* ── SHARED STATES ──────────────────────────────────────────── */

.loading, .empty {
  font-family: var(--mono);
  font-size: 0.72rem;
  line-height: 1.6;
  color: var(--sage);
  opacity: 0.8;
  padding: 1.2rem 0;
}

/* ── HOMEPAGE RAIL THREADS ──────────────────────────────────── */

.rail-loading {
  color: var(--sage);
  opacity: 0.7;
  font-style: italic;
}

/* ── REPLIES (thread page) ──────────────────────────────────── */

.replies { list-style: none; margin: 0 0 2.4rem; padding: 0; }

.reply {
  padding: 1.2rem 1.3rem;
  background: var(--basalt-2);
  border: 1px solid var(--line);
  border-radius: 3px;
  margin-bottom: 0.8rem;
}
.reply.pending { border-style: dashed; opacity: 0.85; }

.r-meta {
  font-family: var(--mono);
  font-size: 0.62rem;
  letter-spacing: 0.08em;
  color: var(--sage);
  margin-bottom: 0.5rem;
}
.pending-tag {
  color: var(--heat-c1, #d9a441);
  margin-left: 0.5rem;
}
.r-body {
  font-family: var(--body);
  font-size: 1.02rem;
  line-height: 1.6;
  color: var(--snowmelt);
  white-space: pre-wrap;
}
.r-admin { margin-top: 0.7rem; display: flex; gap: 0.5rem; }

/* ── REPLY BOX ──────────────────────────────────────────────── */

.reply-box {
  border-top: 1px solid var(--line);
  padding-top: 1.6rem;
}
.reply-form { display: flex; flex-direction: column; gap: 0.8rem; }
.reply-box .input {
  font-family: var(--body); font-size: 1rem; color: var(--snowmelt);
  background: var(--basalt-2); border: 1px solid var(--line);
  border-radius: 3px; padding: 0.8rem;
  line-height: 1.5; resize: vertical;
}
.reply-box .input:focus { border-color: var(--oxide); outline: none; }
.reply-box .post-btn {
  align-self: flex-start;
  font-family: var(--mono); font-size: 0.72rem;
  letter-spacing: 0.12em; text-transform: uppercase;
  color: var(--basalt); background: var(--oxide);
  border: 1px solid var(--oxide); border-radius: 3px;
  padding: 0.6rem 1.2rem; cursor: pointer;
}
.reply-box .post-btn:hover { background: #d2683a; }
.reply-box .post-btn:disabled { opacity: 0.6; cursor: default; }
.reply-box .notice {
  font-family: var(--mono); font-size: 0.7rem;
  color: var(--heat-c1, #d9a441); margin: 0;
}
.reply-box .signed-out {
  font-family: var(--mono); font-size: 0.72rem;
  color: var(--sage); margin: 0 0 1rem;
}
.auth-slot { margin-top: 1.2rem; display: flex; }

/* thread card becomes a link */
.t-link {
  display: flex;
  align-items: center;
  gap: 1rem;
  text-decoration: none;
  flex: 1;
}
STAGEC_EOF

echo "  src/styles/heat.css"
cat > 'src/styles/heat.css' << 'STAGEC_EOF'
/* ═══════════════════════════════════════════════════════════════
   HEAT — "what's hot" indicator for The Table.

   Three bands of behaviour:
     LOW   a dot flashes in place on the bottom edge. No travel.
     MED   a segment traverses the bottom edge. Faster as heat rises.
     HIGH  travels half the box, then HOLDS. No flashing. Calm,
           but the colour itself carries the urgency.

   The border colour shifts smoothly yellow -> red with heat.

   ─── KNOBS ────────────────────────────────────────────────────
   Everything you'd want to tune is in the :root block below.
   Change, save, refresh. Experimental by design.
   ═══════════════════════════════════════════════════════════════ */

:root {
  /* ── Colour stops: rest (yellow) through to hot (red) ── */
  --heat-c0: #d9c04a;   /* baseline / quiet — yellow */
  --heat-c1: #d9a441;   /* stirring — amber */
  --heat-c2: #c9803e;   /* warm — amber-rust */
  --heat-c3: #c05a2e;   /* live — oxide */
  --heat-c4: #d93b1f;   /* hot — red */

  /* ── Band thresholds (heat is 0–100) ──
     Below LOW-max: dot flashes in place.
     Between: segment traverses the bottom edge.
     Above HIGH-min: travels half, then holds. */
  --heat-band-low:  25;   /* documentation only; logic lives in forum.ts */
  --heat-band-high: 70;

  /* ── Motion ──
     travel-dur  = how long one sweep takes (fast flick)
     gap-*       = rest between sweeps; smaller = more often */
  --heat-travel-dur: 0.125s;
  --heat-gap-slow:   3.2s;    /* low activity */
  --heat-gap-med:    1.6s;    /* medium */
  --heat-gap-fast:   0.9s;    /* upper medium */

  /* ── Geometry ── */
  --heat-rail-h:     2px;     /* thickness of the bottom rail */
  --heat-dot-w:      10%;     /* width of the "flash in place" dot */
  --heat-seg-w:      22%;     /* width of the travelling segment */
  --heat-hold-w:     50%;     /* HIGH: how far it travels and holds */
}

/* ── The card ────────────────────────────────────────────────
   Put data-heat="quiet|warm|live|hot" on the card element.
   Border colour follows the band. */

.heat-card {
  position: relative;
  overflow: hidden;                 /* keeps the rail inside the corners */
  border: 1px solid var(--heat-border, var(--heat-c0));
  border-radius: 3px;
  transition: border-color 0.6s ease;
}

[data-heat="quiet"] { --heat-border: var(--heat-c0); --heat-rgb: 217, 192, 74; }
[data-heat="warm"]  { --heat-border: var(--heat-c2); --heat-rgb: 201, 128, 62; }
[data-heat="live"]  { --heat-border: var(--heat-c3); --heat-rgb: 192,  90, 46; }
[data-heat="hot"]   { --heat-border: var(--heat-c4); --heat-rgb: 217,  59, 31; }

/* ── The rail: a track along the bottom edge of the card ───── */
.heat-rail {
  position: absolute;
  left: 0; right: 0; bottom: 0;
  height: var(--heat-rail-h);
  pointer-events: none;
  overflow: hidden;
}

/* The moving light itself. */
.heat-rail::after {
  content: "";
  position: absolute;
  top: 0; bottom: 0;
  left: 0;
  width: var(--heat-dot-w);
  background: linear-gradient(
    90deg,
    transparent 0%,
    rgb(var(--heat-rgb)) 50%,
    transparent 100%
  );
  filter: drop-shadow(0 0 4px rgba(var(--heat-rgb), 0.75));
  opacity: 0;
}

/* QUIET — nothing. Just the yellow border. */
[data-heat="quiet"] .heat-rail::after { opacity: 0; animation: none; }

/* LOW / WARM — a dot flashing in place, no travel. */
[data-heat="warm"] .heat-rail::after {
  width: var(--heat-dot-w);
  left: 50%;
  transform: translateX(-50%);
  animation: heat-blink var(--heat-gap-slow) steps(1, end) infinite;
}

/* MEDIUM / LIVE — a segment traverses the bottom edge. */
[data-heat="live"] .heat-rail::after {
  width: var(--heat-seg-w);
  animation: heat-travel var(--heat-gap-med) linear infinite;
}

/* HIGH / HOT — travels half the box, then HOLDS. No flashing.
   Steady presence: the colour carries the urgency. */
[data-heat="hot"] .heat-rail::after {
  width: var(--heat-hold-w);
  left: 0;
  opacity: 1;
  animation: heat-settle 1.4s ease-out 1 forwards;
  background: linear-gradient(
    90deg,
    rgb(var(--heat-rgb)) 0%,
    rgba(var(--heat-rgb), 0.55) 70%,
    transparent 100%
  );
}

/* ── Keyframes ─────────────────────────────────────────────── */

/* flash in place: brief on, long off */
@keyframes heat-blink {
  0%   { opacity: 0; }
  2%   { opacity: 1; }
  6%   { opacity: 0; }
  100% { opacity: 0; }
}

/* fast sweep across, then rest.
   The visible travel occupies only the first slice of the cycle,
   so --heat-gap-* controls how OFTEN, not how fast. */
@keyframes heat-travel {
  0%   { transform: translateX(-100%); opacity: 0; }
  1%   { opacity: 1; }
  8%   { transform: translateX(calc(100vw)); opacity: 1; }
  9%   { opacity: 0; }
  100% { transform: translateX(calc(100vw)); opacity: 0; }
}

/* settle in and hold */
@keyframes heat-settle {
  0%   { transform: translateX(-100%); opacity: 0; }
  60%  { opacity: 1; }
  100% { transform: translateX(0); opacity: 1; }
}

/* ── The dot (used in headings and the rail card) ──────────── */
.heat-dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  flex: none;
  background: var(--heat-border, var(--heat-c0));
  opacity: 0.55;
  transition: background 0.6s ease, opacity 0.6s ease;
}
[data-heat="warm"] .heat-dot,
.heat-dot[data-heat="warm"] { opacity: 0.9; }
[data-heat="live"] .heat-dot,
.heat-dot[data-heat="live"] { opacity: 1; }
[data-heat="hot"]  .heat-dot,
.heat-dot[data-heat="hot"]  { opacity: 1; }

/* ── OFF SWITCH ────────────────────────────────────────────────
   All motion stops for anyone who asks for reduced motion.
   Colour still communicates heat; nothing moves. */
@media (prefers-reduced-motion: reduce) {
  .heat-rail::after {
    animation: none !important;
    opacity: 0.9 !important;
    transform: none !important;
    left: 0 !important;
    width: var(--heat-hold-w) !important;
  }
  [data-heat="quiet"] .heat-rail::after { opacity: 0 !important; }
  .heat-dot { animation: none !important; }
}
STAGEC_EOF

echo "  src/components/ThreadComposer.astro"
cat > 'src/components/ThreadComposer.astro' << 'STAGEC_EOF'
---
// ─────────────────────────────────────────────────────────────
//  ThreadComposer — "Start a thread".
//
//  Two modes, set by the `mode` prop:
//    "section"  section comes from context; no picker.
//    "picker"   shows a section chooser with blurbs, so a
//               newcomer can tell Briefs from Preparedness.
//
//  Signed out, it invites sign-in instead of showing the form.
// ─────────────────────────────────────────────────────────────
interface Props {
  mode?: "section" | "picker";
  sectionId?: string;
}
const { mode = "section", sectionId = "" } = Astro.props;
---

<div class="composer" data-composer data-mode={mode} data-section-id={sectionId}>
  <!-- signed out -->
  <p class="signed-out" data-composer-signedout hidden>
    Sign in to start a thread.
  </p>

  <!-- collapsed: the button -->
  <button class="start-btn" type="button" data-composer-open hidden>
    Start a thread
  </button>

  <!-- expanded: the form -->
  <div class="form" data-composer-form hidden>
    {mode === "picker" && (
      <label class="field">
        <span class="label">Which part of The Table?</span>
        <select class="input select" data-composer-section></select>
        <span class="hint" data-composer-hint></span>
      </label>
    )}

    <label class="field">
      <span class="label">Title</span>
      <input class="input" type="text" maxlength="140"
             placeholder="What's this about?" data-composer-title />
    </label>

    <label class="field">
      <span class="label">Say more <span class="opt">(optional)</span></span>
      <textarea class="input area" rows="5"
                placeholder="Context, details, what you need."
                data-composer-body></textarea>
    </label>

    <p class="notice" data-composer-notice hidden></p>

    <div class="actions">
      <button class="post-btn" type="button" data-composer-post>Post it</button>
      <button class="cancel-btn" type="button" data-composer-cancel>Cancel</button>
    </div>
  </div>
</div>

<script>
  import { supabase } from "../lib/supabase";
  import { createThread, currentUser } from "../lib/forum";

  const root = document.querySelector("[data-composer]");
  if (root) {
    const mode      = root.dataset.mode;
    const signedOut = root.querySelector("[data-composer-signedout]");
    const openBtn   = root.querySelector("[data-composer-open]");
    const form      = root.querySelector("[data-composer-form]");
    const titleEl   = root.querySelector("[data-composer-title]");
    const bodyEl    = root.querySelector("[data-composer-body]");
    const noticeEl  = root.querySelector("[data-composer-notice]");
    const postBtn   = root.querySelector("[data-composer-post]");
    const cancelBtn = root.querySelector("[data-composer-cancel]");
    const selectEl  = root.querySelector("[data-composer-section]");
    const hintEl    = root.querySelector("[data-composer-hint]");

    let sections = [];

    function show(session) {
      const inUser = !!session?.user;
      signedOut.hidden = inUser;
      openBtn.hidden = !inUser;
      if (!inUser) form.hidden = true;
    }

    const { data } = await supabase.auth.getSession();
    show(data.session);
    supabase.auth.onAuthStateChange((_e, s) => show(s));

    // Picker mode: load sections with their blurbs so the choice
    // is self-explanatory for someone new.
    if (mode === "picker" && selectEl) {
      const { data: rows } = await supabase
        .from("sections")
        .select("id, label, blurb, sort_order")
        .order("sort_order");
      sections = rows ?? [];
      selectEl.innerHTML = sections
        .map((s) => `<option value="${s.id}">${s.label}</option>`)
        .join("");
      const setHint = () => {
        const s = sections.find((x) => x.id === selectEl.value);
        hintEl.textContent = s?.blurb ?? "";
      };
      selectEl.addEventListener("change", setHint);
      setHint();
    }

    openBtn.addEventListener("click", () => {
      form.hidden = false;
      openBtn.hidden = true;
      titleEl.focus();
    });

    cancelBtn.addEventListener("click", () => {
      form.hidden = true;
      openBtn.hidden = false;
      noticeEl.hidden = true;
      titleEl.value = "";
      bodyEl.value = "";
    });

    postBtn.addEventListener("click", async () => {
      // Read at click time — the section page fills this in
      // after its data loads.
      const sectionId =
        mode === "picker" ? selectEl.value : root.dataset.sectionId;

      if (!sectionId) {
        noticeEl.textContent = "Pick a section first.";
        noticeEl.hidden = false;
        return;
      }

      postBtn.disabled = true;
      postBtn.textContent = "Posting…";
      noticeEl.hidden = true;

      const res = await createThread(sectionId, titleEl.value, bodyEl.value);

      postBtn.disabled = false;
      postBtn.textContent = "Post it";

      if (res.error) {
        noticeEl.textContent = res.error;
        noticeEl.hidden = false;
        return;
      }
      window.location.href = `/forum/thread?id=${res.id}`;
    });
  }
</script>

<style>
  .composer { margin: 0 0 2rem; }

  .signed-out {
    font-family: var(--mono); font-size: 0.72rem;
    color: var(--sage); margin: 0; text-align: center;
  }

  .start-btn {
    display: inline-flex; align-items: center;
    font-family: var(--mono); font-size: 0.74rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.7rem 1.2rem; cursor: pointer;
    transition: background 0.2s ease, border-color 0.2s ease;
  }
  .start-btn:hover { background: rgba(192, 90, 46, 0.1); }

  .form {
    display: flex; flex-direction: column; gap: 1.1rem;
    background: var(--basalt-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    padding: 1.5rem;
  }
  .field { display: flex; flex-direction: column; gap: 0.45rem; }
  .label {
    font-family: var(--mono); font-size: 0.66rem;
    letter-spacing: 0.1em; text-transform: uppercase; color: var(--snowmelt);
  }
  .opt { color: var(--sage); text-transform: none; letter-spacing: 0; }
  .input {
    font-family: var(--body); font-size: 1rem; color: var(--snowmelt);
    background: var(--basalt); border: 1px solid var(--line);
    border-radius: 3px; padding: 0.7rem 0.8rem;
  }
  .input:focus { border-color: var(--oxide); outline: none; }
  .area { resize: vertical; line-height: 1.5; }
  .select { cursor: pointer; }
  .hint {
    font-family: var(--body); font-style: italic;
    font-size: 0.85rem; color: var(--sage);
  }

  .notice {
    font-family: var(--mono); font-size: 0.7rem;
    color: var(--heat-c4, #d93b1f); margin: 0;
  }

  .actions { display: flex; align-items: center; gap: 0.8rem; }
  .post-btn {
    font-family: var(--mono); font-size: 0.72rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--basalt); background: var(--oxide);
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.6rem 1.2rem; cursor: pointer;
  }
  .post-btn:hover { background: #d2683a; }
  .post-btn:disabled { opacity: 0.6; cursor: default; }
  .cancel-btn {
    font-family: var(--mono); font-size: 0.66rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: none; cursor: pointer;
  }
  .cancel-btn:hover { color: var(--snowmelt); }
</style>
STAGEC_EOF

echo "  src/pages/forum.astro"
cat > 'src/pages/forum.astro' << 'STAGEC_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import AuthButton from "../components/AuthButton.astro";
import ThreadComposer from "../components/ThreadComposer.astro";
import "../styles/heat.css";
import "../styles/forum.css";
import { forum } from "../site.config";
---
<SiteFrame title="The Table — Blaine County Preparedness" description="The community forum. Pull up a chair.">
  <div class="table">
    <div class="table-head">
      <div class="table-title-row">
        <span class="heat-dot" data-table-pulse></span>
        <h1 class="h1">The Table</h1>
      </div>
      <div class="table-auth"><AuthButton /></div>
    </div>
    <p class="lede">{forum.line}</p>

    <ThreadComposer mode="picker" />

    <ul class="sections" data-sections>
      <li class="loading">Opening the room…</li>
    </ul>

    <p class="soon" data-empty hidden>
      No threads yet. The chairs are set — someone has to speak first.
    </p>
  </div>
</SiteFrame>

<script>
  import { getSections, heatState } from "../lib/forum";

  const list = document.querySelector("[data-sections]");
  const empty = document.querySelector("[data-empty]");
  const tablePulse = document.querySelector("[data-table-pulse]");

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const sections = await getSections();

  if (!sections.length) {
    list.innerHTML = `<li class="loading">Sections not found.</li>`;
  } else {
    list.innerHTML = sections
      .map((s) => {
        const state = heatState(s.heat);
        const count =
          s.threadCount === 0
            ? "—"
            : `${s.threadCount} thread${s.threadCount === 1 ? "" : "s"}`;
        return `
          <li class="section heat-card" data-heat="${state}">
            <a class="s-link" href="/forum/${esc(s.slug)}">
              <span class="heat-dot"></span>
              <span class="s-text">
                <span class="s-label">${esc(s.label)}</span>
                <span class="s-blurb">${esc(s.blurb ?? "")}</span>
              </span>
              <span class="s-count">${count}</span>
            </a>
            <span class="heat-rail" aria-hidden="true"></span>
          </li>`;
      })
      .join("");

    // The Table's own dot reflects the hottest section.
    const peak = Math.max(...sections.map((s) => s.heat));
    tablePulse.setAttribute("data-heat", heatState(peak));

    const total = sections.reduce((n, s) => n + s.threadCount, 0);
    if (total === 0) empty.hidden = false;
  }
</script>

<style>
  /* Only elements rendered by Astro (not injected by JS) belong here.
     Section/thread card styling lives in src/styles/forum.css —
     scoped styles can't reach runtime-injected markup. */
  .table { max-width: 72ch; margin: 0 auto; }
  .table-head {
    display: flex; flex-direction: column; align-items: center;
    gap: 0.9rem; text-align: center;
  }
  .table-title-row { display: flex; align-items: center; gap: 0.8rem; }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.6rem, 8vw, 4.2rem); line-height: 1.02;
    margin: 0; color: var(--snowmelt);
  }
  .lede {
    font-family: var(--body); font-style: italic; font-size: 1.25rem;
    color: var(--sage); margin: 1rem 0 2.4rem; text-align: center;
  }
  .soon {
    font-family: var(--mono); font-size: 0.72rem; line-height: 1.6;
    color: var(--sage); margin: 0; text-align: center;
  }
  @media (max-width: 560px) {
    .table-auth { width: 100%; display: flex; justify-content: center; }
  }
</style>
STAGEC_EOF

echo "  src/pages/forum/[slug].astro"
cat > 'src/pages/forum/[slug].astro' << 'STAGEC_EOF'
---
import SiteFrame from "../../layouts/SiteFrame.astro";
import AuthButton from "../../components/AuthButton.astro";
import ThreadComposer from "../../components/ThreadComposer.astro";
import "../../styles/heat.css";
import "../../styles/forum.css";

// Static build needs to know the section URLs ahead of time.
// These match the seeded rows in the database.
export function getStaticPaths() {
  return [
    { params: { slug: "preparedness" } },
    { params: { slug: "signal-power" } },
    { params: { slug: "land-water" } },
    { params: { slug: "briefs" } },
    { params: { slug: "news" } },
  ];
}

const { slug } = Astro.params;
---
<SiteFrame title="The Table — Blaine County Preparedness">
  <div class="sec" data-slug={slug}>
    <a class="back" href="/forum">← The Table</a>

    <div class="sec-head">
      <div class="sec-title-row">
        <span class="heat-dot" data-sec-pulse></span>
        <h1 class="h1" data-sec-label>…</h1>
      </div>
      <p class="blurb" data-sec-blurb></p>
      <div class="sec-auth"><AuthButton /></div>
    </div>

    <ThreadComposer mode="section" />

    <ul class="threads" data-threads>
      <li class="loading">Pulling up chairs…</li>
    </ul>
  </div>
</SiteFrame>

<script>
  import { getSection, getThreads, heatState, ago } from "../../lib/forum";

  const root   = document.querySelector("[data-slug]");
  const slug   = root.dataset.slug;
  const labelEl = document.querySelector("[data-sec-label]");
  const blurbEl = document.querySelector("[data-sec-blurb]");
  const pulseEl = document.querySelector("[data-sec-pulse]");
  const list    = document.querySelector("[data-threads]");

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const section = await getSection(slug);
  if (!section) {
    labelEl.textContent = "Not found";
    list.innerHTML = `<li class="loading">That room doesn't exist.</li>`;
  } else {
    labelEl.textContent = section.label;
    blurbEl.textContent = section.blurb ?? "";
    document.title = `${section.label} — The Table`;

    // Hand the section id to the composer now that we know it.
    const composerEl = document.querySelector("[data-composer]");
    if (composerEl) composerEl.dataset.sectionId = section.id;

    const threads = await getThreads(section.id);

    if (!threads.length) {
      pulseEl.setAttribute("data-heat", "quiet");
      list.innerHTML = `
        <li class="empty">
          Nothing here yet.${section.is_auto
            ? " Threads appear as news posts are published."
            : " Be the first to start something."}
        </li>`;
    } else {
      const peak = Math.max(...threads.map((t) => t.heat));
      pulseEl.setAttribute("data-heat", heatState(peak));

      list.innerHTML = threads
        .map((t) => {
          const state = heatState(t.heat);
          const replies =
            t.replyCount === 0
              ? "no replies"
              : `${t.replyCount} repl${t.replyCount === 1 ? "y" : "ies"}`;
          return `
            <li class="thread heat-card" data-heat="${state}">
              <a class="t-link" href="/forum/thread?id=${t.id}">
                <span class="heat-dot"></span>
                <span class="t-text">
                  <span class="t-title">${esc(t.title)}</span>
                  <span class="t-meta">${esc(t.author)} · ${replies} · ${ago(t.last_reply_at)}</span>
                </span>
              </a>
              <span class="heat-rail" aria-hidden="true"></span>
            </li>`;
        })
        .join("");
    }
  }
</script>

<style>
  /* Thread card styling lives in src/styles/forum.css (unscoped),
     because those cards are injected by JavaScript at runtime. */
  .sec { max-width: 72ch; margin: 0 auto; }
  .back {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase; color: var(--sage);
  }
  .back:hover { color: var(--oxide); }
  .sec-head {
    display: flex; flex-direction: column; align-items: center;
    gap: 0.7rem; text-align: center; margin: 1.6rem 0 2.2rem;
  }
  .sec-title-row { display: flex; align-items: center; gap: 0.7rem; }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.2rem, 7vw, 3.4rem); line-height: 1.03;
    margin: 0; color: var(--snowmelt);
  }
  .blurb {
    font-family: var(--body); font-style: italic; font-size: 1.05rem;
    color: var(--sage); margin: 0;
  }
</style>
STAGEC_EOF

echo "  src/pages/forum/thread.astro"
cat > 'src/pages/forum/thread.astro' << 'STAGEC_EOF'
---
import SiteFrame from "../../layouts/SiteFrame.astro";
import AuthButton from "../../components/AuthButton.astro";
import "../../styles/heat.css";
import "../../styles/forum.css";
---
<SiteFrame title="Thread — The Table">
  <div class="tp">
    <a class="back" href="/forum" data-back>← The Table</a>

    <article class="post" data-post hidden>
      <h1 class="t-h1" data-post-title></h1>
      <p class="t-by" data-post-meta></p>
      <div class="t-body" data-post-body></div>

      <!-- admin only -->
      <div class="admin" data-admin hidden>
        <label class="admin-label">Move to</label>
        <select class="admin-select" data-move-select></select>
        <button class="admin-btn" type="button" data-move-btn>Move</button>
        <button class="admin-btn danger" type="button" data-hide-btn>Hide thread</button>
      </div>
    </article>

    <p class="loading" data-loading>Opening…</p>

    <ul class="replies" data-replies></ul>

    <!-- reply box -->
    <div class="reply-box" data-replybox hidden>
      <p class="signed-out" data-reply-signedout hidden>Sign in to reply.</p>
      <div class="reply-form" data-reply-form hidden>
        <textarea class="input area" rows="4"
                  placeholder="Add to the conversation."
                  data-reply-body></textarea>
        <p class="notice" data-reply-notice hidden></p>
        <button class="post-btn" type="button" data-reply-post>Reply</button>
      </div>
      <div class="auth-slot"><AuthButton /></div>
    </div>
  </div>
</SiteFrame>

<script>
  import { supabase } from "../../lib/supabase";
  import { getThread, createReply, myProfile, moveThread,
           hideThread, hideReply, approveReply, ago } from "../../lib/forum";

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const id = new URLSearchParams(location.search).get("id");
  const loadingEl = document.querySelector("[data-loading]");
  const postEl    = document.querySelector("[data-post]");
  const repliesEl = document.querySelector("[data-replies]");
  const boxEl     = document.querySelector("[data-replybox]");

  if (!id) {
    loadingEl.textContent = "No thread specified.";
  } else {
    const result = await getThread(id);

    if (!result) {
      loadingEl.textContent = "That thread doesn't exist.";
    } else {
      const { thread, replies } = result;
      const profile = await myProfile();
      const isAdmin = profile?.is_admin === true;

      loadingEl.hidden = true;
      postEl.hidden = false;
      boxEl.hidden = false;

      document.title = `${thread.title} — The Table`;
      document.querySelector("[data-post-title]").textContent = thread.title;
      document.querySelector("[data-post-meta]").textContent =
        `${thread.profiles?.display_name ?? "neighbor"} · ${ago(thread.created_at)}`;
      document.querySelector("[data-post-body]").textContent = thread.body ?? "";

      const back = document.querySelector("[data-back]");
      if (thread.sections?.slug) {
        back.href = `/forum/${thread.sections.slug}`;
        back.textContent = `← ${thread.sections.label}`;
      }

      // ── replies ──
      function renderReplies(list) {
        if (!list.length) {
          repliesEl.innerHTML =
            `<li class="empty">No replies yet. Yours would be the first.</li>`;
          return;
        }
        repliesEl.innerHTML = list.map((r) => `
          <li class="reply${r.is_pending ? " pending" : ""}">
            <div class="r-meta">
              ${esc(r.profiles?.display_name ?? "neighbor")} · ${ago(r.created_at)}
              ${r.is_pending ? '<span class="pending-tag">held for review</span>' : ""}
            </div>
            <div class="r-body">${esc(r.body)}</div>
            ${isAdmin ? `
              <div class="r-admin">
                ${r.is_pending
                  ? `<button class="admin-btn" data-approve="${r.id}">Approve</button>`
                  : ""}
                <button class="admin-btn danger" data-hide-reply="${r.id}">Hide</button>
              </div>` : ""}
          </li>`).join("");

        if (isAdmin) {
          repliesEl.querySelectorAll("[data-approve]").forEach((b) =>
            b.addEventListener("click", async () => {
              await approveReply(b.dataset.approve);
              location.reload();
            }));
          repliesEl.querySelectorAll("[data-hide-reply]").forEach((b) =>
            b.addEventListener("click", async () => {
              await hideReply(b.dataset.hideReply);
              location.reload();
            }));
        }
      }
      renderReplies(replies);

      // ── admin controls on the thread ──
      if (isAdmin) {
        const adminEl = document.querySelector("[data-admin]");
        adminEl.hidden = false;
        const sel = document.querySelector("[data-move-select]");
        const { data: sections } = await supabase
          .from("sections").select("id,label,blurb").order("sort_order");
        sel.innerHTML = (sections ?? [])
          .map((s) => `<option value="${s.id}"${s.id === thread.section_id ? " selected" : ""}>${esc(s.label)}</option>`)
          .join("");

        document.querySelector("[data-move-btn]")
          .addEventListener("click", async () => {
            await moveThread(thread.id, sel.value);
            location.reload();
          });
        document.querySelector("[data-hide-btn]")
          .addEventListener("click", async () => {
            if (!confirm("Hide this thread from the public?")) return;
            await hideThread(thread.id);
            location.href = "/forum";
          });
      }

      // ── reply form ──
      const signedOut = document.querySelector("[data-reply-signedout]");
      const form      = document.querySelector("[data-reply-form]");
      const bodyEl    = document.querySelector("[data-reply-body]");
      const noticeEl  = document.querySelector("[data-reply-notice]");
      const postBtn   = document.querySelector("[data-reply-post]");

      function showForm(session) {
        const inUser = !!session?.user;
        signedOut.hidden = inUser;
        form.hidden = !inUser;
      }
      const { data: sess } = await supabase.auth.getSession();
      showForm(sess.session);
      supabase.auth.onAuthStateChange((_e, s) => showForm(s));

      postBtn.addEventListener("click", async () => {
        postBtn.disabled = true;
        postBtn.textContent = "Posting…";
        noticeEl.hidden = true;

        const res = await createReply(thread.id, bodyEl.value);

        postBtn.disabled = false;
        postBtn.textContent = "Reply";

        if (res.error) {
          noticeEl.textContent = res.error;
          noticeEl.hidden = false;
          return;
        }
        if (res.pending) {
          noticeEl.textContent =
            "Posted — held for review since it's your first. It'll appear once approved.";
          noticeEl.hidden = false;
          bodyEl.value = "";
          return;
        }
        location.reload();
      });
    }
  }
</script>

<style>
  .tp { max-width: 68ch; margin: 0 auto; }
  .back {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase; color: var(--sage);
  }
  .back:hover { color: var(--oxide); }

  .post { margin: 1.6rem 0 2.4rem; }
  .t-h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(1.9rem, 5vw, 2.8rem); line-height: 1.08;
    margin: 0 0 0.6rem; color: var(--snowmelt);
  }
  .t-by {
    font-family: var(--mono); font-size: 0.66rem;
    letter-spacing: 0.08em; color: var(--sage); margin: 0 0 1.2rem;
  }
  .t-body {
    font-family: var(--body); font-size: 1.1rem; line-height: 1.65;
    color: var(--snowmelt); white-space: pre-wrap;
  }

  .admin {
    display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap;
    margin-top: 1.6rem; padding-top: 1.2rem;
    border-top: 1px dashed var(--line);
  }
  .admin-label {
    font-family: var(--mono); font-size: 0.62rem;
    letter-spacing: 0.1em; text-transform: uppercase; color: var(--sage);
  }
  .admin-select {
    font-family: var(--body); font-size: 0.9rem; color: var(--snowmelt);
    background: var(--basalt-2); border: 1px solid var(--line);
    border-radius: 3px; padding: 0.35rem 0.5rem;
  }
  .admin-btn {
    font-family: var(--mono); font-size: 0.62rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.35rem 0.7rem; cursor: pointer;
  }
  .admin-btn:hover { color: var(--snowmelt); border-color: var(--sage); }
  .admin-btn.danger:hover { color: #d93b1f; border-color: #d93b1f; }
</style>
STAGEC_EOF

echo ""
echo "Files written. Next:"
echo "  1) Supabase SQL Editor -> paste db/stage-c-moderation.sql -> Run"
echo "  2) Ctrl-C the dev server, then: npm run dev"
echo "  3) Visit /forum and try Start a thread"
