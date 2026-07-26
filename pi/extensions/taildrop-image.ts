import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { chmod, mkdir, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_UPLOAD_DIR = join(homedir(), "uploads", "moshi");
const RECEIVE_TIMEOUT_MS = 20_000;
const WAIT_TIMEOUT_MS = 5 * 60_000;
const PICK_LIMIT = 20;
const IMAGE_EXTENSIONS = new Set([
  ".bmp",
  ".gif",
  ".jpeg",
  ".jpg",
  ".png",
  ".webp",
]);
const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".m4v", ".webm"]);

type MediaFile = {
  path: string;
  name: string;
  modifiedMs: number;
  size: number;
};

type ReceiveResult = {
  media: MediaFile[];
  received: MediaFile[];
  error?: string;
};

type EditorContext = {
  ui: {
    getEditorText(): string;
    pasteToEditor(text: string): void;
  };
};

type KindConfig = {
  command: string;
  extensions: ReadonlySet<string>;
  statusKey: string;
  noun: string;
  nounPlural: string;
  selectTitle: string;
  unsupportedHint: string;
  allEmptyHint: string;
};

const KINDS: KindConfig[] = [
  {
    command: "image",
    extensions: IMAGE_EXTENSIONS,
    statusKey: "taildrop-image",
    noun: "image",
    nounPlural: "images",
    selectTitle: "Choose an image",
    unsupportedHint:
      "No PNG/JPEG/GIF/WebP/BMP image found. For HEIC photos, convert to JPEG on iPhone before sharing.",
    allEmptyHint:
      "No new image batch found. Share multiple photos through Tailscale, then run /image all.",
  },
  {
    command: "video",
    extensions: VIDEO_EXTENSIONS,
    statusKey: "taildrop-video",
    noun: "video",
    nounPlural: "videos",
    selectTitle: "Choose a video",
    unsupportedHint: "No MP4/MOV/M4V/WebM video found.",
    allEmptyHint:
      "No new video batch found. Share multiple videos through Tailscale, then run /video all.",
  },
];
function uploadDir(): string {
  return process.env.PI_TAILDROP_DIR ?? DEFAULT_UPLOAD_DIR;
}

