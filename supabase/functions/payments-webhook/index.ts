// payments-webhook: endpoint для шлюза. Проверяет подпись, зовёт confirm_payment service-ролью,
// отвечает 200 всегда: идемпотентность и бизнес-правила в SQL (ТЗ раздел 6).
import { handler, json } from "../_shared/http.ts";
import { rpc, serviceClient } from "../_shared/supabase.ts";
import { gateway, type WebhookBody } from "../_shared/gateway.ts";

Deno.serve(handler(async (req) => {
  if (req.method !== "POST") return json({ ok: false, code: "METHOD_NOT_ALLOWED" }, 405);
  const raw = await req.text();
  if (!(await gateway.verify(raw, req.headers.get("x-gateway-signature")))) {
    return json({ ok: false, code: "BAD_SIGNATURE" }, 401);
  }

  let body: WebhookBody;
  try {
    body = JSON.parse(raw) as WebhookBody;
  } catch {
    return json({ ok: false, code: "BAD_JSON" }, 400);
  }
  if (body.status === "pending") return json({ ok: true, ignored: "pending" });

  try {
    await rpc(serviceClient(), "confirm_payment", {
      payment_id: body.reference,
      provider_ref: body.transaction_id,
      new_status: body.status,
      payer_phone: body.payer_phone ?? null,
      raw: body,
    });
    return json({ ok: true });
  } catch (e) {
    // шлюз получает 200 и не ретраит: ошибка наша, разбираем по логам
    const msg = e instanceof Error ? e.message : String(e);
    console.error("confirm_payment failed", body.reference, msg);
    return json({ ok: false, code: msg.match(/BOLEIA_([A-Z_]+)/)?.[1] ?? "INTERNAL" });
  }
}));
