local core = require("tunnelvision.core")

local M = {}

local DYNAMIC_DEBOUNCE_MS = 35

local state = {
  commands_set = false,
  augroup = nil,
  dynamic_seq = {},
}

local function cancel_dynamic_activate(bufnr)
  state.dynamic_seq[bufnr] = (state.dynamic_seq[bufnr] or 0) + 1
end

local function schedule_dynamic_activate(bufnr, symbol, cursor)
  cancel_dynamic_activate(bufnr)
  local seq = state.dynamic_seq[bufnr]
  local queued_symbol = symbol
  local queued_cursor = { cursor[1], cursor[2] }

  vim.defer_fn(function()
    if state.dynamic_seq[bufnr] ~= seq or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local bs = core.state.bufs[bufnr]
    if not bs or not bs.active or core.get_active_mode(bufnr) ~= "dynamic" then
      return
    end

    if not core.should_dynamic_retarget(bufnr, queued_symbol, queued_cursor) then
      return
    end

    core.activate(bufnr, {
      silent = true,
      config = bs.config,
      symbol = queued_symbol,
      cursor = queued_cursor,
      reuse_scope = true,
    })
  end, DYNAMIC_DEBOUNCE_MS)
end

function M.ensure_highlights(config)
  config = config or core.state.config
  if config.dim == "none" then
    return
  end
  if not config.dim and config.dim_hl == core.state.config.dim_hl and core.state.config.dim then
    config = core.state.config
  end
  if type(config.dim) == "table" then
    pcall(vim.api.nvim_set_hl, 0, config.dim_hl, config.dim)
    return
  end
  if type(config.dim) == "string" then
    -- Copy resolved attrs from an existing highlight group (not a link, so
    -- ColorScheme re-apply picks up updated source group attributes).
    local ok, src = pcall(vim.api.nvim_get_hl, 0, { name = config.dim, link = false })
    if ok and src and next(src) ~= nil then
      src.link = nil
      src.default = nil
      pcall(vim.api.nvim_set_hl, 0, config.dim_hl, src)
      return
    end
  end

  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok and comment and comment.fg then
    vim.api.nvim_set_hl(0, config.dim_hl, { fg = comment.fg, italic = true })
  else
    vim.api.nvim_set_hl(0, config.dim_hl, { link = "Comment", default = true })
  end
end

local style_keys = { "fg", "bg", "bold", "italic", "underline", "undercurl", "strikethrough" }

local function has_style(style)
  for _, key in ipairs(style_keys) do
    if style and style[key] ~= nil then
      return true
    end
  end
  return false
end

local function merge_style(into, style)
  for key, value in pairs(style or {}) do
    into[key] = value
  end
end

local function resolved_style(style)
  local resolved = vim.deepcopy(style)
  local opacity = resolved.bg_opacity
  resolved.bg_opacity = nil
  if opacity == nil or resolved.bg == nil then
    return resolved
  end

  local hex = type(resolved.bg) == "string" and resolved.bg:match("^#(%x%x%x%x%x%x)$")
  local bg = type(resolved.bg) == "number" and resolved.bg or hex and tonumber(hex, 16)
  if not bg and type(resolved.bg) == "string" then
    local ok_color, color = pcall(vim.api.nvim_get_color_by_name, resolved.bg)
    bg = ok_color and color >= 0 and color or nil
  end
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if not bg or not ok or not normal or not normal.bg then
    return resolved
  end

  local amount = math.max(0, math.min(1, opacity))
  local blended = 0
  for shift = 0, 16, 8 do
    local channel = math.floor(((bg / 2 ^ shift) % 256) * amount + ((normal.bg / 2 ^ shift) % 256) * (1 - amount) + 0.5)
    blended = blended + channel * 2 ^ shift
  end
  resolved.bg = blended
  return resolved
end

local function style_group(bufnr, bs, style)
  local attrs = resolved_style(style)
  local parts = {}
  for _, key in ipairs(style_keys) do
    if attrs[key] ~= nil then
      parts[#parts + 1] = key .. "=" .. tostring(attrs[key])
    end
  end
  if #parts == 0 then
    return nil
  end

  local key = table.concat(parts, ";")
  bs.render_groups = bs.render_groups or { next = 0 }
  if bs.render_groups[key] then
    return bs.render_groups[key]
  end

  bs.render_groups.next = bs.render_groups.next + 1
  local group = ("TunnelVisionHighlight%d_%d"):format(bufnr, bs.render_groups.next)
  local ok = pcall(vim.api.nvim_set_hl, 0, group, attrs)
  if not ok then
    return nil
  end
  bs.render_groups[key] = group
  return group
end

function M.clear_render_groups(bs)
  for key, group in pairs(bs and bs.render_groups or {}) do
    if key ~= "next" then
      pcall(vim.api.nvim_set_hl, 0, group, {})
    end
  end
  if bs then
    bs.render_groups = nil
  end
end

local function range_mark(bufnr, row, start_col, end_col, group, priority)
  if not group or start_col >= end_col then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, core.state.ns, row, start_col, {
    end_row = row,
    end_col = end_col,
    hl_group = group,
    priority = priority,
  })
end

