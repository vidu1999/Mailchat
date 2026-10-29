// Receives a Supabase Database Webhook for user_notifications INSERT and sends
// a visible FCM notification to that recipient's registered Android devices.
// Deploy with: supabase functions deploy send-fcm --project-ref <ref> --no-verify-jwt
// Required Edge Function secrets: FCM_PROJECT_ID, FCM_SERVICE_ACCOUNT_JSON,
// FCM_WEBHOOK_SECRET. Supabase supplies SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY to deployed functions.

const encoder = new TextEncoder();
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function encodeJson(value: unknown): string {
  return base64Url(encoder.encode(JSON.stringify(value)));
}

function pemBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

async function googleAccessToken(account: Record<string, string>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${encodeJson({ alg: "RS256", typ: "JWT" })}.${encodeJson({
    iss: account.client_email,
    scope: FCM_SCOPE,
    aud: TOKEN_URL,
    iat: now,
    exp: now + 3600,
  })}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(account.private_key.replace(/\\n/g, "\n")),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    encoder.encode(unsigned),
  );
  const assertion = `${unsigned}.${base64Url(new Uint8Array(signature))}`;
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok || typeof result.access_token !== "string") {
    throw new Error(`Google OAuth failed (${response.status})`);
  }
  return result.access_token;
}

function postgrestHeaders(serviceKey: string): HeadersInit {
  return {
    apikey: serviceKey,
    authorization: `Bearer ${serviceKey}`,
    "content-type": "application/json",
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const expected = Deno.env.get("FCM_WEBHOOK_SECRET");
  const supplied = request.headers.get("x-mailchat-webhook-secret");
  if (!expected || !supplied || supplied !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const projectId = Deno.env.get("FCM_PROJECT_ID");
  const accountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!supabaseUrl || !serviceKey || !projectId || !accountJson) {
    console.error("FCM sender configuration is incomplete");
    return new Response("FCM sender is not configured", { status: 503 });
  }

  try {
    const webhook = await request.json();
    const row = webhook?.record;
    if (webhook?.type !== "INSERT" || webhook?.table !== "user_notifications" || !row) {
      return new Response("Ignored", { status: 202 });
    }
    if (row.notification_type !== "message" && row.notification_type !== "missed_call") {
      return new Response("Ignored notification type", { status: 202 });
    }
    if (typeof row.user_id !== "string" || typeof row.title !== "string" || typeof row.body !== "string") {
      return new Response("Invalid event", { status: 400 });
    }

    const deviceUrl = new URL("/rest/v1/user_devices", supabaseUrl);
    deviceUrl.search = new URLSearchParams({
      select: "push_token",
      user_id: `eq.${row.user_id}`,
      platform: "eq.android",
      push_token: "not.is.null",
    }).toString();
    const deviceResponse = await fetch(deviceUrl, { headers: postgrestHeaders(serviceKey) });
    if (!deviceResponse.ok) {
      console.error("Device token lookup failed", deviceResponse.status);
      return new Response("Could not load device tokens", { status: 502 });
    }
    const devices = await deviceResponse.json();
    const tokens = [...new Set(
      (Array.isArray(devices) ? devices : [])
        .map((device) => device?.push_token)
        .filter((token): token is string => typeof token === "string" && token.length > 0),
    )];
    if (!tokens.length) return Response.json({ sent: 0, reason: "no_android_tokens" });

    const account = JSON.parse(accountJson) as Record<string, string>;
    const accessToken = await googleAccessToken(account);
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`;
    const payload = row.payload && typeof row.payload === "object" ? row.payload : {};
    const data: Record<string, string> = {
      notificationType: row.notification_type,
    };
    for (const [key, value] of Object.entries(payload)) {
      if (value === null || value === undefined) continue;
      data[key] = typeof value === "string" ? value : JSON.stringify(value);
    }
    if (typeof row.conversation_id === "string") data.conversationId ??= row.conversation_id;
    if (typeof row.call_id === "string") data.callId ??= row.call_id;

    let sent = 0;
    let removed = 0;
    for (const token of tokens) {
      const response = await fetch(fcmUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token,
            notification: { title: row.title, body: row.body },
            data,
            android: {
              priority: "HIGH",
              notification: { channel_id: "fcm_fallback_notification_channel" },
            },
          },
        }),
      });
      if (response.ok) {
        sent++;
        continue;
      }
      const errorText = await response.text();
      let unregistered = false;
      try {
        const errorJson = JSON.parse(errorText);
        const details = errorJson?.error?.details;
        unregistered = Array.isArray(details) && details.some(
          (detail) => detail?.errorCode === "UNREGISTERED",
        );
      } catch (_) {
        // Keep the token; a malformed error body is not proof it expired.
      }
      if (unregistered) {
        const deleteUrl = new URL("/rest/v1/user_devices", supabaseUrl);
        deleteUrl.search = new URLSearchParams({
          user_id: `eq.${row.user_id}`,
          push_token: `eq.${token}`,
        }).toString();
        const deleted = await fetch(deleteUrl, {
          method: "DELETE",
          headers: postgrestHeaders(serviceKey),
        });
        if (deleted.ok) removed++;
      } else {
        // Never log token values, error bodies, or service-account material.
        console.error("FCM send failed", response.status);
      }
    }
    return Response.json({ sent, removedInvalidTokens: removed });
  } catch (error) {
    console.error("FCM webhook processing failed", String(error));
    return new Response("Push delivery failed", { status: 500 });
  }
});
