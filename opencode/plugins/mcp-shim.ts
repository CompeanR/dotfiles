/**
 * MCP shim — Cursor-compatible meta-tool for OpenCode
 *
 * Composer and other Cursor-trained models call a generic `mcp` tool with
 * { server, toolName, arguments }. OpenCode exposes flat MCP tool names instead
 * (engram_mem_search, mcp__engram__mem_search, …), which routes to `invalid`
 * and loops. This plugin registers `mcp` and forwards calls to configured
 * MCP servers from opencode.json.
 */

import { existsSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { spawn } from "node:child_process"
import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin/tool"

type McpLocalConfig = {
  name: string
  type: "local"
  command: string[]
  environment?: Record<string, string>
  timeout?: number
}

type McpRemoteConfig = {
  name: string
  type: "remote"
  url: string
  headers?: Record<string, string>
  timeout?: number
}

type McpServerConfig = McpLocalConfig | McpRemoteConfig

type McpCallArgs = {
  server?: string
  serverName?: string
  providerIdentifier?: string
  toolName?: string
  tool?: string
  name?: string
  arguments?: Record<string, unknown>
  args?: Record<string, unknown>
}

const MCPTOOL_BIN = process.env.MCPTOOL_BIN ?? "mcptool"
const DEFAULT_TIMEOUT_MS = Number(process.env.MCP_SHIM_TIMEOUT_MS ?? 30000)

function resolveConfigPath(): string {
  const xdg = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config")
  return join(xdg, "opencode", "opencode.json")
}

function readMcpConfigs(): McpServerConfig[] {
  const configPath = resolveConfigPath()
  if (!existsSync(configPath)) return []

  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(readFileSync(configPath, "utf8"))
  } catch {
    return []
  }

  const mcpSection = parsed.mcp
  if (!mcpSection || typeof mcpSection !== "object" || Array.isArray(mcpSection)) {
    return []
  }

  const configs: McpServerConfig[] = []
  for (const [name, entry] of Object.entries(mcpSection as Record<string, unknown>)) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
    const e = entry as Record<string, unknown>
    if (e.enabled === false) continue

    if (e.type === "local" && Array.isArray(e.command) && e.command.length > 0) {
      configs.push({
        name,
        type: "local",
        command: e.command as string[],
        environment: isStringRecord(e.environment) ? e.environment : undefined,
        timeout: typeof e.timeout === "number" ? e.timeout : undefined,
      })
      continue
    }

    if (e.type === "remote" && typeof e.url === "string") {
      configs.push({
        name,
        type: "remote",
        url: e.url,
        headers: isStringRecord(e.headers) ? e.headers : undefined,
        timeout: typeof e.timeout === "number" ? e.timeout : undefined,
      })
    }
  }

  return configs
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function normalizeKey(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "")
}

function resolveServerName(input: string, servers: string[]): string | null {
  const aliases: Record<string, string> = {
    "plugin-engram-engram": "engram",
    "pluginengramengram": "engram",
  }

  const aliasTarget = aliases[normalizeKey(input)]
  if (aliasTarget) {
    const resolved = resolveServerName(aliasTarget, servers)
    if (resolved) return resolved
  }

  const exact = servers.find((s) => s === input)
  if (exact) return exact

  const ci = servers.find((s) => s.toLowerCase() === input.toLowerCase())
  if (ci) return ci

  const inputKey = normalizeKey(input)
  for (const server of servers) {
    const serverKey = normalizeKey(server)
    if (inputKey === serverKey || inputKey.endsWith(serverKey) || inputKey.includes(serverKey)) {
      return server
    }
  }

  return null
}

function normalizeToolName(raw: string): string {
  return raw.replace(/^mcp__[^_]+__/, "").replace(/-/g, "_")
}

function parseFlatPluginToolName(raw: string): { server: string | null; toolName: string | null } {
  // e.g. plugin-engram-engram-mem_context → engram / mem_context
  const match = raw.match(/^plugin-([a-z0-9-]+?)-((?:mem|mcp)_[a-z0-9_]+)$/i)
  if (!match) {
    return { server: null, toolName: null }
  }
  return {
    server: match[1].replace(/-/g, "_").replace(/^engram_engram$/, "engram"),
    toolName: normalizeToolName(match[2]),
  }
}

