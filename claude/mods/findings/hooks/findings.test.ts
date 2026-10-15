import { expect, test } from 'claude-code/testing'
import type { PromptComposeInput } from 'claude-code'

const BAND = {
  plugin: 'findings',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 30,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const PANE = {
  plugin: 'findings',
  component: 'Pane',
  requestId: 'findings',
  props: {
    title: 'Findings',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const COMPOSE: PromptComposeInput = {
  model: 'claude-opus-5-5',
  promptModel: 'claude-opus-5-5',
  surfaces: ['terminal'],
  tools: [],
  outputStyle: null,
  traits: [],
}

const NOTE = { tool: 'mcp__findings__note', tool_use_id: 'u1', kind: 'needs-you', text: 'Set DATABASE_URL' } as const

test('a note shows in the pane, with a one-line summary above the prompt', async $ => {
  const result = await $.tool.call(NOTE)
  expect(result.deny).toBeUndefined()

  for (const surface of ['terminal', 'desktop'] as const) {
    const pane = await $.ui.mount({ ...PANE, surface })
    expect(await pane.find({ text: /NEEDS YOU · 1/ })).toBeDefined()
    await pane.unmount()
    const band = await $.ui.mount({ ...BAND, surface })
    expect(await band.find({ text: /1 need you/ })).toBeDefined()
    expect(await band.find({ key: 'open' })).toBeDefined()
    await band.unmount()
  }
})

test('Do it, Apply them and Discuss hand the findings to Claude', async ($, on) => {
  const submitted: string[] = []
  let drafted = ''
  on('prompt.submit', ($, e) => {
    submitted.push(e.text)
    return { text: e.text }
  })
  on('prompt.fill', ($, e) => {
    drafted = e.text
    return { isFilled: true }
  })

  await $.tool.call(NOTE)
  await $.tool.call({ ...NOTE, kind: 'decision', text: 'Keep per-feature folders' })
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await pane.press({ key: 'do-needs' })
  await pane.press({ key: 'apply-decisions' })
  await pane.press({ key: 'discuss-decisions' })

  expect(submitted).toEqual([
    'Go ahead and do these yourself:\n- Set DATABASE_URL',
    'Apply these decisions:\n- Keep per-feature folders',
  ])
  expect(drafted).toContain('- Keep per-feature folders')
})

test('a note with an unknown kind is refused', async $ => {
  const result = await $.tool.call({ ...NOTE, kind: 'todo' })

  expect(typeof result.deny).toBe('string')
})

test('/clear empties the findings', async ($, on) => {
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))

  await $.tool.call(NOTE)
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { isResumable: false } } as never)

  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await pane.find({ text: /No findings yet/ })).toBeDefined()
})

test('compaction is told to keep the findings', async ($, on) => {
  let instructions: string | undefined
  on('session.compact', ($, e) => {
    instructions = e.instructions
    return { messages: e.messages }
  })

  await $.tool.call(NOTE)
  await $.session.compact({ trigger: 'manual', messages: [{ role: 'user', text: 'hi', toolUses: [] }] } as never)

  expect(instructions).toContain('! Set DATABASE_URL')
})

test('the protocol joins the system prompt only where the tool is offered', async ($, on) => {
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'intro', scope: 'shared' }] }))

  const offered = await $.prompt.compose({ ...COMPOSE, tools: ['mcp__findings__note'] })
  const withheld = await $.prompt.compose({ ...COMPOSE, tools: ['Read'] })

  expect(offered.sections.map(one => one.id)).toEqual(['intro', 'findings:protocol'])
  expect(withheld.sections.map(one => one.id)).toEqual(['intro'])
})
