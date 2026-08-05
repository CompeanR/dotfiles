-- pi popup for code questions, with shorter mappings inside diffview panes.
--
-- Global:
-- <leader>pa  ask pi about a selection or the code around the cursor
-- <leader>pe  explain a selection or the code around the cursor
-- <leader>pp  open/toggle the popup;  <C-q> or <C-g> hides it from inside
--
-- Diffview:
-- <leader>a   ask pi about the selected/current hunk
-- <leader>e   explain the selected/current hunk
-- <leader>F   diffview's focus_files, rehomed since <leader>e is taken
--
-- The hunk is written to a temp file and passed as a pi `@file` argument, so the
-- prompt itself stays a single line. That matters: it lets a second question be
-- typed into an already-running pi TUI instead of spawning a new one.

local M = {}

local scratch_dir = vim.fn.stdpath("cache") .. "/pi-diffview"

-- Keep the lightweight popup independent from the global pi defaults. The model
-- must match an entry in ~/dotfiles/pi/settings.json "enabledModels".
local MODEL = "openai-codex/gpt-5.6-terra"
local THINKING = "medium"

-- pi is not detected by screen scraping — it registers itself through the
-- herdr-agent-state / herdr-attention extensions, which both enable themselves
-- only when HERDR_ENV == "1" (with HERDR_SOCKET_PATH and HERDR_PANE_ID set).
-- Clearing that one variable in the popup's environment keeps this transient
-- session out of the sidebar entirely, and silences its attention toasts, while
-- leaving real pi sessions in their own panes untouched.
local NO_HERDR_AGENT = { HERDR_ENV = "0" }

---Lines of the current visual selection, or nil when not in visual mode.
---@return integer?, integer?
local function visual_range()
  local mode = vim.fn.mode()
  if not mode:match("^[vV\22]") then
    return nil
  end
  -- Leave visual mode so '< and '> are set.
  vim.cmd("normal! \27")
  local s = vim.fn.line("'<")
  local e = vim.fn.line("'>")
  if s > e then
    s, e = e, s
  end
  return s, e
end

---Extent of the diff-highlighted block under the cursor in the current window.
---Falls back to a window around the cursor when sitting on a context line.
---@return integer, integer
local function hunk_range()
  local lnum = vim.fn.line(".")
  local last = vim.fn.line("$")

  -- diff_hlID is window-local and returns 0 for unchanged lines.
  local function changed(l)
    return vim.fn.diff_hlID(l, 1) ~= 0
  end

  if not changed(lnum) then
    return math.max(1, lnum - 15), math.min(last, lnum + 15)
  end

  local s, e = lnum, lnum
  while s > 1 and changed(s - 1) do
    s = s - 1
  end
  while e < last and changed(e + 1) do
    e = e + 1
  end
  -- A little context on each side makes the excerpt readable on its own.
  return math.max(1, s - 5), math.min(last, e + 5)
end

