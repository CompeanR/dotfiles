import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import {
  buildSubagentDescription,
  createSubagentService,
  parseRoleFile,
} from "../pi/extensions/lib/subagent-core.mjs";

const FAKE_PI = `#!/usr/bin/env node
import { existsSync, writeFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";

if (process.env.FAKE_SENTINEL) {
  writeFileSync(process.env.FAKE_SENTINEL, JSON.stringify({
    argv: process.argv.slice(2),
    pid: process.pid,
    cwd: process.cwd(),
  }));
}

const sleepMs = Number(process.env.FAKE_SLEEP_MS ?? 0);
if (sleepMs > 0) await delay(sleepMs);

if (process.env.FAKE_BARRIER_DIR) {
  writeFileSync(
    process.env.FAKE_BARRIER_DIR + "/ready-" + process.pid,
    String(process.pid),
  );
  const go = process.env.FAKE_BARRIER_DIR + "/go";
  const deadline = Date.now() + 15000;
  while (!existsSync(go)) {
    if (Date.now() > deadline) process.exit(2);
    await delay(15);
  }
}

if (process.env.FAKE_FINISHED) {
  writeFileSync(process.env.FAKE_FINISHED, "done");
}

process.stderr.write(process.env.FAKE_STDERR ?? "");
process.stdout.write(process.env.FAKE_STDOUT ?? "ok\\n");
process.exit(Number(process.env.FAKE_EXIT ?? 0));
`;

function tempDir() {
  return mkdtempSync(join(tmpdir(), "subagent-core-"));
}

async function waitUntil(pred, label, ms = 8000) {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > ms) throw new Error(`timeout waiting for ${label}`);
    await delay(15);
  }
}

function writeRole(agentsDir, role, body) {
  writeFileSync(join(agentsDir, `work-${role}.md`), body);
}

function goodRole(role, extra = {}) {
  const tools = extra.toolsBlock ?? `tools:\n  - read\n  - grep\n`;
  const description = extra.description ?? `${role} does work`;
  const returns = extra.returns ?? `Provide:\n\n1. concise verdict;\n2. evidence with paths.`;
  return `---
name: work-${role}
description: ${description}
${tools}---

# Work ${role}

## Return

${returns}
`;
}

