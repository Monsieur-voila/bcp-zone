#!/usr/bin/env bash
# Contact/Tips installer — run from inside ~/site
set -e
if [ ! -f package.json ]; then echo "ERROR: run from ~/site"; exit 1; fi
echo "Writing tips files..."
mkdir -p db src/lib src/styles src/pages

echo "  db/stage-tips.sql"
cat > 'db/stage-tips.sql' << 'TIPS_EOF'
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
TIPS_EOF

echo "  src/lib/forum.ts"
cat > 'src/lib/forum.ts' << 'TIPS_EOF'
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

// ═══════════════════════════════════════════════════════════════
//  TIPS — the private contact inbox
// ═══════════════════════════════════════════════════════════════

export async function sendTip(name: string, email: string, message: string) {
  const clean = message.trim();
  if (clean.length < 2) return { error: "Tell us a little more." };
  if (clean.length > 5000) return { error: "That's too long (5000 max)." };

  const e = email.trim();
  if (e && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) {
    return { error: "That email doesn't look right." };
  }

  const { error } = await supabase.from("tips").insert({
    name: name.trim() || null,
    email: e || null,
    message: clean,
  });

  if (error) return { error: "Something went wrong sending that." };
  return { ok: true };
}

export async function getTips() {
  const { data, error } = await supabase
    .from("tips")
    .select("id, name, email, message, is_read, is_archived, created_at")
    .eq("is_archived", false)
    .order("created_at", { ascending: false });

  if (error) return [];
  return data ?? [];
}

export async function markTipRead(id: string, read = true) {
  const { error } = await supabase
    .from("tips").update({ is_read: read }).eq("id", id);
  return error ? { error: error.message } : { ok: true };
}

export async function archiveTip(id: string) {
  const { error } = await supabase
    .from("tips").update({ is_archived: true }).eq("id", id);
  return error ? { error: error.message } : { ok: true };
}
TIPS_EOF

echo "  src/styles/forum.css"
cat > 'src/styles/forum.css' << 'TIPS_EOF'
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

/* ═══════════════════════════════════════════════════════════════
   ADMIN CONTROLS

   These are injected by JavaScript, so they live here (unscoped)
   rather than in a component <style> block, which can't reach them.

   Design intent: moderation should be nearly invisible until you
   look for it. Content is what matters; these are tools, not
   features. Muted by default, only asserting on hover.
   ═══════════════════════════════════════════════════════════════ */

.admin-btn,
.r-admin button {
  font-family: var(--mono);
  font-size: 0.58rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
  background: transparent;
  border: 1px solid transparent;
  border-radius: 2px;
  padding: 0.25rem 0.55rem;
  cursor: pointer;
  opacity: 0.35;
  transition: opacity 0.2s ease, color 0.2s ease, border-color 0.2s ease;
}

/* Reveal on hover — of the button, or of the reply it belongs to. */
.admin-btn:hover,
.r-admin button:hover,
.reply:hover .r-admin button,
.post:hover .admin-btn {
  opacity: 1;
  border-color: var(--line);
}

.admin-btn:hover,
.r-admin button:hover {
  color: var(--snowmelt);
  border-color: var(--sage);
}

