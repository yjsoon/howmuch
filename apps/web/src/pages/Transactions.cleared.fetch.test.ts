import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { Window } from "happy-dom";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { MemoryRouter, useNavigate, type NavigateFunction } from "react-router-dom";
import type { Transaction } from "../api/types";

// Keep the page, API client, request encoding, and row controls real. Only the
// surrounding shell/reference cache is outside this interaction's contract.
mock.module("../state/plan", () => ({
  usePlan: () => ({
    accounts: [{ id: "a", name: "Cash", closed: false, deleted: false,
      balance: -12000, cleared_balance: 0, uncleared_balance: -12000 }],
    categoryGroups: [], planId: "p", planSelectionError: null, userId: "u",
    ledgerKnowledge: 1, knowledgeTrusted: true, cacheEpoch: 0, reload: () => {},
  }),
}));
mock.module("../state/use-cached-api", () => ({
  useCachedApi: () => ({ data: [], loading: false, error: null }),
}));
const { TransactionsPage } = await import("./Transactions");

type Cleared = "cleared" | "uncleared";
let row: Transaction;
let uncertain: boolean;
let holdNextItemRead: boolean;
let releaseItemRead: (() => void) | undefined;
let navigate: NavigateFunction;
let window: Window;
let container: HTMLDivElement;
let root: Root;
const originalFetch = globalThis.fetch;
const globals = ["window", "document", "navigator", "HTMLElement", "HTMLInputElement", "HTMLSelectElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const originalGlobals = new Map(globals.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const requests: Array<{ path: string; method: string; body: any }> = [];
const json = (data: unknown) => new Response(JSON.stringify({ data }), {
  headers: { "content-type": "application/json" },
});

function Harness() {
  navigate = useNavigate();
  return createElement(TransactionsPage);
}

beforeEach(() => {
  window = new Window({ url: "http://localhost/transactions" });
  for (const key of globals) {
    Object.defineProperty(globalThis, key, { configurable: true, value:
      key === "window" ? window : key === "IS_REACT_ACT_ENVIRONMENT" ? true : window[key] });
  }
  window.HTMLElement.prototype.scrollIntoView = () => {};
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  row = {
    id: "t", date: "2024-01-02", amount: -12000, memo: null,
    cleared: "uncleared", approved: true, flag_color: null, flag_name: null,
    account_id: "a", account_name: "Cash", payee_id: null, payee_name: "Invoice",
    category_id: null, category_name: null, transfer_account_id: null,
    transfer_transaction_id: null, deleted: false, subtransactions: [],
  };
  uncertain = false;
  holdNextItemRead = false;
  releaseItemRead = undefined;
  requests.length = 0;
  globalThis.fetch = async (input, init) => {
    const path = String(input);
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    requests.push({ path, method, body });
    if (path.includes("unapproved_count")) return json({ count: 0, server_knowledge: 1 });
    if (path.endsWith("/t/cleared")) {
      expect(body.expected_cleared).toBe(row.cleared);
      row = { ...row, cleared: body.cleared };
      return json({ transaction: row });
    }
    if (path.endsWith("/transactions/cleared")) {
      expect(body.transactions[0].expected_cleared).toBe(row.cleared);
      row = { ...row, cleared: body.transactions[0].cleared };
      // An unresolved response can follow a committed write. Only the GET may
      // establish the resulting state; the UI must not claim confirmed success.
      return json({ outcomes: [{ id: "t", status: uncertain ? "unresolved" : "applied" }],
        applied_count: uncertain ? 0 : 1, conflict_count: 0, unresolved_count: uncertain ? 1 : 0,
        already_removed_count: 0, unattempted_count: 0, server_knowledge: 3 });
    }
    if (path.endsWith("/transactions/t")) {
      const response = json({ transaction: row });
      if (holdNextItemRead) {
        holdNextItemRead = false;
        return new Promise<Response>((resolve) => { releaseItemRead = () => resolve(response); });
      }
      return response;
    }
    if (path.includes("/transactions?")) {
      return json({ transactions: [row], has_more: false, next_offset: null, server_knowledge: 3 });
    }
    if (path.startsWith("/api/import/rewards-tracker?")) return json({ cards: [] });
    throw new Error(`Unexpected fixture request: ${method} ${path}`);
  };
});

afterEach(async () => {
  await act(async () => { releaseItemRead?.(); root.unmount(); });
  await window.happyDOM.abort();
  globalThis.fetch = originalFetch;
  for (const key of globals) {
    const original = originalGlobals.get(key);
    if (original) Object.defineProperty(globalThis, key, original);
    else Reflect.deleteProperty(globalThis, key);
  }
});

async function interact(action: () => void) {
  await act(async () => { action(); await new Promise((resolve) => setTimeout(resolve, 0)); });
}

function status() {
  const button = container.querySelector<HTMLButtonElement>(".register-status button");
  expect(button).not.toBeNull();
  return button!;
}

function expectStatus(cleared: Cleared) {
  expect(status().getAttribute("title")).toBe(cleared === "cleared"
    ? "Cleared — click to mark uncleared" : "Uncleared — click to mark cleared");
}

for (const initial of ["uncleared", "cleared"] as const) {
  for (const unresolved of [false, true]) {
    test(`single toggle then bulk ${initial}, ${unresolved ? "unresolved" : "confirmed"} response`, async () => {
      row = { ...row, cleared: initial };
      uncertain = unresolved;
      await interact(() => root.render(createElement(MemoryRouter, {
        initialEntries: ["/transactions?range=all&accounts=all"],
      }, createElement(Harness))));
      expectStatus(initial);
      await interact(() => status().click());
      const intermediate = initial === "cleared" ? "uncleared" : "cleared";
      expectStatus(intermediate);

      // Capture a GET at the intermediate state and delay its delivery until
      // after the bulk write and its fresh reads. It must not undo the result.
      holdNextItemRead = true;
      await interact(() => navigate("/transactions?range=all&accounts=all&plan=p&transaction=t"));
      expect(releaseItemRead).toBeDefined();
      await interact(() => container.querySelector<HTMLInputElement>("tbody input[type=checkbox]")!.click());
      await interact(() => {
        const button = [...container.querySelectorAll("button")].find((item) => item.textContent === `Mark ${initial}`)!;
        expect(button.disabled).toBe(false);
        button.click();
      });
      const bulkIndex = requests.findIndex((request) => request.path.endsWith("/transactions/cleared"));
      expect(bulkIndex).toBeGreaterThanOrEqual(0);
      expect(requests[bulkIndex]!.body).toEqual({ transactions: [{ id: "t", expected_cleared: intermediate, cleared: initial }] });
      expect(requests.slice(bulkIndex + 1).some((request) => request.method === "GET" && request.path.includes("/transactions?"))).toBe(true);
      expect(row.cleared).toBe(initial);
      expectStatus(initial);
      if (unresolved) {
        expect(container.textContent).toContain("1 transaction may or may not have been updated.");
        expect(container.textContent).not.toContain(`Marked ${initial} 1 transaction.`);
      } else {
        expect(container.textContent).toContain(`Marked ${initial} 1 transaction.`);
        expect(container.textContent).not.toContain("may or may not");
      }
      await interact(() => releaseItemRead!());
      expectStatus(initial);
      await interact(() => status().click());
      expect(requests.at(-1)?.body).toEqual({ expected_cleared: initial, cleared: intermediate });
      expect(row.cleared).toBe(intermediate);
      expectStatus(intermediate);
    });
  }
}
