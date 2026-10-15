export type FindingKind = 'needs-you' | 'decision' | 'gotcha' | 'fact'

export type Finding = { id: string; kind: FindingKind; text: string }

declare module 'claude-code' {
  interface PluginState {
    findings: {
      notes: Finding[]
      isExpanded: boolean
      isDismissed: boolean
    }
  }
}
