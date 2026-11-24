// Supabase Edge Function: add-comment
// Stores a real video/post comment using the server-side key only. The app has
// no Supabase JWT (its sessions are local/Firebase), so direct PostgREST INSERT
// would be rejected by RLS. No author identity or text is invented here.
// Secrets: SUPABASE_URL, SUPABASE_SECRET_KEYS (or legacy SUPABASE_SERVICE_ROLE_KEY)

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
    const readServiceKey = (): string => {
      const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
      if (raw) {
        try {
          const keys = JSON.parse(raw);
          const key = keys?.default ?? Object.values(keys)[0];
          if (typeof key === "string" && key) return key;
        } catch (_) { /* fall through to legacy key */ }
      }
      return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    };
    const serviceKey = readServiceKey();
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "missing_supabase_secrets" }, 500);
    }

    const body = await req.json();
    const targetType = String(body.targetType ?? "").trim();
    const targetId = String(body.targetId ?? "").trim();
    const authorKey = String(body.authorKey ?? "").trim();
    const authorName = String(body.authorName ?? "").trim();
    const content = String(body.content ?? "").trim();

    if (!["video", "post"].includes(targetType)) {
      return json({ error: "invalid_target_type" }, 400);
    }
    if (!targetId || targetId.length > 128 || targetId.includes("..")) {
      return json({ error: "invalid_target_id" }, 400);
    }
    if (!authorKey || authorKey.length > 128) {
      return json({ error: "invalid_author" }, 400);
    }
    if (authorName.length < 2 || authorName.length > 120) {
      return json({ error: "invalid_author_name" }, 400);
    }
    if (content.length < 1 || content.length > 2000) {
      return json({ error: "invalid_content" }, 400);
    }

    // app_comments is a separate table so local/Firebase accounts are supported
    // without inventing a profiles row or weakening the existing UUID foreign keys.
    const payload = {
      target_type: targetType,
      target_id: targetId,
      author_key: authorKey,
      author_name: authorName,
      content,
    };

    const insertRes = await fetch(`${supabaseUrl}/rest/v1/app_comments`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify(payload),
    });
    if (!insertRes.ok) {
      return json(
        { error: "insert_failed", status: insertRes.status, detail: (await insertRes.text()).slice(0, 500) },
        502,
      );
    }

    const rows = await insertRes.json();
    const row = Array.isArray(rows) ? rows[0] : rows;
    return json({ id: String(row?.id ?? ""), createdAt: row?.created_at ?? null });
  } catch (error) {
    return json({ error: "unexpected", detail: String(error) }, 500);
  }
});
