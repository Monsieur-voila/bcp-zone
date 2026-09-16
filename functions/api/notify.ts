// ─────────────────────────────────────────────────────────────
//  POST /api/notify
//
//  Fires a push notification (ntfy) AND an email (Resend) when
//  a tip arrives. Neither can block the other, and neither can
//  ever block a tip from being saved — this runs after the tip
//  is already in the database.
//
//  ntfy: https://ntfy.sh — open source, no account needed.
//  If NTFY_URL/NTFY_TOPIC are missing, that half quietly does
//  nothing. NTFY_TOKEN (optional) authenticates under your
//  ntfy.sh account, avoiding the shared anonymous-IP rate limit.
//
//  Resend: sends from auth@bcp.zone to contacts@bcp.zone.
//  Requires RESEND_API_KEY. If missing, that half quietly does
//  nothing.
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

const EMAIL_FROM = "auth@bcp.zone";
const EMAIL_TO = "contacts@bcp.zone";

interface Env {
  NTFY_URL?: string;
  NTFY_TOPIC?: string;
  NTFY_TOKEN?: string;
  RESEND_API_KEY?: string;
}

export const onRequestPost: PagesFunction<Env> = async (ctx) => {
  const ok = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });

  const base = ctx.env.NTFY_URL || NTFY_URL;
  const topic = ctx.env.NTFY_TOPIC || NTFY_TOPIC;
  const token = ctx.env.NTFY_TOKEN;
  const resendKey = ctx.env.RESEND_API_KEY;

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
    const plainBody = `${preview}${extras}${reply}`;

    // ── ntfy push ──────────────────────────────────────────
    let ntfyResult: { sent: boolean; status?: number; reason?: string } =
      { sent: false, reason: "not configured" };

    if (base && topic && topic !== "REPLACE_WITH_YOUR_TOPIC") {
      try {
        const res = await fetch(`${base.replace(/\/$/, "")}/${topic}`, {
          method: "POST",
          headers: {
            ...(token ? { "Authorization": `Basic ${btoa(":" + token)}` } : {}),
            "Title": `Tip from ${who}`,
            "Priority": "default",
            "Tags": body.hasVoicemail ? "speech_balloon" : "envelope",
            "Click": `${site}/tips`,
          },
          body: plainBody,
        });
        ntfyResult = { sent: res.ok, status: res.status };
      } catch (e) {
        ntfyResult = { sent: false, reason: String(e?.message || e) };
      }
    }

    // ── Resend email ───────────────────────────────────────
    let emailResult: { sent: boolean; status?: number; reason?: string } =
      { sent: false, reason: "not configured" };
  
    if (resendKey) {
      try {
        const res = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${resendKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: `BCP Zone <${EMAIL_FROM}>`,
            to: [EMAIL_TO],
            subject: `Tip from ${who}`,
            text: `${plainBody}\n\nReview: ${site}/tips`,
          }),
        });
        emailResult = { sent: res.ok, status: res.status };
      } catch (e) {
        emailResult = { sent: false, reason: String(e?.message || e) };
      }
    }

    return ok({ ntfy: ntfyResult, email: emailResult });
  } catch (e) {
    // Never let a notification failure surface to the sender,
    // but do report it so it can be diagnosed.
    return ok({ sent: false, reason: String(e?.message || e) });
  }
};