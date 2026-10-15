import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Finding } from '../types'

const NOTE = 'mcp__findings__note'
const RESOLVE = 'mcp__findings__resolve'
const DIGEST = 'mcp__findings__digest'

const notes = atom({ plugin: 'findings', key: 'notes' } as const, [])
const nextId = atom({ plugin: 'findings', key: 'nextId' } as const, 1)
const summary = atom({ plugin: 'findings', key: 'summary' } as const, '')
const isHidden = atom({ plugin: 'findings', key: 'isHidden' } as const, false)

const KINDS = [
  { kind: 'needs-you', label: 'NEEDS YOU', mark: '!', color: 'warning', button: 'Do it' },
  { kind: 'next', label: 'NEXT STEPS', mark: '→', color: 'success', button: 'Do it' },
  { kind: 'decision', label: 'DECISIONS', mark: '◆', color: 'claude', button: 'Discuss' },
  { kind: 'gotcha', label: 'GOTCHAS', mark: '▲', color: 'error', button: undefined },
  { kind: 'fact', label: 'FACTS', mark: '·', color: 'inactive', button: undefined },
] as const

const PROTOCOL = `# Findings
For any task that takes more than a few steps, or any answer with several moving parts, call the ${NOTE} tool the moment you learn something the user must not lose:
- needs-you: something only the user can do or provide
- next: an action you propose and can do yourself once the user says go, phrased as that action, e.g. "Add the plugin dir to ~/.claude/settings.json". When the user must pick between options, note one next step per option instead of asking a needs-you question.
- decision: a choice you made, and why
- gotcha: a surprise, a risk or a workaround
- fact: a fact that shapes the work
One short sentence each, written for the user. Skip routine progress.
Before your final answer, make sure every proposal or question in it is a next or needs-you finding, so the user can act on it with one key.
Each note answers with its id. The moment a finding stops mattering (you did it, the user picked another option, the gotcha is fixed), call ${RESOLVE} with its id so the user's list only shows what is still open.

When a long or complex task ends, or you give an answer with several moving parts, call the ${DIGEST} tool right before your final answer with a summary the user can read instead of the answer: 2 to 4 short sentences in plain words covering what they asked, what you did or found, what it means for them, and what is waiting on them. Someone who reads only the card must understand the outcome.
The card shows that summary and every open finding with its buttons right under your answer, so the answer is for depth: go straight to the specifics and don't restate the summary or the findings. This holds under every output style, Concise included.
A short task keeps a plain short answer with no digest.`

const byKind = (list: readonly Finding[]) =>
  KINDS.map(group => ({ ...group, items: list.filter(one => one.kind === group.kind) })).filter(
    group => group.items.length > 0,
  )

