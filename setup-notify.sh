#!/usr/bin/env bash
# Tip notifications via ntfy — run from ~/site on the uploads branch
set -e
if [ ! -f package.json ]; then echo "ERROR: run from ~/site"; exit 1; fi
echo "Writing..."
mkdir -p functions/api src/lib src/pages

echo "  functions/api/notify.ts"
cat > 'functions/api/notify.ts' << 'NOTIFY_EOF'
// ─────────────────────────────────────────────────────────────
//  POST /api/notify
//
//  Fires a push notification when a tip arrives.
//
//  Uses ntfy (https://ntfy.sh) — open source, self-hostable,
//  no account needed. Set two environment variables:
//
//    NTFY_URL   e.g. https://ntfy.sh  (or your own instance)
//    NTFY_TOPIC your unguessable topic string
//
//  If either is missing, this quietly does nothing — a failed
//  notification must never block a tip from being saved.
// ─────────────────────────────────────────────────────────────

interface Env {
  NTFY_URL?: string;
  NTFY_TOPIC?: string;
}

export const onRequestPost: PagesFunction<Env> = async (ctx) => {
  const ok = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });

  const base = ctx.env.NTFY_URL;
  const topic = ctx.env.NTFY_TOPIC;

  // Not configured — succeed silently. The tip is already saved.
  if (!base || !topic) return ok({ sent: false, reason: "not configured" });

  try {
    const body = await ctx.request.json<{
      name?: string;
      email?: string;
      message?: string;
      attachments?: number;
      hasVoicemail?: boolean;
    }>();

    const who = (body.name || "").trim() || "someone";
    const preview = (body.message || "").trim().slice(0, 160);
    const site = new URL(ctx.request.url).origin;

    const bits: string[] = [];
    if (body.hasVoicemail) bits.push("voicemail");
    if (body.attachments) bits.push(`${body.attachments} file${body.attachments === 1 ? "" : "s"}`);
    const extras = bits.length ? `\n[${bits.join(" · ")}]` : "";

    const reply = body.email ? `\nreply: ${body.email}` : "";

    await fetch(`${base.replace(/\/$/, "")}/${topic}`, {
      method: "POST",
      headers: {
        // ntfy reads these headers for the notification's shape.
        "Title": `Tip from ${who}`,
        "Priority": "default",
        "Tags": body.hasVoicemail ? "speech_balloon" : "envelope",
        "Click": `${site}/tips`,
      },
      body: `${preview}${extras}${reply}`,
    });

    return ok({ sent: true });
  } catch {
    // Never let a notification failure surface to the sender.
    return ok({ sent: false, reason: "error" });
  }
};
NOTIFY_EOF

echo "  src/lib/forum.ts"
cat > 'src/lib/forum.ts' << 'NOTIFY_EOF'
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
NOTIFY_EOF

