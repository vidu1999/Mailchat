// Supabase Database Webhook sender for message/missed-call inbox rows and
// incoming call rows. All Google credentials stay in Edge Function secrets.
// Deploy with: supabase functions deploy send-fcm --project-ref <ref> --no-verify-jwt

const encoder = new TextEncoder();
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

type SupabaseWebhookEvent = {
  type?: string;
  table?: string;
  record?: Record<string, unknown>;
};
type PushNotification = {
  userId: string;
  title: string;
  body: string;
  data: Record<string, string>;
};

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

function restUrl(base: string, table: string, query: Record<string, string>): URL {
  const url = new URL(`/rest/v1/${table}`, base);
  url.search = new URLSearchParams(query).toString();
  return url;
}

async function getRows(
  base: string,
  key: string,
  table: string,
  query: Record<string, string>,
): Promise<Record<string, unknown>[]> {
  const response = await fetch(restUrl(base, table, query), {
    headers: postgrestHeaders(key),
  });
  if (!response.ok) throw new Error(`${table} lookup failed (${response.status})`);
  const result: unknown = await response.json();
  return Array.isArray(result) ? result as Record<string, unknown>[] : [];
}

function isMuted(row: Record<string, unknown> | undefined): boolean {
  if (!row) return false;
  if (row.muted === true) return true;
  if (typeof row.muted_until === "string") {
    const until = Date.parse(row.muted_until);
    return Number.isFinite(until) && until > Date.now();
  }
  return false;
}

async function fromInboxRow(
  base: string,
  key: string,
  row: Record<string, unknown>,
): Promise<PushNotification | null> {
  const type = row.notification_type;
  if (type !== "message" && type !== "missed_call") return null;
  if (typeof row.user_id !== "string" || typeof row.title !== "string" ||
      typeof row.body !== "string") return null;
  const payload = row.payload && typeof row.payload === "object"
    ? row.payload as Record<string, unknown>
    : {};
  const conversationId = typeof row.conversation_id === "string"
    ? row.conversation_id
    : typeof payload.conversationId === "string" ? payload.conversationId : "";
  const data: Record<string, string> = {
    notificationType: type,
    recipientId: row.user_id,
    title: row.title,
    body: row.body,
  };
  for (const field of [
    "conversationId",
    "conversationType",
    "conversationName",
    "messageId",
    "actorId",
  ]) {
    const value = payload[field];
    if (typeof value !== "string") continue;
    data[field] = field === "conversationName"
      ? [...value].slice(0, 80).join("")
      : value;
  }
  if (typeof row.id === "string") data.notificationId = row.id;
  if (conversationId) data.conversationId = conversationId;
  if (typeof row.call_id === "string") data.callId = row.call_id;

  let title = row.title;
  let body = row.body;
  if (type === "message" && conversationId) {
    const recent = await getRows(base, key, "user_notifications", {
      select: "id,title,body",
      user_id: `eq.${row.user_id}`,
      conversation_id: `eq.${conversationId}`,
      notification_type: "eq.message",
      read_at: "is.null",
      order: "created_at.desc",
      limit: "3",
    });
    const newestFirst = recent.length ? recent : [row];
    const truncate = (value: unknown, max: number): string =>
      [...String(value ?? "")].slice(0, max).join("");
    const lines = newestFirst
      .map((item) => `${truncate(item.title, 48)}: ${truncate(item.body, 120)}`)
      .reverse();
    data.messages = JSON.stringify(lines);
    data.notificationIds = JSON.stringify(
      newestFirst.map((item) => item.id).filter((id): id is string => typeof id === "string"),
    );
    data.notificationCount = String(newestFirst.length);
    const displayName = payload.conversationName;
    if (typeof displayName === "string" && displayName.trim()) title = displayName;
  }
  return { userId: row.user_id, title, body, data };
}

