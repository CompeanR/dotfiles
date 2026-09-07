-- Clipboard for sessions whose yanks may need to reach another machine:
-- every copy is emitted as OSC 52 (inside tmux this becomes a tmux buffer,
-- rebroadcast to every attached client, local or SSH). Paste prefers the
-- local Wayland clipboard when one is available, so content copied in other
-- apps remains pasteable; without one it reads back the unnamed register.
--
-- This only installs itself where nvim's own provider cannot do the job, so
-- a plain local session on macOS keeps pbcopy and a plain Linux desktop keeps
-- wl-copy untouched.
local M = {}

local function proc_lines(pid, file)
  local ok, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/" .. file)
  return ok and lines or {}
end

local function proc_ppid(pid)
  for _, line in ipairs(proc_lines(pid, "status")) do
    local ppid = line:match("^PPid:%s+(%d+)")
    if ppid then
      return tonumber(ppid)
    end
  end
end

local function ancestor_process_named(name)
  local pid = vim.fn.getpid()

  for _ = 1, 16 do
    local ppid = proc_ppid(pid)
    if not ppid or ppid <= 1 then
      return false
    end

    local comm = proc_lines(ppid, "comm")[1] or ""
    if comm:find(name, 1, true) then
      return true
    end

    pid = ppid
  end

  return false
end

function M.setup()
  local in_tmux = vim.env.TMUX ~= nil
  local in_ssh = vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil
  local in_herdr = vim.env.HERDR_PANE_ID ~= nil or ancestor_process_named("herdr")

  local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1

  -- Remote sessions need us: nothing else can reach the far-end clipboard.
  -- A local tmux session only needs us to broadcast the yank as a tmux buffer,
  -- and that is worth displacing the native provider only when a real local
  -- clipboard survives underneath for paste -- i.e. on the Wayland desktop.
  -- Without this guard a local tmux on macOS loses pbcopy.
  if not (in_ssh or in_herdr or (in_tmux and has_wayland)) then
    return
  end

  local osc52 = require("vim.ui.clipboard.osc52")

  local function copy(register)
    local emit = osc52.copy(register)

    return function(lines)
      if has_wayland then
        local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
        vim.fn.system(cmd, lines)
      end

      if vim.g.omarchy_remote_clipboard_osc52 ~= false then
        emit(lines)
      end
    end
  end

  local function paste(register)
    if not has_wayland then
      -- Read back the unnamed register rather than issuing an OSC 52 query:
      -- herdr drops those outright and plenty of terminals never answer, and
      -- an unanswered query stalls the paste.
      return function()
        return { vim.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
      end
    end

    return function()
      local cmd = { "wl-paste", "--no-newline" }
      if register == "*" then
        cmd[#cmd + 1] = "--primary"
      end

      local lines = vim.fn.systemlist(cmd, "", 1)
      return vim.v.shell_error == 0 and lines or {}
    end
  end

  vim.g.clipboard = {
    name = "OmarchyRemoteClipboard",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }

  -- LazyVim sets clipboard = "" under SSH_CONNECTION, which leaves plain `y`
  -- writing only to nvim's registers. Re-link it so yanks reach the provider.
  vim.opt.clipboard = "unnamedplus"
end

return M
