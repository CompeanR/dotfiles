import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const DIGEST = 'mcp__findings__digest'

const summary = atom({ plugin: 'findings', key: 'summary' } as const, '')

const PROTOCOL = `# Summary card
When long or complex work ends in a long answer, more than about 20 lines, call the ${DIGEST} tool right before your final answer with 2 to 4 short sentences in plain words: what the user asked, what you did or found, and what is waiting on them. Someone who reads only the card must understand the outcome. Then answer for depth without restating it. This holds under every output style, Concise included.
Short answers get no summary.`

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({
      name: 'digest',
      description:
        'Put a plain-language summary above the prompt, right before a long final answer. Never for answers of about 20 lines or fewer.',
      inputSchema: {
        type: 'object',
        properties: {
          summary: {
            type: 'string',
            description:
              '2 to 4 short sentences in plain words: what the user asked, what you did or found, what is waiting on them.',
          },
        },
        required: ['summary'],
      },
      isDeferred: false,
    })

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, summary, () => '')
    }

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.command === undefined && e.isMeta === undefined) {
      await update($, summary, () => '')
    }

    return next(e)
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!e.tools.includes(DIGEST)) {
      return composed
    }

    return { sections: [...composed.sections, { id: 'findings:protocol', text: PROTOCOL, scope: 'session' }] }
  })

  on('tool.call', { tool: DIGEST }, async ($, e) => {
    const text = typeof e.summary === 'string' ? e.summary.trim() : ''
    if (text === '') {
      return { deny: 'Give the summary as 2 to 4 short sentences.' }
    }
    await update($, summary, () => text)

    return { result: 'Shown above the prompt. Now give your answer for depth, without restating it.' }
  }).catch(() => ({ deny: 'The summary could not be shown.' }))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const text = await read($, summary)
    if (e.props.hasSurvey || text === '') {
      return next(e)
    }

    const { Box, Text, Button } = $.ui.resolve(e)
    const copy = async (surface: typeof e.surface) => {
      const copied = await $.ui.copy({ text, surface })
      $.ui.toast(copied.isCopied ? 'Summary copied' : `Could not copy: ${copied.reason}`)
    }

    return (
      <Box flexDirection="column" borderStyle="round" borderDimColor paddingX={1}>
        <Box flexDirection="row" gap={2}>
          <Text dimColor>SUMMARY</Text>
          <Box flexGrow={1} />
          <Button key="copy" label="copy" plain hotkey="c" onPress={event => copy(event.surface)} />
          <Button key="close" label="close" plain hotkey="x" onPress={() => update($, summary, () => '')} />
        </Box>
        <Text>{text}</Text>
      </Box>
    )
  })
}
