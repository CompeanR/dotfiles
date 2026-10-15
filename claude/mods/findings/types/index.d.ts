export type FindingKind = 'needs-you' | 'next' | 'decision' | 'gotcha' | 'fact'

export type Finding = { id: string; kind: FindingKind; text: string }

declare module 'claude-code' {
  interface PluginState {
    findings: {
      notes: Finding[]
      nextId: number
      summary: string
      isHidden: boolean
    }
  }
}
