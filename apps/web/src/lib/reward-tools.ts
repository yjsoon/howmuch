import type { TermsPatch } from "../../../api/src/reward-tools-contract";
import { notifyLocalWrite } from "../api/client";

/**
 * These calls bypass `request` in `api/client.ts` because they need their own
 * abort signal and timeout, so they must invalidate the client cache
 * themselves. Every call here is a POST or PATCH; `patchRewardCard` really
 * does write the ledger, and the two `/api/tools/` analysers do not, so this
 * invalidates a little more often than it strictly must. That is the safe
 * direction, and it keeps the rule here to one line instead of a list of
 * exceptions to maintain. Like `request`, it invalidates however the call
 * ends: a write that times out may still have been applied.
 */
export async function toolRequest<T>(path: string, body: unknown, signal?: AbortSignal, method = "POST"): Promise<T> {
  const timeout = new AbortController();
  const timer = setTimeout(() => timeout.abort(), 75_000);
  try {
    const combined = AbortSignal.any([timeout.signal, ...(signal ? [signal] : [])]);
    const response = await fetch(path, { method, credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: combined });
    const result = await response.json();
    combined.throwIfAborted();
    if (!response.ok) throw new Error(result.error?.detail ?? "Request failed. Try again.");
    return result.data as T;
  } catch (error) {
    if (timeout.signal.aborted) throw new Error("Request timed out. No further data will be sent.");
    throw error;
  } finally { clearTimeout(timer); notifyLocalWrite(); }
}
export function patchRewardCard(planId: string, cardId: string, card: TermsPatch) {
  return toolRequest(`/api/rewards/cards/${encodeURIComponent(cardId)}`, { plan_id: planId, card }, undefined, "PATCH");
}

export type StatementImage = { id: string; name: string; data: string };
export async function readStatementImage(file: File): Promise<StatementImage> {
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type) || file.size > 5 * 1024 * 1024) throw new Error("Choose PNG, JPEG or WebP images up to 5 MiB each.");
  const bytes = await file.arrayBuffer();
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  const id = Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const data = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader(); reader.onerror = () => reject(new Error("Could not read image."));
    reader.onload = () => resolve(String(reader.result)); reader.readAsDataURL(file);
  });
  return { id, name: file.name, data };
}
export function mergeStatementImages(previous: StatementImage[], next: StatementImage[]): StatementImage[] {
  return [...new Map([...previous, ...next].map((image) => [image.id, image])).values()].slice(0, 20);
}
