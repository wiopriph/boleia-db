// Доставка: castbrick (SMS) и FCM (push). Без ключей работает адаптер log: пишет в консоль, считает доставленным.

export interface SmsProvider {
  send(phone: string, text: string): Promise<void>;
}
export interface PushProvider {
  send(token: string, title: string, body: string, data: Record<string, string>): Promise<void>;
}

const logSms: SmsProvider = {
  send: (phone, text) => {
    console.log(`[sms:log] to=${phone} text=${JSON.stringify(text)}`);
    return Promise.resolve();
  },
};
const logPush: PushProvider = {
  send: (token, title, body, data) => {
    console.log(`[push:log] token=${token.slice(0, 12)}… title=${JSON.stringify(title)} body=${JSON.stringify(body)} data=${JSON.stringify(data)}`);
    return Promise.resolve();
  },
};

// castbrick: HTTP API провайдера; формат тела уточняется по их документации, меняется только здесь
function castbrick(apiKey: string): SmsProvider {
  const url = Deno.env.get("CASTBRICK_URL") ?? "https://api.castbrick.com/v1/sms";
  const sender = Deno.env.get("CASTBRICK_SENDER") ?? "Boleia";
  return {
    async send(phone, text) {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ to: phone, from: sender, message: text }),
      });
      if (!res.ok) throw new Error(`castbrick ${res.status}: ${(await res.text()).slice(0, 200)}`);
    },
  };
}

// FCM HTTP v1 с сервисным аккаунтом: JWT RS256 -> access token -> messages:send
interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

function b64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

let cachedToken: { value: string; exp: number } | null = null;

async function fcmAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp > now + 60) return cachedToken.value;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const key = await importPrivateKey(sa.private_key);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const assertion = `${header}.${claims}.${b64url(sig)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const tok = (await res.json()) as { access_token: string; expires_in: number };
  cachedToken = { value: tok.access_token, exp: now + tok.expires_in };
  return tok.access_token;
}

function fcm(sa: ServiceAccount): PushProvider {
  return {
    async send(token, title, body, data) {
      const access = await fcmAccessToken(sa);
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${access}` },
        body: JSON.stringify({ message: { token, notification: { title, body }, data } }),
      });
      if (!res.ok) throw new Error(`fcm ${res.status}: ${(await res.text()).slice(0, 200)}`);
    },
  };
}

export function smsProvider(): SmsProvider {
  const key = Deno.env.get("CASTBRICK_API_KEY");
  return key ? castbrick(key) : logSms;
}

export function pushProvider(): PushProvider {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) return logPush;
  return fcm(JSON.parse(raw) as ServiceAccount);
}
