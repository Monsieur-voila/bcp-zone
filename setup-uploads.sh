#!/usr/bin/env bash
# Tips: photos, video, and voicemail — run from ~/site on the uploads branch
set -e
if [ ! -f package.json ]; then echo "ERROR: run from ~/site"; exit 1; fi
echo "Writing files..."
mkdir -p db functions/api src/lib src/styles src/components src/pages

echo "  db/stage-uploads.sql"
cat > 'db/stage-uploads.sql' << 'UPLOAD_EOF'
-- ═══════════════════════════════════════════════════════════════
--  TIPS — image attachments
--  Paste into Supabase: SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════

-- Attachment keys are stored on the tip itself. The files live in
-- Cloudflare R2 (private); these are just the object keys, which
-- the admin page exchanges for short-lived signed URLs.

alter table public.tips
  add column if not exists attachments jsonb not null default '[]'::jsonb;

-- Allow the insert policy to accept attachments, capped at 3.
drop policy if exists "anyone may send a tip" on public.tips;
create policy "anyone may send a tip"
  on public.tips for insert
  with check (
    length(coalesce(message, '')) between 2 and 5000
    and length(coalesce(name, '')) <= 120
    and length(coalesce(email, '')) <= 200
    and jsonb_array_length(coalesce(attachments, '[]'::jsonb)) <= 3
  );
UPLOAD_EOF

echo "  functions/api/upload.ts"
cat > 'functions/api/upload.ts' << 'UPLOAD_EOF'
// ─────────────────────────────────────────────────────────────
//  POST /api/upload
//
//  Receives an image, video, or audio file, validates it, and
//  stores it in a PRIVATE R2 bucket. Returns the object key —
//  never a public URL.
//
//  Validation is by MAGIC BYTES, not the claimed content type.
//  A renamed executable fails here even if it says image/jpeg.
// ─────────────────────────────────────────────────────────────

const LIMITS = {
  image: 25 * 1024 * 1024,    // 25MB
  video: 150 * 1024 * 1024,   // 150MB
  audio: 25 * 1024 * 1024,    // 25MB — voice is small; 5 min ≈ 3MB
};

type Kind = "image" | "video" | "audio";

// Identify a file from its leading bytes. Returns the kind and a
// file extension, or null if it isn't something we accept.
function sniff(b: Uint8Array): { kind: Kind; ext: string } | null {
  if (b.length < 16) return null;

  // ── images ──
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff)
    return { kind: "image", ext: "jpg" };
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47)
    return { kind: "image", ext: "png" };
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38)
    return { kind: "image", ext: "gif" };
  if (b[0] === 0x42 && b[1] === 0x4d)
    return { kind: "image", ext: "bmp" };
  // TIFF
  if ((b[0] === 0x49 && b[1] === 0x49 && b[2] === 0x2a) ||
      (b[0] === 0x4d && b[1] === 0x4d && b[2] === 0x00))
    return { kind: "image", ext: "tif" };

  // RIFF container: WEBP (image) or WAV (audio)
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) {
    if (b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50)
      return { kind: "image", ext: "webp" };
    if (b[8] === 0x57 && b[9] === 0x41 && b[10] === 0x56 && b[11] === 0x45)
      return { kind: "audio", ext: "wav" };
  }

  // ISO base media (ftyp at offset 4): HEIC, MP4, MOV, M4A
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8], b[9], b[10], b[11]).toLowerCase();
    if (brand.startsWith("hei") || brand.startsWith("mif") || brand.startsWith("msf"))
      return { kind: "image", ext: "heic" };
    if (brand.startsWith("qt"))
      return { kind: "video", ext: "mov" };
    if (brand.startsWith("m4a"))
      return { kind: "audio", ext: "m4a" };
    return { kind: "video", ext: "mp4" };
  }

  // Matroska / WebM — audio or video depending on what the browser made
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3)
    return { kind: "video", ext: "webm" };

  // ── audio ──
  if (b[0] === 0x4f && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53)
    return { kind: "audio", ext: "ogg" };
  if (b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33)
    return { kind: "audio", ext: "mp3" };
  if (b[0] === 0xff && (b[1] & 0xe0) === 0xe0)
    return { kind: "audio", ext: "mp3" };
  if (b[0] === 0x66 && b[1] === 0x4c && b[2] === 0x61 && b[3] === 0x43)
    return { kind: "audio", ext: "flac" };

  return null;
}

