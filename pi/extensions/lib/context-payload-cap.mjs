export const MAX_TOOL_ARGS_CHARS = 2048
export const MAX_TOOL_RESULT_CHARS = 8192
// ponytail: 2k/8k head caps; if a later turn needs the omitted tail, raise these or keep-full for the latest toolCallId.

const LARGE_ARG_KEYS = ["task", "workflowScript", "content", "command", "prompt", "message"]

export function capText(text, max) {
    if (typeof text !== "string" || text.length <= max) return text
    const omitted = text.length - max
    return `${text.slice(0, max)}\n[truncated ${omitted} chars]`
}

function jsonSize(value) {
    try {
        return JSON.stringify(value).length
    } catch {
        return Number.POSITIVE_INFINITY
    }
}

export function capToolArguments(args) {
    if (args == null || typeof args !== "object") {
        if (typeof args === "string") return capText(args, MAX_TOOL_ARGS_CHARS)
        return args
    }

    if (jsonSize(args) <= MAX_TOOL_ARGS_CHARS) return args

    const next = Array.isArray(args) ? args.map((item) => capToolArguments(item)) : { ...args }
    if (!Array.isArray(next)) {
        for (const key of LARGE_ARG_KEYS) {
            if (typeof next[key] === "string") next[key] = capText(next[key], MAX_TOOL_ARGS_CHARS)
        }
    }
    if (jsonSize(next) <= MAX_TOOL_ARGS_CHARS + 80) return next

    const encoded = typeof args === "string" ? args : JSON.stringify(args)
    return {
        _capped: true,
        chars: encoded.length,
        preview: encoded.slice(0, MAX_TOOL_ARGS_CHARS),
    }
}

export function capToolResultContent(content) {
    if (typeof content === "string") return capText(content, MAX_TOOL_RESULT_CHARS)
    if (!Array.isArray(content)) return content

    let changed = false
    const next = content.map((block) => {
        if (!block || typeof block !== "object") return block
        if (block.type === "text" && typeof block.text === "string" && block.text.length > MAX_TOOL_RESULT_CHARS) {
            changed = true
            return { ...block, text: capText(block.text, MAX_TOOL_RESULT_CHARS) }
        }
        return block
    })
    return changed ? next : content
}

function capAssistantContent(content) {
    if (!Array.isArray(content)) return content
    let changed = false
    const next = content.map((block) => {
        if (!block || typeof block !== "object" || (block.type !== "toolCall" && !block.arguments)) return block
        const cappedArgs = capToolArguments(block.arguments)
        if (cappedArgs === block.arguments) return block
        changed = true
        return { ...block, arguments: cappedArgs }
    })
    return changed ? next : content
}

export function capContextMessages(messages) {
    if (!Array.isArray(messages)) return messages

    let changed = false
    const next = messages.map((message) => {
        if (!message || typeof message !== "object") return message
        if (message.role === "assistant") {
            const content = capAssistantContent(message.content)
            if (content === message.content) return message
            changed = true
            return { ...message, content }
        }
        if (message.role === "toolResult") {
            const content = capToolResultContent(message.content)
            if (content === message.content) return message
            changed = true
            return { ...message, content }
        }
        return message
    })
    return changed ? next : messages
}