echo "  src/pages/contact.astro"
cat > 'src/pages/contact.astro' << 'NOTIFY_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import VoiceRecorder from "../components/VoiceRecorder.astro";
import "../styles/forum.css";
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

      <VoiceRecorder />

      <div class="field">
        <span class="label">Photos or video <span class="opt">(optional)</span></span>
        <label class="filepick">
          <input type="file" accept="image/*,video/*" multiple data-tip-files />
          <span class="filepick-btn">Choose files</span>
          <span class="filepick-hint">Photos to 25MB · video to 150MB · smaller sends faster</span>
        </label>
        <ul class="filelist" data-file-list></ul>
      </div>

      <p class="notice" data-tip-notice hidden></p>

      <button class="send" type="button" data-tip-send>Send</button>

      <p class="foot-hint">
        Sending video or audio? Mention it here and we'll write back with a
        way to get it to us.
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
  import { sendTipWithFiles, uploadFile, UPLOAD_LIMITS, kindOf, notifyTip } from "../lib/forum";

  const form    = document.querySelector("[data-tipform]");
  const thanks  = document.querySelector("[data-tip-thanks]");
  const nameEl  = document.querySelector("[data-tip-name]");
  const emailEl = document.querySelector("[data-tip-email]");
  const msgEl   = document.querySelector("[data-tip-message]");
  const notice  = document.querySelector("[data-tip-notice]");
  const sendBtn = document.querySelector("[data-tip-send]");
  const again   = document.querySelector("[data-tip-again]");
  const fileEl  = document.querySelector("[data-tip-files]");
  const listEl  = document.querySelector("[data-file-list]");
  const vmEl    = document.querySelector("[data-vm]");

  let chosen = [];

  const totalBytes = () => {
    const rec = vmEl && vmEl._recording ? vmEl._recording.size : 0;
    return chosen.reduce((n, f) => n + f.size, 0) + rec;
  };

  function drawList() {
    if (!chosen.length) { listEl.innerHTML = ""; return; }
    listEl.innerHTML = chosen.map((f, i) => `
      <li class="fileitem">
        <span class="fileitem-name">${f.name.replace(/[<>&"]/g, "")}</span>
        <span class="fileitem-size">${(f.size / 1048576).toFixed(1)}MB</span>
        <button type="button" class="fileitem-x" data-drop="${i}">remove</button>
      </li>`).join("");
    listEl.querySelectorAll("[data-drop]").forEach((b) =>
      b.addEventListener("click", () => {
        chosen.splice(Number(b.dataset.drop), 1);
        drawList();
      }));
  }

  fileEl.addEventListener("change", () => {
    notice.hidden = true;
    for (const f of Array.from(fileEl.files)) {
      const kind = kindOf(f);
      if (!kind) {
        notice.textContent = f.name + " isn't a photo or video.";
        notice.hidden = false; continue;
      }
      if (f.size > UPLOAD_LIMITS[kind]) {
        const mb = Math.round(UPLOAD_LIMITS[kind] / 1048576);
        notice.textContent = f.name + " is over " + mb + "MB.";
        notice.hidden = false; continue;
      }
      if (totalBytes() + f.size > UPLOAD_LIMITS.totalPerTip) {
        notice.textContent = "That's more than 250MB in one message.";
        notice.hidden = false; break;
      }
      chosen.push(f);
    }
    fileEl.value = "";
    drawList();
  });

  sendBtn.addEventListener("click", async () => {
    sendBtn.disabled = true;
    notice.hidden = true;

    // The voicemail, if there is one, uploads first.
    const queue = [];
    if (vmEl && vmEl._recording) queue.push(vmEl._recording);
    queue.push(...chosen);

    const keys = [];
    for (let i = 0; i < queue.length; i++) {
      sendBtn.textContent = queue.length === 1
        ? "Sending..."
        : "Sending " + (i + 1) + " of " + queue.length + "...";
      const res = await uploadFile(queue[i]);
      if (res.error) {
        notice.textContent = res.error;
        notice.hidden = false;
        sendBtn.disabled = false;
        sendBtn.textContent = "Send";
        return;
      }
      keys.push(res.key);
    }

    sendBtn.textContent = "Sending...";
    const res = await sendTipWithFiles(
      nameEl.value, emailEl.value, msgEl.value, keys
    );

    sendBtn.disabled = false;
    sendBtn.textContent = "Send";

    if (res.error) {
      notice.textContent = res.error;
      notice.hidden = false;
      return;
    }

    // Tell Sonny a tip landed. Fire-and-forget.
    notifyTip({
      name: nameEl.value,
      email: emailEl.value,
      message: msgEl.value,
      attachments: chosen.length,
      hasVoicemail: !!(vmEl && vmEl._recording),
    });

    nameEl.value = ""; emailEl.value = ""; msgEl.value = "";
    chosen = []; drawList();
    if (vmEl) vmEl._recording = null;
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
  /* An explicit `display` beats the `hidden` attribute, so without
     this, elements meant to be hidden stay on screen. */
  [hidden] { display: none !important; }


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

  .filepick {
    display: flex; align-items: center; gap: 0.8rem; flex-wrap: wrap;
    cursor: pointer;
  }
  .filepick input[type="file"] {
    position: absolute; width: 1px; height: 1px;
    opacity: 0; overflow: hidden;
  }
  .filepick-btn {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.55rem 1rem;
    transition: border-color 0.2s ease;
  }
  .filepick:hover .filepick-btn { border-color: var(--oxide); }
  .filepick input:focus-visible + .filepick-btn { outline: 2px solid var(--oxide); }
  .filepick-hint {
    font-family: var(--mono); font-size: 0.62rem;
    color: var(--sage); opacity: 0.75;
  }

  .filelist { list-style: none; margin: 0.8rem 0 0; padding: 0; }
  .fileitem {
    display: flex; align-items: center; gap: 0.7rem;
    padding: 0.5rem 0.7rem;
    background: var(--basalt-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    margin-bottom: 0.4rem;
  }
  .fileitem-name {
    font-family: var(--body); font-size: 0.92rem;
    color: var(--snowmelt);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .fileitem-size {
    font-family: var(--mono); font-size: 0.6rem;
    color: var(--sage); margin-left: auto; flex: none;
  }
  .fileitem-x {
    font-family: var(--mono); font-size: 0.58rem;
    letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: none; cursor: pointer; flex: none;
  }
  .fileitem-x:hover { color: #d93b1f; }

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
NOTIFY_EOF

echo ""
echo "NEXT — add two variables in Cloudflare Pages"
echo "  Settings > Variables and Secrets (Production AND Preview):"
echo "     NTFY_URL    https://ntfy.sh"
echo "     NTFY_TOPIC  your-unguessable-topic"
echo ""
echo "Then: git add -A && git commit -m \"tip notifications\" && git push"
