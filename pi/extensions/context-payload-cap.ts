import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import { capContextMessages, capToolResultContent } from "./lib/context-payload-cap.mjs"

export default function contextPayloadCap(pi: ExtensionAPI): void {
  pi.on("context", (event) => {
    const messages = capContextMessages(event.messages)
    if (messages === event.messages) return
    return { messages }
  })

  pi.on("tool_result", (event) => {
    const content = capToolResultContent(event.content)
    if (content === event.content) return
    return { content }
  })
}
