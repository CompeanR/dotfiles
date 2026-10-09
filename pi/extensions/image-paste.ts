import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { getNativeClipboard } from "@earendil-works/pi-tui";
import { randomUUID } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

type PastedImage = { type: "image"; data: string; mimeType: string };

const PLACEHOLDER = /\[image (\d+)\]/g;
const PASTE_START = "\x1b[200~";
const PASTE_END = "\x1b[201~";
const PATH_TOKEN = /'[^']*'|"[^"]*"|(?:\\.|[^\s\\'"])+/g;
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

function mimeOf(bytes: Uint8Array): string | undefined {
  const head = Buffer.from(bytes.subarray(0, 12));
  if (head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return "image/jpeg";
  if (head.subarray(0, 4).toString("ascii") === "GIF8") return "image/gif";
  if (head.subarray(0, 4).toString("ascii") === "RIFF" && head.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  return undefined;
}

function toPath(token: string): string {
  let path = token;
  if (/^(['"]).*\1$/.test(path)) path = path.slice(1, -1);
  else path = path.replace(/\\(.)/g, "$1");
  if (path.startsWith("file://")) path = decodeURIComponent(path.slice("file://".length));
  if (path.startsWith("~/")) path = join(homedir(), path.slice(2));
  return path;
}

function readImage(path: string): PastedImage | undefined {
  try {
    const stats = statSync(path);
    if (!stats.isFile() || stats.size > MAX_IMAGE_BYTES) return undefined;
    const bytes = readFileSync(path);
    const mimeType = mimeOf(bytes);
    return mimeType ? { type: "image", data: bytes.toString("base64"), mimeType } : undefined;
  } catch {
    return undefined;
  }
}

function imagesFromPaste(content: string): PastedImage[] | undefined {
  const tokens = content.trim().match(PATH_TOKEN);
  if (!tokens?.length) return undefined;
  const found: PastedImage[] = [];
  for (const token of tokens) {
    const path = toPath(token);
    if (!path.startsWith("/")) return undefined;
    const image = readImage(path);
    if (!image) return undefined;
    found.push(image);
  }
  return found;
}

export default function (pi: ExtensionAPI) {
  const images = new Map<number, PastedImage>();
  let next = 1;
  let stopListening: (() => void) | undefined;

  const remember = (image: PastedImage) => {
    const id = next++;
    images.set(id, image);
    return `[image ${id}]`;
  };

  pi.on("session_start", (_event, ctx) => {
    stopListening?.();
    stopListening = ctx.ui.onTerminalInput((data) => {
      if (!data.startsWith(PASTE_START) || !data.endsWith(PASTE_END)) return undefined;
      const found = imagesFromPaste(data.slice(PASTE_START.length, -PASTE_END.length));
      if (!found) return undefined;
      return { data: `${PASTE_START}${found.map(remember).join(" ")}${PASTE_END}` };
    });
  });

  pi.on("session_shutdown", () => {
    stopListening?.();
    stopListening = undefined;
  });

  pi.registerShortcut("ctrl+v", {
    description: "Paste an image as [image N], or files and text",
    handler: async (ctx) => {
      const clipboard = getNativeClipboard();
      if (!clipboard) return;

      const paste = (text: string) => {
        ctx.ui.pasteToEditor(text);
        ctx.ui.setStatus("image-paste", undefined);
      };

      const files = await clipboard.getFilePaths?.().catch(() => null);
      if (files?.length) {
        paste(files.join("\n"));
        return;
      }

      const bytes = await clipboard.getImage().catch(() => null);
      if (bytes?.length) {
        const mimeType = mimeOf(bytes);
        if (!mimeType) {
          const path = join(tmpdir(), `pi-clipboard-${randomUUID()}.png`);
          writeFileSync(path, bytes);
          paste(path);
          return;
        }
        paste(remember({ type: "image", data: Buffer.from(bytes).toString("base64"), mimeType }));
        return;
      }

      const text = await clipboard.getText().catch(() => null);
      if (text) paste(text);
    },
  });

  pi.on("input", async (event) => {
    const attached = [...event.text.matchAll(PLACEHOLDER)]
      .map((match) => images.get(Number(match[1])))
      .filter((image): image is PastedImage => image !== undefined);
    if (attached.length === 0) return { action: "continue" };

    return { action: "transform", text: event.text, images: [...(event.images ?? []), ...attached] };
  });
}
