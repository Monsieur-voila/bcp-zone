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
