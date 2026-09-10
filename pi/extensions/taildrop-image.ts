import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Stats } from "node:fs";
import { chmod, mkdir, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, delimiter, dirname, join } from "node:path";

const DEFAULT_UPLOAD_DIR = join(homedir(), "uploads", "moshi");
// On macOS the Tailscale app receives Taildrop files itself and saves them to
// ~/Downloads, so `tailscale file get` always drains an empty inbox.
const DEFAULT_FALLBACK_DIRS = [join(homedir(), "Downloads")];
const RECEIVE_TIMEOUT_MS = 20_000;
const WAIT_TIMEOUT_MS = 5 * 60_000;
const PICK_LIMIT = 20;
const IMAGE_EXTENSIONS = new Set([
  ".bmp",
  ".gif",
  ".heic",
  ".heif",
  ".jpeg",
  ".jpg",
  ".png",
  ".webp",
]);
// Pi can only read PNG/JPEG/GIF/WebP, so HEIC photos are converted on the way in.
const CONVERTIBLE_EXTENSIONS = new Set([".heic", ".heif"]);
const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".m4v", ".webm"]);

type MediaFile = {
  path: string;
  name: string;
  modifiedMs: number;
  size: number;
  fromFallback?: boolean;
};

type ReceiveResult = {
  media: MediaFile[];
  received: MediaFile[];
  fallback: MediaFile[];
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
      "No PNG/JPEG/HEIC/GIF/WebP/BMP image found in the Taildrop inbox or the fallback folders (default ~/Downloads).",
    allEmptyHint:
      "No new image batch found. Share photos from the iPhone to this Mac, then run /image all.",
  },
  {
    command: "video",
    extensions: VIDEO_EXTENSIONS,
    statusKey: "taildrop-video",
    noun: "video",
    nounPlural: "videos",
    selectTitle: "Choose a video",
    unsupportedHint:
      "No MP4/MOV/M4V/WebM video found in the Taildrop inbox or the fallback folders (default ~/Downloads).",
    allEmptyHint:
      "No new video batch found. Share multiple videos through Tailscale, then run /video all.",
  },
];
function uploadDir(): string {
  return process.env.PI_TAILDROP_DIR ?? DEFAULT_UPLOAD_DIR;
}

function envMilliseconds(name: string, fallbackMs: number): number {
  const raw = process.env[name];
  if (!raw) return fallbackMs;
  const seconds = Number.parseInt(raw, 10);
  return Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : fallbackMs;
}