const toMarkdown = (list: readonly Finding[]) =>
  byKind(list)
    .map(group => [`**${group.label}**`, ...group.items.map(one => `${group.mark} ${one.text}`)].join('\n'))
    .join('\n\n')

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'findings',
      description: 'Show or hide the findings card, or clear it with /findings clear',
      argumentHint: '[clear]',
    })
    await $.tool.register({
      name: 'note',
      description:
        'Record a finding the user must not lose during a multi-step task. It shows on their findings card right away.',
      inputSchema: {
        type: 'object',
        properties: {
          kind: {
            type: 'string',
            enum: KINDS.map(group => group.kind),
            description:
              'needs-you: only the user can do or provide it. next: an action you propose and can do once the user says go, phrased as that action; one per option when they must choose. decision: a choice made, and why. gotcha: a surprise, risk or workaround. fact: a fact that shapes the work.',
          },
          text: { type: 'string', description: 'One short sentence, written for the user.' },
        },
        required: ['kind', 'text'],
      },
      isDeferred: false,
    })
    await $.tool.register({
      name: 'digest',
      description:
        'Put a plain-language summary at the top of the findings card, right before your final answer to a long or complex task.',
      inputSchema: {
        type: 'object',
        properties: {
          summary: {
            type: 'string',
            description:
              '2 to 4 short sentences in plain words: what the user asked, what you did or found, what it means, what is waiting on them.',
          },
        },
        required: ['summary'],
      },
      isDeferred: false,
    })
    await $.tool.register({
      name: 'resolve',
      description:
        "Remove findings from the user's findings card once they no longer matter: done, another option picked, or the gotcha fixed.",
      inputSchema: {
        type: 'object',
        properties: {
          ids: { type: 'array', items: { type: 'string' }, description: 'The ids the note tool answered with.' },
        },
        required: ['ids'],
      },
      isDeferred: false,
    })

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, notes, () => [])
      await update($, summary, () => '')
    }

    return next(e)
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!e.tools.includes(NOTE)) {
      return composed
    }

    return { sections: [...composed.sections, { id: 'findings:protocol', text: PROTOCOL, scope: 'session' }] }
  })

  on('session.compact', async ($, e, next) => {
    const list = await read($, notes)
    if (e.agentId !== undefined || list.length === 0) {
      return next(e)
    }
    const keep = `Keep these open findings verbatim in the summary, with their ids:\n${list
      .map(one => `- [${one.id}] ${one.kind}: ${one.text}`)
      .join('\n')}`

    return next({ ...e, instructions: e.instructions ? `${e.instructions}\n\n${keep}` : keep })
  })

  on('tool.call', { tool: NOTE }, async ($, e) => {
    const kind = KINDS.find(group => group.kind === e.kind)?.kind
    const text = typeof e.text === 'string' ? e.text.trim() : ''
    if (kind === undefined || text === '') {
      return { deny: `Give kind as one of ${KINDS.map(group => group.kind).join(', ')} and text as one sentence.` }
    }

    const id = String(await read($, nextId))
    await update($, nextId, n => n + 1)
    await update($, notes, list => [...list, { id, kind, text }])
    await update($, isHidden, () => false)

    const result =
      e.agentId === undefined
        ? `Noted as ${id}.`
        : `Noted as ${id} for the user. Also include it in your final report.`

    return { result }
  }).catch(() => ({ deny: 'The finding could not be recorded.' }))

  on('tool.call', { tool: DIGEST }, async ($, e) => {
    const text = typeof e.summary === 'string' ? e.summary.trim() : ''
    if (text === '') {
      return { deny: 'Give the summary as 2 to 4 short sentences.' }
    }
    await update($, summary, () => text)
    await update($, isHidden, () => false)

    return { result: 'Shown on the card. Now give your answer for depth, without restating it.' }
  }).catch(() => ({ deny: 'The summary could not be shown.' }))

  on('tool.call', { tool: RESOLVE }, async ($, e) => {
    const ids = Array.isArray(e.ids) ? e.ids.map(String) : []
    const list = await read($, notes)
    const gone = list.filter(one => ids.includes(one.id))
    await update($, notes, all => all.filter(one => !ids.includes(one.id)))

    return { result: `Resolved ${gone.length} of ${ids.length}.` }
  }).catch(() => ({ deny: 'The findings could not be resolved.' }))

  on('command.run', { command: 'findings' }, async ($, e) => {
    if (e.args.trim() === 'clear') {
      await update($, notes, () => [])
      await update($, summary, () => '')

      return { text: 'Findings cleared.' }
    }
    const hidden = !(await read($, isHidden))
    await update($, isHidden, () => hidden)

    return { text: hidden ? 'Findings hidden.' : 'Findings shown.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, notes)
    const digest = await read($, summary)
    if (e.props.hasSurvey || (list.length === 0 && digest === '')) {
      return next(e)
    }

    const { Box, Text, Button } = $.ui.resolve(e)

    if (await read($, isHidden)) {
      const asks = list.filter(one => one.kind === 'needs-you' || one.kind === 'next').length

      return (
        <Box flexDirection="row" gap={2}>
          <Text>
            Findings <Text dimColor>{`${list.length} open`}</Text>
            {asks > 0 && <Text color="warning">{`  ${asks} waiting on you`}</Text>}
          </Text>
          <Button key="show" label="Show" hotkey="s" onPress={() => update($, isHidden, () => false)} />
        </Box>
      )
    }

    const act = async (one: Finding) => {
      if (one.kind === 'decision') {
        await $.prompt.fill({ text: `Let's discuss this decision: ${one.text}\n\n`, mode: 'append' })
        return
      }
      const text = one.kind === 'next' ? `Go ahead: ${one.text}` : `Go ahead and do this yourself: ${one.text}`
      await update($, notes, all => all.filter(other => other.id !== one.id))
      await $.prompt.submit({ text, asUser: true })
    }
    const skip = (one: Finding) => update($, notes, all => all.filter(other => other.id !== one.id))
    const copy = async (surface: typeof e.surface) => {
      const text = digest === '' ? toMarkdown(list) : `**SUMMARY**\n${digest}\n\n${toMarkdown(list)}`
      const copied = await $.ui.copy({ text: text.trim(), surface })
      $.ui.toast(copied.isCopied ? 'Findings copied' : `Could not copy: ${copied.reason}`)
    }

    const clear = async () => {
      await update($, notes, () => [])
      await update($, summary, () => '')
    }

    let index = 0

    return (
      <Box flexDirection="column" borderStyle="round" borderDimColor paddingX={1}>
        <Text>
          <Text weight="bold">Findings</Text> <Text dimColor>{`${list.length} open`}</Text>
        </Text>
        {digest !== '' && (
          <Box flexDirection="column" marginTop={1}>
            <Text weight="bold">SUMMARY</Text>
            <Text>{digest}</Text>
          </Box>
        )}
        {byKind(list).map(group => (
          <Box flexDirection="column" marginTop={1}>
            <Text color={group.color} weight="bold">
              {group.label}
            </Text>
            {group.items.map(one => {
              index += 1
              const hotkey = index <= 9 ? String(index) : undefined

              return (
                <Box flexDirection="column">
                  <Box flexDirection="row" gap={1}>
                    <Text color={group.color}>{group.mark}</Text>
                    <Box flexShrink={1}>
                      <Text>{one.text}</Text>
                    </Box>
                  </Box>
                  {group.button !== undefined && (
                    <Box flexDirection="row" gap={2} marginLeft={2}>
                      <Button key={`act-${one.id}`} label={group.button} hotkey={hotkey} onPress={() => act(one)} />
                      {group.button === 'Do it' && (
                        <Button key={`skip-${one.id}`} label="Skip it" onPress={() => skip(one)} />
                      )}
                    </Box>
                  )}
                </Box>
              )
            })}
          </Box>
        ))}
        <Box flexDirection="row" gap={2} marginTop={1}>
          <Button key="copy" label="Copy" hotkey="c" onPress={press => copy(press.surface)} />
          <Button key="clear" label="Clear" hotkey="x" onPress={clear} />
          <Button key="hide" label="Hide" hotkey="h" onPress={() => update($, isHidden, () => true)} />
        </Box>
      </Box>
    )
  })
}