// Strip EXIF from JPEG by dropping APP1/APP2 marker segments.
// Removes GPS coordinates and camera identifiers — a tipster
// shouldn't disclose their home location by accident.
function stripJpegExif(b: Uint8Array): Uint8Array {
  if (!(b[0] === 0xff && b[1] === 0xd8)) return b;
  const out: number[] = [0xff, 0xd8];
  let i = 2;
  while (i < b.length - 1) {
    if (b[i] !== 0xff) { out.push(...b.subarray(i)); break; }
    const marker = b[i + 1];
    // Start of scan — copy the rest verbatim.
    if (marker === 0xda) { out.push(...b.subarray(i)); break; }
    const len = (b[i + 2] << 8) | b[i + 3];
    const isMeta = marker === 0xe1 || marker === 0xe2 || marker === 0xed;
    if (!isMeta) out.push(...b.subarray(i, i + 2 + len));
    i += 2 + len;
  }
  return new Uint8Array(out);
}

export const onRequestPost: PagesFunction<{ TIPS_BUCKET: R2Bucket }> = async (ctx) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status, headers: { "content-type": "application/json" },
    });

  try {
    const form = await ctx.request.formData();
    const file = form.get("file");

    if (!(file instanceof File)) return json({ error: "No file received." }, 400);
    if (file.size === 0)         return json({ error: "That file is empty." }, 400);

    let bytes = new Uint8Array(await file.arrayBuffer());
    const id = sniff(bytes);

    if (!id) {
      return json({ error: "Only photos, video, and audio can be sent." }, 400);
    }
    if (file.size > LIMITS[id.kind]) {
      const mb = Math.round(LIMITS[id.kind] / 1048576);
      return json({ error: `That ${id.kind} is over ${mb}MB.` }, 400);
    }

    if (id.ext === "jpg") bytes = stripJpegExif(bytes);

    const key = `tips/${crypto.randomUUID()}.${id.ext}`;
    await ctx.env.TIPS_BUCKET.put(key, bytes, {
      httpMetadata: { contentType: file.type || "application/octet-stream" },
    });

    return json({ key, kind: id.kind, size: bytes.length });
  } catch {
    return json({ error: "Upload failed." }, 500);
  }
};
UPLOAD_EOF

echo "  functions/api/attachment.ts"
cat > 'functions/api/attachment.ts' << 'UPLOAD_EOF'
// ─────────────────────────────────────────────────────────────
//  GET /api/attachment?key=tips/xxxx.jpg
//
//  Streams a private R2 object back to an ADMIN.
//
//  The bucket is private, so this is the only way to view an
//  attachment. Every request verifies the caller's Supabase
//  session and checks is_admin server-side — a stranger with a
//  guessed key gets nothing.
// ─────────────────────────────────────────────────────────────

interface Env {
  TIPS_BUCKET: R2Bucket;
  PUBLIC_SUPABASE_URL: string;
  PUBLIC_SUPABASE_ANON_KEY: string;
}

