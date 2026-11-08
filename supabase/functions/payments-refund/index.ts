// payments-refund: cron читает view pending_refunds, ходит в шлюз, результат пишет RPC
// payment_refund_result (3 попытки, дальше ручная очередь). Только service key.
import { handler, HttpError, json } from "../_shared/http.ts";
import { isServiceCall, rpc, serviceClient } from "../_shared/supabase.ts";
import { gateway } from "../_shared/gateway.ts";

interface RefundRow {
  payment_id: string;
  provider_ref: string | null;
  refund_kz: number;
}

Deno.serve(handler(async (req) => {
  if (!isServiceCall(req)) throw new HttpError(403, "NOT_ADMIN");
  const sb = serviceClient();
  const { data: rows, error } = await sb.from("pending_refunds").select("payment_id, provider_ref, refund_kz").limit(50);
  if (error) throw new Error(error.message);

  let ok = 0, failed = 0;
  for (const r of (rows ?? []) as RefundRow[]) {
    if (!r.provider_ref) {
      // оплаты без транзакции в шлюзе не бывает; фиксируем как неудачу, чтобы попало в ручную очередь
      await rpc(sb, "payment_refund_result", { payment_id: r.payment_id, ok: false, refund_ref: null, raw: { error: "no provider_ref" } });
      failed++;
      continue;
    }
    try {
      const res = await gateway.refund(r.provider_ref, r.refund_kz, r.payment_id);
      const success = res.status === "accepted" && !!res.refund_id;
      await rpc(sb, "payment_refund_result", {
        payment_id: r.payment_id,
        ok: success,
        refund_ref: success ? res.refund_id : null,
        raw: res,
      });
      success ? ok++ : failed++;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await rpc(sb, "payment_refund_result", { payment_id: r.payment_id, ok: false, refund_ref: null, raw: { error: msg } });
      failed++;
    }
  }
  return json({ processed: rows?.length ?? 0, ok, failed });
}));