function makeHarness(t, {
  roles = ["explore", "apply"],
  roleBodies = {},
  overrides = {},
  serviceOptions = {},
  env = {},
} = {}) {
  const dir = tempDir();
  const savedEnv = {};
  for (const key of Object.keys(env)) {
    savedEnv[key] = process.env[key];
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  t.after(() => {
    for (const key of Object.keys(env)) {
      if (savedEnv[key] === undefined) delete process.env[key];
      else process.env[key] = savedEnv[key];
    }
    rmSync(dir, { recursive: true, force: true });
  });

  const agentsDir = join(dir, "agents");
  mkdirSync(agentsDir);
  const settingsPath = join(dir, "settings.json");
  const agentOverrides = {};
  for (const role of roles) {
    writeRole(agentsDir, role, roleBodies[role] ?? goodRole(role));
    agentOverrides[`work-${role}`] = {
      model: overrides[role]?.model ?? `model-${role}`,
      thinking: overrides[role]?.thinking,
    };
  }
  writeFileSync(settingsPath, JSON.stringify({ subagents: { agentOverrides } }));

  const piCommand = join(dir, "fake-pi");
  writeFileSync(piCommand, FAKE_PI);
  chmodSync(piCommand, 0o755);

  const dispatchPath = join(dir, "dispatch.sh");
  writeFileSync(dispatchPath, FAKE_PI);
  chmodSync(dispatchPath, 0o755);

  const service = createSubagentService({
    settingsPath,
    agentsDir,
    dispatchPath,
    piCommand,
    ...serviceOptions,
  });

  return { dir, agentsDir, settingsPath, piCommand, dispatchPath, service };
}

test.describe("subagent-core", { concurrency: 1 }, () => {

test("frontmatter with BOM + CRLF parses correctly", () => {
  const raw = "\uFEFF---\r\nname: work-explore\r\ndescription: Investigate a task.\r\ntools:\r\n  - read\r\n  - grep\r\n---\r\n\r\n# Title\r\n\r\n## Return\r\n\r\nProvide:\r\n\r\n1. answer;\r\n";
  const parsed = parseRoleFile(raw);
  assert.equal(parsed.description, "Investigate a task.");
  assert.deepEqual(parsed.tools, ["read", "grep"]);
  assert.equal(parsed.toolsDeclared, true);
  assert.match(parsed.returns, /concise|answer/i);
});

test("inline tools: [read, grep] including quoted items", () => {
  const parsed = parseRoleFile(`---
description: "quoted desc"
tools: [read, "grep", 'find']
---

## Return
ok
`);
  assert.equal(parsed.description, "quoted desc");
  assert.deepEqual(parsed.tools, ["read", "grep", "find"]);
  assert.equal(parsed.toolsDeclared, true);
});

test("block-list tools with blank lines", () => {
  const parsed = parseRoleFile(`---
description: block
tools:

  - read

  - grep

---

body
`);
  assert.deepEqual(parsed.tools, ["read", "grep"]);
  assert.equal(parsed.toolsDeclared, true);
});

test("malformed --- delimiters yield empty parse", () => {
  const parsed = parseRoleFile(`----
tools:
  - read
----

## Return
nope
`);
  assert.deepEqual(parsed, { description: "", tools: [], toolsDeclared: false, returns: "" });
});

test("indented tools / Tools: / tools : all produce configError", (t) => {
  const cases = {
    explore: `---
description: indented
  tools:
  - read
---
`,
    apply: `---
description: caps
Tools:
  - read
---
`,
    design: `---
description: spaced
tools :
  - read
---
`,
  };

  const { service } = makeHarness(t, {
    roles: ["explore", "apply", "design"],
    roleBodies: cases,
  });

  for (const role of Object.keys(cases)) {
    assert.ok(service.roles[role], `role ${role} should remain present`);
    assert.match(service.roles[role].configError, /no line-start "tools:" key was found/);
    assert.equal(service.roles[role].tools.length, 0);
  }
});

test("explicit tools: [] produces the declared-but-empty diagnostic", (t) => {
  const { service } = makeHarness(t, {
    roles: ["explore"],
    roleBodies: {
      explore: `---
description: empty list
tools: []
---
`,
    },
  });
  assert.equal(service.roles.explore.toolsDeclared, true);
  assert.match(service.roles.explore.configError, /a "tools:" key is present but produced no entries/);
});

test("FAIL-CLOSED: empty tools never spawn the fake executable", async (t) => {
  const sentinel = join(tempDir(), "should-not-exist");
  t.after(() => rmSync(sentinel, { force: true }));

  const { service } = makeHarness(t, {
    roles: ["explore"],
    roleBodies: {
      explore: `---
description: none
tools: []
---
`,
    },
    env: { FAKE_SENTINEL: sentinel },
  });

  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "do not run" }),
    (err) => {
      assert.equal(err.name, "SubagentError");
      assert.equal(err.code, "config");
      assert.match(err.message, /produced no entries|empty tool allowlist/);
      return true;
    },
  );
  assert.equal(existsSync(sentinel), false);
});

test("unknown role; missing brief; non-string brief; whitespace-only brief", async (t) => {
  const { service } = makeHarness(t);

  await assert.rejects(
    () => service.dispatch({ role: "nope", brief: "x" }),
    (err) => {
      assert.equal(err.code, "unknown_role");
      assert.match(err.message, /unknown role "nope"/);
      assert.match(err.message, /explore, apply/);
      return true;
    },
  );
  await assert.rejects(
    () => service.dispatch({ role: "explore" }),
    (err) => {
      assert.equal(err.code, "invalid_brief");
      return true;
    },
  );
  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: 12 }),
    (err) => err.code === "invalid_brief",
  );
  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "   " }),
    (err) => err.code === "invalid_brief",
  );
});

test("exact argv ordering includes non-empty --tools", async (t) => {
  const dir = tempDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sentinel = join(dir, "sentinel.json");
  const { service, agentsDir } = makeHarness(t, {
    roles: ["explore"],
    env: { FAKE_SENTINEL: sentinel, FAKE_STDOUT: "done\n" },
  });

  const result = await service.dispatch({ role: "explore", brief: "inspect the parser" });
  assert.equal(result.text, "done");
  const dumped = JSON.parse(readFileSync(sentinel, "utf8"));
  const argv = dumped.argv;
  const toolsIdx = argv.indexOf("--tools");
  assert.ok(toolsIdx !== -1);
  assert.equal(argv[toolsIdx + 1], "read,grep");
  assert.deepEqual(argv, [
    "-p",
    "--model", "model-explore",
    "--thinking", "medium",
    "--append-system-prompt", join(agentsDir, "work-explore.md"),
    "--no-session",
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "--tools", "read,grep",
    "inspect the parser",
  ]);
});