export const onRequestGet: PagesFunction<Env> = async (ctx) => {
  const url = new URL(ctx.request.url);
  const key = url.searchParams.get("key");

  const deny = (msg: string, status: number) =>
    new Response(msg, { status });

  if (!key || !key.startsWith("tips/")) {
    return deny("Bad request", 400);
  }

  // ── Verify the caller is a signed-in admin ──
  const auth = ctx.request.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) {
    return deny("Not permitted", 401);
  }
  const token = auth.slice(7);

  // Ask Supabase who this token belongs to.
  const userRes = await fetch(`${ctx.env.PUBLIC_SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: ctx.env.PUBLIC_SUPABASE_ANON_KEY,
      authorization: `Bearer ${token}`,
    },
  });
  if (!userRes.ok) return deny("Not permitted", 401);
  const user = await userRes.json<{ id?: string }>();
  if (!user?.id) return deny("Not permitted", 401);

  // Check the admin flag on their profile.
  const profRes = await fetch(
    `${ctx.env.PUBLIC_SUPABASE_URL}/rest/v1/profiles?id=eq.${user.id}&select=is_admin`,
    {
      headers: {
        apikey: ctx.env.PUBLIC_SUPABASE_ANON_KEY,
        authorization: `Bearer ${token}`,
      },
    }
  );
  if (!profRes.ok) return deny("Not permitted", 403);
  const rows = await profRes.json<Array<{ is_admin?: boolean }>>();
  if (!rows?.[0]?.is_admin) return deny("Not permitted", 403);

  // ── Serve the object ──
  const obj = await ctx.env.TIPS_BUCKET.get(key);
  if (!obj) return deny("Not found", 404);

  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("cache-control", "private, max-age=300");
  return new Response(obj.body, { headers });
};
UPLOAD_EOF

echo "  src/lib/forum.ts"
cat > 'src/lib/forum.ts' << 'UPLOAD_EOF'
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
UPLOAD_EOF

echo "  src/styles/forum.css"
cat > 'src/styles/forum.css' << 'UPLOAD_EOF'
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

/* ── TIP ATTACHMENTS (admin inbox) ──────────────────────────── */

.tip-shots {
  display: flex;
  flex-wrap: wrap;
  gap: 0.6rem;
  margin-top: 1rem;
}
.tip-shot {
  width: 140px;
  height: 140px;
  object-fit: cover;
  border: 1px solid var(--line);
  border-radius: 3px;
  background: var(--basalt);
  cursor: zoom-in;
  transition: border-color 0.2s ease;
}
.tip-shot:hover { border-color: var(--oxide); }
.tip-shot-fail {
  font-family: var(--mono);
  font-size: 0.6rem;
  color: var(--sage);
  opacity: 0.6;
}

/* voicemail in the inbox — highlighted, because it's the channel
   we most want people using */
.tip-voice {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  width: 100%;
  padding: 0.8rem 0.9rem;
  background: rgba(224, 163, 60, 0.06);
  border: 1px solid rgba(224, 163, 60, 0.5);
  border-radius: 3px;
  margin-bottom: 0.6rem;
}
.tip-voice-tag {
  font-family: var(--mono);
  font-size: 0.56rem;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: #e0a33c;
}
.tip-audio { width: 100%; }
.tip-media { display: inline-block; }
.tip-video {
  max-width: 320px;
  border: 1px solid var(--line);
  border-radius: 3px;
  background: #000;
}
UPLOAD_EOF

echo "  src/components/VoiceRecorder.astro"
cat > 'src/components/VoiceRecorder.astro' << 'UPLOAD_EOF'
---
// ─────────────────────────────────────────────────────────────
//  VoiceRecorder — leave a message, like a voicemail.
//
//  Press record, get a 3-2-1 countdown so there's no doubt when
//  it starts, then speak. A live level meter and a visible
//  countdown make the recording state unmistakable. Auto-stops
//  at 5:00 and KEEPS what was captured.
//
//  The microphone is only opened after the button is pressed.
//  Nothing is captured before that.
// ─────────────────────────────────────────────────────────────
---

<div class="vm" data-vm>
  <div class="vm-head">
    <span class="vm-icon" aria-hidden="true">●</span>
    <div>
      <p class="vm-title">Leave a voicemail</p>
      <p class="vm-sub">
        Sometimes it's easier to just say it. Up to five minutes.
      </p>
    </div>
  </div>

  <!-- idle -->
  <div class="vm-idle" data-vm-idle>
    <button class="vm-rec" type="button" data-vm-start>Start recording</button>
    <span class="vm-or">or</span>
    <label class="vm-attach">
      <input type="file" accept="audio/*" data-vm-file />
      <span>attach an audio file</span>
    </label>
  </div>

  <!-- counting in -->
  <div class="vm-count" data-vm-count hidden>
    <span class="vm-count-n" data-vm-count-n>3</span>
    <span class="vm-count-t">get ready…</span>
  </div>

  <!-- recording -->
  <div class="vm-live" data-vm-live hidden>
    <div class="vm-live-top">
      <span class="vm-dot" aria-hidden="true"></span>
      <span class="vm-live-label">Recording</span>
      <span class="vm-time" data-vm-time>5:00 left</span>
    </div>
    <div class="vm-meter" aria-hidden="true">
      <div class="vm-meter-fill" data-vm-meter></div>
    </div>
    <button class="vm-stop" type="button" data-vm-stop>Stop</button>
  </div>

  <!-- done -->
  <div class="vm-done" data-vm-done hidden>
    <audio class="vm-play" controls data-vm-audio></audio>
    <div class="vm-done-acts">
      <span class="vm-kept" data-vm-kept></span>
      <button class="vm-redo" type="button" data-vm-redo>Record again</button>
    </div>
  </div>

  <p class="vm-err" data-vm-err hidden></p>
</div>

<script>
  const MAX_SECONDS = 300;   // 5 minutes

  const root    = document.querySelector("[data-vm]");
  if (root) {
    const idleEl  = root.querySelector("[data-vm-idle]");
    const countEl = root.querySelector("[data-vm-count]");
    const countN  = root.querySelector("[data-vm-count-n]");
    const liveEl  = root.querySelector("[data-vm-live]");
    const doneEl  = root.querySelector("[data-vm-done]");
    const timeEl  = root.querySelector("[data-vm-time]");
    const meterEl = root.querySelector("[data-vm-meter]");
    const audioEl = root.querySelector("[data-vm-audio]");
    const keptEl  = root.querySelector("[data-vm-kept]");
    const errEl   = root.querySelector("[data-vm-err]");
    const fileEl  = root.querySelector("[data-vm-file]");

    let recorder = null, chunks = [], stream = null;
    let audioCtx = null, raf = null, ticker = null;

    function show(which) {
      idleEl.hidden  = which !== "idle";
      countEl.hidden = which !== "count";
      liveEl.hidden  = which !== "live";
      doneEl.hidden  = which !== "done";
    }

    function fail(msg) {
      errEl.textContent = msg;
      errEl.hidden = false;
      show("idle");
    }

    function cleanup() {
      if (raf) cancelAnimationFrame(raf);
      if (ticker) clearInterval(ticker);
      if (audioCtx) { audioCtx.close(); audioCtx = null; }
      if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
    }

    // Live level meter — visible proof the mic is capturing.
    function meter(src) {
      audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 512;
      audioCtx.createMediaStreamSource(src).connect(analyser);
      const buf = new Uint8Array(analyser.frequencyBinCount);

      const tick = () => {
        analyser.getByteTimeDomainData(buf);
        let peak = 0;
        for (const v of buf) peak = Math.max(peak, Math.abs(v - 128));
        const pct = Math.min(100, (peak / 128) * 180);
        meterEl.style.width = `${pct}%`;
        raf = requestAnimationFrame(tick);
      };
      tick();
    }

    async function begin() {
      errEl.hidden = true;

      // Mic is requested only now — never before the button.
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      } catch {
        fail("We couldn't reach your microphone. Check the browser's permission.");
        return;
      }

      // 3-2-1 so the start moment is unmistakable.
      show("count");
      for (let n = 3; n >= 1; n--) {
        countN.textContent = String(n);
        await new Promise((r) => setTimeout(r, 700));
      }

      chunks = [];
      try {
        recorder = new MediaRecorder(stream);
      } catch {
        cleanup();
        fail("This browser can't record audio. You can attach a file instead.");
        return;
      }

      recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      recorder.onstop = () => {
        cleanup();
        const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
        const ext = (recorder.mimeType || "").includes("mp4") ? "m4a" : "webm";
        root._recording = new File([blob], `voicemail.${ext}`, { type: blob.type });
        audioEl.src = URL.createObjectURL(blob);
        keptEl.textContent = `${(blob.size / 1048576).toFixed(1)}MB — it'll send with your message.`;
        root.dispatchEvent(new CustomEvent("vm:ready", { bubbles: true }));
        show("done");
      };

      recorder.start();
      show("live");
      meter(stream);

      let left = MAX_SECONDS;
      const paint = () => {
        const m = Math.floor(left / 60), s = left % 60;
        timeEl.textContent = `${m}:${String(s).padStart(2, "0")} left`;
        timeEl.classList.toggle("low", left <= 30);
      };
      paint();
      ticker = setInterval(() => {
        left -= 1;
        paint();
        // Auto-stop at the cap, keeping what was captured.
        if (left <= 0 && recorder.state === "recording") recorder.stop();
      }, 1000);
    }

    root.querySelector("[data-vm-start]").addEventListener("click", begin);
    root.querySelector("[data-vm-stop]").addEventListener("click", () => {
      if (recorder?.state === "recording") recorder.stop();
    });
    root.querySelector("[data-vm-redo]").addEventListener("click", () => {
      root._recording = null;
      audioEl.removeAttribute("src");
      root.dispatchEvent(new CustomEvent("vm:ready", { bubbles: true }));
      show("idle");
    });

    // Attaching an audio file instead of recording.
    fileEl.addEventListener("change", () => {
      const f = fileEl.files?.[0];
      if (!f) return;
      root._recording = f;
      audioEl.src = URL.createObjectURL(f);
      keptEl.textContent = `${f.name} — ${(f.size / 1048576).toFixed(1)}MB`;
      root.dispatchEvent(new CustomEvent("vm:ready", { bubbles: true }));
      show("done");
    });
  }
