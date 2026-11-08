// payments-init: клиент после request_booking. Создаёт транзакцию в шлюзе на номер аккаунта
// и переводит платёж в pending через RPC payment_initiated (ТЗ разделы 6, 10).
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { FUNCTIONS_URL, requireUser, rpc, serviceClient } from "../_shared/supabase.ts";
import { gateway, isMock } from "../_shared/gateway.ts";

interface Body {
  booking_id?: string;
  simulate?: string; // только для мока: paid | failed | mismatch | silent
}

Deno.serve(handler(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");
  const user = await requireUser(req);
  const body = await readJson<Body>(req);
  if (!body.booking_id) throw new HttpError(400, "BOOKING_ID_REQUIRED");

  const sb = serviceClient();
  const { data: payment } = await sb
    .from("payments")
    .select("id, booking_id, payer_id, amount_kz, status, provider_ref, expires_at, raw_request")
    .eq("booking_id", body.booking_id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!payment) throw new HttpError(404, "PAYMENT_NOT_FOUND");
  if (payment.payer_id !== user.id) throw new HttpError(403, "NOT_PARTICIPANT");

  // повторный вызов по уже начатому платежу возвращает прежнюю инструкцию
  if (payment.status === "pending" && payment.provider_ref) {
    return json({
      payment_id: payment.id,
      booking_id: payment.booking_id,
      amount_kz: payment.amount_kz,
      expires_at: payment.expires_at,
      instructions: payment.raw_request?.response?.instructions ?? null,
      already: true,
    });
  }
  if (payment.status !== "created") throw new HttpError(409, "PAYMENT_STATUS_INVALID");

  const { data: profile } = await sb.from("profiles").select("phone").eq("id", user.id).single();
  if (!profile?.phone) throw new HttpError(409, "PROFILE_INCOMPLETE");

  const metadata: Record<string, unknown> = { booking_id: payment.booking_id };
  if (isMock && body.simulate) metadata.simulate = body.simulate;

  const request = {
    reference: payment.id,
    amount: payment.amount_kz,
    payerPhone: profile.phone,
    callbackUrl: `${FUNCTIONS_URL}/payments-webhook`,
    expiresInSeconds: 900,
    metadata,
  };
  const created = await gateway.create(request);

  const result = await rpc<{ payment_id: string; status: string; expires_at: string }>(sb, "payment_initiated", {
    payment_id: payment.id,
    provider_ref: created.transaction_id,
    raw: { request, response: created },
  });

  return json({
    payment_id: payment.id,
    booking_id: payment.booking_id,
    amount_kz: payment.amount_kz,
    expires_at: result.expires_at,
    instructions: created.instructions,
  });
}));
