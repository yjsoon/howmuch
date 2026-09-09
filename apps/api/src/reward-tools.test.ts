import { expect, test } from "bun:test";
import { fetchTerms, handleRewardTool, readLimited } from "./reward-tools";

test("terms allow only exact HTTPS bank hosts; redirects never followed", async () => {
  let calls = 0;
  const transport = (async (_url: unknown, init: RequestInit) => { calls++; expect(init.redirect).toBe("error"); return new Response("redirect", { status: 302 }); }) as typeof fetch;
  for (const url of ["http://www.dbs.com.sg/x", "https://127.0.0.1/x", "https://www.dbs.com.sg.evil.test", "https://user@www.dbs.com.sg", "https://www.dbs.com.sg:444/x"]) {
    await expect(fetchTerms(url, transport)).rejects.toThrow();
  }
  expect(calls).toBe(0);
  await expect(fetchTerms("https://www.dbs.com.sg/terms", transport)).rejects.toThrow();
  expect(calls).toBe(1);
});

test("stream limit applies without content-length", async () => {
  await expect(readLimited(new Response("abcdef"), 5)).rejects.toThrow();
});

test("fixed endpoint, exact model, no incoming credentials; provider failures sanitized", async () => {
  const body = { provider: "openai", apiKey: "secret-provider", model: "my-exact-model", terms: "Dining 4%", cardType: "cashback", consent: true };
  const request = () => new Request("https://howmuch.test/api/tools/reward-terms", { method: "POST", headers: { authorization: "Bearer ledger-secret", cookie: "login-secret" }, body: JSON.stringify(body) });
  const result = await handleRewardTool(request(), "reward-terms", (async (url: unknown, init: RequestInit) => {
    expect(url).toBe("https://api.openai.com/v1/chat/completions");
    expect(init.redirect).toBe("error");
    expect(JSON.stringify(init)).not.toContain("ledger-secret");
    expect(JSON.stringify(init)).not.toContain("login-secret");
    expect(JSON.parse(init.body as string).model).toBe("my-exact-model");
    throw new Error("secret-provider + private body");
  }) as typeof fetch);
  expect(result.status).toBe(502);
  expect(await result.text()).not.toContain("secret-provider");
});

test("statement requires consent and valid image before any provider call", async () => {
  let calls = 0;
  const transport = (async () => { calls++; throw new Error(); }) as typeof fetch;
  for (const body of [{ consent: false }, { consent: true, image: "https://internal/image" }, { consent: true, image: "data:image/png;base64,YWJj" }]) {
    const response = await handleRewardTool(new Request("https://howmuch.test", { method: "POST", body: JSON.stringify({ provider: "gemini", apiKey: "key", model: "gemini-model", ...body }) }), "statement-formatter", transport);
    expect(response.status).toBe(400);
  }
  expect(calls).toBe(0);
});

test("successful provider transports return validated terms without changing exact model", async () => {
  const raw = JSON.stringify({ buckets: [{ name: "Dining", rewardValue: 4 }] });
  for (const [provider, model, endpoint, payload] of [
    ["openai", "exact-model", "https://api.openai.com/v1/chat/completions", { choices: [{ message: { content: raw } }] }],
    ["openrouter", "vendor/exact-model", "https://openrouter.ai/api/v1/chat/completions", { choices: [{ message: { content: raw } }] }],
    ["opencode", "deepseek-v4-flash", "https://opencode.ai/zen/v1/chat/completions", { choices: [{ message: { content: raw } }] }],
    ["opencode", "go/gpt-5.6-luna", "https://opencode.ai/zen/go/v1/responses", { output: [{ content: [{ text: raw }] }] }],
    ["opencode", "go/minimax-m3", "https://opencode.ai/zen/go/v1/messages", { content: [{ text: raw }] }],
  ] as const) {
    const calls: Array<{ url: unknown; init: RequestInit }> = [];
    const response = await handleRewardTool(new Request("https://howmuch.test", { method: "POST", body: JSON.stringify({ provider, model, apiKey: "provider-key", terms: "Dining", cardType: "cashback", consent: true, ledger: "NEVER SEND" }) }), "reward-terms", (async (url: unknown, init: RequestInit) => { calls.push({ url, init }); return Response.json(payload); }) as typeof fetch);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ data: { raw } });
    expect(calls.length).toBe(1);
    expect(calls[0].url).toBe(endpoint);
    const sent = JSON.parse(calls[0].init.body as string);
    expect(sent.model).toBe(model.replace(/^go\//, ""));
    expect(JSON.stringify(sent)).not.toContain("NEVER SEND");
    if (provider === "openrouter") expect(sent.provider.allow_fallbacks).toBe(false);
  }
});

test("Gemini uses header key, validated inline image, exact model, validated rows", async () => {
  const rows = [{ date: "2026-09-02", payee: "Cafe", memo: "USD 10.00", outflow: "13.42", inflow: "" }];
  const calls: Array<{ url: unknown; init: RequestInit }> = [];
  const response = await handleRewardTool(new Request("https://howmuch.test", { method: "POST", body: JSON.stringify({ provider: "gemini", model: "gemini-exact", apiKey: "gemini-secret", image: `data:image/png;base64,${btoa("\x89PNG\r\n\x1a\nfixture")}`, consent: true }) }), "statement-formatter", (async (url: unknown, init: RequestInit) => { calls.push({ url, init }); return Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(rows) }] } }] }); }) as typeof fetch);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ data: { rows } });
  expect(calls[0].url).toBe("https://generativelanguage.googleapis.com/v1beta/models/gemini-exact:generateContent");
  expect(new Headers(calls[0].init.headers).get("x-goog-api-key")).toBe("gemini-secret");
  expect(JSON.parse(calls[0].init.body as string).contents[0].parts[1].inlineData.mimeType).toBe("image/png");
});

test("consent, request and provider response limits apply before use", async () => {
  let calls = 0;
  const transport = (async () => { calls++; return new Response("x".repeat(1024 * 1024 + 1)); }) as typeof fetch;
  const base = { provider: "openai", model: "exact-model", apiKey: "key", terms: "Dining", cardType: "cashback" };
  for (const extra of [{ consent: false }, { consent: true, terms: "x".repeat(100001) }]) {
    const response = await handleRewardTool(new Request("https://howmuch.test", { method: "POST", body: JSON.stringify({ ...base, ...extra }) }), "reward-terms", transport);
    expect(response.status).toBe(400);
  }
  expect(calls).toBe(0);
  const response = await handleRewardTool(new Request("https://howmuch.test", { method: "POST", body: JSON.stringify({ ...base, consent: true }) }), "reward-terms", transport);
  expect(response.status).toBe(502);
  expect(calls).toBe(1);
});
