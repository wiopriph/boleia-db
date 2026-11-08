import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";
import { HttpError } from "./http.ts";

export const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "http://kong:8000";
export const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
export const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
// Публичный адрес функций для вебхуков шлюза; локально kong виден моку под тем же именем
export const FUNCTIONS_URL = (Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? `${SUPABASE_URL}/functions/v1`).replace(/\/$/, "");

export type Service = SupabaseClient;

export function serviceClient(): Service {
  return createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
}

function bearer(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  return h.toLowerCase().startsWith("bearer ") ? h.slice(7).trim() : null;
}

// Вызов от cron (edge_call) или другой нашей функции: service role key
export function isServiceCall(req: Request): boolean {
  const t = bearer(req);
  return !!t && !!SERVICE_KEY && t === SERVICE_KEY;
}

export function requireService(req: Request): void {
  if (!isServiceCall(req)) throw new HttpError(403, "NOT_ADMIN");
}

// Пользовательский JWT -> auth user id. Бизнес-проверки делают RPC, здесь только личность.
export async function requireUser(req: Request): Promise<{ id: string }> {
  const token = bearer(req);
  if (!token) throw new HttpError(401, "NOT_AUTHENTICATED");
  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await anon.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, "NOT_AUTHENTICATED");
  return { id: data.user.id };
}

// RPC с ошибкой -> исключение с текстом BOLEIA_<CODE>, которое errorResponse превращает в {code}
export async function rpc<T = unknown>(sb: Service, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
