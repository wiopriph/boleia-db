// notify: доставка push (FCM) и SMS (castbrick) из notifications. Вызывается триггером на insert
// ({id}) и раз в минуту sweep'ом (?sweep=1) для отложенных и повторов. Результат пишет RPC
// notification_delivered (ТЗ разделы 6, 9).
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { isServiceCall, rpc, type Service, serviceClient } from "../_shared/supabase.ts";
import { pushProvider, smsProvider } from "../_shared/providers.ts";
import { textFor } from "../_shared/texts.ts";

interface Row {
  id: string;
  user_id: string;
  type: string;
  channel: "push" | "sms" | "inapp";
  payload: Record<string, unknown>;
}

const sms = smsProvider();
const push = pushProvider();

async function deliver(sb: Service, n: Row): Promise<void> {
  const { title, body } = textFor(n.type, n.payload);
  if (n.channel === "sms") {
    const { data: prof } = await sb.from("profiles").select("phone").eq("id", n.user_id).single();
    if (!prof?.phone) throw new Error("no phone");
    await sms.send(prof.phone, `${title}: ${body}`);
    return;
  }
  const { data: devices } = await sb.from("devices").select("push_token").eq("user_id", n.user_id);
  if (!devices?.length) throw new Error("no devices");
  const data: Record<string, string> = { type: n.type };
  for (const k of ["booking_id", "trip_id", "conversation_id", "payment_id"]) {
    if (n.payload[k]) data[k] = String(n.payload[k]);
  }
  let sent = 0;
  const errors: string[] = [];
  for (const d of devices) {
    try {
      await push.send(d.push_token, title, body, data);
      sent++;
    } catch (e) {
      errors.push(e instanceof Error ? e.message : String(e));
    }
  }
  if (!sent) throw new Error(errors.join("; ") || "push failed");
}

Deno.serve(handler(async (req) => {
  if (!isServiceCall(req)) throw new HttpError(403, "NOT_ADMIN");
  const sb = serviceClient();
  const url = new URL(req.url);

  let q = sb
    .from("notifications")
    .select("id, user_id, type, channel, payload")
    .eq("status", "queued")
    .in("channel", ["push", "sms"])
    .or(`scheduled_for.is.null,scheduled_for.lte.${new Date().toISOString()}`)
    .order("created_at")
    .limit(100);
  if (!url.searchParams.get("sweep")) {
    const body = await readJson<{ id?: string }>(req);
    if (!body.id) throw new HttpError(400, "ID_REQUIRED");
    q = q.eq("id", body.id);
  }
  const { data: rows, error } = await q;
  if (error) throw new Error(error.message);

  let sent = 0, failed = 0;
  for (const n of (rows ?? []) as Row[]) {
    try {
      await deliver(sb, n);
      await rpc(sb, "notification_delivered", { id: n.id, ok: true, error: null });
      sent++;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await rpc(sb, "notification_delivered", { id: n.id, ok: false, error: msg });
      failed++;
    }
  }
  return json({ processed: rows?.length ?? 0, sent, failed });
}));
