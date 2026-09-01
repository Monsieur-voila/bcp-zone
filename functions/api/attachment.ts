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
