local core = require("tunnelvision.core")

local M = {}

local state = {
  commands_set = false,
  augroup = nil,
  user_dim_hl = nil,
}

local function has_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" and next(hl) ~= nil then
    return hl
  end
  return nil
end

function M.ensure_highlights()
  local name = core.state.config.dim_hl
  local existing = has_highlight(name)
  if existing then
    state.user_dim_hl = vim.deepcopy(existing)
    return
  end

  if state.user_dim_hl then
    vim.api.nvim_set_hl(0, name, state.user_dim_hl)
    return
  end

  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok and comment and comment.fg then
    vim.api.nvim_set_hl(0, name, { fg = comment.fg, italic = true })
  else
    vim.api.nvim_set_hl(0, name, { link = "Comment", default = true })
  end
end

function M.apply_dim(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.state.ns, 0, -1)

  local bs = core.state.bufs[bufnr]
  if not bs or not bs.active or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total > core.state.config.max_dim_lines then
    core.notify(("TunnelVision: file too large to dim (%d lines > %d)"):format(total, core.state.config.max_dim_lines), vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for idx, line in ipairs(lines) do
    if not bs.path_set[idx] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, core.state.ns, idx - 1, 0, {
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

  local commands = {
    { "TunnelVisionOn", function() core.activate(vim.api.nvim_get_current_buf()) end, "Turn on tunnel vision for symbol under cursor" },
    { "TunnelVisionOff", function() core.deactivate(vim.api.nvim_get_current_buf()) end, "Turn off tunnel vision in current buffer" },
    { "TunnelVisionToggle", api.toggle, "Toggle tunnel vision for symbol under cursor" },
    { "TunnelVisionForward", api.forward, "Retarget to symbol under cursor without toggling off" },
    { "TunnelVisionDynamic", api.dynamic, "Switch to dynamic mode and track symbol under cursor" },
    { "TunnelVisionNext", function() api.next(vim.v.count1) end, "Jump to next path line" },
    { "TunnelVisionPrev", function() api.prev(vim.v.count1) end, "Jump to previous path line" },
    { "TunnelVisionRefresh", api.refresh, "Recompute tunnel vision path for this buffer" },
  }

  for _, cmd in ipairs(commands) do
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

  create_query_command(
    "TunnelVisionMode",
    api.get_mode,
    api.set_mode,
    { "static", "flow", "dynamic", "toggle" },
    "mode",
    "Set tunnel vision mode (static|flow|dynamic|toggle)"
  )

  create_query_command(
    "TunnelVisionFlowDirection",
    api.get_flow_direction,
    api.set_flow_direction,
    { "forward", "both", "toggle" },
    "flow direction",
    "Set flow direction (forward|both|toggle)"
  )

  create_query_command(
    "TunnelVisionSymbolSource",
    api.get_symbol_source,
    api.set_symbol_source,
    { "lsp_strict_fallback", "hybrid", "lexical", "toggle" },
    "symbol source",
    "Set symbol source (lsp_strict_fallback|hybrid|lexical|toggle)"
  )
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
      core.refresh_all()
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    callback = function(args)
      local bs = core.state.bufs[args.buf]
      if core.get_mode() == "dynamic" and bs and bs.active then
        local symbol = vim.fn.expand("<cword>")
        if symbol and symbol ~= "" and symbol ~= bs.symbol then
          core.activate(args.buf, { silent = true })
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    callback = function(args)
      if core.is_active(args.buf) then
        core.refresh(args.buf)
      end
    end,
  })
end

function M.setup(api)
  M.ensure_highlights()
  ensure_commands(api)
  ensure_autocmds()
end

return M