function M.render(bufnr)
  local bs = core.state.bufs[bufnr]
  if not bs or not bs.active or bs.pending or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.state.ns, 0, -1)

  local config = bs.config or core.state.config
  M.ensure_highlights(config)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local do_dim = config.dim ~= "none" and total <= config.max_dim_lines
  if config.dim ~= "none" and not do_dim then
    -- Dimming is an O(total lines) extmark pass, so skip very large buffers
    -- instead of doing expensive redraw work on every refresh.
    if not bs.warned_large_buffer then
      core.notify(
        ("TunnelVision: file too large to dim (%d lines > %d)"):format(total, config.max_dim_lines),
        vim.log.levels.WARN
      )
      bs.warned_large_buffer = true
    end
  else
    bs.warned_large_buffer = false
  end

  local rules = config.highlights
  local symbols = {}
  if rules.symbol then
    for _, range in ipairs(bs.symbol_ranges) do
      local line_ranges = symbols[range.line] or {}
      local previous = line_ranges[#line_ranges]
      if previous and range.start_col <= previous.end_col then
        previous.end_col = math.max(previous.end_col, range.end_col)
      else
        line_ranges[#line_ranges + 1] = vim.deepcopy(range)
      end
      symbols[range.line] = line_ranges
    end
  end

  local function render_line(idx, line)
    local style = {}
    local whole = false
    for _, context in ipairs({ "scope_head", "statement", "line" }) do
      local covered = context == "scope_head" and bs.scope_head_set[idx]
        or context == "statement" and bs.statement_set[idx]
        or context == "line" and bs.path_set[idx]
      if rules[context] and covered then
        whole = true
        merge_style(style, rules[context])
      end
    end

    local ranges = symbols[idx]
    if whole then
      local col = 0
      for _, range in ipairs(ranges or {}) do
        range_mark(bufnr, idx - 1, col, range.start_col, style_group(bufnr, bs, style), 1100)
        local symbol_style = vim.deepcopy(style)
        merge_style(symbol_style, rules.symbol)
        range_mark(bufnr, idx - 1, range.start_col, range.end_col, style_group(bufnr, bs, symbol_style), 1100)
        col = range.end_col
      end
      range_mark(bufnr, idx - 1, col, #line, style_group(bufnr, bs, style), 1100)
    elseif ranges then
      local col = 0
      for _, range in ipairs(ranges) do
        if do_dim then
          range_mark(bufnr, idx - 1, col, range.start_col, config.dim_hl, 1000)
        end
        range_mark(bufnr, idx - 1, range.start_col, range.end_col, style_group(bufnr, bs, rules.symbol), 1100)
        col = range.end_col
      end
      if do_dim then
        range_mark(bufnr, idx - 1, col, #line, config.dim_hl, 1000)
      end
    elseif do_dim then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, core.state.ns, idx - 1, 0, {
        line_hl_group = config.dim_hl,
        priority = 1000,
      })
    end
  end

  if do_dim then
    for idx, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      render_line(idx, line)
    end
    return
  end

  local positive_lines = {}
  for context, covered in pairs({
    scope_head = bs.scope_head_set,
    statement = bs.statement_set,
    line = bs.path_set,
  }) do
    if has_style(rules[context]) then
      for lnum in pairs(covered) do
        positive_lines[lnum] = true
      end
    end
  end
  if has_style(rules.symbol) then
    for lnum in pairs(symbols) do
      positive_lines[lnum] = true
    end
  end
  for lnum in pairs(positive_lines) do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    render_line(lnum, line)
  end
end

local function ensure_commands(api)
  if state.commands_set then
    return
  end
  state.commands_set = true

  local subcommands = {
    on = {
      run = api.on,
    },
    retarget = {
      run = api.on,
    },
    off = {
      run = api.off,
    },
    toggle = {
      run = api.toggle,
    },
    next = {
      run = function()
        api.next(vim.v.count1)
      end,
    },
    prev = {
      run = function()
        api.prev(vim.v.count1)
      end,
    },
    refresh = {
      run = api.refresh,
    },
    mode = {
      get = api.get_mode,
      set = api.set_mode,
      values = { "static", "flow", "dynamic" },
    },
    direction = {
      get = api.get_direction,
      set = api.set_direction,
      values = { "forward", "backward", "both" },
    },
    scope = {
      get = api.get_scope,
      set = api.set_scope,
      values = { "function", "buffer" },
    },
    source = {
      get = core.get_sources_label,
      set = core.set_source_command,
      values = {
        "word",
        "lsp",
        "lsp_else_word",
        "lsp_and_word",
        "lsp,word",
        "treesitter",
        "treesitter,word",
        "lsp,treesitter,word",
      },
    },
    status = {
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
            status.sources_label,
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
        "TunnelVision: use one of on, retarget, off, toggle, next, prev, refresh, "
          .. "mode, direction, scope, source, status",
        vim.log.levels.ERROR
      )
      return
    end

    if sub.values then
      if args[1] == "direction" and api.get_mode() ~= "flow" then
        core.notify("TunnelVision: direction is used only in flow mode", vim.log.levels.WARN)
      end

      local value = args[2]
      if not value or value == "" then
        local current = sub.get()
        core.notify(("TunnelVision %s: %s"):format(args[1], current))
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
      state.dynamic_seq[args.buf] = nil
      core.clear_buf_state(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.augroup,
    callback = function()
      M.ensure_highlights()
      for bufnr, bs in pairs(core.state.bufs) do
        if bs.active and bs.config and not bs.pending then
          M.clear_render_groups(bs)
          M.render(bufnr)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    callback = function(args)
      local bs = core.state.bufs[args.buf]
      if core.get_active_mode(args.buf) == "dynamic" and bs and bs.active then
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
      cancel_dynamic_activate(args.buf)
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
