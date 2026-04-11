return {
  "ibhagwan/fzf-lua",
  config = function()
    local actions = require("fzf-lua.actions")

    require("fzf-lua").setup({
      keymap = {
        builtin = {
          ["<c-f>"] = false,
          ["<c-b>"] = false,
          ["<c-d>"] = "preview-page-down",
          ["<c-u>"] = "preview-page-up",
        },
        fzf = {
          ["ctrl-f"] = false,
          ["ctrl-b"] = false,
          ["ctrl-d"] = "preview-page-down",
          ["ctrl-u"] = "preview-page-up",
          ["ctrl-h"] = "execute-silent(tmux select-pane -L)",
          ["ctrl-l"] = "execute-silent(tmux select-pane -R)",
        },
      },
      files = {
        hidden = false,
        fd_opts = "--color=never --type f --type l --exclude .git",
      },
      actions = {
        files = {
          -- Remap ctrl+s to open in vertical split
          ["alt-s"] = actions.file_vsplit,
          -- Map ctrl+v to open in horizontal split
          ["alt-v"] = actions.file_split,
          -- Disable ctrl+v since it conflicts with paste on Linux
          ["ctrl-v"] = false,
          -- Keep other default actions
          ["enter"] = actions.file_edit_or_qf,
          ["ctrl-t"] = actions.file_tabedit,
          ["alt-q"] = actions.file_sel_to_qf,
          ["alt-Q"] = actions.file_sel_to_ll,
          ["alt-i"] = actions.toggle_ignore,
          ["alt-h"] = actions.toggle_hidden,
          ["alt-f"] = actions.toggle_follow,
        },
      },
    })
  end,
}
