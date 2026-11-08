// send-sms: Supabase Auth Send SMS Hook (standard-webhooks). Получает телефон и OTP, отправляет
// через castbrick. В dev для номеров из auth.sms.test_otp не вызывается (ТЗ раздел 8).
import { json } from "../_shared/http.ts";
import { smsProvider } from "../_shared/providers.ts";

const sms = smsProvider();
const enc = new TextEncoder();

// secrets = "v1,whsec_<base64>"; подпись: base64(HMAC-SHA256(secret, "<id>.<timestamp>.<body>"))
async function verify(req: Request, body: string): Promise<boolean> {
  const secrets = Deno.env.get("SEND_SMS_HOOK_SECRET");
  if (!secrets) return true; // dev без секрета
  const id = req.headers.get("webhook-id") ?? "";
  const ts = req.headers.get("webhook-timestamp") ?? "";
  const sigs = (req.headers.get("webhook-signature") ?? "").split(" ").map((s) => s.split(",")[1]).filter(Boolean);
  if (!id || !ts || !sigs.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;

  for (const raw of secrets.split("|")) {
    const b64 = raw.replace(/^v1,/, "").replace(/^whsec_/, "");
    const keyBytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${id}.${ts}.${body}`));
    const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
    if (sigs.includes(expected)) return true;
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const body = await req.text();
  if (!(await verify(req, body))) return json({ error: "bad signature" }, 401);

  let payload: { user?: { phone?: string }; sms?: { otp?: string } };
  try {
    payload = JSON.parse(body);
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const phone = payload.user?.phone;
  const otp = payload.sms?.otp;
  if (!phone || !otp) return json({ error: "phone and otp required" }, 400);

  try {
    await sms.send(phone.startsWith("+") ? phone : `+${phone}`, `Boleia: o seu código é ${otp}. Válido 10 minutos.`);
    return json({});
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("send-sms failed", msg);
    return json({ error: { http_code: 500, message: msg } }, 500);
  }
});
