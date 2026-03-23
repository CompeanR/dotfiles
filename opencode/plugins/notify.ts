import type { Plugin } from "@opencode-ai/plugin"

const NOTIFY_CMD =
  process.env.OPENCODE_NOTIFY_CMD ??
  `${process.env.HOME}/.config/opencode/bin/opencode-notify.sh`
const COOLDOWN_MS = parseInt(process.env.OPENCODE_NOTIFY_COOLDOWN_MS ?? "2500")

const lastByKey = new Map<string, number>()
const rootBySessionID = new Map<string, boolean>()
const rootLookupBySessionID = new Map<string, Promise<boolean>>()

function shouldNotify(key: string): boolean {
  const now = Date.now()
  const last = lastByKey.get(key) ?? 0
  if (now - last < COOLDOWN_MS) return false
  lastByKey.set(key, now)
  return true
}

function spawnNotify(args: string[]): void {
  try {
    Bun.spawn([NOTIFY_CMD, ...args], {
      stdout: "ignore",
      stderr: "ignore",
      stdin: "ignore",
    })
  } catch {
    // no-op
  }
}

function cacheSessionRootFromInfo(raw: unknown): void {
  const info = (raw as any)?.info ?? raw
  const sessionID = String((info as any)?.id ?? "")
  if (!sessionID) return
  rootBySessionID.set(sessionID, !(info as any)?.parentID)
}

async function isRootSession(client: any, sessionID: string): Promise<boolean> {
  if (!sessionID) return false

  const cached = rootBySessionID.get(sessionID)
  if (cached !== undefined) return cached

  const inflight = rootLookupBySessionID.get(sessionID)
  if (inflight) return inflight

  const lookup = (async () => {
    try {
      const result = await client.session.get({
        path: { id: sessionID },
      })

      if ((result as any)?.error) return false

      const info = (result as any)?.data ?? result
      const isRoot = !((info as any)?.parentID ?? null)
      rootBySessionID.set(sessionID, isRoot)
      return isRoot
    } catch {
      return false
    } finally {
      rootLookupBySessionID.delete(sessionID)
    }
  })()

  rootLookupBySessionID.set(sessionID, lookup)
  return lookup
}

function toErrorText(raw: unknown): string {
  if (!raw) return ""
  if (typeof raw === "string") return raw
  if (typeof raw === "object") {
    const msg = (raw as any).message
    if (typeof msg === "string") return msg
    try {
      return JSON.stringify(raw)
    } catch {
      return "unknown error"
    }
  }
  return String(raw)
}

function toStringArray(input: unknown): string[] {
  if (Array.isArray(input)) return input.map((v) => String(v))
  if (!input) return []
  return [String(input)]
}

function buildPermissionDetail(raw: any): string {
  const permissionType = String(raw?.permission ?? raw?.type ?? "permission")
  const patterns = toStringArray(raw?.patterns ?? raw?.pattern).filter(Boolean)
  const title = typeof raw?.title === "string" ? raw.title : ""
  const snippet =
    patterns[0] ??
    title ??
    (typeof raw?.metadata?.tool === "string" ? raw.metadata.tool : "") ??
    ""

  return snippet ? `${permissionType} — ${snippet}` : permissionType
}

export const Notify: Plugin = async ({ client }) => {
  return {
    event: async ({ event }) => {
      if (event.type === "session.created" || event.type === "session.updated") {
        cacheSessionRootFromInfo(event.properties)
        return
      }

      if (event.type === "session.deleted") {
        const info = (event.properties as any)?.info ?? event.properties
        const sessionID = String((info as any)?.id ?? "")
        if (sessionID) {
          rootBySessionID.delete(sessionID)
          rootLookupBySessionID.delete(sessionID)
        }
        return
      }

      if (event.type === "session.idle") {
        const sessionID = (event.properties as any)?.sessionID ?? ""
        if (!(await isRootSession(client, sessionID))) return
        const key = `completed:${sessionID || "none"}`
        if (!shouldNotify(key)) return
        spawnNotify(["completed", sessionID])
        return
      }

      if (event.type === "session.error") {
        const sessionID = (event.properties as any)?.sessionID ?? ""
        const errorText = toErrorText((event.properties as any)?.error)
        const key = `error:${sessionID || "none"}:${errorText.slice(0, 80)}`
        if (!shouldNotify(key)) return
        spawnNotify(["error", sessionID, errorText])
        return
      }

      if (event.type === "permission.updated" || event.type === "permission.asked") {
        const props = (event.properties as any) ?? {}
        const sessionID = String(props.sessionID ?? "")
        const requestID = String(props.id ?? "")
        const detail = buildPermissionDetail(props)
        const key = `permission_ask:${requestID || `${sessionID}:${detail.slice(0, 80)}`}`
        if (!shouldNotify(key)) return
        spawnNotify(["permission_ask", sessionID, detail, requestID])
      }
    },
  }
}

export default Notify