---Describe what is being reviewed, for the prompt header.
local function review_context()
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  local rev = view and view.rev_arg or nil
  local branch = vim.fn.systemlist("git rev-parse --abbrev-ref HEAD")[1]
  if vim.v.shell_error ~= 0 then
    branch = nil
  end
  local parts = {}
  if rev then
    parts[#parts + 1] = "diff range: " .. rev
  end
  if branch then
    parts[#parts + 1] = "branch: " .. branch
  end
  return table.concat(parts, ", ")
end

---Write the excerpt to a temp file and return its path.
---@return string?
local function capture()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)

  -- diffview:// buffers hold the base revision; note which side we grabbed.
  -- Their URIs look like diffview:///repo/.git/<object>/path/to/file — strip
  -- through the git object dir to recover the real repo-relative path.
  local side = "WORKING"
  if name:match("^diffview://") then
    side = "BASE (left pane)"
  elseif vim.wo.diff then
    side = "WORKING (right pane)"
  end
  local path = name:gsub("^diffview://", ""):gsub("^.-/%.git/[^/]+/", "")
  path = vim.fn.fnamemodify(path, ":.")

  local s, e = visual_range()
  if not s then
    s, e = hunk_range()
  end

  local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
  if #lines == 0 then
    return nil
  end

  local header = {
    ("File: %s"):format(path ~= "" and path or "(unnamed)"),
    ("Lines: %d-%d  [%s]"):format(s, e, side),
  }
  local ctx = review_context()
  if ctx ~= "" then
    header[#header + 1] = ctx
  end
  header[#header + 1] = ""
  header[#header + 1] = ("```%s"):format(vim.bo[buf].filetype or "")
  vim.list_extend(header, lines)
  header[#header + 1] = "```"

  vim.fn.mkdir(scratch_dir, "p")
  local file = ("%s/excerpt-%s.md"):format(scratch_dir, os.date("%H%M%S"))
  vim.fn.writefile(header, file)
  return file
end

---The running pi terminal, if any.
local function pi_term()
  local ok, terminal = pcall(require, "snacks.terminal")
  if not ok then
    return nil
  end
  for _, term in ipairs(terminal.list()) do
    if vim.api.nvim_buf_is_valid(term.buf) and vim.b[term.buf].pi_diffview then
      return term
    end
  end
  return nil
end

---Open a new pi popup, optionally with initial arguments.
---@param args? string[]
---@return snacks.terminal?
local function open_pi(args)
  local ok, terminal = pcall(require, "snacks.terminal")
  if not ok then
    vim.notify("[pi-diffview] snacks.terminal unavailable", vim.log.levels.ERROR)
    return nil
  end

  -- nice: pi is a Node process that will happily saturate a core. On a 2-CPU box
  -- that starves the editor; deprioritising it keeps typing responsive while the
  -- answer streams in (it costs pi some latency, not correctness).
  --
  -- -n names the pi session, so it is distinguishable in `pi --resume` too.
  local cmd = {
    "nice",
    "-n",
    "15",
    "pi",
    "--model",
    MODEL,
    "--thinking",
    THINKING,
    "-n",
    "nvim popup",
  }
  vim.list_extend(cmd, args or {})

  local term = terminal.open(cmd, {
    win = {
      position = "float",
      width = 0.85,
      height = 0.85,
      border = "rounded",
      title = " pi — agent ",
      title_pos = "center",
      -- Must live under `win`: terminal.open passes only opts.win to Snacks.win,
      -- so keys declared at the top level are silently dropped.
      --
      -- Avoids herdr's bindings — alt+q is its close_pane, ctrl+h/k/l its pane
      -- navigation, alt+g its lazygit popup.
      keys = {
        pi_hide = {
          "<C-q>",
          function(self)
            self:hide()
          end,
          mode = { "t", "n" },
          desc = "Hide pi popup",
        },
        pi_hide_g = {
          "<C-g>",
          function(self)
            self:hide()
          end,
          mode = { "t", "n" },
          desc = "Hide pi popup",
        },
      },
    },
    env = NO_HERDR_AGENT,
    interactive = true,
  })
  if term and term.buf then
    vim.b[term.buf].pi_diffview = true
  end
  return term
end

---Send an already-captured excerpt plus a question to pi, reusing the open
---session when there is one.
---@param file string path to the excerpt written by capture()
---@param question string
local function send(file, question)
  local existing = pi_term()
  if existing then
    existing:show()
    local job = vim.b[existing.buf].terminal_job_id
    if job then
      -- Into a running TUI the @file reference is parsed inline, so one line is
      -- right here — unlike argv, where it must be its own argument.
      vim.api.nvim_chan_send(job, ("@%s %s"):format(file, question) .. "\r")
      return
    end
  end

  -- `pi [@files...] [messages...]` — the @file must be a separate argv entry, or
  -- pi reads the whole string as one filename.
  open_pi({ "@" .. file, question })
end

function M.ask()
  -- Capture before vim.ui.input runs: the input popup ends visual mode, which
  -- would otherwise lose the selection the question is about.
  local file = capture()
  if not file then
    vim.notify("[pi-diffview] nothing under the cursor to send", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Ask pi about this code: " }, function(answer)
    if answer and answer ~= "" then
      send(file, answer)
    end
  end)
end

---Open the popup, or hide/show it without losing the session.
function M.toggle()
  local term = pi_term()
  -- Deliberately buf_valid, not valid(): valid() also requires a live window, so
  -- a hidden-but-running session would look like no session at all.
  if term and term:buf_valid() then
    term:toggle()
    return
  end
  open_pi()
end

function M.explain()
  local file = capture()
  if not file then
    vim.notify("[pi-diffview] nothing under the cursor to send", vim.log.levels.WARN)
    return
  end
  send(file, "Explain this code clearly and concisely. If it is a diff, explain what changed and why.")
end

package.loaded["pi_diffview"] = M

-- Excerpts are only needed until pi has read them; clear them out on exit so the
-- cache dir doesn't grow one file per question forever.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, f in ipairs(vim.fn.glob(scratch_dir .. "/excerpt-*.md", false, true)) do
      pcall(vim.fn.delete, f)
    end
  end,
})

-- Namespaced globally to preserve LazyVim's <leader>e explorer mapping. Diffview
-- keeps the shorter buffer-local <leader>a and <leader>e mappings below.
vim.keymap.set({ "n", "x" }, "<leader>pa", M.ask, { desc = "pi: ask about this code" })
vim.keymap.set({ "n", "x" }, "<leader>pe", M.explain, { desc = "pi: explain this code" })
vim.keymap.set("n", "<leader>pp", M.toggle, { desc = "pi: open/toggle popup" })

return {
  {
    "sindrets/diffview.nvim",
    opts = function(_, opts)
      opts.keymaps = opts.keymaps or {}
      opts.keymaps.view = opts.keymaps.view or {}

      local view_maps = {
        { { "n", "x" }, "<leader>a", M.ask, { desc = "pi: ask about this hunk" } },
        { { "n", "x" }, "<leader>e", M.explain, { desc = "pi: explain this hunk" } },
        -- diffview binds <leader>e to focus_files by default; rehome it.
        { "n", "<leader>F", require("diffview.actions").focus_files, { desc = "Focus file panel" } },
      }

      -- lazy may evaluate opts more than once and hands back a fresh table each
      -- time, so a "already applied" flag doesn't survive. Drop any entry we own
      -- before appending, which makes this idempotent however often it runs.
      local ours = {}
      for _, m in ipairs(view_maps) do
        ours[m[2]] = true
      end
      opts.keymaps.view = vim.tbl_filter(function(m)
        return not (type(m) == "table" and ours[m[2]])
      end, opts.keymaps.view)

      for _, m in ipairs(view_maps) do
        table.insert(opts.keymaps.view, m)
      end
      return opts
    end,
  },
}