function normalizeMcpCall(raw: McpCallArgs): {
  server: string | null
  toolName: string | null
  toolArgs: Record<string, unknown>
} {
  const serverCandidate =
    (typeof raw.server === "string" && raw.server.trim().length > 0 ? raw.server.trim() : null)
    ?? (typeof raw.providerIdentifier === "string" && raw.providerIdentifier.trim().length > 0
      ? raw.providerIdentifier.trim()
      : null)
    ?? (typeof raw.serverName === "string" && raw.serverName.trim().length > 0
      ? raw.serverName.trim()
      : null)

  const toolCandidate =
    raw.toolName
    ?? raw.tool
    ?? raw.name
    ?? null

  let server = serverCandidate
  let toolName = typeof toolCandidate === "string" && toolCandidate.trim().length > 0
    ? normalizeToolName(toolCandidate.trim())
    : null

  if ((!server || !toolName) && typeof toolCandidate === "string") {
    const parsed = parseFlatPluginToolName(toolCandidate.trim())
    server = server ?? parsed.server
    toolName = toolName ?? parsed.toolName
  }

  // plugin-engram-engram → engram (handled again at call time via resolveServerName)
  if (server && normalizeKey(server) === "pluginengramengram") {
    server = "engram"
  }

  const toolArgs = isRecord(raw.arguments)
    ? raw.arguments
    : isRecord(raw.args)
      ? raw.args
      : {}

  return { server, toolName, toolArgs }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function formatMcpResult(result: unknown): string {
  if (typeof result === "string") return result

  const content = isRecord(result) ? result.content : undefined
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!isRecord(part)) return JSON.stringify(part)
        if (part.type === "text" && typeof part.text === "string") return part.text
        return JSON.stringify(part)
      })
      .join("\n")
  }

  return JSON.stringify(result)
}

async function loadMcpSdk(): Promise<{
  Client: new (...args: any[]) => any
  StdioClientTransport: new (...args: any[]) => any
  StreamableHTTPClientTransport: new (...args: any[]) => any
}> {
  const [{ Client }, { StdioClientTransport }, { StreamableHTTPClientTransport }] = await Promise.all([
    import("@modelcontextprotocol/sdk/client/index.js"),
    import("@modelcontextprotocol/sdk/client/stdio.js"),
    import("@modelcontextprotocol/sdk/client/streamableHttp.js"),
  ])
  return { Client, StdioClientTransport, StreamableHTTPClientTransport }
}

class McpShimManager {
  private configs: McpServerConfig[]
  private connections = new Map<string, { client: any; config: McpServerConfig }>()
  private sdkPromise: ReturnType<typeof loadMcpSdk> | null = null

  constructor(configs: McpServerConfig[]) {
    this.configs = configs
  }

  private getConfig(serverName: string): McpServerConfig | undefined {
    return this.configs.find((c) => c.name === serverName)
  }

  private async getSdk() {
    if (!this.sdkPromise) this.sdkPromise = loadMcpSdk()
    return this.sdkPromise
  }

  private async connect(serverName: string): Promise<void> {
    if (this.connections.has(serverName)) return

    const config = this.getConfig(serverName)
    if (!config) {
      throw new Error(`Unknown MCP server "${serverName}". Configured: ${this.configs.map((c) => c.name).join(", ") || "none"}`)
    }

    const { Client, StdioClientTransport, StreamableHTTPClientTransport } = await this.getSdk()
    const client = new Client({ name: "opencode-mcp-shim", version: "1.0.0" }, { capabilities: {} })

    if (config.type === "local") {
      const transport = new StdioClientTransport({
        command: config.command[0],
        args: config.command.slice(1),
        env: { ...process.env, ...(config.environment ?? {}) },
        stderr: "pipe",
      })
      await client.connect(transport)
    } else {
      const transport = new StreamableHTTPClientTransport(new URL(config.url), {
        requestInit: config.headers ? { headers: config.headers } : undefined,
      })
      await client.connect(transport)
    }

    this.connections.set(serverName, { client, config })
  }

