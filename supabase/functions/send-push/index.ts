// ============================================================================
// send-push -- deliver a chat notification to a user via FCM.
//
// This is the third and final link in the push chain. Without it nothing can
// wake a killed app, because Supabase Realtime only works while the Dart
// isolate is alive.
//
// Requires:
//   1. supabase/fcm.sql                 (fcm_token column)
//   2. the app writing its token there  (firebase_messaging_service.dart)
//   3. THIS function, deployed
//
// Deploy with the Supabase CLI:
//   supabase functions deploy send-push --no-verify-jwt
//
// It reads the FCM credentials from the environment rather than hard-coding
// them. Set them with:
//   supabase secrets set FCM_PROJECT_ID=chat-app-3b3e9 FCM_CLIENT_EMAIL=... FCM_PRIVATE_KEY=...
//
// Alternatively, if you prefer the legacy HTTP API, set just
//   FCM_SERVER_KEY=<your legacy server key>
// and the function will use that path instead.
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PROJECT_ID = Deno.env.get("FCM_PROJECT_ID") ?? "";
const CLIENT_EMAIL = Deno.env.get("FCM_CLIENT_EMAIL") ?? "";
const LEGACY_SERVER_KEY = Deno.env.get("FCM_SERVER_KEY") ?? "";

/** Decodes a PEM private key that may have been stored with escaped \n. */
function pem(key: string): string {
  return key.replace(/\\n/g, "\n");
}

type Claims = {
  access_token: string;
  expires_in: number;
};

let cachedToken: { value: string; expiresAt: number } | null = null;

/**
 * Fetches a Google OAuth2 access token for the FCM scope, caching it until it
 * is close to expiry so we do not hit the token endpoint on every message.
 */
async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.value;
  }

  const privateKey = Deno.env.get("FCM_PRIVATE_KEY") ?? "";
  if (!privateKey || !CLIENT_EMAIL) {
    throw new Error("FCM_PRIVATE_KEY and FCM_CLIENT_EMAIL must be set");
  }

  // Build the JWT that Google expects for a service-account assertion.
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const now = Math.floor(Date.now() / 1000);
  const claim = btoa(
    JSON.stringify({
      iss: CLIENT_EMAIL,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  ).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem(privateKey)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claim}`),
  );
  const assertion = `${header}.${claim}.${
    btoa(String.fromCharCode(...new Uint8Array(sig)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  }`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    throw new Error(`token endpoint returned ${res.status}: ${await res.text()}`);
  }

  const claims: Claims = await res.json();
  cachedToken = {
    value: claims.access_token,
    expiresAt: Date.now() + claims.expires_in * 1000,
  };
  return cachedToken.value;
}

/** Strips the PEM armour so the key can be imported as PKCS#8. */
function pemToDer(pemText: string): Uint8Array {
  const body = pemText
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Sends one message to one device token. */
async function sendToToken(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<{ ok: boolean; detail?: string }> {
  const message = { token, notification: { title, body }, data };

  // Legacy HTTP API path -- simpler, needs only a server key.
  if (LEGACY_SERVER_KEY) {
    const res = await fetch(
      `https://fcm.googleapis.com/fcm/send`,
      {
        method: "POST",
        headers: {
          "Authorization": `key=${LEGACY_SERVER_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(message),
      },
    );
    return { ok: res.ok, detail: res.ok ? undefined : await res.text() };
  }

  // HTTP v1 path -- preferred, and what a new project is set up for.
  const accessToken = await getAccessToken();
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ message }),
    },
  );
  return { ok: res.ok, detail: res.ok ? undefined : await res.text() };
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("POST only", { status: 405 });
  }

  let payload: { user_id?: string; title?: string; body?: string; data?: Record<string, string> };
  try {
    payload = await req.json();
  } catch {
    return new Response("invalid JSON", { status: 400 });
  }

  const { user_id, title, body, data } = payload;
  if (!user_id || !title || !body) {
    return new Response(
      JSON.stringify({ error: "user_id, title and body are required" }),
      { status: 400 },
    );
  }

  // Service-role client: bypasses RLS so it can read the token regardless of
  // which user is asking.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  const { data, error } = await supabase
    .from("profiles")
    .select("fcm_token")
    .eq("id", user_id)
    .maybeSingle();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  const token = data?.fcm_token as string | null;
  if (!token) {
    return new Response(
      JSON.stringify({
        sent: false,
        reason: "user has no stored fcm_token (app has not registered yet)",
      }),
      { status: 200 },
    );
  }

  try {
    const result = await sendToToken(token, title, body, data ?? {});
    return new Response(
      JSON.stringify({ sent: result.ok, detail: result.detail }),
      { status: result.ok ? 200 : 502 },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ sent: false, error: String(e) }),
      { status: 500 },
    );
  }
});