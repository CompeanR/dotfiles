import { expect, test } from 'claude-code/testing'
import type { PromptComposeInput } from 'claude-code'

const CARD = {
  plugin: 'findings',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 40,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 40 },
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

test('findings show grouped on the card, one button per actionable item', async $ => {
  expect((await $.tool.call(NOTE)).result).toBe('Noted as 1.')
  await $.tool.call({ ...NOTE, kind: 'next', text: 'Add the plugin dir' })
  await $.tool.call({ ...NOTE, kind: 'gotcha', text: 'Themes are solid only' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const card = await $.ui.mount({ ...CARD, surface })
    expect(await card.find({ text: /3 open/ })).toBeDefined()
    expect(await card.find({ text: /NEXT STEPS/ })).toBeDefined()
    expect(await card.find({ key: 'act-1' })).toBeDefined()
    expect(await card.find({ key: 'act-2' })).toBeDefined()
    expect(await card.find({ key: 'act-3' })).toBeUndefined()
    await card.unmount()
  }
})

test('Do it sends one finding and removes it; Discuss drafts a decision', async ($, on) => {
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

  await $.tool.call({ ...NOTE, kind: 'next', text: 'Add the plugin dir' })
  await $.tool.call({ ...NOTE, kind: 'decision', text: 'Keep per-feature folders' })
  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  await card.press({ key: 'act-2' })
  await card.press({ key: 'act-1' })

  expect(drafted).toBe("Let's discuss this decision: Keep per-feature folders\n\n")
  expect(submitted).toEqual(['Go ahead: Add the plugin dir'])
  expect(await card.find({ key: 'act-1' })).toBeUndefined()
  expect(await card.find({ key: 'act-2' })).toBeDefined()
})

test('Skip it removes a finding without sending anything', async ($, on) => {
  const submitted: string[] = []
  on('prompt.submit', ($, e) => {
    submitted.push(e.text)
    return { text: e.text }
  })

  await $.tool.call({ ...NOTE, kind: 'next', text: 'Add the plugin dir' })
  await $.tool.call({ ...NOTE, kind: 'next', text: 'Port the skill' })
  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  await card.press({ key: 'skip-1' })

  expect(submitted).toEqual([])
  expect(await card.find({ key: 'act-1' })).toBeUndefined()
  expect(await card.find({ key: 'act-2' })).toBeDefined()
})

test('digest puts a plain summary at the top of the card, and Clear removes it', async ($, on) => {
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)

  const result = await $.tool.call({
    tool: 'mcp__findings__digest',
    tool_use_id: 'u4',
    summary: 'You asked for search in pi. Web and X are covered; Facebook needs a browser.',
  })
  expect(typeof result.result).toBe('string')

  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  expect(await card.find({ text: /SUMMARY/ })).toBeDefined()
  expect(await card.find({ text: /Facebook needs a browser/ })).toBeDefined()
  await card.press({ key: 'clear' })
  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('Hide folds the card to one line, Show brings it back', async $ => {
  await $.tool.call(NOTE)
  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  await card.press({ key: 'hide' })
  expect(await card.find({ text: /1 waiting on you/ })).toBeDefined()
  await card.press({ key: 'show' })
  expect(await card.find({ key: 'act-1' })).toBeDefined()
})

test('resolve removes findings by the id the note answered with', async ($, on) => {
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)

  await $.tool.call(NOTE)
  const resolved = await $.tool.call({ tool: 'mcp__findings__resolve', tool_use_id: 'u3', ids: ['1'] })
  expect(resolved.result).toBe('Resolved 1 of 1.')

  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('a note with an unknown kind is refused', async $ => {
  const result = await $.tool.call({ ...NOTE, kind: 'todo' })

  expect(typeof result.deny).toBe('string')
})

test('/clear empties the findings', async ($, on) => {
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)

  await $.tool.call(NOTE)
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { isResumable: false } } as never)

  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('compaction is told to keep the open findings with their ids', async ($, on) => {
  let instructions: string | undefined
  on('session.compact', ($, e) => {
    instructions = e.instructions
    return { messages: e.messages }
  })

  await $.tool.call(NOTE)
  await $.session.compact({ trigger: 'manual', messages: [{ role: 'user', text: 'hi', toolUses: [] }] } as never)

  expect(instructions).toContain('- [1] needs-you: Set DATABASE_URL')
})

test('the protocol joins the system prompt only where the tool is offered', async ($, on) => {
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'intro', scope: 'shared' }] }))

  const offered = await $.prompt.compose({ ...COMPOSE, tools: ['mcp__findings__note'] })
  const withheld = await $.prompt.compose({ ...COMPOSE, tools: ['Read'] })

  expect(offered.sections.map(one => one.id)).toEqual(['intro', 'findings:protocol'])
  expect(withheld.sections.map(one => one.id)).toEqual(['intro'])
})
