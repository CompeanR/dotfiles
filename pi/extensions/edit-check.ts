/**
 * Before the agent hands back, type-check what it edited and report new problems so it fixes them first.
 *
 * - TypeScript: the project's own tsc (`node_modules/.bin/tsc --noEmit`), plus the AGENTS.md rule
 *   "public methods inside classes use the `public` keyword" (only violations introduced this run;
 *   needs the project's TypeScript JS API, so it is skipped on TypeScript 7).
 * - Go: `go vet ./...` in the module.
 * Output is filtered to the edited files. Nothing is installed; missing tools are skipped.
 * At most MAX_ROUNDS fix rounds per user prompt.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, extname, join, relative, resolve } from "node:path";

const MAX_ROUNDS = 2;
const TIMEOUT_MS = 90_000;
const MAX_LINES = 40;
const TS_EXT = new Set([".ts", ".tsx", ".mts", ".cts"]);

type Ts = typeof import("typescript");

function findUp(start: string, marker: string): string | undefined {
  let dir = start;
  while (true) {
    if (existsSync(join(dir, marker))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

function loadTypescript(root: string): Ts | undefined {
  try {
    const ts = createRequire(join(root, "package.json"))("typescript") as Ts;
    return typeof ts.createSourceFile === "function" ? ts : undefined;
  } catch {
    return undefined;
  }
}

function methodsMissingPublic(ts: Ts, file: string): Map<string, number> {
  const found = new Map<string, number>();
  if (!existsSync(file)) return found;
  const source = ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true);
  const accessKinds = [ts.SyntaxKind.PublicKeyword, ts.SyntaxKind.PrivateKeyword, ts.SyntaxKind.ProtectedKeyword];

  const visit = (node: import("typescript").Node, className: string): void => {
    if (ts.isClassLike(node)) className = node.name?.text ?? "<anonymous>";
    const isMethod = ts.isMethodDeclaration(node) || ts.isGetAccessorDeclaration(node) || ts.isSetAccessorDeclaration(node);
    if (isMethod && ts.isClassLike(node.parent) && !ts.isPrivateIdentifier(node.name)) {
      const modifiers = ts.getModifiers(node) ?? [];
      if (!modifiers.some((m) => accessKinds.includes(m.kind))) {
        const line = source.getLineAndCharacterOfPosition(node.getStart()).line + 1;
        found.set(`${className}.${node.name.getText(source)}`, line);
      }
    }
    ts.forEachChild(node, (child) => visit(child, className));
  };
  visit(source, "");
  return found;
}

export default function editCheck(pi: ExtensionAPI): void {
  const edited = new Set<string>();
  const publicBaseline = new Map<string, Set<string>>();
  let rounds = 0;

  pi.on("before_agent_start", async () => {
    rounds = 0;
    edited.clear();
    publicBaseline.clear();
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return undefined;
    const file = resolve(ctx.cwd, String(event.input.path ?? ""));
    if (!TS_EXT.has(extname(file)) || publicBaseline.has(file)) return undefined;
    const root = findUp(dirname(file), "package.json");
    const ts = root ? loadTypescript(root) : undefined;
    publicBaseline.set(file, new Set(ts ? methodsMissingPublic(ts, file).keys() : []));
    return undefined;
  });

  pi.on("tool_result", async (event, ctx) => {
    if ((event.toolName === "edit" || event.toolName === "write") && !event.isError) {
      edited.add(resolve(ctx.cwd, String(event.input.path ?? "")));
    }
    return undefined;
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (edited.size === 0 || event.outcome !== "completed") return undefined;
    if (rounds >= MAX_ROUNDS) return undefined;

    const files = [...edited];
    edited.clear();
    const problems: string[] = [];

    const byRoot = (marker: string, exts: (ext: string) => boolean): Map<string, string[]> => {
      const groups = new Map<string, string[]>();
      for (const file of files.filter((f) => exts(extname(f)))) {
        const root = findUp(dirname(file), marker);
        if (root) groups.set(root, [...(groups.get(root) ?? []), file]);
      }
      return groups;
    };

    const filtered = (output: string, root: string, group: string[]): string[] => {
      const rels = group.map((f) => relative(root, f));
      return output.split("\n").filter((line) => rels.some((rel) => line.includes(rel)));
    };

    for (const [root, group] of byRoot("tsconfig.json", (ext) => TS_EXT.has(ext))) {
      const tsc = join(root, "node_modules", ".bin", "tsc");
      if (!existsSync(tsc)) continue;
      const result = await pi.exec(tsc, ["--noEmit", "--pretty", "false"], { cwd: root, timeout: TIMEOUT_MS, signal: ctx.signal });
      problems.push(...filtered(result.stdout + result.stderr, root, group).map((l) => `${relative(ctx.cwd, root) || "."}: ${l}`));
    }

    for (const file of files.filter((f) => TS_EXT.has(extname(f)))) {
      const root = findUp(dirname(file), "package.json");
      const ts = root ? loadTypescript(root) : undefined;
      if (!ts) continue;
      const baseline = publicBaseline.get(file) ?? new Set<string>();
      for (const [name, line] of methodsMissingPublic(ts, file)) {
        if (!baseline.has(name)) problems.push(`${relative(ctx.cwd, file)}:${line}: method ${name} needs the 'public' keyword (AGENTS.md rule)`);
      }
    }

    for (const [root, group] of byRoot("go.mod", (ext) => ext === ".go")) {
      const result = await pi.exec("go", ["vet", "./..."], { cwd: root, timeout: TIMEOUT_MS, signal: ctx.signal });
      if (result.code !== 0) problems.push(...filtered(result.stderr, root, group));
    }

    if (problems.length === 0) return undefined;
    rounds++;
    const shown = problems.slice(0, MAX_LINES);
    const more = problems.length > shown.length ? `\n…and ${problems.length - shown.length} more` : "";
    return {
      entries: [{
        type: "custom_message",
        customType: "edit-check",
        display: true,
        content: `Edit check found problems in files you changed. Fix the ones your change introduced (ignore pre-existing ones), then finish:\n${shown.join("\n")}${more}`,
      }],
      continue: true,
    };
  });
}
