// Адаптер шлюза Multicaixa Express по docs/gateway-contract.md. Под реальный GPO меняется только этот файл.
import { SUPABASE_URL } from "./supabase.ts";

export const GATEWAY_BASE_URL = (Deno.env.get("GATEWAY_BASE_URL") ?? `${SUPABASE_URL}/functions/v1/payments-mock`).replace(/\/$/, "");
export const GATEWAY_API_KEY = Deno.env.get("GATEWAY_API_KEY") ?? "dev-gateway-key";
const GATEWAY_SECRET = Deno.env.get("GATEWAY_SECRET") ?? "dev-gateway-secret";
export const isMock = GATEWAY_BASE_URL.includes("/payments-mock");

export type GatewayStatus = "pending" | "paid" | "failed" | "expired";

export interface CreateInput {
  reference: string;
  amount: number;
  payerPhone: string;
  callbackUrl: string;
  expiresInSeconds: number;
  metadata?: Record<string, unknown>;
}
export interface CreateResult {
  transaction_id: string;
  status: GatewayStatus;
  instructions: { type: "push" | "qr" | "redirect"; deep_link?: string; qr_payload?: string; url?: string };
}
export interface StatusResult {
  transaction_id: string;
  status: GatewayStatus;
  payer_phone?: string;
  paid_at?: string;
}
export interface RefundResult {
  refund_id?: string;
  status: "accepted" | "failed";
  error?: string;
}
export interface WebhookBody {
  event: string;
  transaction_id: string;
  reference: string;
  status: GatewayStatus;
  payer_phone?: string;
  amount?: number;
  occurred_at?: string;
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(GATEWAY_BASE_URL + path, {
    ...init,
    headers: { "content-type": "application/json", authorization: `Bearer ${GATEWAY_API_KEY}`, ...(init.headers ?? {}) },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`gateway ${res.status} ${path}: ${text.slice(0, 300)}`);
  return JSON.parse(text) as T;
}

const enc = new TextEncoder();
async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export const gateway = {
  create(input: CreateInput): Promise<CreateResult> {
    return call<CreateResult>("/payments", {
      method: "POST",
      body: JSON.stringify({
        reference: input.reference,
        amount: input.amount,
        currency: "AOA",
        payer_phone: input.payerPhone,
        callback_url: input.callbackUrl,
        expires_in_seconds: input.expiresInSeconds,
        metadata: input.metadata ?? {},
      }),
    });
  },
  status(transactionId: string): Promise<StatusResult> {
    return call<StatusResult>(`/payments/${encodeURIComponent(transactionId)}`);
  },
  refund(transactionId: string, amount: number, reference: string): Promise<RefundResult> {
    return call<RefundResult>("/refunds", {
      method: "POST",
      body: JSON.stringify({ transaction_id: transactionId, amount, reference }),
    });
  },
  // X-Gateway-Signature: sha256=<hex>
  async sign(body: string): Promise<string> {
    return "sha256=" + (await hmacHex(GATEWAY_SECRET, body));
  },
  async verify(body: string, header: string | null): Promise<boolean> {
    if (!header) return false;
    const expected = await gateway.sign(body);
    if (expected.length !== header.length) return false;
    let diff = 0;
    for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ header.charCodeAt(i);
    return diff === 0;
  },
};
