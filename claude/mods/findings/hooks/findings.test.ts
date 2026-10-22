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

const DIGEST = {
  tool: 'mcp__findings__digest',
  tool_use_id: 'u1',
  summary: 'You asked for search in pi. Web and X are covered; Facebook needs a browser.',
} as const

test('digest shows the summary above the prompt', async $ => {
  expect(typeof (await $.tool.call(DIGEST)).result).toBe('string')

  for (const surface of ['terminal', 'desktop'] as const) {
    const card = await $.ui.mount({ ...CARD, surface })
    expect(await card.find({ text: /SUMMARY/ })).toBeDefined()
    expect(await card.find({ text: /Facebook needs a browser/ })).toBeDefined()
    await card.unmount()
  }
})

test('an empty summary is refused', async $ => {
  const result = await $.tool.call({ ...DIGEST, summary: ' ' })

  expect(typeof result.deny).toBe('string')
})

test('close removes the summary', async ($, on) => {
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)

  await $.tool.call(DIGEST)
  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  await card.press({ key: 'close' })

  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('the next prompt clears the summary', async ($, on) => {
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)
  on('prompt.submit', ($, e) => ({ text: e.text }))

  await $.tool.call(DIGEST)
  await $.prompt.submit({ text: 'merge it' } as never)

  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('/clear empties the summary', async ($, on) => {
  on('ui.render', ($, e) => h($.ui.resolve(e).Text, {}, 'engine band') as never)
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))

  await $.tool.call(DIGEST)
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { isResumable: false } } as never)

  const card = await $.ui.mount({ ...CARD, surface: 'terminal' })
  expect(await card.find({ text: /engine band/ })).toBeDefined()
})

test('the protocol joins the system prompt only where the tool is offered', async ($, on) => {
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'intro', scope: 'shared' }] }))

  const offered = await $.prompt.compose({ ...COMPOSE, tools: ['mcp__findings__digest'] })
  const withheld = await $.prompt.compose({ ...COMPOSE, tools: ['Read'] })

  expect(offered.sections.map(one => one.id)).toEqual(['intro', 'findings:protocol'])
  expect(withheld.sections.map(one => one.id)).toEqual(['intro'])
})
