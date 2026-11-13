// send-sms: Supabase Auth Send SMS Hook (standard-webhooks). Supabase сам генерирует код и считает
// лимиты, функция только доставляет его через castbrick. Номера из auth.sms.test_otp сюда не
// попадают (ТЗ раздел 8).
import { json } from "../_shared/http.ts";
import { hasRealSmsProvider, smsProvider } from "../_shared/providers.ts";

const sms = smsProvider();
const encoder = new TextEncoder();
const TIMESTAMP_TOLERANCE_SECONDS = 300;

interface HookPayload {
  user?: { phone?: string };
  sms?: { otp?: string };
}

// Ответ об ошибке в формате Auth Hooks: по нему Supabase показывает причину в логах Auth
function hookError(status: number, message: string): Response {
  return json({ error: { http_code: status, message } }, status);
}

function isSameSignature(left: string, right: string): boolean {
  if (left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

// secrets = "v1,whsec_<base64>", несколько через "|" на время ротации.
// Подпись: base64(HMAC-SHA256(secret, "<webhook-id>.<webhook-timestamp>.<body>"))
async function isSignatureValid(req: Request, body: string, secrets: string): Promise<boolean> {
  const id = req.headers.get("webhook-id") ?? "";
  const timestamp = req.headers.get("webhook-timestamp") ?? "";
  const signatures = (req.headers.get("webhook-signature") ?? "")
    .split(" ")
    .map((entry) => entry.split(","))
    .filter(([version, signature]) => version === "v1" && Boolean(signature))
    .map(([, signature]) => signature);

  if (!id || !timestamp || !signatures.length) {
    return false;
  }
  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(age) || age > TIMESTAMP_TOLERANCE_SECONDS) {
    return false;
  }

  for (const secret of secrets.split("|")) {
    const encoded = secret.replace(/^v1,/, "").replace(/^whsec_/, "");
    const keyBytes = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${id}.${timestamp}.${body}`));
    const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
    if (signatures.some((signature) => isSameSignature(signature, expected))) {
      return true;
    }
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return hookError(405, "method not allowed");
  }
  const body = await req.text();
  const secrets = Deno.env.get("SEND_SMS_HOOK_SECRET");

  // Функция публичная (verify_jwt = false). Без секрета её может вызвать кто угодно, поэтому без
  // подписи она работает только с адаптером log; с настоящим провайдером отказывает.
  if (!secrets && hasRealSmsProvider()) {
    console.error("send-sms: SEND_SMS_HOOK_SECRET is not set while a real SMS provider is configured");
    return hookError(500, "hook secret is not configured");
  }
  if (secrets && !(await isSignatureValid(req, body, secrets))) {
    return hookError(401, "invalid signature");
  }

  let payload: HookPayload;
  try {
    payload = JSON.parse(body);
  } catch {
    return hookError(400, "invalid json");
  }
  const phone = String(payload.user?.phone ?? "").replace(/[^\d]/g, "");
  const otp = String(payload.sms?.otp ?? "");
  if (!/^\d{9,15}$/.test(phone) || !/^\d{4,8}$/.test(otp)) {
    return hookError(400, "phone and otp required");
  }

  try {
    await sms.send(`+${phone}`, `Boleia: o seu código é ${otp}. Não o partilhe com ninguém.`);
    // Supabase проверяет content-type ответа: нужен JSON, иначе hook_payload_invalid_content_type
    return json({});
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("send-sms failed", message);
    return hookError(502, message);
  }
});
