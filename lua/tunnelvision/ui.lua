local core = require("tunnelvision.core")

local M = {}

local state = {
  commands_set = false,
  mappings_set = false,
  augroup = nil,
}

function M.ensure_highlights()
  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok and comment and comment.fg then
    vim.api.nvim_set_hl(0, core.state.config.dim_hl, { fg = comment.fg, italic = true })
  else
    vim.api.nvim_set_hl(0, core.state.config.dim_hl, { link = "Comment", default = true })
  end
end

function M.apply_dim(bufnr)
  ---@type TunnelVisionBufState|nil
  local bs = core.state.bufs[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, core.state.ns, 0, -1)
  if not bs or not bs.active then
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total > core.state.config.max_dim_lines then
    core.notify(("TunnelVision: file too large to dim (%d lines > %d)"):format(total, core.state.config.max_dim_lines), vim.log.levels.WARN)
    return
  end

  for idx, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not bs.path_set[idx] then
      vim.api.nvim_buf_set_extmark(bufnr, core.state.ns, idx - 1, 0, {
        end_row = idx - 1,
        end_col = #line,
        hl_group = core.state.config.dim_hl,
        hl_eol = true,
        priority = 1000,
      })
    end
  end
end

local function ensure_commands(api)
  if state.commands_set then
    return
  end
  state.commands_set = true

  for _, cmd in ipairs({
    { "TunnelVisionOn", function() core.activate(vim.api.nvim_get_current_buf()) end, "Turn on tunnel vision for symbol under cursor" },
    { "TunnelVisionOff", function() core.deactivate(vim.api.nvim_get_current_buf()) end, "Turn off tunnel vision in current buffer" },
    { "TunnelVisionToggle", api.toggle, "Toggle tunnel vision for symbol under cursor" },
    { "TunnelVisionForward", api.forward, "Track symbol under cursor without toggling" },
    { "TunnelVisionDynamic", api.dynamic, "Set dynamic mode and track symbol under cursor" },
    { "TunnelVisionNext", function() api.next(vim.v.count1) end, "Jump to next tunnel vision line" },
    { "TunnelVisionPrev", function() api.prev(vim.v.count1) end, "Jump to previous tunnel vision line" },
    { "TunnelVisionRefresh", api.refresh, "Recompute tunnel vision path" },
  }) do
    vim.api.nvim_create_user_command(cmd[1], cmd[2], { desc = cmd[3] })
  end

  local function create_query_command(name, get_value, set_value, choices, label, desc)
    vim.api.nvim_create_user_command(name, function(opts)
      local arg = vim.trim(opts.args or "")
      if arg == "" then
        core.notify(("TunnelVision %s: %s"):format(label, get_value()))
      else
        set_value(arg)
      end
    end, {
      nargs = "?",
      complete = function()
        return choices
      end,
      desc = desc,
    })
  end

  create_query_command("TunnelVisionMode", api.get_mode, api.set_mode, { "static", "flow", "dynamic", "toggle" }, "mode", "Set tunnel vision mode (static|flow|dynamic|toggle)")
  create_query_command("TunnelVisionFlowDirection", api.get_flow_direction, api.set_flow_direction, { "forward", "both", "toggle" }, "flow direction", "Set flow direction (forward|both|toggle)")
  create_query_command(
    "TunnelVisionSymbolSource",
    api.get_symbol_source,
    api.set_symbol_source,
    { "lsp_strict_fallback", "hybrid", "lexical" },
    "symbol source",
    "Set symbol source (lsp_strict_fallback|hybrid|lexical)"
  )
end

local function ensure_mappings(api)
  if state.mappings_set then
    return
  end
  state.mappings_set = true

  local cfg = core.state.config

  if cfg.use_nN then
    local function set_path_mapping(key, direction, desc)
      vim.keymap.set("n", key, function()
        if core.is_active(0) then
          core.jump_in_path(direction, vim.v.count1)
          return ""
        end
        return key
      end, { expr = true, silent = true, desc = desc })
    end

    set_path_mapping("n", 1, "Next search (TunnelVision aware)")
    set_path_mapping("N", -1, "Prev search (TunnelVision aware)")
  end

  if cfg.use_bracket_h then
    vim.keymap.set("n", "]h", function()
      if core.is_active(0) then
        core.jump_in_path(1, vim.v.count1)
      end
    end, { silent = true, desc = "TunnelVision next" })

    vim.keymap.set("n", "[h", function()
      if core.is_active(0) then
        core.jump_in_path(-1, vim.v.count1)
      end
    end, { silent = true, desc = "TunnelVision prev" })
  end

  if cfg.use_esc then
    vim.keymap.set("n", "<Esc>", function()
      if core.is_active(0) then
        core.deactivate(vim.api.nvim_get_current_buf())
        return ""
      end
      return "<Esc>"
    end, { expr = true, silent = true, desc = "Exit TunnelVision on Esc" })
  end

  if cfg.use_leader_h then
    local function toggle_mode_mapping(mode)
      local bufnr = vim.api.nvim_get_current_buf()
      if core.is_active(bufnr) then
        if core.get_mode() == mode then
          core.deactivate(bufnr)
        else
          core.set_mode(mode)
        end
      else
        core.set_mode(mode)
        core.activate(bufnr)
      end
    end

    vim.keymap.set("n", "<leader>hh", function() core.activate(vim.api.nvim_get_current_buf()) end, { silent = true, desc = "TunnelVision on/remap" })
    vim.keymap.set("n", "<leader>hs", function() toggle_mode_mapping("static") end, { silent = true, desc = "TunnelVision toggle static" })
    vim.keymap.set("n", "<leader>hd", function() toggle_mode_mapping("dynamic") end, { silent = true, desc = "TunnelVision toggle dynamic" })
    vim.keymap.set("n", "<leader>hf", function() toggle_mode_mapping("flow") end, { silent = true, desc = "TunnelVision toggle flow" })
    vim.keymap.set("n", "<leader>ho", function() core.deactivate(vim.api.nvim_get_current_buf()) end, { silent = true, desc = "TunnelVision off" })
  end
end

local function ensure_autocmds()
  if state.augroup then
    return
  end

  state.augroup = vim.api.nvim_create_augroup("TunnelVision", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.augroup,
    callback = function(args)
      core.clear_buf_state(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.augroup,
    callback = function()
      M.ensure_highlights()
      core.each_active_buffer(M.apply_dim)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    callback = function(args)
      if core.get_mode() ~= "dynamic" then
        return
      end

      ---@type TunnelVisionBufState|nil
      local bs = core.state.bufs[args.buf]
      if not bs or not bs.active then
        return
      end

      local symbol = vim.fn.expand("<cword>")
      if not symbol or symbol == "" or symbol == bs.symbol then
        return
      end

      core.activate(args.buf, { silent = true })
    end,
  })
end

--- Registers highlights, commands, keymaps, and autocmds using the public API
--- table exported from init.lua.
function M.setup(api)
  M.ensure_highlights()
  ensure_commands(api)
  ensure_mappings(api)
  ensure_autocmds()
end

return M
