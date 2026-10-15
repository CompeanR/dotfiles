import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Finding } from '../types'

const TOOL = 'mcp__findings__note'

const notes = atom({ plugin: 'findings', key: 'notes' } as const, [])
const isExpanded = atom({ plugin: 'findings', key: 'isExpanded' } as const, false)
const isDismissed = atom({ plugin: 'findings', key: 'isDismissed' } as const, false)

const KINDS = [
  { kind: 'needs-you', label: 'NEEDS YOU', mark: '!', color: 'warning' },
  { kind: 'decision', label: 'DECISIONS', mark: '◆', color: 'claude' },
  { kind: 'gotcha', label: 'GOTCHAS', mark: '▲', color: 'error' },
  { kind: 'fact', label: 'FACTS', mark: '·', color: 'inactive' },
] as const

const PROTOCOL = `# Findings
For any task that takes more than a few steps, call the ${TOOL} tool the moment you learn something the user must not lose:
- needs-you: something they have to do, decide or provide
- decision: a choice you made or propose, and why
- gotcha: a surprise, a risk or a workaround
- fact: a fact that shapes the work
One short sentence each, written for the user. Skip routine progress.

When such a task ends, answer in this order:
1. The result, in one or two lines.
2. "What you need to know": every finding that still matters, needs-you first.
3. "Details": the technical specifics, kept short.
A short task with no findings keeps a plain short answer.
This shape holds under every output style, Concise included. "What you need to know" is not a recap: the user may not have read the narration, so list each finding there even if you mentioned it earlier.`

const byKind = (list: readonly Finding[]) =>
  KINDS.map(group => ({ ...group, items: list.filter(one => one.kind === group.kind) })).filter(
    group => group.items.length > 0,
  )

const toMarkdown = (list: readonly Finding[]) =>
  byKind(list)
    .map(group => [`**${group.label}**`, ...group.items.map(one => `${group.mark} ${one.text}`)].join('\n'))
    .join('\n\n')