test("timeout kills the child and reports configured ms", async (t) => {
  const dir = tempDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sentinel = join(dir, "sentinel.json");
  const finished = join(dir, "finished");
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: {
      FAKE_SENTINEL: sentinel,
      FAKE_SLEEP_MS: "30000",
      FAKE_FINISHED: finished,
    },
  });

  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "hang", timeout_ms: 200 }),
    (err) => {
      assert.equal(err.code, "timeout");
      assert.match(err.message, /timed out after 200ms/);
      return true;
    },
  );
  assert.equal(existsSync(finished), false);
  const { pid } = JSON.parse(readFileSync(sentinel, "utf8"));
  await waitUntil(() => {
    try {
      process.kill(pid, 0);
      return false;
    } catch {
      return true;
    }
  }, "child death after timeout");
});

test("non-zero exit prefers stderr over stdout", async (t) => {
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: {
      FAKE_EXIT: "7",
      FAKE_STDERR: "boom-err",
      FAKE_STDOUT: "boom-out",
    },
  });
  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "fail" }),
    (err) => {
      assert.equal(err.code, "process_exit");
      assert.equal(err.message, "pi exited 7\nboom-err");
      return true;
    },
  );
});

test("zero exit with empty stdout is an error", async (t) => {
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: { FAKE_STDOUT: "", FAKE_STDERR: "whisper" },
  });
  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "silent" }),
    (err) => {
      assert.equal(err.code, "empty_output");
      assert.match(err.message, /produced no output/);
      assert.match(err.message, /whisper/);
      return true;
    },
  );
});

test("two explore dispatches overlap via file barrier", async (t) => {
  const barrier = tempDir();
  t.after(() => rmSync(barrier, { recursive: true, force: true }));
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: { FAKE_BARRIER_DIR: barrier, FAKE_STDOUT: "ok\n" },
    serviceOptions: { enforceSingleWriterPerCwd: true },
  });

  const a = service.dispatch({ role: "explore", brief: "one" });
  const b = service.dispatch({ role: "explore", brief: "two" });

  await waitUntil(
    () => readdirSync(barrier).filter((name) => name.startsWith("ready-")).length === 2,
    "both explore children ready",
  );
  writeFileSync(join(barrier, "go"), "go");
  const results = await Promise.all([a, b]);
  assert.equal(results[0].text, "ok");
  assert.equal(results[1].text, "ok");
});

