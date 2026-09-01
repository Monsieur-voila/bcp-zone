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

// ── CONFIG ───────────────────────────────────────────────────
//  Set directly here rather than via environment variables.
//  Cloudflare's variables were not reaching this Function, and a
//  notification topic is not a meaningful secret — the worst a
//  leak allows is someone sending you junk notifications. It
//  grants no access to tips, the database, or anything else.
//
//  To change where notifications go, edit these two lines.
const NTFY_URL = "https://ntfy.sh";
const NTFY_TOPIC = "k0mme_thr3ceb";

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

  // Environment variables win if present; otherwise fall back to
  // the constants above.
  const base = ctx.env.NTFY_URL || NTFY_URL;
  const topic = ctx.env.NTFY_TOPIC || NTFY_TOPIC;

  if (!base || !topic || topic === "REPLACE_WITH_YOUR_TOPIC") {
    return ok({ sent: false, reason: "not configured" });
  }

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

    const res = await fetch(`${base.replace(/\/$/, "")}/${topic}`, {
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

    return ok({ sent: res.ok, status: res.status });
  } catch (e) {
    // Never let a notification failure surface to the sender,
    // but do report it so it can be diagnosed.
    return ok({ sent: false, reason: String(e?.message || e) });
  }
};