function fallbackDirs(): string[] {
  const configured = process.env.PI_TAILDROP_FALLBACK_DIRS;
  const raw = configured ? configured.split(delimiter) : DEFAULT_FALLBACK_DIRS;
  const primary = uploadDir();
  const dirs: string[] = [];
  for (const item of raw) {
    const trimmed = item.trim();
    if (!trimmed) continue;
    const directory = trimmed.startsWith("~")
      ? join(homedir(), trimmed.slice(1))
      : trimmed;
    if (directory === primary || dirs.includes(directory)) continue;
    dirs.push(directory);
  }
  return dirs;
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

/**
 * Media the macOS Tailscale app dropped straight into a user folder. These are
 * the user's own files, so unlike the inbox this never chmods them.
 */
async function listFallbackMedia(
  extensions: ReadonlySet<string>,
): Promise<MediaFile[]> {
  const cutoff = Date.now() - envMilliseconds("PI_TAILDROP_WINDOW", 30 * 60_000);
  const media: MediaFile[] = [];

  await Promise.all(
    fallbackDirs().map(async (directory) => {
      let entries: Awaited<ReturnType<typeof readdir>>;
      try {
        entries = await readdir(directory, { withFileTypes: true });
      } catch {
        return;
      }
      await Promise.all(
        entries.map(async (entry) => {
          if (!entry.isFile() || !extensions.has(extensionOf(entry.name))) return;
          const path = join(directory, entry.name);
          let metadata: Stats;
          try {
            metadata = await stat(path);
          } catch {
            return;
          }
          if (metadata.mtimeMs < cutoff) return;
          media.push({
            path,
            name: entry.name,
            modifiedMs: metadata.mtimeMs,
            size: metadata.size,
            fromFallback: true,
          });
        }),
      );
    }),
  );

  return media.sort((left, right) => right.modifiedMs - left.modifiedMs);
}

async function convertAll(
  pi: ExtensionAPI,
  files: MediaFile[],
): Promise<MediaFile[]> {
  return Promise.all(files.map((file) => convertIfNeeded(pi, file)));
}

function sourceSuffix(file: MediaFile): string {
  return file.fromFallback ? ` · ${basename(dirname(file.path))}` : "";
}

/** Hand back a Pi-readable sibling for HEIC/HEIF photos (Pi reads PNG/JPEG/GIF/WebP only). */
async function convertIfNeeded(
  pi: ExtensionAPI,
  file: MediaFile,
): Promise<MediaFile> {
  if (!CONVERTIBLE_EXTENSIONS.has(extensionOf(file.name))) return file;

  const target = file.path.replace(/\.[^./\\]+$/, ".jpg");
  try {
    const existing = await stat(target);
    if (existing.mtimeMs >= file.modifiedMs) {
      return {
        ...file,
        path: target,
        name: basename(target),
        modifiedMs: existing.mtimeMs,
        size: existing.size,
      };
    }
  } catch {
    // No converted sibling yet.
  }

  try {
    const result = await pi.exec(
      "sips",
      ["-s", "format", "jpeg", file.path, "--out", target],
      { timeout: 60_000 },
    );
    if (result.code !== 0) return file;
    await chmod(target, 0o600);
    const metadata = await stat(target);
    return {
      path: target,
      name: basename(target),
      modifiedMs: metadata.mtimeMs,
      size: metadata.size,
      fromFallback: file.fromFallback,
    };
  } catch {
    return file;
  }
}

function mergeMedia(...groups: MediaFile[][]): MediaFile[] {
  return groups.flat().sort((left, right) => right.modifiedMs - left.modifiedMs);
}

/// Newest file in a newest-first list, or 0 when the list is empty.
function newestMs(media: MediaFile[]): number {
  return media[0]?.modifiedMs ?? 0;
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

  let error: string | undefined;
  try {
    const result = await pi.exec("tailscale", commandArgs, {
      timeout: wait ? WAIT_TIMEOUT_MS : RECEIVE_TIMEOUT_MS,
    });
    if (result.code !== 0) {
      error =
        result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }

  const media = await listMedia(directory, extensions);
  const fallback = await listFallbackMedia(extensions);
  const received = error
    ? []
    : media.filter((file) => before.get(file.path) !== file.modifiedMs);
  return { media, received, fallback, ...(error ? { error } : {}) };
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
        const media = mergeMedia(
          await listMedia(directory, config.extensions),
          await listFallbackMedia(config.extensions),
        );
        if (media.length === 0) {
          ctx.ui.notify(
            `No supported ${config.nounPlural} in ${directory} or ${fallbackDirs().join(", ")}`,
            "warning",
          );
          return;
        }
        const summary = media
          .slice(0, 5)
          .map(
            (file) =>
              `${file.name} (${formatSize(file.size)}, ${formatAge(file.modifiedMs)})${sourceSuffix(file)}`,
          )
          .join("\n");
        ctx.ui.notify(summary, "info");
        return;
      }

      if (action === "latest") {
        const media = mergeMedia(
          await listMedia(directory, config.extensions),
          await listFallbackMedia(config.extensions),
        );
        if (media.length === 0) {
          ctx.ui.notify(
            `No supported ${config.nounPlural} in ${directory} or ${fallbackDirs().join(", ")}`,
            "warning",
          );
          return;
        }
        const chosen = await convertIfNeeded(pi, media[0]);
        pastePaths([chosen.path], ctx);
        ctx.ui.notify(`Added ${chosen.name}`, "info");
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
          const candidates = mergeMedia(result.media, result.fallback).slice(
            0,
            PICK_LIMIT,
          );
          if (candidates.length === 0) {
            ctx.ui.notify(
              `No supported ${config.nounPlural} in ${directory} or ${fallbackDirs().join(", ")}`,
              "warning",
            );
            return;
          }
          const labels = candidates.map(
            (file, index) =>
              `${index + 1}. ${file.name} · ${formatSize(file.size)} · ${formatAge(file.modifiedMs)}${sourceSuffix(file)}`,
          );
          const choice = await ctx.ui.select(config.selectTitle, labels);
          if (!choice) return;
          const selected = candidates[labels.indexOf(choice)];
          if (!selected) return;
          const chosen = await convertIfNeeded(pi, selected);
          pastePaths([chosen.path], ctx);
          ctx.ui.notify(`Added ${chosen.name}`, "info");
          return;
        }

        if (action === "all") {
          const previousBatch = new Set(lastBatchPaths);
          let batch =
            result.received.length > 0
              ? result.received
              : result.media.filter((file) => previousBatch.has(file.path));
          if (batch.length === 0) {
            // The macOS app delivered the batch straight to the fallback folder.
            const floor = newestMs(result.media);
            const fresh = result.fallback.filter(
              (file) => file.modifiedMs > floor,
            );
            if (fresh.length > 0) {
              const batchWindowMs = envMilliseconds(
                "PI_TAILDROP_BATCH_WINDOW",
                2 * 60_000,
              );
              const newest = fresh[0].modifiedMs;
              batch = fresh.filter(
                (file) => newest - file.modifiedMs <= batchWindowMs,
              );
            }
          }
          if (batch.length === 0) {
            ctx.ui.notify(config.allEmptyHint, "warning");
            return;
          }
          const ordered = [...batch].sort(
            (left, right) => left.modifiedMs - right.modifiedMs,
          );
          const chosen = await convertAll(pi, ordered);
          pastePaths(
            chosen.map((file) => file.path),
            ctx,
          );
          ctx.ui.notify(`Added ${chosen.length} ${config.nounPlural}`, "info");
          return;
        }

        const floor = newestMs(result.media);
        const fromFallback =
          result.received.length === 0
            ? result.fallback.find((file) => file.modifiedMs > floor)
            : undefined;
        const pending = result.received[0] ?? fromFallback ?? result.media[0];
        if (!pending) {
          ctx.ui.notify(config.unsupportedHint, "warning");
          return;
        }
        const selected = await convertIfNeeded(pi, pending);
        pastePaths([selected.path], ctx);
        const label =
          result.received.length > 0 || fromFallback
            ? "Received"
            : "Added latest";
        ctx.ui.notify(
          `${label} ${selected.name} (${formatSize(selected.size)})${sourceSuffix(selected)}`,
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
