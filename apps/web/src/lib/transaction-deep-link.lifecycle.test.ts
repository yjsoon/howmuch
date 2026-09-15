import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { act, createElement, useEffect, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Transaction } from "../api/types";
import {
  applyDeepLinkedTransactionMutation,
  deepLinkTargetsRow,
  type DeepLinkedTransactionMutation,
  type DeepLinkedTransactionResolution,
  type TransactionDeepLink,
} from "./transaction-deep-link";

const transaction: Transaction = {
  id: "txn-1",
  date: "2020-02-01",
  amount: -12000,
  memo: null,
  cleared: "cleared",
  approved: false,
  flag_color: null,
  flag_name: null,
  account_id: "account-1",
  account_name: "Checking",
  payee_id: null,
  payee_name: "Invoice",
  category_id: null,
  category_name: null,
  transfer_account_id: null,
  transfer_transaction_id: null,
  deleted: false,
  subtransactions: [{ id: "split-1", amount: -12000, payee_id: null, category_id: "category-1", memo: null, deleted: false }],
};

const initial: DeepLinkedTransactionResolution = {
  key: "plan-1:txn-1:",
  transaction,
  loading: false,
  error: null,
};

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  const window = new Window();
  Object.defineProperties(globalThis, {
    window: { value: window, configurable: true },
    document: { value: window.document, configurable: true },
    navigator: { value: window.navigator, configurable: true },
    IS_REACT_ACT_ENVIRONMENT: { value: true, configurable: true },
  });
  container = window.document.createElement("div") as unknown as HTMLDivElement;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root.unmount());
});

function MountedResolution(props: {
  filter: string;
  link: TransactionDeepLink;
  mutation: DeepLinkedTransactionMutation | null;
}) {
  const [resolution, setResolution] = useState(initial);
  useEffect(() => {
    if (props.mutation) {
      setResolution((current) => applyDeepLinkedTransactionMutation(current, "txn-1", props.mutation!));
    }
  }, [props.mutation]);
  const targeted = Boolean(resolution.transaction && deepLinkTargetsRow(props.link, resolution.transaction));
  return createElement("output", {
    "data-filter": props.filter,
    "data-targeted": targeted,
  }, resolution.transaction?.approved ? "approved" : resolution.transaction ? "unapproved" : "deleted");
}

describe("mounted deep-link mutation lifecycle", () => {
  test("approval remains settled after an unrelated filter rerender", () => {
    const link = { planId: "plan-1", transactionId: "txn-1", subtransactionId: null };
    act(() => { root.render(createElement(MountedResolution, { filter: "category-a", link, mutation: "approved" })); });
    expect(container.querySelector("output")?.textContent).toBe("approved");
    act(() => { root.render(createElement(MountedResolution, { filter: "category-b", link, mutation: null })); });
    expect(container.querySelector("output")?.textContent).toBe("approved");
  });

  test("deleting a parent with a targeted split remains settled after a filter rerender", () => {
    const link = { planId: "plan-1", transactionId: "txn-1", subtransactionId: "split-1" };
    act(() => { root.render(createElement(MountedResolution, { filter: "date-a", link, mutation: null })); });
    expect(container.querySelector("output")?.dataset.targeted).toBe("true");
    act(() => { root.render(createElement(MountedResolution, { filter: "date-a", link, mutation: "deleted" })); });
    act(() => { root.render(createElement(MountedResolution, { filter: "date-b", link, mutation: null })); });
    expect(container.querySelector("output")?.textContent).toBe("deleted");
    expect(container.querySelector("output")?.dataset.targeted).toBe("false");
  });
});
