// Juno's AI relay. The OpenAI key lives here as a project secret, never in
// the app: a signed-in user's device sends an OpenAI-style chat request, this
// function checks the caller and their monthly cap, forwards it with the key,
// records the cost from the reported token usage, and returns the reply.
//
// Secrets: OPENAI_API_KEY (required). Optional: AI_MODEL (default
// gpt-5-mini), AI_MONTHLY_CAP_CENTS (default 200), AI_PRICE_IN_PER_M /
// AI_PRICE_OUT_PER_M (USD per million tokens for AI_MODEL).
import { createClient } from "jsr:@supabase/supabase-js@2";

const MODEL = Deno.env.get("AI_MODEL") ?? "gpt-5-mini";
const CAP_MICROS = Number(Deno.env.get("AI_MONTHLY_CAP_CENTS") ?? "200") * 10_000;
const PRICE_IN = Number(Deno.env.get("AI_PRICE_IN_PER_M") ?? "0.25");
const PRICE_OUT = Number(Deno.env.get("AI_PRICE_OUT_PER_M") ?? "2");
const MAX_BODY = 200_000;
const ROLES = new Set(["system", "user", "assistant", "tool"]);
const reasoning = /^(gpt-5|o\d)/.test(MODEL);

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function reply(status: number, body: unknown, extra: Record<string, string> = {}) {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...extra },
  });
}

// USD per million tokens × tokens = micro-dollars.
const cost = (input: number, cached: number, output: number) => {
  const c = Math.min(Math.max(cached, 0), input);
  return Math.ceil((input - c) * PRICE_IN + c * PRICE_IN * 0.1 + output * PRICE_OUT);
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: { code: "method" } });

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(jwt);
  const user = auth?.user;
  if (!user) return reply(401, { error: { code: "auth" } });

  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) return reply(503, { error: { code: "not_configured" } });

  const raw = await req.text();
  if (raw.length > MAX_BODY) return reply(413, { error: { code: "too_large" } });
  let body: { messages?: unknown; tools?: unknown; max_output?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return reply(400, { error: { code: "bad_json" } });
  }
  const messages = body.messages;
  if (
    !Array.isArray(messages) || messages.length === 0 || messages.length > 80 ||
    !messages.every((m) => m && typeof m === "object" && ROLES.has((m as { role?: string }).role ?? ""))
  ) {
    return reply(400, { error: { code: "bad_messages" } });
  }
  const tools = Array.isArray(body.tools) && body.tools.length > 0 ? body.tools.slice(0, 20) : undefined;
  const maxOutput = Math.min(Math.max(Number(body.max_output) || 600, 1), 1500);

  const month = new Date().toISOString().slice(0, 7);
  const { data: row } = await admin
    .from("ai_usage").select("spent_micros").eq("user_id", user.id).eq("month", month).maybeSingle();
  const spent = Number(row?.spent_micros ?? 0);
  const meter = (s: number) => ({ "x-juno-spent-micros": String(s), "x-juno-cap-micros": String(CAP_MICROS) });
  if (spent >= CAP_MICROS) return reply(429, { error: { code: "cap" } }, meter(spent));

  const upstream = {
    model: MODEL,
    messages,
    ...(tools ? { tools } : {}),
    ...(reasoning
      ? { max_completion_tokens: maxOutput + 1500, reasoning_effort: MODEL.startsWith("gpt-5-") ? "minimal" : "low" }
      : { max_tokens: maxOutput, temperature: 0.2 }),
  };

  let res: Response;
  try {
    res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(upstream),
      signal: AbortSignal.timeout(45_000),
    });
  } catch {
    // It may still have been billed: count the input.
    const s = await admin.rpc("ai_charge", { p_user: user.id, p_month: month, p_micros: cost(raw.length / 4, 0, 0) });
    return reply(504, { error: { code: "upstream_timeout" } }, meter(Number(s.data ?? spent)));
  }

  const text = await res.text();
  if (!res.ok) {
    // Pass the provider's reason through (it never contains the key).
    let reason = "upstream";
    try {
      reason = JSON.parse(text)?.error?.code ?? JSON.parse(text)?.error?.type ?? reason;
    } catch { /* not JSON */ }
    return reply(502, { error: { code: reason, status: res.status } }, meter(spent));
  }

  let charged = spent;
  try {
    const usage = JSON.parse(text)?.usage ?? {};
    const micros = cost(
      Number(usage.prompt_tokens ?? raw.length / 4),
      Number(usage.prompt_tokens_details?.cached_tokens ?? 0),
      Number(usage.completion_tokens ?? maxOutput),
    );
    const s = await admin.rpc("ai_charge", { p_user: user.id, p_month: month, p_micros: micros });
    charged = Number(s.data ?? spent + micros);
  } catch { /* the reply still goes back */ }
  return reply(200, text, meter(charged));
});
