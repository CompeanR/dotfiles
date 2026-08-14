import assert from "node:assert/strict"
import test from "node:test"
import { fileURLToPath } from "node:url"
import { createJiti } from "../pi/npm/node_modules/jiti/lib/jiti.mjs"
import {
    MAX_TOOL_ARGS_CHARS,
    MAX_TOOL_RESULT_CHARS,
    capContextMessages,
    capText,
    capToolArguments,
    capToolResultContent,
} from "../pi/extensions/lib/context-payload-cap.mjs"

const extensionPath = fileURLToPath(new URL("../pi/extensions/context-payload-cap.ts", import.meta.url))
const contextPayloadCap = createJiti(import.meta.url)(extensionPath).default

function loadExtension() {
    const handlers = new Map()
    contextPayloadCap({
        on(name, handler) {
            handlers.set(name, handler)
        },
    })
    return handlers
}

test("caps a parent-replayed work-verify brief instead of keeping the full payload", () => {
    const workflowScript = `return await runs.run('main', { agent: 'work-verify', task: ${JSON.stringify("X".repeat(50_000))} });`
    const messages = [
        { role: "user", content: "build the Debug client" },
        {
            role: "assistant",
            content: [
                { type: "text", text: "Launching verify" },
                {
                    type: "toolCall",
                    id: "call-verify",
                    name: "subagent",
                    arguments: { async: false, context: "fresh", workflowScript },
                },
            ],
        },
        {
            role: "toolResult",
            toolName: "subagent",
            toolCallId: "call-verify",
            content: [{ type: "text", text: "Y".repeat(200_000) }],
        },
        { role: "user", content: "what are you going to verify man? haha" },
    ]

    const originalSize = JSON.stringify(messages).length
    const capped = capContextMessages(messages)
    const cappedSize = JSON.stringify(capped).length

    assert.equal(JSON.stringify(messages).length, originalSize, "must not mutate the stored session copy")
    assert.ok(cappedSize < 20_000, `capped parent context must stay small, got ${cappedSize}`)
    assert.equal(JSON.stringify(capped[3]), JSON.stringify(messages[3]))
    assert.doesNotMatch(JSON.stringify(capped), /X{10000}/)
    assert.doesNotMatch(JSON.stringify(capped), /Y{20000}/)
})

test("argument and result caps are deterministic and bounded", () => {
    const args = { workflowScript: "Z".repeat(MAX_TOOL_ARGS_CHARS + 5000), task: "ok" }
    const first = capToolArguments(args)
    const second = capToolArguments(args)
    assert.deepEqual(first, second)
    assert.ok(JSON.stringify(first).length <= MAX_TOOL_ARGS_CHARS + 80)
    assert.equal(args.workflowScript.length, MAX_TOOL_ARGS_CHARS + 5000)

    const result = capToolResultContent([{ type: "text", text: "Q".repeat(MAX_TOOL_RESULT_CHARS + 9000) }])
    assert.equal(result[0].type, "text")
    assert.ok(result[0].text.length <= MAX_TOOL_RESULT_CHARS + 80)
    assert.match(result[0].text, /truncated/)
})

test("small payloads pass through unchanged", () => {
    const args = { agent: "work-explore", task: "Inspect the parser seam" }
    assert.deepEqual(capToolArguments(args), args)
    assert.equal(capText("short", 100), "short")
    const content = [{ type: "text", text: "ok" }]
    assert.deepEqual(capToolResultContent(content), content)
})

test("context and tool_result extension hooks return capped copies", () => {
    const handlers = loadExtension()
    const huge = {
        messages: [{
            role: "toolResult",
            toolName: "mem_search",
            toolCallId: "m1",
            content: [{ type: "text", text: "M".repeat(120_000) }],
        }],
    }

    const contextResult = handlers.get("context")(huge)
    assert.ok(JSON.stringify(contextResult.messages).length < 20_000)
    assert.equal(huge.messages[0].content[0].text.length, 120_000)

    const toolResult = handlers.get("tool_result")({
        toolName: "mem_search",
        toolCallId: "m1",
        content: [{ type: "text", text: "M".repeat(120_000) }],
        isError: false,
    })
    assert.ok(toolResult.content[0].text.length <= MAX_TOOL_RESULT_CHARS + 80)
})
