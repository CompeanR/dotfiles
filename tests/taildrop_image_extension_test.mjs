import assert from "node:assert/strict";
import { writeFile, mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import test from "node:test";

const { default: taildropImage } = await import(
  "../pi/extensions/taildrop-image.ts"
);

const EMPTY_TAILDROP = { code: 0, stdout: "", stderr: "" };

/** Fake `pi.exec`: the macOS Tailscale app leaves the CLI inbox empty. */
function fakeExec({ onSips } = {}) {
  return async (command, args) => {
    if (command === "tailscale") return EMPTY_TAILDROP;
    if (command === "sips") {
      if (onSips) await onSips(args);
      return EMPTY_TAILDROP;
    }
    throw new Error(`unexpected command: ${command}`);
  };
}

function loadCommand(exec) {
  const commands = new Map();
  taildropImage({
    registerCommand(name, definition) {
      commands.set(name, definition);
    },
    exec,
  });
  return commands.get("image");
}

function uiContext() {
  const notices = [];
  let text = "";
  return {
    notices,
    editorText: () => text,
    ui: {
      getEditorText: () => text,
      pasteToEditor: (value) => {
        text += value;
      },
      setStatus() {},
      select: async (_title, labels) => labels[0],
      notify(message, level) {
        notices.push({ message, level });
      },
    },
  };
}

async function scenario({ files }) {
  const inbox = await mkdtemp(join(tmpdir(), "taildrop-inbox-"));
  const downloads = await mkdtemp(join(tmpdir(), "taildrop-downloads-"));
  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(downloads, name), contents);
  }
  process.env.PI_TAILDROP_DIR = inbox;
  process.env.PI_TAILDROP_FALLBACK_DIRS = downloads;
  delete process.env.PI_TAILDROP_WINDOW;
  delete process.env.PI_TAILDROP_BATCH_WINDOW;
  return { inbox, downloads };
}

test("picks up an iPhone photo the macOS app saved to the fallback folder", async () => {
  const { downloads } = await scenario({ files: { "IMG_0558.jpeg": "photo" } });
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("", ctx);

  assert.match(ctx.editorText(), new RegExp(join(downloads, "IMG_0558.jpeg")));
  assert.match(ctx.notices.at(-1).message, /^Received IMG_0558\.jpeg/);
});

test("skips the fallback folder when the inbox already has a newer file", async () => {
  const { inbox, downloads } = await scenario({
    files: { "IMG_0558.jpeg": "photo" },
  });
  await writeFile(join(inbox, "inbox.png"), "inbox");
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("", ctx);

  assert.match(ctx.editorText(), new RegExp(join(inbox, "inbox.png")));
  assert.doesNotMatch(ctx.editorText(), new RegExp(downloads));
});

test("converts a HEIC capture to JPEG before pasting it", async () => {
  const { downloads } = await scenario({ files: { "IMG_0002.HEIC": "heic" } });
  const command = loadCommand(
    fakeExec({
      onSips: async (args) => {
        const out = args[args.indexOf("--out") + 1];
        await writeFile(out, "jpeg");
      },
    }),
  );
  const ctx = uiContext();

  await command.handler("", ctx);

  const pasted = ctx.editorText().trim();
  assert.equal(pasted, join(downloads, "IMG_0002.jpg"));
  assert.equal(await readFile(pasted, "utf8"), "jpeg");
});

test("list reports the fallback folder", async () => {
  const { downloads } = await scenario({ files: { "IMG_0558.jpeg": "photo" } });
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("list", ctx);

  assert.match(ctx.notices.at(-1).message, /IMG_0558\.jpeg/);
  assert.match(ctx.notices.at(-1).message, new RegExp(basename(downloads)));
});

test("all pastes every photo from one share-sheet burst", async () => {
  const { downloads } = await scenario({
    files: { "IMG_0558.jpeg": "one", "IMG_0559.jpeg": "two" },
  });
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("all", ctx);

  assert.match(ctx.editorText(), new RegExp(join(downloads, "IMG_0558.jpeg")));
  assert.match(ctx.editorText(), new RegExp(join(downloads, "IMG_0559.jpeg")));
  assert.match(ctx.notices.at(-1).message, /^Added 2 images/);
});

test("explains itself when nothing arrived anywhere", async () => {
  await scenario({ files: {} });
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("", ctx);

  assert.equal(ctx.editorText(), "");
  assert.match(ctx.notices.at(-1).message, /No PNG\/JPEG\/HEIC/);
});

test("accepts a freshly arrived inbox image without touching the fallback", async () => {
  const { inbox, downloads } = await scenario({
    files: { "IMG_0558.jpeg": "photo" },
  });
  const ctx = uiContext();

  // Simulate Taildrop writing into the CLI inbox during `tailscale file get`.
  const inboxCommand = loadCommand(async (name, args) => {
    if (name === "tailscale") {
      await writeFile(join(inbox, "fresh.png"), "fresh");
      return EMPTY_TAILDROP;
    }
    throw new Error(`unexpected command: ${name} ${args}`);
  });
  await inboxCommand.handler("", ctx);

  assert.match(ctx.editorText(), new RegExp(join(inbox, "fresh.png")));
  assert.doesNotMatch(ctx.editorText(), new RegExp(downloads));
});

test("honours PI_TAILDROP_FALLBACK_DIRS", async () => {
  await scenario({ files: {} });
  const custom = await mkdtemp(join(tmpdir(), "taildrop-custom-"));
  await writeFile(join(custom, "IMG_0777.jpeg"), "elsewhere");
  process.env.PI_TAILDROP_FALLBACK_DIRS = custom;
  const command = loadCommand(fakeExec());
  const ctx = uiContext();

  await command.handler("", ctx);

  assert.match(ctx.editorText(), new RegExp(join(custom, "IMG_0777.jpeg")));
});
