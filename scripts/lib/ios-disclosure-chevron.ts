/** Find Form `NavigationLink` rows that still draw DisclosureValueRow's own chevron. */

export type SwiftSource = {
  path: string;
  source: string;
};

export type DisclosureChevronFault = {
  path: string;
  line: number;
  detail: string;
};

const VIEW_STRUCT = /(?:private\s+)?struct\s+(\w+)\s*:\s*View\b/g;

export function findFormDisclosureChevronFaults(files: readonly SwiftSource[]): DisclosureChevronFault[] {
  const faults: DisclosureChevronFault[] = [];
  for (const file of files) {
    if (file.path.endsWith("Components.swift")) {
      faults.push(...componentFaults(file));
      continue;
    }
    const views = viewStructs(file.source);
    for (const view of views) {
      const nested = views.filter(
        (candidate) => candidate.start > view.start && candidate.start < view.start + view.body.length,
      );
      const body = ownViewBody(view, nested);
      if (!containsSwiftUIForm(body) || !body.includes("DisclosureValueRow(")) {
        continue;
      }
      for (const call of calleeCalls(view.body, "DisclosureValueRow")) {
        const at = view.start + call.offset;
        if (nested.some((inner) => at >= inner.start && at < inner.start + inner.body.length)) continue;
        if (/\bshowsChevron\s*:\s*false\b/.test(call.args)) continue;
        faults.push({
          path: file.path,
          line: lineNumber(file.source, at),
          detail: `${view.name} is a Form view; DisclosureValueRow needs showsChevron: false or Form adds a second >.`,
        });
      }
    }
  }
  return faults;
}

function componentFaults(file: SwiftSource): DisclosureChevronFault[] {
  const view = viewStructs(file.source).find((candidate) => candidate.name === "DisclosureValueRow");
  if (!view) {
    return [{ path: file.path, line: 1, detail: "DisclosureValueRow is missing." }];
  }
  const faults: DisclosureChevronFault[] = [];
  if (!/\bvar showsChevron\b/.test(view.body)) {
    faults.push({
      path: file.path,
      line: lineNumber(file.source, view.start),
      detail: "DisclosureValueRow must expose showsChevron so Form labels can hide the custom >.",
    });
  }
  const chevron = view.body.indexOf('Image(systemName: "chevron.right")');
  const gate = view.body.lastIndexOf("if showsChevron", chevron);
  if (chevron >= 0 && (gate < 0 || gate > chevron)) {
    faults.push({
      path: file.path,
      line: lineNumber(file.source, view.start + Math.max(chevron, 0)),
      detail: "DisclosureValueRow's trailing chevron must be behind if showsChevron.",
    });
  }
  return faults;
}

/** True only for a SwiftUI `Form` token, not identifiers that merely end in Form. */
function containsSwiftUIForm(body: string): boolean {
  return /\bForm\s*\{/.test(body);
}

function ownViewBody(
  view: { start: number; body: string },
  nested: Array<{ start: number; body: string }>,
): string {
  let text = view.body;
  for (const inner of [...nested].sort((a, b) => b.start - a.start)) {
    const rel = inner.start - view.start;
    const header = structHeaderStart(text.slice(0, rel));
    text = text.slice(0, header) + text.slice(rel + inner.body.length);
  }
  return text;
}

function structHeaderStart(prefix: string): number {
  const match = prefix.match(/(?:private\s+)?struct\s+\w+\s*:\s*View\s*$/);
  return match?.index ?? prefix.length;
}

function viewStructs(source: string): Array<{ name: string; body: string; start: number }> {
  const structs: Array<{ name: string; body: string; start: number }> = [];
  for (const match of source.matchAll(VIEW_STRUCT)) {
    const name = match[1];
    const header = match.index ?? 0;
    const brace = source.indexOf("{", header + match[0].length);
    if (!name || brace < 0) continue;
    const close = matchingBrace(source, brace);
    if (close < 0) continue;
    structs.push({ name, body: source.slice(brace, close + 1), start: brace });
  }
  return structs;
}

function calleeCalls(source: string, callee: string): Array<{ args: string; offset: number }> {
  const needle = `${callee}(`;
  const calls: Array<{ args: string; offset: number }> = [];
  let from = 0;
  while (from < source.length) {
    const start = source.indexOf(needle, from);
    if (start < 0) break;
    const open = start + needle.length - 1;
    const close = matchingParen(source, open);
    if (close < 0) break;
    calls.push({ args: source.slice(open + 1, close), offset: start });
    from = close + 1;
  }
  return calls;
}

function matchingBrace(source: string, open: number): number {
  return matchingPair(source, open, "{", "}");
}

function matchingParen(source: string, open: number): number {
  return matchingPair(source, open, "(", ")");
}

function matchingPair(source: string, open: number, left: string, right: string): number {
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (ch === left) depth += 1;
    else if (ch === right) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function lineNumber(source: string, index: number): number {
  return source.slice(0, index).split("\n").length;
}
