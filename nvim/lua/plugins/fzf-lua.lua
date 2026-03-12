return {
  "ibhagwan/fzf-lua",
  config = function()
    local actions = require("fzf-lua.actions")

    require("fzf-lua").setup({
      files = {
        hidden = false,
        fd_opts = "--color=never --type f --type l --exclude .git",
      },
      actions = {
        files = {
          -- Remap ctrl+s to open in vertical split
          ["alt-v"] = actions.file_vsplit,
          -- Map ctrl+shift+s to open in horizontal split
          ["alt-s"] = actions.file_split,
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
