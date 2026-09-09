import { expect, test } from "bun:test";
import { mergeStatementImages } from "./reward-tools";

test("image dedup uses content digest rather than filename and preserves order", () => {
  const first = { id: "digest-a", name: "same.png", data: "a" };
  const second = { id: "digest-b", name: "same.png", data: "b" };
  expect(mergeStatementImages([first], [second, { ...first, name: "renamed.png" }]).map((i) => i.id)).toEqual(["digest-a", "digest-b"]);
});