test("enforceSingleWriterPerCwd: second apply in same cwd is writer_busy", async (t) => {
  const barrier = tempDir();
  const work = tempDir();
  t.after(() => {
    rmSync(barrier, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  });
  const { service } = makeHarness(t, {
    roles: ["apply"],
    env: { FAKE_BARRIER_DIR: barrier, FAKE_STDOUT: "ok\n" },
    serviceOptions: { enforceSingleWriterPerCwd: true },
  });

  const first = service.dispatch({ role: "apply", brief: "write one", cwd: work });
  await waitUntil(
    () => readdirSync(barrier).some((name) => name.startsWith("ready-")),
    "first apply ready",
  );

  await assert.rejects(
    () => service.dispatch({ role: "apply", brief: "write two", cwd: work }),
    (err) => {
      assert.equal(err.code, "writer_busy");
      assert.match(err.message, new RegExp(realpathSync(work).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
      return true;
    },
  );

  writeFileSync(join(barrier, "go"), "go");
  assert.equal((await first).text, "ok");
});

test("enforceSingleWriterPerCwd: symlink alias of the same cwd is writer_busy", async (t) => {
  const barrier = tempDir();
  const parent = tempDir();
  const work = join(parent, "real");
  mkdirSync(work);
  const alias = join(parent, "alias");
  symlinkSync(work, alias);
  t.after(() => {
    rmSync(barrier, { recursive: true, force: true });
    rmSync(parent, { recursive: true, force: true });
  });

  const { service } = makeHarness(t, {
    roles: ["apply"],
    env: { FAKE_BARRIER_DIR: barrier, FAKE_STDOUT: "ok\n" },
    serviceOptions: { enforceSingleWriterPerCwd: true },
  });

  const first = service.dispatch({ role: "apply", brief: "write one", cwd: work });
  await waitUntil(
    () => readdirSync(barrier).some((name) => name.startsWith("ready-")),
    "first apply ready",
  );
  await assert.rejects(
    () => service.dispatch({ role: "apply", brief: "write via alias", cwd: alias }),
    (err) => err.code === "writer_busy",
  );
  writeFileSync(join(barrier, "go"), "go");
  await first;
});

test("two apply in different cwds may overlap", async (t) => {
  const barrier = tempDir();
  const cwdA = tempDir();
  const cwdB = tempDir();
  t.after(() => {
    rmSync(barrier, { recursive: true, force: true });
    rmSync(cwdA, { recursive: true, force: true });
    rmSync(cwdB, { recursive: true, force: true });
  });
  const { service } = makeHarness(t, {
    roles: ["apply"],
    env: { FAKE_BARRIER_DIR: barrier, FAKE_STDOUT: "ok\n" },
    serviceOptions: { enforceSingleWriterPerCwd: true },
  });

  const a = service.dispatch({ role: "apply", brief: "a", cwd: cwdA });
  const b = service.dispatch({ role: "apply", brief: "b", cwd: cwdB });
  await waitUntil(
    () => readdirSync(barrier).filter((name) => name.startsWith("ready-")).length === 2,
    "both apply children ready",
  );
  writeFileSync(join(barrier, "go"), "go");
  const results = await Promise.all([a, b]);
  assert.equal(results[0].text, "ok");
  assert.equal(results[1].text, "ok");
});

test("already-aborted signal does not spawn", async (t) => {
  const dir = tempDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sentinel = join(dir, "sentinel.json");
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: { FAKE_SENTINEL: sentinel, FAKE_STDOUT: "ok\n" },
  });
  const signal = AbortSignal.abort();
  await assert.rejects(
    () => service.dispatch({ role: "explore", brief: "nope" }, { signal }),
    (err) => err.code === "aborted",
  );
  assert.equal(existsSync(sentinel), false);
});

test("abort after spawn kills the child and rejects aborted", async (t) => {
  const dir = tempDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sentinel = join(dir, "sentinel.json");
  const finished = join(dir, "finished");
  const { service } = makeHarness(t, {
    roles: ["explore"],
    env: {
      FAKE_SENTINEL: sentinel,
      FAKE_SLEEP_MS: "30000",
      FAKE_FINISHED: finished,
    },
  });

  const ac = new AbortController();
  const pending = service.dispatch({ role: "explore", brief: "hang" }, { signal: ac.signal });
  await waitUntil(() => existsSync(sentinel), "child start");
  const { pid } = JSON.parse(readFileSync(sentinel, "utf8"));
  ac.abort();
  await assert.rejects(pending, (err) => err.code === "aborted");
  assert.equal(existsSync(finished), false);
  await waitUntil(() => {
    try {
      process.kill(pid, 0);
      return false;
    } catch {
      return true;
    }
  }, "child death after abort");
});

test("buildSubagentDescription contains roles, model, thinking, compacted Returns", (t) => {
  const { service } = makeHarness(t, {
    roles: ["explore", "apply"],
    overrides: {
      explore: { model: "grok-4.6", thinking: "high" },
      apply: { model: "composer", thinking: "medium" },
    },
    roleBodies: {
      explore: goodRole("explore", {
        description: "Investigate a routine coding task.",
        returns: "Provide:\n\n1. concise verdict;\n2. evidence with paths.",
      }),
    },
  });

  const text = service.description;
  assert.equal(text, buildSubagentDescription(service.roles));
  assert.match(text, /explore — grok-4\.6 \(thinking: high\)/);
  assert.match(text, /apply — composer \(thinking: medium\)/);
  assert.match(text, /Returns: 1\. concise verdict; 2\. evidence with paths\./);
  assert.match(text, /NO ROLE IS MECHANICALLY READ-ONLY/);
});

});
