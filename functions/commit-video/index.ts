// Supabase Edge Function: commit-video
// Verifies the file exists on B2, finalizes quota and inserts the videos row.
// Secrets: SUPABASE_URL, SUPABASE_SECRET_KEYS (or legacy SUPABASE_SERVICE_ROLE_KEY),
//          B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME

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
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    // New projects expose sb_secret_... as SUPABASE_SECRET_KEYS (JSON by name).
    // Fall back to the legacy service_role key for older projects.
    const readServiceKey = (): string => {
      const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
      if (raw) {
        try {
          const keys = JSON.parse(raw);
          const key = keys?.default ?? Object.values(keys)[0];
          if (typeof key === "string" && key) return key;
        } catch (_) { /* fall through to legacy key */ }
      }
      return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    };
    const serviceKey = readServiceKey();
    const keyId = Deno.env.get("B2_KEY_ID")?.trim();
    const appKey = Deno.env.get("B2_APPLICATION_KEY")?.trim();
    const bucketName = Deno.env.get("B2_BUCKET_NAME")?.trim() ||
      "clips-videos-ithuzzzkhnbypgvmdugk";
    // Diagnose secret problems without echoing any value back.
    if (!keyId || !appKey) {
      const missing = [
        ...(!keyId ? ["B2_KEY_ID"] : []),
        ...(!appKey ? ["B2_APPLICATION_KEY"] : []),
      ];
      return json({ error: "missing_b2_secrets", missing }, 500);
    }
    if (/^['"]|['"]$/.test(appKey)) {
      return json(
        { error: "malformed_b2_secret", field: "B2_APPLICATION_KEY", hint: "remove surrounding quotes" },
        500,
      );
    }

    const body = await req.json();
    const sessionId = String(body.sessionId ?? "");
    const b2Key = String(body.b2Key ?? "");
    const publicUrl = String(body.publicUrl ?? "");
    const fileId = String(body.fileId ?? "").trim();
    const sizeBytes = Number(body.sizeBytes ?? 0);
    const missing: string[] = [];
    if (!sessionId) missing.push("sessionId");
    if (!b2Key) missing.push("b2Key");
    if (!publicUrl) missing.push("publicUrl");
    if (!fileId) missing.push("fileId");
    if (!(sizeBytes > 0)) missing.push("sizeBytes");
    if (missing.length) {
      // Old APKs omit fileId; this makes the cause visible in the app error.
      return json(
        { error: "invalid_payload", missing, hint: "update app to 1.0.1055+" },
        400,
      );
    }

    let userId: string | null = null;
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
        headers: { apikey: serviceKey, authorization: authHeader },
      });
      if (userRes.ok) userId = (await userRes.json())?.id ?? null;
    }

    // Verify the object really reached B2 before charging quota.
    const basic = btoa(`${keyId}:${appKey}`);
    const authRes = await fetch(
      "https://api.backblazeb2.com/b2api/v2/b2_authorize_account",
      { headers: { Authorization: `Basic ${basic}` } },
    );
    if (!authRes.ok) return json({ error: "b2_authorize_failed" }, 502);
    const account = await authRes.json();

    const infoRes = await fetch(`${account.apiUrl}/b2api/v2/b2_get_file_info`, {
      method: "POST",
      headers: {
        Authorization: account.authorizationToken,
        "Content-Type": "application/json",
      },
      // b2_get_file_info only accepts a fileId — bucketName/fileName are not
      // valid fields here. The app gets fileId from the b2_upload_file response.
      body: JSON.stringify({ fileId }),
    });
    if (!infoRes.ok) {
      return json({ error: "file_not_uploaded", detail: await infoRes.text() }, 400);
    }
    const info = await infoRes.json();
    if (info?.fileName && String(info.fileName) !== b2Key) {
      return json({ error: "file_mismatch", expected: b2Key, actual: String(info.fileName) }, 400);
    }

    const videoId = crypto.randomUUID();
    const finalizeRes = await fetch(`${supabaseUrl}/rest/v1/rpc/finalize_b2_upload_session`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_session_id: sessionId,
        p_video_id: videoId,
        p_playback_url: publicUrl,
        p_size_bytes: sizeBytes,
      }),
    });
    if (!finalizeRes.ok) {
      return json({ error: "finalize_failed", detail: await finalizeRes.text() }, 500);
    }

    const insertRes = await fetch(`${supabaseUrl}/rest/v1/videos`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({
        id: videoId,
        user_id: userId,
        title: String(body.title ?? "فيديو من clips"),
        description: String(body.description ?? ""),
        video_url: publicUrl,
        storage_type: "b2",
        b2_key: b2Key,
        b2_bucket: bucketName,
        mime_type: String(body.mimeType ?? "video/mp4"),
        size_bytes: sizeBytes,
        duration: Number(body.duration ?? 0),
        is_vertical: Boolean(body.isVertical),
        is_short: Boolean(body.isVertical),
        status: "ready",
      }),
    });
    if (!insertRes.ok) {
      return json({ error: "video_insert_failed", detail: await insertRes.text() }, 500);
    }

    return json({ success: true, videoId, publicUrl });
  } catch (error) {
    return json({ error: "unexpected", detail: String(error) }, 500);
  }
});
