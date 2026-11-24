// Supabase Edge Function: upload-ticket
// Creates a B2 single-upload URL and reserves quota through the service role.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, B2_KEY_ID,
//          B2_APPLICATION_KEY, B2_BUCKET_NAME

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
    const keyId = Deno.env.get("B2_KEY_ID")!;
    const appKey = Deno.env.get("B2_APPLICATION_KEY")!;
    const bucketName = Deno.env.get("B2_BUCKET_NAME") ?? "clips-videos-ithuzzzkhnbypgvmdugk";

    const body = await req.json();
    const fileName = String(body.fileName ?? "").trim();
    const size = Number(body.size ?? 0);
    const contentType = String(body.contentType ?? "video/mp4");
    const uploadType = String(body.uploadType ?? "short");

    if (!fileName || !Number.isFinite(size) || size <= 0) {
      return json({ error: "invalid_file" }, 400);
    }
    if (size > 50 * 1024 * 1024) {
      return json({ error: "file_too_large" }, 413);
    }
    if (!["wide", "short", "post", "video_in_post"].includes(uploadType)) {
      return json({ error: "invalid_upload_type" }, 400);
    }

    // Supabase Auth user when available; local/Firebase sessions upload anonymously.
    let userId: string | null = null;
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
        headers: { apikey: serviceKey, authorization: authHeader },
      });
      if (userRes.ok) {
        const user = await userRes.json();
        userId = user?.id ?? null;
      }
    }

    // 1) B2 authorize
    const basic = btoa(`${keyId}:${appKey}`);
    const authorizeRes = await fetch(
      "https://api.backblazeb2.com/b2api/v2/b2_authorize_account",
      { headers: { Authorization: `Basic ${basic}` } },
    );
    if (!authorizeRes.ok) {
      return json({ error: "b2_authorize_failed", detail: await authorizeRes.text() }, 502);
    }
    const account = await authorizeRes.json();

    // 2) Find bucket id
    const bucketsRes = await fetch(`${account.apiUrl}/b2api/v2/b2_list_buckets`, {
      method: "POST",
      headers: {
        Authorization: account.authorizationToken,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ accountId: account.accountId, bucketName }),
    });
    if (!bucketsRes.ok) {
      return json({ error: "b2_bucket_failed", detail: await bucketsRes.text() }, 502);
    }
    const buckets = await bucketsRes.json();
    const bucket = buckets.buckets?.find((b: { bucketName: string }) => b.bucketName === bucketName);
    if (!bucket) return json({ error: "bucket_not_found" }, 500);

    // 3) Upload URL
    const uploadUrlRes = await fetch(`${account.apiUrl}/b2api/v2/b2_get_upload_url`, {
      method: "POST",
      headers: {
        Authorization: account.authorizationToken,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ bucketId: bucket.bucketId }),
    });
    if (!uploadUrlRes.ok) {
      return json({ error: "b2_upload_url_failed", detail: await uploadUrlRes.text() }, 502);
    }
    const upload = await uploadUrlRes.json();

    // 4) Reserve quota / daily limits in SQL (service role only)
    const rpcRes = await fetch(`${supabaseUrl}/rest/v1/rpc/reserve_b2_upload_session`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_user_id: userId,
        p_expected_size: size,
        p_b2_key: fileName,
        p_upload_type: uploadType,
      }),
    });
    if (!rpcRes.ok) {
      return json({ error: "upload_not_allowed", detail: await rpcRes.text() }, 403);
    }
    const sessionId = await rpcRes.json();

    const encodedName = encodeURIComponent(fileName);
    return json({
      sessionId,
      uploadUrl: upload.uploadUrl,
      authorizationToken: upload.authorizationToken,
      b2Key: fileName,
      bucket: bucketName,
      publicUrl: `${account.downloadUrl}/file/${bucketName}/${encodedName}`,
      contentType,
    });
  } catch (error) {
    return json({ error: "unexpected", detail: String(error) }, 500);
  }
});