</script>

<style>
  /* The voicemail block is deliberately the warmest thing on the
     page — this is the channel we most want people to use. */
  .vm {
    --vm-accent: #e0a33c;
    border: 1px solid var(--vm-accent);
    border-radius: 4px;
    background:
      linear-gradient(180deg, rgba(224,163,60,0.07) 0%, rgba(224,163,60,0.02) 100%);
    padding: 1.4rem 1.5rem;
  }

  .vm-head { display: flex; align-items: flex-start; gap: 0.8rem; margin-bottom: 1.1rem; }
  .vm-icon { color: var(--vm-accent); font-size: 0.9rem; line-height: 1.4; }
  .vm-title {
    font-family: var(--display); font-size: 1.35rem;
    color: var(--snowmelt); margin: 0 0 0.2rem;
  }
  .vm-sub {
    font-family: var(--body); font-size: 0.95rem;
    color: var(--sage); margin: 0;
  }

  .vm-idle { display: flex; align-items: center; gap: 0.9rem; flex-wrap: wrap; }
  .vm-rec {
    font-family: var(--mono); font-size: 0.74rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--basalt); background: var(--vm-accent);
    border: 1px solid var(--vm-accent); border-radius: 3px;
    padding: 0.7rem 1.3rem; cursor: pointer;
    transition: background 0.2s ease;
  }
  .vm-rec:hover { background: #f0b855; }
  .vm-or { font-family: var(--body); font-size: 0.9rem; color: var(--sage); }
  .vm-attach { cursor: pointer; }
  .vm-attach input { position: absolute; width: 1px; height: 1px; opacity: 0; }
  .vm-attach span {
    font-family: var(--body); font-size: 0.92rem;
    color: var(--vm-accent);
    border-bottom: 1px solid rgba(224,163,60,0.4);
  }
  .vm-attach:hover span { color: #f0b855; }

  /* counting in */
  .vm-count { display: flex; align-items: center; gap: 0.9rem; }
  .vm-count-n {
    font-family: var(--display); font-size: 2.6rem;
    color: var(--vm-accent); line-height: 1;
  }
  .vm-count-t {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase; color: var(--sage);
  }

  /* recording */
  .vm-live-top { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 0.7rem; }
  .vm-dot {
    width: 10px; height: 10px; border-radius: 50%;
    background: #d93b1f; flex: none;
    animation: vmpulse 1.2s ease-in-out infinite;
  }
  @keyframes vmpulse {
    0%,100% { opacity: 1; box-shadow: 0 0 0 0 rgba(217,59,31,0.5); }
    50%     { opacity: 0.7; box-shadow: 0 0 0 7px rgba(217,59,31,0); }
  }
  .vm-live-label {
    font-family: var(--mono); font-size: 0.72rem;
    letter-spacing: 0.14em; text-transform: uppercase; color: #d93b1f;
  }
  .vm-time {
    margin-left: auto; font-family: var(--mono);
    font-size: 0.7rem; color: var(--sage);
  }
  .vm-time.low { color: #d93b1f; }

  .vm-meter {
    height: 6px; background: rgba(255,255,255,0.07);
    border-radius: 3px; overflow: hidden; margin-bottom: 0.9rem;
  }
  .vm-meter-fill {
    height: 100%; width: 0%;
    background: linear-gradient(90deg, var(--vm-accent), #d93b1f);
    transition: width 0.06s linear;
  }

  .vm-stop {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.5rem 1.1rem; cursor: pointer;
  }
  .vm-stop:hover { border-color: #d93b1f; color: #d93b1f; }

  /* done */
  .vm-play { width: 100%; margin-bottom: 0.7rem; }
  .vm-done-acts { display: flex; align-items: center; gap: 0.9rem; flex-wrap: wrap; }
  .vm-kept { font-family: var(--mono); font-size: 0.64rem; color: var(--sage); }
  .vm-redo {
    font-family: var(--mono); font-size: 0.62rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: none; cursor: pointer; margin-left: auto;
  }
  .vm-redo:hover { color: var(--vm-accent); }

  .vm-err {
    font-family: var(--mono); font-size: 0.7rem;
    color: #d93b1f; margin: 0.9rem 0 0;
  }

  @media (prefers-reduced-motion: reduce) {
    .vm-dot { animation: none; }
  }
</style>
UPLOAD_EOF

echo "  src/pages/contact.astro"
cat > 'src/pages/contact.astro' << 'UPLOAD_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import VoiceRecorder from "../components/VoiceRecorder.astro";
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
  import { sendTipWithFiles, uploadFile, UPLOAD_LIMITS, kindOf } from "../lib/forum";

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
UPLOAD_EOF

echo "  src/pages/tips.astro"
cat > 'src/pages/tips.astro' << 'UPLOAD_EOF'
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
  import { supabase } from "../lib/supabase";
  import { myProfile, getTips, markTipRead, archiveTip, ago, attachmentUrl } from "../lib/forum";

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const loading = document.querySelector("[data-loading]");
  const locked  = document.querySelector("[data-locked]");
  const list    = document.querySelector("[data-list]");

  let rendered = false;

  async function renderInbox() {
    if (rendered) return;

    const tips = await getTips();
    rendered = true;
    loading.hidden = true;
    locked.hidden = true;
    list.hidden = false;

    if (!tips.length) {
      list.innerHTML = `<p class="empty">Nothing yet.</p>`;
      return;
    }

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
        ${(t.attachments && t.attachments.length)
          ? `<div class="tip-shots" data-shots='${JSON.stringify(t.attachments)}'></div>`
          : ""}
        <div class="tip-acts">
          <button class="tip-btn" data-read="${t.id}" data-state="${t.is_read}">
            ${t.is_read ? "Mark unread" : "Mark read"}
          </button>
          <button class="tip-btn" data-archive="${t.id}">Archive</button>
        </div>
      </article>`).join("");

    // Load attachments. Each request re-verifies admin server-side.
    for (const box of list.querySelectorAll("[data-shots]")) {
      let keys = [];
      try { keys = JSON.parse(box.dataset.shots); } catch {}
      for (const key of keys) {
        // Pick the player from the stored extension.
        const ext = String(key).split(".").pop().toLowerCase();
        const isAudio = ["m4a","mp3","wav","ogg","flac"].includes(ext);
        const isVideo = ["mp4","mov","webm"].includes(ext);

        const holder = document.createElement("div");
        holder.className = isAudio ? "tip-voice" : "tip-media";
        if (isAudio) {
          holder.innerHTML = `<span class="tip-voice-tag">voicemail</span>`;
        }
        box.appendChild(holder);

        attachmentUrl(key).then((url) => {
          if (!url) {
            holder.innerHTML = `<span class="tip-shot-fail">unavailable</span>`;
            return;
          }
          let el;
          if (isAudio) {
            el = document.createElement("audio");
            el.controls = true;
            el.className = "tip-audio";
          } else if (isVideo) {
            el = document.createElement("video");
            el.controls = true;
            el.className = "tip-video";
            el.preload = "metadata";
          } else {
            el = document.createElement("img");
            el.className = "tip-shot";
            el.alt = "attachment";
            el.loading = "lazy";
          }
          el.src = url;
          holder.appendChild(el);
        });
      }
    }

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

  function showLocked() {
    loading.hidden = true;
    list.hidden = true;
    locked.hidden = false;
  }

  // Check admin status against a session. Called on load AND whenever
  // the auth state changes — Supabase restores the session
  // asynchronously, so checking only on load races it and wrongly
  // locks the page for a signed-in admin.
  async function check(session) {
    if (!session?.user) {
      if (!rendered) showLocked();
      return;
    }
    const profile = await myProfile();
    if (profile?.is_admin) {
      await renderInbox();
    } else {
      showLocked();
    }
  }

  const { data } = await supabase.auth.getSession();
  await check(data.session);

  supabase.auth.onAuthStateChange((_event, session) => {
    check(session);
  });
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
UPLOAD_EOF

echo "  astro.config.mjs"
cat > 'astro.config.mjs' << 'UPLOAD_EOF'
import { defineConfig } from "astro/config";

// Static output. The /functions directory is picked up by
// Cloudflare Pages directly — it does NOT require the Astro
// Cloudflare adapter, and keeping the site static avoids the
// build complications the adapter introduced previously.
export default defineConfig({
  output: "static",
});
UPLOAD_EOF

echo ""
echo "NEXT:"
echo " 1) Supabase SQL Editor: paste db/stage-uploads.sql, Run"
echo " 2) Cloudflare Pages > Settings > Functions > R2 bindings:"
echo "      variable: TIPS_BUCKET    bucket: bcp-tips"
echo " 3) git add -A && git commit -m uploads && git push -u origin uploads"
