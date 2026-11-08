// payments-mock: dev-реализация docs/gateway-contract.md. Состояния не хранит: статус читает из нашей
// таблицы payments, вебхук шлёт сам через 5 секунд. metadata.simulate: paid (по умолчанию) | failed |
// mismatch (чужой номер) | silent (вебхука нет, проверяет sweep payments-status) | silent_failed |
// qr (инструкция с qr_payload) | redirect (инструкция со ссылкой); оплата при этом как обычно через 5 с.
import { handler, json } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { gateway, GATEWAY_API_KEY, type GatewayStatus } from "../_shared/gateway.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const WEBHOOK_DELAY_MS = Number(Deno.env.get("MOCK_WEBHOOK_DELAY_MS") ?? 5000);
const MISMATCH_PHONE = "+244999999999";

interface CreateBody {
  reference: string;
  amount: number;
  payer_phone: string;
  callback_url: string;
  metadata?: { simulate?: string };
}

async function deliverWebhook(body: CreateBody, transactionId: string) {
  await new Promise((r) => setTimeout(r, WEBHOOK_DELAY_MS));
  const sim = body.metadata?.simulate ?? "paid";
  if (sim.startsWith("silent")) return;
  // qr и redirect меняют только инструкцию, оплата проходит
  const payload = JSON.stringify({
    event: "payment.updated",
    transaction_id: transactionId,
    reference: body.reference,
    status: sim === "failed" ? "failed" : "paid",
    payer_phone: sim === "mismatch" ? MISMATCH_PHONE : body.payer_phone,
    amount: body.amount,
    occurred_at: new Date().toISOString(),
  });
  const res = await fetch(body.callback_url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-gateway-signature": await gateway.sign(payload) },
    body: payload,
  });
  console.log(`[mock] webhook ${transactionId} -> ${res.status}`);
}

function mapStatus(dbStatus: string, simulate: string | undefined): GatewayStatus {
  if (["paid", "refunded", "partially_refunded"].includes(dbStatus)) return "paid";
  if (dbStatus === "failed") return "failed";
  if (dbStatus === "expired") return "expired";
  if (simulate === "silent") return "paid";
  if (simulate === "silent_failed") return "failed";
  return "pending";
}

Deno.serve(handler(async (req) => {
  const auth = req.headers.get("authorization") ?? "";
  if (auth !== `Bearer ${GATEWAY_API_KEY}`) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/payments-mock/, "") || "/";

  if (req.method === "POST" && path === "/payments") {
    const body = (await req.json()) as CreateBody;
    const transactionId = `gw_${body.reference}`;
    const job = deliverWebhook(body, transactionId).catch((e) => console.error("[mock] webhook failed", e));
    if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(job);
    const sim = body.metadata?.simulate ?? "paid";
    const instructions = sim === "qr"
      ? { type: "qr", qr_payload: `MCX|${transactionId}|${body.amount}|AOA` }
      : sim === "redirect"
      ? { type: "redirect", url: `${GATEWAY_BASE_URL}/checkout/${transactionId}` }
      : { type: "push", deep_link: `mcx://pay/${transactionId}` };
    return json({ transaction_id: transactionId, status: "pending", instructions }, 201);
  }

  const statusMatch = path.match(/^\/payments\/([^/]+)$/);
  if (req.method === "GET" && statusMatch) {
    const transactionId = decodeURIComponent(statusMatch[1]);
    const sb = serviceClient();
    const { data: p } = await sb
      .from("payments")
      .select("status, raw_request, payer_id, paid_at")
      .eq("provider_ref", transactionId)
      .maybeSingle();
    if (!p) return json({ error: "not found" }, 404);
    const simulate = p.raw_request?.request?.metadata?.simulate as string | undefined;
    const status = mapStatus(p.status, simulate);
    let payerPhone: string | undefined;
    if (status === "paid") {
      const { data: prof } = await sb.from("profiles").select("phone").eq("id", p.payer_id).single();
      payerPhone = simulate === "mismatch" ? MISMATCH_PHONE : prof?.phone ?? undefined;
    }
    return json({ transaction_id: transactionId, status, payer_phone: payerPhone, paid_at: p.paid_at ?? (status === "paid" ? new Date().toISOString() : undefined) });
  }

  if (req.method === "POST" && path === "/refunds") {
    const body = (await req.json()) as { transaction_id: string; amount: number; reference: string };
    if (!body.amount || body.amount <= 0) return json({ status: "failed", error: "bad amount" });
    if (body.transaction_id?.endsWith("_norefund")) return json({ status: "failed", error: "refund rejected" });
    return json({ refund_id: `rf_${body.reference}_${Date.now()}`, status: "accepted" });
  }

  return json({ error: "not found" }, 404);
}));