const bullets = (list: readonly Finding[], kind: Finding['kind']) =>
  list
    .filter(one => one.kind === kind)
    .map(one => `- ${one.text}`)
    .join('\n')

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'findings',
      description: 'Show or hide the findings above the prompt, or clear them with /findings clear',
      argumentHint: '[clear]',
    })
    await $.tool.register({
      name: 'note',
      description:
        'Record a finding the user must not lose during a multi-step task. It shows above their prompt right away.',
      inputSchema: {
        type: 'object',
        properties: {
          kind: {
            type: 'string',
            enum: KINDS.map(group => group.kind),
            description:
              'needs-you: they must act, decide or provide something. decision: a choice made or proposed, and why. gotcha: a surprise, risk or workaround. fact: a fact that shapes the work.',
          },
          text: { type: 'string', description: 'One short sentence, written for the user.' },
        },
        required: ['kind', 'text'],
      },
      isDeferred: false,
    })

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, notes, () => [])
    }

    return next(e)
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!e.tools.includes(TOOL)) {
      return composed
    }

    return { sections: [...composed.sections, { id: 'findings:protocol', text: PROTOCOL, scope: 'session' }] }
  })

  on('session.compact', async ($, e, next) => {
    const list = await read($, notes)
    if (e.agentId !== undefined || list.length === 0) {
      return next(e)
    }
    const keep = `Keep these findings verbatim in the summary:\n${toMarkdown(list)}`

    return next({ ...e, instructions: e.instructions ? `${e.instructions}\n\n${keep}` : keep })
  })

  on('turn.complete', async ($, e, next) => {
    const hasNeeds = (await read($, notes)).some(one => one.kind === 'needs-you')
    if (e.agentId === undefined && hasNeeds && !(await read($, isDismissed))) {
      await update($, isExpanded, () => true)
    }

    return next(e)
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const kind = KINDS.find(group => group.kind === e.kind)?.kind
    const text = typeof e.text === 'string' ? e.text.trim() : ''
    if (kind === undefined || text === '') {
      return { deny: `Give kind as one of ${KINDS.map(group => group.kind).join(', ')} and text as one sentence.` }
    }

    await update($, notes, list => [...list, { id: `${list.length}-${text.slice(0, 24)}`, kind, text }])
    if (kind === 'needs-you') {
      await update($, isDismissed, () => false)
    }

    const result = e.agentId === undefined ? 'Noted.' : 'Noted for the user. Also include it in your final report.'

    return { result }
  }).catch(() => ({ deny: 'The finding could not be recorded.' }))

  on('command.run', { command: 'findings' }, async ($, e) => {
    if (e.args.trim() === 'clear') {
      await update($, notes, () => [])

      return { text: 'Findings cleared.' }
    }
    const expanded = !(await read($, isExpanded))
    await update($, isExpanded, () => expanded)
    if (!expanded) {
      await update($, isDismissed, () => true)
    }

    return { text: expanded ? 'Findings shown.' : 'Findings hidden.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, notes)
    if (e.props.hasSurvey || list.length === 0) {
      return next(e)
    }

    const { Box, Text, Button } = $.ui.resolve(e)
    const needs = list.filter(one => one.kind === 'needs-you')
    const show = () => update($, isExpanded, () => true)
    const hide = async () => {
      await update($, isExpanded, () => false)
      await update($, isDismissed, () => true)
    }

    if (!(await read($, isExpanded))) {
      const latest = list[list.length - 1]

      return (
        <Box flexDirection="row" gap={2}>
          <Box flexShrink={1}>
            <Text wrap="truncate-end">
              Findings <Text dimColor>{list.length} noted</Text>
              {needs.length > 0 && <Text color="warning">{`  ! ${needs.length} need you`}</Text>}
              <Text dimColor>{`  latest: ${latest?.text ?? ''}`}</Text>
            </Text>
          </Box>
          <Button key="show" label="Show" hotkey="s" onPress={show} />
        </Box>
      )
    }

    const send = async (text: string, toast: string) => {
      await $.prompt.submit({ text, asUser: true })
      $.ui.toast(toast)
    }
    const doNeeds = () =>
      send(`Go ahead and do these yourself:\n${bullets(list, 'needs-you')}`, 'Queued: Claude will do them')
    const applyDecisions = () =>
      send(`Apply these decisions:\n${bullets(list, 'decision')}`, 'Queued: apply the decisions')
    const discussDecisions = () =>
      $.prompt.fill({
        text: `Before applying them, let's discuss these decisions:\n${bullets(list, 'decision')}\n\n`,
        mode: 'append',
      })
    const copy = async (surface: typeof e.surface) => {
      const copied = await $.ui.copy({ text: toMarkdown(list), surface })
      $.ui.toast(copied.isCopied ? 'Findings copied' : `Could not copy: ${copied.reason}`)
    }

    return (
      <Box flexDirection="column">
        {byKind(list).map(group => (
          <Box flexDirection="column">
            <Text color={group.color} weight="bold">{`${group.label} · ${group.items.length}`}</Text>
            {group.items.map(one => (
              <Box flexDirection="row" gap={1}>
                <Text color={group.color}>{group.mark}</Text>
                <Box flexShrink={1}>
                  <Text>{one.text}</Text>
                </Box>
              </Box>
            ))}
            {group.kind === 'needs-you' && (
              <Box marginLeft={2}>
                <Button key="do-needs" label="Do it" hotkey="d" onPress={doNeeds} />
              </Box>
            )}
            {group.kind === 'decision' && (
              <Box flexDirection="row" gap={2} marginLeft={2}>
                <Button key="apply-decisions" label="Apply them" hotkey="a" onPress={applyDecisions} />
                <Button key="discuss-decisions" label="Discuss" hotkey="t" onPress={discussDecisions} />
              </Box>
            )}
          </Box>
        ))}
        <Box flexDirection="row" gap={2}>
          <Button key="copy" label="Copy" hotkey="c" onPress={press => copy(press.surface)} />
          <Button key="clear" label="Clear" hotkey="x" onPress={() => update($, notes, () => [])} />
          <Button key="hide" label="Hide" hotkey="h" onPress={hide} />
        </Box>
      </Box>
    )
  })
}
