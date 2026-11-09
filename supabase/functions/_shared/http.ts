export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

export function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, "BAD_JSON");
  }
}

// Коды BOLEIA_* из RPC (ТЗ раздел 7) -> HTTP-статусы; текст клиенты берут из своих локалей
function statusFor(code: string): number {
  if (code === "NOT_AUTHENTICATED") return 401;
  if (code === "NOT_PARTICIPANT" || code === "NOT_ADMIN" || code === "PROFILE_RESTRICTED") return 403;
  if (code.endsWith("_NOT_FOUND")) return 404;
  if (code === "RATE_LIMITED") return 429;
  if (code.endsWith("_INVALID") || code.endsWith("_EMPTY") || code.endsWith("_TOO_LONG")) return 400;
  return 409;
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) return json({ code: e.code, message: e.message }, e.status);
  const msg = e instanceof Error ? e.message : String(e);
  const m = msg.match(/BOLEIA_([A-Z_]+)/);
  if (m) return json({ code: m[1] }, statusFor(m[1]));
  console.error("unhandled", msg);
  return json({ code: "INTERNAL", message: msg }, 500);
}

export function handler(fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          // supabase-js in the browser also sends x-client-info and x-supabase-api-version
          "access-control-allow-headers": "authorization, apikey, content-type, x-client-info, x-supabase-api-version",
          "access-control-allow-methods": "GET, POST, OPTIONS",
        },
      });
    }
    try {
      const res = await fn(req);
      res.headers.set("access-control-allow-origin", "*");
      return res;
    } catch (e) {
      const res = errorResponse(e);
      res.headers.set("access-control-allow-origin", "*");
      return res;
    }
  };
}
