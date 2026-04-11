// Pin the Claude auth plugin to an exact dependency version installed from
// ~/.config/opencode/package.json instead of loading the npm plugin by name.
export { ClaudeAuthPlugin, default } from "opencode-claude-auth"
