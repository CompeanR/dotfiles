import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import test from "node:test";

import { ROLE_NAMES, SubagentError } from "../pi/extensions/lib/subagent-core.mjs";

const JITI_PATH = "/Users/compean/.pi/agent/npm/node_modules/jiti/lib/jiti.mjs";
const TYPEBOX_PATH = "/Users/compean/.pi/agent/npm/node_modules/typebox/build/index.mjs";
const EXTENSION_PATH = new URL("../pi/extensions/subagent.ts", import.meta.url);

const canLoadTs = existsSync(JITI_PATH) && existsSync(TYPEBOX_PATH);
const skipReason = "jiti/typebox unavailable (pi/npm/node_modules is missing; not installing)";

async function loadExtensionModule() {
  const { createJiti } = await import(pathToFileURL(JITI_PATH).href);
  const jiti = createJiti(import.meta.url, {
    alias: { typebox: TYPEBOX_PATH },
  });
  return jiti.import(fileURLFrom(EXTENSION_PATH));
}

function fileURLFrom(url) {
  return url.href;
}

function fakePi() {
  const tools = [];
  return {
    tools,
    registerTool(def) {
      tools.push(def);
    },
  };
}

function roleEnumValues(schema) {
  const role = schema.properties.role;
  if (Array.isArray(role?.enum)) return [...role.enum];
  const variants = role?.anyOf ?? role?.oneOf ?? [];
  return variants.map((v) => v.const ?? v.enum?.[0]);
}

function requiredKeys(schema) {
  return [...(schema.required ?? [])].sort();
}

test("registers one parallel subagent tool from real config", { skip: canLoadTs ? false : skipReason }, async () => {
  const mod = await loadExtensionModule();
  const pi = fakePi();
  mod.default(pi);

  assert.equal(pi.tools.length, 1);
  const tool = pi.tools[0];
  assert.equal(tool.name, "subagent");
  assert.equal(tool.label, "Subagent");
  assert.equal(typeof tool.description, "string");
  assert.ok(tool.description.length > 0);
  for (const role of ROLE_NAMES) {
    assert.match(tool.description, new RegExp(`\\b${role}\\b`));
  }
  assert.equal(tool.executionMode, "parallel");

  const schema = tool.parameters;
  assert.equal(schema.additionalProperties, false);
  assert.deepEqual(requiredKeys(schema), ["brief", "role"]);
  for (const key of ["role", "brief", "cwd", "watch", "timeout_ms"]) {
    assert.equal(key in schema.properties, true, `missing property ${key}`);
  }
  assert.deepEqual(roleEnumValues(schema).sort(), [...ROLE_NAMES].sort());
});

test("execute success shape forwards signal and ctx.cwd", { skip: canLoadTs ? false : skipReason }, async () => {
  const mod = await loadExtensionModule();
  const ac = new AbortController();
  let seen;
  const stub = {
    roleNames: [...ROLE_NAMES],
    description: "stub",
    dispatch: async (args, runtime) => {
      seen = { args, runtime };
      return { text: "ok-text", details: { role: args.role, cwd: runtime.cwd } };
    },
  };

  const pi = fakePi();
  mod.registerSubagent(pi, stub);
  const tool = pi.tools[0];
  const result = await tool.execute(
    "call-1",
    { role: "explore", brief: "do the thing" },
    ac.signal,
    undefined,
    { cwd: "/tmp/subagent-fallback" },
  );

  assert.equal("isError" in result, false);
  assert.deepEqual(result.content, [{ type: "text", text: "ok-text" }]);
  assert.deepEqual(result.details, { role: "explore", cwd: "/tmp/subagent-fallback" });
  assert.equal(seen.runtime.signal, ac.signal);
  assert.equal(seen.runtime.cwd, "/tmp/subagent-fallback");
});

test("SubagentError from dispatch propagates out of execute", { skip: canLoadTs ? false : skipReason }, async () => {
  const mod = await loadExtensionModule();
  const err = new SubagentError("timeout", "boom");
  const stub = {
    roleNames: [...ROLE_NAMES],
    description: "stub",
    dispatch: async () => {
      throw err;
    },
  };
  const pi = fakePi();
  mod.registerSubagent(pi, stub);

  await assert.rejects(
    () => pi.tools[0].execute("x", { role: "explore", brief: "n" }, undefined, undefined, { cwd: process.cwd() }),
    (caught) => {
      assert.equal(caught, err);
      assert.equal(caught.code, "timeout");
      return true;
    },
  );
});

test("watch:true is watch_unsupported", { skip: canLoadTs ? false : skipReason }, async () => {
  const mod = await loadExtensionModule();
  const pi = fakePi();
  mod.default(pi);

  await assert.rejects(
    () => pi.tools[0].execute(
      "w",
      { role: "explore", brief: "self-contained brief", watch: true },
      undefined,
      undefined,
      { cwd: process.cwd() },
    ),
    (caught) => {
      assert.equal(caught.name, "SubagentError");
      assert.equal(caught.code, "watch_unsupported");
      return true;
    },
  );
});
