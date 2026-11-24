// Supabase Edge Function: download-ticket
// For PRIVATE B2 buckets: returns a B2 download-authorization token so the app
// can play/prefetch files with a plain HTTPS URL (B2 requires ?token=<grant>).
// Secrets: B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME

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

const VALID_SECONDS = 604800; // B2 maximum: 7 days

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
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
    const prefix = String(body.prefix ?? body.fileKey ?? "clips_").trim();
    if (!prefix || prefix.length > 512 || prefix.includes("..")) {
      return json({ error: "invalid_prefix" }, 400);
    }

    // 1) Authorize with Backblaze
    const basic = btoa(`${keyId}:${appKey}`);
    const authRes = await fetch(
      "https://api.backblazeb2.com/b2api/v2/b2_authorize_account",
      { headers: { Authorization: `Basic ${basic}` } },
    );
    if (!authRes.ok) {
      return json({ error: "b2_authorize_failed", detail: await authRes.text() }, 502);
    }
    const account = await authRes.json();

    // 2) Resolve the bucket id
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

    // 3) Download authorization for the clips_ prefix (one token for all files)
    const grantRes = await fetch(
      `${account.apiUrl}/b2api/v2/b2_get_download_authorization`,
      {
        method: "POST",
        headers: {
          Authorization: account.authorizationToken,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          bucketId: bucket.bucketId,
          fileNamePrefix: prefix,
          validDurationInSeconds: VALID_SECONDS,
        }),
      },
    );
    if (!grantRes.ok) {
      return json({ error: "download_auth_failed", detail: await grantRes.text() }, 502);
    }
    const grant = await grantRes.json();

    return json({
      baseUrl: `${account.downloadUrl}/file/${bucketName}/`,
      token: grant.authorizationToken,
      prefix,
      expiresInSeconds: VALID_SECONDS,
    });
  } catch (error) {
    return json({ error: "unexpected", detail: String(error) }, 500);
  }
});
