// payments-status: кнопка "Verificar pagamento" (JWT, {payment_id}) и sweep из pg_cron (?sweep=1,
// service key) по pending-платежам с истёкшим expires_at: вебхук мог потеряться (ТЗ раздел 6).
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { isServiceCall, requireUser, rpc, type Service, serviceClient } from "../_shared/supabase.ts";
import { gateway } from "../_shared/gateway.ts";

interface PaymentRow {
  id: string;
  booking_id: string;
  payer_id: string;
  status: string;
  provider_ref: string | null;
}

// Спрашивает шлюз и при терминальном статусе зовёт confirm_payment. Возвращает статус шлюза.
async function syncOne(sb: Service, p: PaymentRow): Promise<string> {
  if (!p.provider_ref) return p.status;
  const s = await gateway.status(p.provider_ref);
  if (s.status === "pending") return "pending";
  await rpc(sb, "confirm_payment", {
    payment_id: p.id,
    provider_ref: p.provider_ref,
    new_status: s.status,
    payer_phone: s.payer_phone ?? null,
    raw: { source: "payments-status", ...s },
  });
  return s.status;
}

Deno.serve(handler(async (req) => {
  const sb = serviceClient();
  const url = new URL(req.url);

  if (url.searchParams.get("sweep")) {
    if (!isServiceCall(req)) throw new HttpError(403, "NOT_ADMIN");
    const { data: rows } = await sb
      .from("payments")
      .select("id, booking_id, payer_id, status, provider_ref")
      .eq("status", "pending")
      .lt("expires_at", new Date().toISOString())
      .order("expires_at")
      .limit(50);
    let updated = 0;
    const errors: string[] = [];
    for (const p of (rows ?? []) as PaymentRow[]) {
      try {
        if ((await syncOne(sb, p)) !== "pending") updated++;
      } catch (e) {
        errors.push(`${p.id}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    if (errors.length) console.error("sweep errors", errors);
    return json({ checked: rows?.length ?? 0, updated, errors: errors.length });
  }

  if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");
  const user = await requireUser(req);
  const body = await readJson<{ payment_id?: string }>(req);
  if (!body.payment_id) throw new HttpError(400, "PAYMENT_ID_REQUIRED");

  const { data: p } = await sb
    .from("payments")
    .select("id, booking_id, payer_id, status, provider_ref")
    .eq("id", body.payment_id)
    .maybeSingle();
  if (!p) throw new HttpError(404, "PAYMENT_NOT_FOUND");
  if (p.payer_id !== user.id) throw new HttpError(403, "NOT_PARTICIPANT");

  if (p.status === "pending") await syncOne(sb, p as PaymentRow);

  const { data: fresh } = await sb.from("payments").select("status").eq("id", p.id).single();
  const { data: booking } = await sb.from("bookings").select("status").eq("id", p.booking_id).single();
  return json({ payment_id: p.id, payment_status: fresh?.status, booking_status: booking?.status });
}));