.admin-btn.danger:hover,
.r-admin button.danger:hover,
.r-admin [data-hide-reply]:hover {
  color: var(--heat-c4, #d93b1f);
  border-color: var(--heat-c4, #d93b1f);
}

.r-admin {
  margin-top: 0.6rem;
  display: flex;
  gap: 0.4rem;
}

/* The thread-level admin bar: set apart, quiet, clearly a tool. */
.admin {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  flex-wrap: wrap;
  margin-top: 1.8rem;
  padding-top: 1rem;
  border-top: 1px dashed var(--line);
  opacity: 0.4;
  transition: opacity 0.2s ease;
}
.admin:hover { opacity: 1; }

.admin-label {
  font-family: var(--mono);
  font-size: 0.58rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
}

.admin-select {
  font-family: var(--body);
  font-size: 0.85rem;
  color: var(--snowmelt);
  background: var(--basalt-2);
  border: 1px solid var(--line);
  border-radius: 2px;
  padding: 0.3rem 0.45rem;
}


/* ═══════════════════════════════════════════════════════════════
   CONTENT HIERARCHY — what the eye should find first
   ═══════════════════════════════════════════════════════════════ */

/* Reply: the body is the point. Metadata recedes. */
.reply {
  padding: 1.4rem 1.5rem;
  background: var(--basalt-2);
  border: 1px solid var(--line);
  border-radius: 3px;
  margin-bottom: 1rem;
}

.r-meta {
  font-family: var(--mono);
  font-size: 0.58rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
  opacity: 0.65;
  margin-bottom: 0.7rem;
}

.r-body {
  font-family: var(--body);
  font-size: 1.08rem;
  line-height: 1.65;
  color: var(--snowmelt);
  white-space: pre-wrap;
}

/* The opening post should read as the anchor of the page. */
.t-body {
  font-family: var(--body);
  font-size: 1.15rem;
  line-height: 1.7;
  color: var(--snowmelt);
  white-space: pre-wrap;
}

.t-by {
  font-family: var(--mono);
  font-size: 0.6rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
  opacity: 0.7;
  margin: 0 0 1.4rem;
}

/* ── TIPS INBOX (admin only) ────────────────────────────────── */

.count {
  font-family: var(--mono);
  font-size: 0.66rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
  margin: 0 0 1.4rem;
}

.tip {
  background: var(--basalt-2);
  border: 1px solid var(--line);
  border-left: 2px solid var(--line);
  border-radius: 3px;
  padding: 1.3rem 1.4rem;
  margin-bottom: 1rem;
}
/* Unread messages carry the oxide edge — the eye finds them first. */
.tip.unread { border-left-color: var(--oxide); }

.tip-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.3rem;
}
.tip-who {
  font-family: var(--body);
  font-size: 1.05rem;
  color: var(--snowmelt);
}
.tip-when {
  font-family: var(--mono);
  font-size: 0.6rem;
  letter-spacing: 0.08em;
  color: var(--sage);
  flex: none;
}
.tip-email {
  font-family: var(--mono);
  font-size: 0.68rem;
  color: #e0c85a;
  border-bottom: 1px solid rgba(224, 200, 90, 0.35);
}
.tip-email:hover { color: #f5e08a; }
.tip-noemail {
  font-family: var(--mono);
  font-size: 0.62rem;
  color: var(--sage);
  opacity: 0.6;
}
.tip-body {
  font-family: var(--body);
  font-size: 1.05rem;
  line-height: 1.6;
  color: var(--snowmelt);
  white-space: pre-wrap;
  margin: 0.9rem 0 0;
}
.tip-acts { display: flex; gap: 0.5rem; margin-top: 1rem; }
.tip-btn {
  font-family: var(--mono);
  font-size: 0.58rem;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--sage);
  background: transparent;
  border: 1px solid var(--line);
  border-radius: 2px;
  padding: 0.3rem 0.65rem;
  cursor: pointer;
  opacity: 0.6;
  transition: opacity 0.2s ease, color 0.2s ease, border-color 0.2s ease;
}
.tip:hover .tip-btn { opacity: 1; }
.tip-btn:hover { color: var(--snowmelt); border-color: var(--sage); }
TIPS_EOF

echo "  src/pages/contact.astro"
cat > 'src/pages/contact.astro' << 'TIPS_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
---
<SiteFrame title="Contact / Tips — Blaine County Preparedness"
           description="Send a tip, a question, or something you think we should know.">
  <div class="doc">
    <p class="eyebrow">Contact / Tips</p>
    <h1 class="h1">Send it over</h1>
    <p class="lede">
      A tip, a question, something you think the valley should know. It comes
      straight to us — privately. Nothing here is published unless we ask you
      first.
    </p>

    <div class="form" data-tipform>
      <label class="field">
        <span class="label">Your name <span class="opt">(optional)</span></span>
        <input class="input" type="text" maxlength="120"
               autocomplete="name" data-tip-name />
      </label>

      <label class="field">
        <span class="label">Email <span class="opt">(if you want a reply)</span></span>
        <input class="input" type="email" maxlength="200"
               autocomplete="email" data-tip-email />
      </label>

      <label class="field">
        <span class="label">What's on your mind</span>
        <textarea class="input area" rows="7" maxlength="5000"
                  data-tip-message></textarea>
      </label>

      <p class="notice" data-tip-notice hidden></p>

      <button class="send" type="button" data-tip-send>Send</button>

      <p class="foot-hint">
        Photos, video, and audio are coming soon. For now, if you have media,
        mention it here and we'll write back with a way to send it.
      </p>
    </div>

    <!-- shown after a successful send -->
    <div class="thanks" data-tip-thanks hidden>
      <p class="thanks-h">Got it.</p>
      <p class="thanks-p">
        Thanks for sending that over. If you left an email, we'll be in touch.
      </p>
      <button class="again" type="button" data-tip-again>Send something else</button>
    </div>
  </div>
</SiteFrame>

<script>
  import { sendTip } from "../lib/forum";

  const form    = document.querySelector("[data-tipform]");
  const thanks  = document.querySelector("[data-tip-thanks]");
  const nameEl  = document.querySelector("[data-tip-name]");
  const emailEl = document.querySelector("[data-tip-email]");
  const msgEl   = document.querySelector("[data-tip-message]");
  const notice  = document.querySelector("[data-tip-notice]");
  const sendBtn = document.querySelector("[data-tip-send]");
  const again   = document.querySelector("[data-tip-again]");

  sendBtn.addEventListener("click", async () => {
    sendBtn.disabled = true;
    sendBtn.textContent = "Sending…";
    notice.hidden = true;

    const res = await sendTip(nameEl.value, emailEl.value, msgEl.value);

    sendBtn.disabled = false;
    sendBtn.textContent = "Send";

    if (res.error) {
      notice.textContent = res.error;
      notice.hidden = false;
      return;
    }

    nameEl.value = ""; emailEl.value = ""; msgEl.value = "";
    form.hidden = true;
    thanks.hidden = false;
  });

  again.addEventListener("click", () => {
    thanks.hidden = true;
    form.hidden = false;
    msgEl.focus();
  });
</script>

<style>
  .doc { max-width: 60ch; margin: 0 auto; }
  .eyebrow {
    font-family: var(--mono); font-size: 0.68rem; letter-spacing: 0.2em;
    text-transform: uppercase; color: var(--sage); margin: 0 0 1rem;
  }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.4rem, 7vw, 3.8rem); line-height: 1.03;
    margin: 0 0 1.2rem; color: var(--snowmelt);
  }
  .lede {
    font-family: var(--body); font-size: 1.15rem; line-height: 1.6;
    color: var(--sage); margin: 0 0 2.6rem; max-width: 52ch;
  }

  .form { display: flex; flex-direction: column; gap: 1.4rem; }
  .field { display: flex; flex-direction: column; gap: 0.5rem; }
  .label {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.08em; text-transform: uppercase; color: var(--snowmelt);
  }
  .opt { color: var(--sage); text-transform: none; letter-spacing: 0; }
  .input {
    font-family: var(--body); font-size: 1rem; color: var(--snowmelt);
    background: var(--basalt-2); border: 1px solid var(--line);
    border-radius: 3px; padding: 0.75rem 0.85rem;
  }
  .input:focus { border-color: var(--oxide); outline: none; }
  .area { resize: vertical; line-height: 1.55; }

  .notice {
    font-family: var(--mono); font-size: 0.72rem;
    color: #d93b1f; margin: 0;
  }

  .send {
    align-self: flex-start;
    font-family: var(--mono); font-size: 0.76rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--basalt); background: var(--oxide);
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.75rem 1.6rem; cursor: pointer;
    transition: background 0.2s ease;
  }
  .send:hover { background: #d2683a; }
  .send:disabled { opacity: 0.6; cursor: default; }

  .foot-hint {
    font-family: var(--body); font-size: 0.88rem; line-height: 1.5;
    color: var(--sage); opacity: 0.8; margin: 0.4rem 0 0;
  }

  .thanks { padding: 2rem 0; }
  .thanks-h {
    font-family: var(--display); font-size: 2rem;
    color: var(--snowmelt); margin: 0 0 0.6rem;
  }
  .thanks-p {
    font-family: var(--body); font-size: 1.1rem; line-height: 1.6;
    color: var(--sage); margin: 0 0 1.6rem;
  }
  .again {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.6rem 1.1rem; cursor: pointer;
  }
  .again:hover { border-color: var(--oxide); }
</style>
TIPS_EOF

echo "  src/pages/tips.astro"
cat > 'src/pages/tips.astro' << 'TIPS_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import AuthButton from "../components/AuthButton.astro";
---
<SiteFrame title="Tips — Blaine County Preparedness">
  <div class="inbox">
    <p class="eyebrow">Private inbox</p>
    <h1 class="h1">Tips</h1>

    <!-- Not admin: nothing to see. The page reveals nothing about
         what's here, and RLS blocks the data regardless. -->
    <div class="locked" data-locked hidden>
      <p class="locked-p">This page is for site administrators.</p>
      <AuthButton />
    </div>

    <p class="loading" data-loading>Checking…</p>

    <div class="list" data-list hidden></div>
  </div>
</SiteFrame>

<script>
  import { myProfile, getTips, markTipRead, archiveTip, ago } from "../lib/forum";

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const loading = document.querySelector("[data-loading]");
  const locked  = document.querySelector("[data-locked]");
  const list    = document.querySelector("[data-list]");

  const profile = await myProfile();

  if (!profile?.is_admin) {
    loading.hidden = true;
    locked.hidden = false;
  } else {
    const tips = await getTips();
    loading.hidden = true;
    list.hidden = false;

    if (!tips.length) {
      list.innerHTML = `<p class="empty">Nothing yet.</p>`;
    } else {
      const unread = tips.filter((t) => !t.is_read).length;
      list.innerHTML = `
        <p class="count">${tips.length} message${tips.length === 1 ? "" : "s"}${
          unread ? ` · ${unread} unread` : ""
        }</p>` + tips.map((t) => `
        <article class="tip${t.is_read ? "" : " unread"}">
          <div class="tip-head">
            <span class="tip-who">${esc(t.name || "no name given")}</span>
            <span class="tip-when">${ago(t.created_at)}</span>
          </div>
          ${t.email
            ? `<a class="tip-email" href="mailto:${esc(t.email)}">${esc(t.email)}</a>`
            : `<span class="tip-noemail">no reply address</span>`}
          <div class="tip-body">${esc(t.message)}</div>
          <div class="tip-acts">
            <button class="tip-btn" data-read="${t.id}" data-state="${t.is_read}">
              ${t.is_read ? "Mark unread" : "Mark read"}
            </button>
            <button class="tip-btn" data-archive="${t.id}">Archive</button>
          </div>
        </article>`).join("");

      list.querySelectorAll("[data-read]").forEach((b) =>
        b.addEventListener("click", async () => {
          await markTipRead(b.dataset.read, b.dataset.state !== "true");
          location.reload();
        }));
      list.querySelectorAll("[data-archive]").forEach((b) =>
        b.addEventListener("click", async () => {
          if (!confirm("Archive this message?")) return;
          await archiveTip(b.dataset.archive);
          location.reload();
        }));
    }
  }
</script>

<style>
  .inbox { max-width: 68ch; margin: 0 auto; }
  .eyebrow {
    font-family: var(--mono); font-size: 0.68rem; letter-spacing: 0.2em;
    text-transform: uppercase; color: var(--sage); margin: 0 0 0.8rem;
  }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.2rem, 6vw, 3.2rem); line-height: 1.03;
    margin: 0 0 2rem; color: var(--snowmelt);
  }
  .loading, .locked-p {
    font-family: var(--mono); font-size: 0.74rem;
    color: var(--sage); margin: 0 0 1.2rem;
  }
  .locked { display: flex; flex-direction: column; gap: 0.8rem; align-items: flex-start; }
</style>
TIPS_EOF

echo ""
echo "Next: paste db/stage-tips.sql into Supabase SQL Editor and Run"
echo "Then restart: npm run dev"