function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? "" : name.slice(dot).toLowerCase();
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatAge(modifiedMs: number): string {
  const elapsedSeconds = Math.max(
    0,
    Math.round((Date.now() - modifiedMs) / 1000),
  );
  if (elapsedSeconds < 60) return "just now";
  const minutes = Math.floor(elapsedSeconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

async function listMedia(
  directory: string,
  extensions: ReadonlySet<string>,
): Promise<MediaFile[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const media: MediaFile[] = [];

  await Promise.all(
    entries.map(async (entry) => {
      if (!entry.isFile() || !extensions.has(extensionOf(entry.name))) return;
      const path = join(directory, entry.name);
      const metadata = await stat(path);
      await chmod(path, 0o600);
      media.push({
        path,
        name: entry.name,
        modifiedMs: metadata.mtimeMs,
        size: metadata.size,
      });
    }),
  );

  return media.sort((left, right) => right.modifiedMs - left.modifiedMs);
}

function pastePaths(paths: string[], ctx: EditorContext): void {
  const current = ctx.ui.getEditorText();
  const separator = current.length > 0 && !/\s$/.test(current) ? " " : "";
  ctx.ui.pasteToEditor(`${separator}${paths.join(" ")}`);
}

async function receiveTaildrop(
  pi: ExtensionAPI,
  directory: string,
  wait: boolean,
  extensions: ReadonlySet<string>,
): Promise<ReceiveResult> {
  const before = new Map(
    (await listMedia(directory, extensions)).map((file) => [
      file.path,
      file.modifiedMs,
    ]),
  );
  const commandArgs = ["file", "get", "--conflict=rename"];
  if (wait) commandArgs.push("--wait");
  commandArgs.push(directory);

  try {
    const result = await pi.exec("tailscale", commandArgs, {
      timeout: wait ? WAIT_TIMEOUT_MS : RECEIVE_TIMEOUT_MS,
    });
    if (result.code !== 0) {
      const message =
        result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
      return {
        media: await listMedia(directory, extensions),
        received: [],
        error: message,
      };
    }
  } catch (error) {
    return {
      media: await listMedia(directory, extensions),
      received: [],
      error: error instanceof Error ? error.message : String(error),
    };
  }

  const media = await listMedia(directory, extensions);
  const received = media.filter(
    (file) => before.get(file.path) !== file.modifiedMs,
  );
  return { media, received };
}

function registerTaildropKind(pi: ExtensionAPI, config: KindConfig): void {
  let lastBatchPaths: string[] = [];

  pi.registerCommand(config.command, {
    description: `Receive, select, and paste Tailscale Taildrop ${config.noun} paths`,
    getArgumentCompletions: (prefix) => {
      const choices = [
        {
          value: "pick",
          label: "pick",
          description: `Choose from the 20 newest ${config.nounPlural}`,
        },
        {
          value: "all",
          label: "all",
          description: `Paste every ${config.noun} in the newest batch`,
        },
        {
          value: "wait",
          label: "wait",
          description: `Wait up to five minutes for the next ${config.noun}`,
        },
        {
          value: "latest",
          label: "latest",
          description: `Paste the newest ${config.noun} already received`,
        },
        {
          value: "list",
          label: "list",
          description: `Show the five newest received ${config.nounPlural}`,
        },
      ];
      const filtered = choices.filter((choice) =>
        choice.value.startsWith(prefix),
      );
      return filtered.length > 0 ? filtered : null;
    },
    handler: async (args, ctx) => {
      const action = args.trim().toLowerCase();
      const directory = uploadDir();
      await mkdir(directory, { recursive: true, mode: 0o700 });
      await chmod(directory, 0o700);

      if (action === "list") {
        const media = await listMedia(directory, config.extensions);
        if (media.length === 0) {
          ctx.ui.notify(
            `No supported ${config.nounPlural} in ${directory}`,
            "warning",
          );
          return;
        }
        const summary = media
          .slice(0, 5)
          .map(
            (file) =>
              `${file.name} (${formatSize(file.size)}, ${formatAge(file.modifiedMs)})`,
          )
          .join("\n");
        ctx.ui.notify(summary, "info");
        return;
      }

      if (action === "latest") {
        const media = await listMedia(directory, config.extensions);
        if (media.length === 0) {
          ctx.ui.notify(
            `No supported ${config.nounPlural} in ${directory}`,
            "warning",
          );
          return;
        }
        pastePaths([media[0].path], ctx);
        ctx.ui.notify(`Added ${media[0].name}`, "info");
        return;
      }

      if (action && !["all", "pick", "wait"].includes(action)) {
        ctx.ui.notify(
          `Usage: /${config.command} [pick|all|wait|latest|list]`,
          "warning",
        );
        return;
      }

      const waiting = action === "wait";
      const status = waiting
        ? `waiting for ${config.noun}…`
        : action === "pick"
          ? `refreshing ${config.nounPlural}…`
          : `receiving ${config.noun}…`;
      ctx.ui.setStatus(config.statusKey, status);

      try {
        const result = await receiveTaildrop(
          pi,
          directory,
          waiting,
          config.extensions,
        );
        if (result.error) {
          ctx.ui.notify(`Taildrop receive failed: ${result.error}`, "error");
          return;
        }
        if (result.received.length > 0) {
          lastBatchPaths = result.received.map((file) => file.path);
        }

        if (action === "pick") {
          if (result.media.length === 0) {
            ctx.ui.notify(
              `No supported ${config.nounPlural} in ${directory}`,
              "warning",
            );
            return;
          }
          const candidates = result.media.slice(0, PICK_LIMIT);
          const labels = candidates.map(
            (file, index) =>
              `${index + 1}. ${file.name} · ${formatSize(file.size)} · ${formatAge(file.modifiedMs)}`,
          );
          const choice = await ctx.ui.select(config.selectTitle, labels);
          if (!choice) return;
          const selected = candidates[labels.indexOf(choice)];
          if (!selected) return;
          pastePaths([selected.path], ctx);
          ctx.ui.notify(`Added ${selected.name}`, "info");
          return;
        }

        if (action === "all") {
          const previousBatch = new Set(lastBatchPaths);
          const batch =
            result.received.length > 0
              ? result.received
              : result.media.filter((file) => previousBatch.has(file.path));
          if (batch.length === 0) {
            ctx.ui.notify(config.allEmptyHint, "warning");
            return;
          }
          const ordered = [...batch].sort(
            (left, right) => left.modifiedMs - right.modifiedMs,
          );
          pastePaths(
            ordered.map((file) => file.path),
            ctx,
          );
          ctx.ui.notify(`Added ${ordered.length} ${config.nounPlural}`, "info");
          return;
        }

        if (result.media.length === 0) {
          ctx.ui.notify(config.unsupportedHint, "warning");
          return;
        }

        const selected = result.received[0] ?? result.media[0];
        pastePaths([selected.path], ctx);
        ctx.ui.notify(
          `${result.received.length > 0 ? "Received" : "Added latest"} ${selected.name} (${formatSize(selected.size)})`,
          "info",
        );
      } finally {
        ctx.ui.setStatus(config.statusKey, undefined);
      }
    },
  });
}

export default function taildropMedia(pi: ExtensionAPI): void {
  for (const config of KINDS) registerTaildropKind(pi, config);
}
