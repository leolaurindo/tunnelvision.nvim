local core = require("tunnelvision.core")
local uv = vim.uv or vim.loop

local M = {}

local DYNAMIC_DEBOUNCE_MS = 35

local state = {
  commands_set = false,
  augroup = nil,
  dynamic_timers = {},
  dynamic_pending = {},
}

local function stop_dynamic_timer(bufnr, close)
  state.dynamic_pending[bufnr] = nil

  local timer = state.dynamic_timers[bufnr]
  if not timer then
    return
  end

  timer:stop()
  if close then
    timer:close()
    state.dynamic_timers[bufnr] = nil
  end
end

local function schedule_dynamic_activate(bufnr, symbol, cursor)
  local pending = { symbol = symbol, cursor = { cursor[1], cursor[2] } }

  if not uv then
    core.activate(bufnr, { silent = true, symbol = symbol, cursor = pending.cursor, reuse_scope = true })
    return
  end

  state.dynamic_pending[bufnr] = pending

  local timer = state.dynamic_timers[bufnr]
  if not timer or timer:is_closing() then
    timer = uv.new_timer()
    state.dynamic_timers[bufnr] = timer
  end

  timer:stop()
  timer:start(
    DYNAMIC_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      local queued = state.dynamic_pending[bufnr]
      state.dynamic_pending[bufnr] = nil

      if not queued or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local bs = core.state.bufs[bufnr]
      if not bs or not bs.active or core.get_mode() ~= "dynamic" then
        return
      end

      if not core.should_dynamic_retarget(bufnr, queued.symbol, queued.cursor) then
        return
      end

      core.activate(bufnr, {
        silent = true,
        symbol = queued.symbol,
        cursor = queued.cursor,
        reuse_scope = true,
      })
    end)
  )
end

function M.ensure_highlights()
  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok and comment and comment.fg then
    vim.api.nvim_set_hl(0, core.state.config.dim_hl, { fg = comment.fg, italic = true })
  else
    vim.api.nvim_set_hl(0, core.state.config.dim_hl, { link = "Comment", default = true })
  end
end

function M.apply_dim(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.state.ns, 0, -1)

  local bs = core.state.bufs[bufnr]
  if not bs or not bs.active or bs.pending or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total > core.state.config.max_dim_lines then
    core.notify(
      ("TunnelVision: file too large to dim (%d lines > %d)"):format(total, core.state.config.max_dim_lines),
      vim.log.levels.WARN
    )
    return
  end

  for idx = 1, total do
    if not bs.path_set[idx] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, core.state.ns, idx - 1, 0, {
        line_hl_group = core.state.config.dim_hl,
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

  local subcommands = {
    on = {
      desc = "Activate tunnel vision for symbol under cursor",
      run = api.on,
    },
    retarget = {
      desc = "Alias of on; retarget to symbol under cursor",
      run = api.on,
    },
    off = {
      desc = "Deactivate tunnel vision in current buffer",
      run = api.off,
    },
    toggle = {
      desc = "Toggle tunnel vision for symbol under cursor",
      run = api.toggle,
    },
    next = {
      desc = "Jump to next path line",
      run = function()
        api.next(vim.v.count1)
      end,
    },
    prev = {
      desc = "Jump to previous path line",
      run = function()
        api.prev(vim.v.count1)
      end,
    },
    refresh = {
      desc = "Recompute tunnel vision path for this buffer",
      run = api.refresh,
    },
    mode = {
      desc = "Query or set tunnel vision mode",
      get = api.get_mode,
      label = "mode",
      set = api.set_mode,
      values = { "static", "flow", "dynamic" },
    },
    direction = {
      desc = "Query or set tunnel vision direction",
      get = api.get_direction,
      label = "direction",
      set = api.set_direction,
      values = { "forward", "both" },
    },
    scope = {
      desc = "Query or set tunnel vision scope",
      get = api.get_scope,
      label = "scope",
      set = api.set_scope,
      values = { "function", "buffer" },
    },
    source = {
      desc = "Query or set tunnel vision source",
      get = api.get_source,
      label = "source",
      set = api.set_source,
      values = { "lsp_else_word", "lsp", "lsp_and_word", "word" },
    },
    status = {
      desc = "Show tunnel vision status",
      run = function()
        local status = api.status()
        local state_label = status.pending and "pending" or (status.active and "on" or "off")
        local symbol = status.symbol and (" symbol=" .. status.symbol) or ""
        core.notify(
          ("TunnelVision: %s mode=%s direction=%s scope=%s source=%s%s"):format(
            state_label,
            status.mode,
            status.direction,
            status.scope,
            status.source,
            symbol
          )
        )
      end,
    },
  }

  local names = vim.tbl_keys(subcommands)
  table.sort(names)

  local function complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+", { trimempty = true })
    if #parts <= 1 or (#parts == 2 and cmdline:sub(-1) ~= " ") then
      return vim.tbl_filter(function(name)
        return name:find("^" .. vim.pesc(arglead)) ~= nil
      end, names)
    end

    local sub = subcommands[parts[2]]
    if not sub or not sub.values then
      return {}
    end

    return vim.tbl_filter(function(value)
      return value:find("^" .. vim.pesc(arglead)) ~= nil
    end, sub.values)
  end

  vim.api.nvim_create_user_command("TunnelVision", function(opts)
    local args = vim.split(vim.trim(opts.args or ""), "%s+", { trimempty = true })
    local sub = subcommands[args[1]]
    if not sub then
      core.notify(
        "TunnelVision: use one of on, retarget, off, toggle, next, prev, refresh, mode, direction, scope, source, status",
        vim.log.levels.ERROR
      )
      return
    end

    if sub.values then
      if sub.label == "direction" and api.get_mode() ~= "flow" then
        core.notify("TunnelVision: direction is used only in flow mode", vim.log.levels.WARN)
      end

      local value = args[2]
      if not value or value == "" then
        core.notify(("TunnelVision %s: %s"):format(sub.label, sub.get()))
        return
      end
      if args[3] then
        core.notify(("TunnelVision: '%s' takes a single value"):format(args[1]), vim.log.levels.ERROR)
        return
      end
      sub.set(value)
      return
    end

    if args[2] then
      core.notify(("TunnelVision: '%s' does not take arguments"):format(args[1]), vim.log.levels.ERROR)
      return
    end

    sub.run()
  end, {
    complete = complete,
    desc = "Control tunnel vision",
    nargs = "*",
  })
end

local function ensure_autocmds()
  if state.augroup then
    return
  end

  state.augroup = vim.api.nvim_create_augroup("TunnelVision", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.augroup,
    callback = function(args)
      stop_dynamic_timer(args.buf, true)
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
        local cursor = vim.api.nvim_win_get_cursor(0)
        if core.should_dynamic_retarget(args.buf, symbol, cursor) then
          schedule_dynamic_activate(args.buf, symbol, cursor)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    callback = function(args)
      stop_dynamic_timer(args.buf, false)
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