  private async callViaMcptool(
    serverName: string,
    toolName: string,
    toolArgs: Record<string, unknown>,
  ): Promise<string> {
    const timeoutMs = this.getConfig(serverName)?.timeout ?? DEFAULT_TIMEOUT_MS

    return new Promise((resolve, reject) => {
      const proc = spawn(
        MCPTOOL_BIN,
        ["call", serverName, toolName, JSON.stringify(toolArgs)],
        { stdio: ["ignore", "pipe", "pipe"] },
      )

      let stdout = ""
      let stderr = ""
      const timer = setTimeout(() => {
        proc.kill()
        reject(new Error(`mcptool timed out after ${timeoutMs}ms`))
      }, timeoutMs)

      proc.stdout.on("data", (chunk) => { stdout += String(chunk) })
      proc.stderr.on("data", (chunk) => { stderr += String(chunk) })

      proc.on("error", (error) => {
        clearTimeout(timer)
        reject(error)
      })

      proc.on("close", (exitCode) => {
        clearTimeout(timer)
        const output = stdout.trim() || stderr.trim()
        if (exitCode !== 0) {
          reject(new Error(output || `mcptool exited with code ${exitCode}`))
          return
        }
        if (output.startsWith("Error:")) {
          reject(new Error(output))
          return
        }
        resolve(output)
      })
    })
  }

  async callTool(
    serverInput: string,
    toolName: string,
    toolArgs: Record<string, unknown>,
  ): Promise<string> {
    const serverName = resolveServerName(serverInput, this.configs.map((c) => c.name))
    if (!serverName) {
      throw new Error(
        `Unknown MCP server "${serverInput}". Configured: ${this.configs.map((c) => c.name).join(", ") || "none"}`,
      )
    }

    const config = this.getConfig(serverName)
    if (!config) {
      throw new Error(`MCP server "${serverName}" is not configured`)
    }

    try {
      await this.connect(serverName)
      const conn = this.connections.get(serverName)
      if (!conn) {
        throw new Error(`Failed to connect MCP server "${serverName}"`)
      }

      const result = await conn.client.callTool({
        name: toolName,
        arguments: toolArgs,
      })
      return formatMcpResult(result)
    } catch (error) {
      if (config.type === "local") {
        return this.callViaMcptool(serverName, toolName, toolArgs)
      }
      throw error
    }
  }
}

export const McpShim: Plugin = async () => {
  const configs = readMcpConfigs()
  const manager = new McpShimManager(configs)

  return {
    tool: {
      mcp: tool({
        description:
          "Call an MCP tool by server name and tool name (Cursor-compatible). "
          + "Example: server=engram, toolName=mem_search, arguments={query:\"tmux\"}. "
          + "You can also call flat OpenCode tool names directly (e.g. engram_mem_search).",
        args: {
          server: tool.schema.string().optional().describe("MCP server name (e.g. engram, context7, playwright)"),
          providerIdentifier: tool.schema.string().optional().describe("Cursor MCP server identifier (alias for server)"),
          serverName: tool.schema.string().optional().describe("Alias for server"),
          toolName: tool.schema.string().optional().describe("MCP tool name (e.g. mem_current_project, mem_search)"),
          tool: tool.schema.string().optional().describe("Alias for toolName"),
          name: tool.schema.string().optional().describe("Alias for toolName, or flat OpenCode name like plugin-engram-engram-mem_context"),
          arguments: tool.schema.record(tool.schema.string(), tool.schema.any()).optional().describe("Tool arguments object"),
          args: tool.schema.record(tool.schema.string(), tool.schema.any()).optional().describe("Alias for arguments"),
        },
        async execute(rawArgs) {
          const { server, toolName, toolArgs } = normalizeMcpCall(rawArgs)
          if (!server) {
            return "Error: missing required parameter `server`"
          }
          if (!toolName) {
            return "Error: missing required parameter `toolName` (aliases: tool, name)"
          }

          try {
            return await manager.callTool(server, toolName, toolArgs)
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error)
            return `Error calling MCP ${server}/${toolName}: ${message}`
          }
        },
      }),
    },
  }
}

export default McpShim
