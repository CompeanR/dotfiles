import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { getNativeClipboard } from "@earendil-works/pi-tui";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

type PastedImage = { type: "image"; data: string; mimeType: string };

const PLACEHOLDER = /\[image (\d+)\]/g;

function mimeOf(bytes: Uint8Array): string | undefined {
  const head = Buffer.from(bytes.subarray(0, 12));
  if (head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return "image/jpeg";
  if (head.subarray(0, 4).toString("ascii") === "GIF8") return "image/gif";
  if (head.subarray(0, 4).toString("ascii") === "RIFF" && head.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  return undefined;
}

export default function (pi: ExtensionAPI) {
  const images = new Map<number, PastedImage>();
  let next = 1;

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
        const id = next++;
        images.set(id, { type: "image", data: Buffer.from(bytes).toString("base64"), mimeType });
        paste(`[image ${id}]`);
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
