export type Summary = string

declare module 'claude-code' {
  interface PluginState {
    findings: {
      summary: Summary
    }
  }
}