async function fromIncomingCall(
  base: string,
  key: string,
  row: Record<string, unknown>,
): Promise<PushNotification | null> {
  if (row.status !== "ringing" || typeof row.callee_id !== "string" ||
      typeof row.caller_id !== "string" || typeof row.id !== "string" ||
      typeof row.conversation_id !== "string") return null;
  const userId = row.callee_id;
  const [globalPrefs, chatPrefs, membership, caller] = await Promise.all([
    getRows(base, key, "notification_preferences", {
      select: "calls_enabled,muted,muted_until",
      user_id: `eq.${userId}`,
      conversation_id: "is.null",
      limit: "1",
    }),
    getRows(base, key, "notification_preferences", {
      select: "calls_enabled,muted,muted_until",
      user_id: `eq.${userId}`,
      conversation_id: `eq.${row.conversation_id}`,
      limit: "1",
    }),
    getRows(base, key, "conversation_members", {
      select: "notifications_muted,muted_until",
      user_id: `eq.${userId}`,
      conversation_id: `eq.${row.conversation_id}`,
      limit: "1",
    }),
    getRows(base, key, "profiles", {
      select: "display_name",
      id: `eq.${row.caller_id}`,
      limit: "1",
    }),
  ]);
  const global = globalPrefs[0];
  const chat = chatPrefs[0];
  const member = membership[0];
  if (global?.calls_enabled === false || chat?.calls_enabled === false ||
      isMuted(global) || isMuted(chat) || member?.notifications_muted === true ||
      (typeof member?.muted_until === "string" &&
       Date.parse(member.muted_until) > Date.now())) return null;
  const callerName = typeof caller[0]?.display_name === "string" &&
      String(caller[0].display_name).trim()
    ? String(caller[0].display_name)
    : "MailChat user";
  const isVideo = row.kind === "video";
  return {
    userId,
    title: isVideo ? "Incoming video call" : "Incoming voice call",
    body: `${callerName} is calling you`,
    data: {
      notificationType: "incoming_call",
      recipientId: userId,
      callId: row.id,
      conversationId: row.conversation_id,
      callerId: row.caller_id,
      callerName,
      isVideo: String(isVideo),
      title: isVideo ? "Incoming video call" : "Incoming voice call",
      body: `${callerName} is calling you`,
    },
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const expected = Deno.env.get("FCM_WEBHOOK_SECRET");
  if (!expected || request.headers.get("x-mailchat-webhook-secret") !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }
  const base = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const projectId = Deno.env.get("FCM_PROJECT_ID");
  const accountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!base || !key || !projectId || !accountJson) {
    console.error("FCM sender configuration is incomplete");
    return new Response("FCM sender is not configured", { status: 503 });
  }

  try {
    const webhook = await request.json() as SupabaseWebhookEvent;
    if (webhook.type !== "INSERT" || !webhook.record) {
      return new Response("Ignored", { status: 202 });
    }
    let notification: PushNotification | null;
    if (webhook.table === "user_notifications") {
      notification = await fromInboxRow(base, key, webhook.record);
    } else if (webhook.table === "calls") {
      notification = await fromIncomingCall(base, key, webhook.record);
    } else {
      return new Response("Ignored table", { status: 202 });
    }
    if (!notification) return new Response("Ignored event", { status: 202 });

    const devices = await getRows(base, key, "user_devices", {
      select: "push_token",
      user_id: `eq.${notification.userId}`,
      platform: "eq.android",
      push_token: "not.is.null",
    });
    const tokens = [...new Set(
      devices.map((device) => device.push_token)
        .filter((token): token is string => typeof token === "string" && token.length > 0),
    )];
    if (tokens.length === 0) return Response.json({ sent: 0, reason: "no_android_tokens" });

    const account = JSON.parse(accountJson) as Record<string, string>;
    const accessToken = await googleAccessToken(account);
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`;
    let sent = 0;
    let removed = 0;
    for (const token of tokens) {
      const response = await fetch(fcmUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        // Data-only: the Android background handler displays one InboxStyle
        // notification per conversation and attaches Reply/Read/Mute actions.
        body: JSON.stringify({
          message: {
            token,
            data: notification.data,
            android: { priority: "HIGH" },
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
        const details = JSON.parse(errorText)?.error?.details;
        unregistered = Array.isArray(details) && details.some(
          (detail) => detail?.errorCode === "UNREGISTERED",
        );
      } catch (_) {
        // Retain tokens unless FCM explicitly says they are unregistered.
      }
      if (unregistered) {
        const deleted = await fetch(restUrl(base, "user_devices", {
          user_id: `eq.${notification.userId}`,
          push_token: `eq.${token}`,
        }), { method: "DELETE", headers: postgrestHeaders(key) });
        if (deleted.ok) removed++;
      } else {
        console.error("FCM send failed", response.status);
      }
    }
    return Response.json({ sent, removedInvalidTokens: removed });
  } catch (error) {
    console.error("FCM webhook processing failed", String(error));
    return new Response("Push delivery failed", { status: 500 });
  }
});
