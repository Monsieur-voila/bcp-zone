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

export async function createReply(
  threadId: string,
  body: string,
  parentReplyId?: string
) {
  const user = await currentUser();
  if (!user) return { error: "You need to be signed in." };

  const clean = body.trim();
  if (clean.length < 2) return { error: "Say a little more." };
  if (clean.length > 5000) return { error: "That's too long (5000 max)." };

  const pending = await needsReview(user);

  const { error } = await supabase.from("replies").insert({
    thread_id: threadId,
    author_id: user.id,
    body: clean,
    is_pending: pending,
    parent_reply_id: parentReplyId || null,
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
    .select(
      "id, body, created_at, is_pending, author_id, parent_reply_id, deleted_at, profiles(display_name)"
    )
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
    .select("id, name, email, message, attachments, is_read, is_archived, created_at")
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

// ═══════════════════════════════════════════════════════════════
//  TIP ATTACHMENTS
//  Files go to a private R2 bucket via a server Function.
//  Only object keys are stored here — never public URLs.
// ═══════════════════════════════════════════════════════════════

export const UPLOAD_LIMITS = {
  image: 25 * 1024 * 1024,     // 25MB per photo
  video: 150 * 1024 * 1024,    // 150MB per video
  audio: 25 * 1024 * 1024,     // 25MB — 5 min of voice is ~3MB
  totalPerTip: 250 * 1024 * 1024,
  accept: "image/*,video/*,audio/*",
};

export function kindOf(file: File): "image" | "video" | "audio" | null {
  if (file.type.startsWith("image/")) return "image";
  if (file.type.startsWith("video/")) return "video";
  if (file.type.startsWith("audio/")) return "audio";
  return null;
}

export async function uploadFile(file: File) {
  const kind = kindOf(file);
  if (!kind) return { error: `${file.name} isn't a photo, video, or audio file.` };
  if (file.size > UPLOAD_LIMITS[kind]) {
    const mb = Math.round(UPLOAD_LIMITS[kind] / 1048576);
    return { error: `${file.name} is over ${mb}MB.` };
  }
  const body = new FormData();
  body.append("file", file);

  try {
    const res = await fetch("/api/upload", { method: "POST", body });
    const data = await res.json();
    if (!res.ok) return { error: data?.error ?? "Upload failed." };
    return { key: data.key };
  } catch {
    return { error: "Upload failed — check your connection." };
  }
}

// Fetch a private attachment as a blob URL (admin only).
// The Function verifies admin status server-side on every call.
export async function attachmentUrl(key: string): Promise<string | null> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) return null;

  try {
    const res = await fetch(`/api/attachment?key=${encodeURIComponent(key)}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    const blob = await res.blob();
    return URL.createObjectURL(blob);
  } catch {
    return null;
  }
}

// Send a tip with optional image attachments.
export async function sendTipWithFiles(
  name: string,
  email: string,
  message: string,
  keys: string[]
) {
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
    attachments: keys,
  });

  if (error) return { error: "Something went wrong sending that." };
  return { ok: true };
}

// Fire a push notification about a new tip. Deliberately
// fire-and-forget: a failed notification must never stop a tip
// from being delivered.
export async function notifyTip(payload: {
  name?: string;
  email?: string;
  message?: string;
  attachments?: number;
  hasVoicemail?: boolean;
}) {
  try {
    await fetch("/api/notify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    // Silence is correct here.
  }
}

const FRESH_WINDOW_MINUTES = 15;

// Is this reply/thread new enough to get the attention treatment?
export function isFresh(createdAt: string): boolean {
  const ageMs = Date.now() - new Date(createdAt).getTime();
  return ageMs < FRESH_WINDOW_MINUTES * 60 * 1000;
}

// Delete a reply: hard-delete if it has no children,
// otherwise tombstone it (content wiped, row kept for its children).
export async function deleteReply(replyId: string, reason?: string) {
  const { count } = await supabase
    .from("replies")
    .select("id", { count: "exact", head: true })
    .eq("parent_reply_id", replyId);

  if (!count) {
    const { error } = await supabase.from("replies").delete().eq("id", replyId);
    return { error };
  }

  const { error } = await supabase
    .from("replies")
    .update({
      body: null,
      author_id: null,
      deleted_at: new Date().toISOString(),
      delete_reason: reason || null,
    })
    .eq("id", replyId);
  return { error };
}

export async function toggleLike(replyId: string, userId: string, currentlyLiked: boolean) {
  if (currentlyLiked) {
    const { error } = await supabase
      .from("reply_likes")
      .delete()
      .eq("reply_id", replyId)
      .eq("user_id", userId);
    return { error };
  }
  const { error } = await supabase
    .from("reply_likes")
    .insert({ reply_id: replyId, user_id: userId });
  return { error };
}

// Fetch likes for a set of replies in one query, returned as
// { [replyId]: { count, likedByMe } }.
export async function getLikesFor(replyIds: string[], myUserId?: string) {
  if (!replyIds.length) return {};
  const { data } = await supabase
    .from("reply_likes")
    .select("reply_id, user_id")
    .in("reply_id", replyIds);

  const result: Record<string, { count: number; likedByMe: boolean }> = {};
  for (const id of replyIds) result[id] = { count: 0, likedByMe: false };
  for (const row of data ?? []) {
    result[row.reply_id].count++;
    if (myUserId && row.user_id === myUserId) result[row.reply_id].likedByMe = true;
  }
  return result;
}

export async function getOrCreateThreadForNews(newsSlug: string, title: string) {
  const { data, error } = await supabase.rpc("get_or_create_news_thread", {
    p_news_slug: newsSlug,
    p_title: title,
  });
  if (error || !data) {
    console.error("[forum] get_or_create_news_thread failed:", error?.message);
    return null;
  }
  return data as string; // the thread id
}

const TOMBSTONE_TEXT = "They Deleted Their Comment But Replies Remain";
const MAX_INDENT_DEPTH = 4;

function escHtml(s: string) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c as string]));
}

function buildReplyTree(list: any[]) {
  const byParent = new Map<string, any[]>();
  for (const r of list) {
    const key = r.parent_reply_id ?? "__root__";
    if (!byParent.has(key)) byParent.set(key, []);
    byParent.get(key)!.push(r);
  }
  return byParent;
}

function renderReplyNode(
  r: any,
  byParent: Map<string, any[]>,
  depth: number,
  likes: Record<string, { count: number; likedByMe: boolean }>,
  isAdmin: boolean,
  myUserId: string | null
): string {
  const children = byParent.get(r.id) ?? [];
  const indentDepth = Math.min(depth, MAX_INDENT_DEPTH);
  const isDeleted = !!r.deleted_at;
  const like = likes[r.id] ?? { count: 0, likedByMe: false };
  const isOwn = myUserId && r.author_id === myUserId;
  const canDelete = !isDeleted && (isOwn || isAdmin);

  const body = isDeleted
    ? `<div class="r-body tombstone">${TOMBSTONE_TEXT}</div>`
    : `<div class="r-body">${escHtml(r.body)}</div>`;

  const meta = isDeleted
    ? `<div class="r-meta">— · ${ago(r.created_at)}</div>`
    : `<div class="r-meta">
         ${escHtml(r.profiles?.display_name ?? "neighbor")} · ${ago(r.created_at)}
         ${r.is_pending ? '<span class="pending-tag">held for review</span>' : ""}
       </div>`;

  const actions = isDeleted ? "" : `
    <div class="r-actions">
      <button class="reply-like-btn${like.likedByMe ? " liked" : ""}" data-like="${r.id}">
        ♥ ${like.count > 0 ? like.count : ""}
      </button>
      <button class="reply-toggle" data-reply-toggle="${r.id}">Reply</button>
      ${canDelete ? `<button class="reply-delete-btn" data-delete="${r.id}">Delete</button>` : ""}
    </div>
    <div class="nested-reply-form" data-nested-form="${r.id}" hidden>
      <textarea class="input area" rows="3" placeholder="Reply to this…" data-nested-body="${r.id}"></textarea>
      <button class="post-btn" data-nested-post="${r.id}">Reply</button>
    </div>`;

  const adminRow = (isAdmin && !isDeleted) ? `
    <div class="r-admin">
      ${r.is_pending ? `<button class="admin-btn" data-approve="${r.id}">Approve</button>` : ""}
      <button class="admin-btn danger" data-hide-reply="${r.id}">Hide</button>
    </div>` : "";

  const childrenHtml = children
    .map((c) => renderReplyNode(c, byParent, depth + 1, likes, isAdmin, myUserId))
    .join("");

  return `
    <li class="reply${r.is_pending ? " pending" : ""}"${isFresh(r.created_at) && !isDeleted ? ' data-fresh="true"' : ""}
        style="margin-left: ${indentDepth * 1.4}rem;">
      ${meta}
      ${body}
      ${actions}
      ${adminRow}
      ${childrenHtml ? `<ul class="reply-children">${childrenHtml}</ul>` : ""}
    </li>`;
}

// Renders a full reply thread (tree + like/delete/reply-form wiring +
// top-level reply box) into the given containers. Used by both
// /forum/thread and a news article's inline comments.
export async function renderReplyThread(opts: {
  threadId: string;
  repliesContainer: HTMLElement;
  replyBoxContainer: HTMLElement;
  isAdmin: boolean;
  myUserId: string | null;
}) {
  const { threadId, repliesContainer, replyBoxContainer, isAdmin, myUserId } = opts;

  const { data: replies } = await supabase
    .from("replies")
    .select(
      "id, body, created_at, is_pending, author_id, parent_reply_id, deleted_at, profiles(display_name)"
    )
    .eq("thread_id", threadId)
    .eq("is_hidden", false)
    .order("created_at");

  const list = replies ?? [];

  async function render() {
    if (!list.length) {
      repliesContainer.innerHTML =
        `<li class="empty">No replies yet. Yours would be the first.</li>`;
      wireBoxEvents();
      return;
    }

    const liveIds = list.filter((r: any) => !r.deleted_at).map((r: any) => r.id);
    const likes = await getLikesFor(liveIds, myUserId ?? undefined);

    const byParent = buildReplyTree(list);
    const roots = byParent.get("__root__") ?? [];
    repliesContainer.innerHTML = roots
      .map((r: any) => renderReplyNode(r, byParent, 0, likes, isAdmin, myUserId))
      .join("");

    wireReplyEvents();
  }

  function wireReplyEvents() {
    if (isAdmin) {
      repliesContainer.querySelectorAll("[data-approve]").forEach((b: any) =>
        b.addEventListener("click", async () => {
          await approveReply(b.dataset.approve);
          location.reload();
        }));
      repliesContainer.querySelectorAll("[data-hide-reply]").forEach((b: any) =>
        b.addEventListener("click", async () => {
          await hideReply(b.dataset.hideReply);
          location.reload();
        }));
    }

    repliesContainer.querySelectorAll("[data-like]").forEach((b: any) =>
      b.addEventListener("click", async () => {
        if (!myUserId) return;
        const replyId = b.dataset.like;
        const liked = b.classList.contains("liked");
        b.disabled = true;
        await toggleLike(replyId, myUserId, liked);
        b.disabled = false;
        await render();
      }));

    repliesContainer.querySelectorAll("[data-delete]").forEach((b: any) =>
      b.addEventListener("click", async () => {
        if (!confirm("Delete this reply?")) return;
        const reason = prompt("Reason (optional):") || undefined;
        await deleteReply(b.dataset.delete, reason);
        location.reload();
      }));

    repliesContainer.querySelectorAll("[data-reply-toggle]").forEach((b: any) =>
      b.addEventListener("click", () => {
        const formEl = repliesContainer.querySelector(
          `[data-nested-form="${b.dataset.replyToggle}"]`
        ) as HTMLElement | null;
        if (formEl) formEl.hidden = !formEl.hidden;
      }));

    repliesContainer.querySelectorAll("[data-nested-post]").forEach((b: any) =>
      b.addEventListener("click", async () => {
        if (!myUserId) return;
        const parentId = b.dataset.nestedPost;
        const textEl = repliesContainer.querySelector(
          `[data-nested-body="${parentId}"]`
        ) as HTMLTextAreaElement;
        const text = textEl.value.trim();
        if (text.length < 2) return;
        b.disabled = true;
        const res = await createReply(threadId, text, parentId);
        b.disabled = false;
        if (res.error) { alert(res.error); return; }
        location.reload();
      }));
  }

  function wireBoxEvents() {
    const signedOut = replyBoxContainer.querySelector("[data-reply-signedout]") as HTMLElement;
    const form      = replyBoxContainer.querySelector("[data-reply-form]") as HTMLElement;
    const bodyEl    = replyBoxContainer.querySelector("[data-reply-body]") as HTMLTextAreaElement;
    const noticeEl  = replyBoxContainer.querySelector("[data-reply-notice]") as HTMLElement;
    const postBtn   = replyBoxContainer.querySelector("[data-reply-post]") as HTMLButtonElement;

    if (!postBtn || postBtn.dataset.wired) return; // avoid double-binding on re-render
    postBtn.dataset.wired = "true";

    function showForm(session: any) {
      const inUser = !!session?.user;
      signedOut.hidden = inUser;
      form.hidden = !inUser;
    }
    supabase.auth.getSession().then(({ data }) => showForm(data.session));
    supabase.auth.onAuthStateChange((_e: any, s: any) => showForm(s));

    postBtn.addEventListener("click", async () => {
      postBtn.disabled = true;
      postBtn.textContent = "Posting…";
      noticeEl.hidden = true;

      const res = await createReply(threadId, bodyEl.value);

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

  await render();
  wireBoxEvents();
}
