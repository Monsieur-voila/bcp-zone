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
