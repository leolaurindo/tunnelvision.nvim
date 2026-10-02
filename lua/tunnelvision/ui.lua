local core = require("tunnelvision.core")

local M = {}

local DYNAMIC_DEBOUNCE_MS = 35
local EDIT_DEBOUNCE_MS = 75

local state = {
  commands_set = false,
  augroup = nil,
  dynamic_seq = {},
  edit_timers = {},
}

local function cancel_dynamic_activate(bufnr)
  state.dynamic_seq[bufnr] = (state.dynamic_seq[bufnr] or 0) + 1
end

local function cancel_edit_refresh(bufnr)
  local timer = state.edit_timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    state.edit_timers[bufnr] = nil
  end
end

local function schedule_edit_refresh(bufnr)
  cancel_edit_refresh(bufnr)
  local timer
  timer = vim.defer_fn(function()
    if state.edit_timers[bufnr] ~= timer or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    state.edit_timers[bufnr] = nil
    if core.is_active(bufnr) then
      core.refresh(bufnr)
    end
  end, EDIT_DEBOUNCE_MS)
  state.edit_timers[bufnr] = timer
end

local function schedule_dynamic_activate(bufnr, symbol, cursor)
  cancel_dynamic_activate(bufnr)
  local seq = state.dynamic_seq[bufnr]
  local queued_symbol = symbol
  local queued_cursor = { cursor[1], cursor[2] }
  local queued_track = core.get_moving_track(bufnr)

  vim.defer_fn(function()
    if state.dynamic_seq[bufnr] ~= seq or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local bs = core.state.bufs[bufnr]
    local track = core.get_moving_track(bufnr)
    if not bs or not bs.active or track ~= queued_track then
      return
    end

    if not core.should_dynamic_retarget(bufnr, queued_symbol, queued_cursor) then
      return
    end

    core.activate(bufnr, {
      silent = true,
      config = track.config,
      track = track,
      symbol = queued_symbol,
      cursor = queued_cursor,
      reuse_scope = true,
    })
  end, DYNAMIC_DEBOUNCE_MS)
end

M.cancel_edit_refresh = cancel_edit_refresh
M.cancel_dynamic_activate = cancel_dynamic_activate

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

local style_keys = { "fg", "bg", "fg_group", "bg_group", "bold", "italic", "underline", "undercurl", "strikethrough" }

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

local function style_token(key, value)
  value = type(value) .. ":" .. tostring(value)
  return key .. "=" .. #value .. ":" .. value
end

local function resolved_style(style, render_cache)
  local resolved = vim.deepcopy(style)
  local fg_group, bg_group = resolved.fg_group, resolved.bg_group
  resolved.fg_group, resolved.bg_group = nil, nil
  if fg_group and resolved.fg == nil then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = fg_group, link = false })
    resolved.fg = ok and hl and hl.fg or nil
  end
  if bg_group and resolved.bg == nil then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = bg_group, link = false })
    resolved.bg = ok and hl and hl.bg or nil
  end
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
  if not bg then
    return resolved
  end
  if not render_cache.normal_bg_loaded then
    local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    render_cache.normal_bg = ok and normal and normal.bg or false
    render_cache.normal_bg_loaded = true
  end
  if not render_cache.normal_bg then
    return resolved
  end

  local amount = math.max(0, math.min(1, opacity))
  local blended = 0
  for shift = 0, 16, 8 do
    local bg_channel = math.floor(bg / 2 ^ shift) % 256
    local normal_channel = math.floor(render_cache.normal_bg / 2 ^ shift) % 256
    local channel = math.floor(bg_channel * amount + normal_channel * (1 - amount) + 0.5)
    blended = blended + channel * 2 ^ shift
  end
  resolved.bg = blended
  return resolved
end

local function style_group(bufnr, bs, style, render_cache)
  if render_cache.styles[style] ~= nil then
    return render_cache.styles[style] or nil
  end

  local attrs = resolved_style(style, render_cache)
  local parts = {}
  for _, key in ipairs(style_keys) do
    if attrs[key] ~= nil then
      parts[#parts + 1] = style_token(key, attrs[key])
    end
  end
  if #parts == 0 then
    render_cache.styles[style] = false
    return nil
  end

  local key = table.concat(parts, ";")
  bs.render_groups = bs.render_groups or { next = 0 }
  if bs.render_groups[key] then
    render_cache.styles[style] = bs.render_groups[key]
    return render_cache.styles[style]
  end

  bs.render_groups.next = bs.render_groups.next + 1
  local group = ("TunnelVisionHighlight%d_%d"):format(bufnr, bs.render_groups.next)
  local ok = pcall(vim.api.nvim_set_hl, 0, group, attrs)
  if not ok then
    render_cache.styles[style] = false
    return nil
  end
  bs.render_groups[key] = group
  render_cache.styles[style] = group
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
  if not bs or not bs.active or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.state.ns, 0, -1)

  local global = core.state.config
  local dim = bs.dim_override ~= nil and bs.dim_override or global.dim
  local dim_config = bs.dim_override ~= nil and { dim = dim, dim_hl = ("TunnelVisionDimBuffer%d"):format(bufnr) }
    or global
  local function rules_for(track)
    return track.pending and track.rendered_highlights or track.config.highlights
  end
  local request_dim = bs.force_dim
  for _, track in ipairs(bs.tracks) do
    local requested = track.config.request_dim
    if track.pending and track.rendered_request_dim ~= nil then
      requested = track.rendered_request_dim
    end
    request_dim = request_dim or requested ~= false
  end
  if dim ~= "none" and request_dim then
    M.ensure_highlights(dim_config)
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local do_dim = dim ~= "none" and request_dim and total <= global.max_dim_lines
  if dim ~= "none" and request_dim and not do_dim then
    if not bs.warned_large_buffer then
      core.notify(
        ("TunnelVision: file too large to dim (%d lines > %d)"):format(total, global.max_dim_lines),
        vim.log.levels.WARN
      )
      bs.warned_large_buffer = true
    end
  else
    bs.warned_large_buffer = false
  end

  local render_cache = { styles = {} }
  local positive_lines = {}
  local symbols = {}
  for _, track in ipairs(bs.tracks) do
    local rules = rules_for(track)
    for _, context in ipairs({ "scope_head", "statement", "line" }) do
      local covered =
        track[({ scope_head = "scope_head_set", statement = "statement_set", line = "path_set" })[context]]
      if has_style(rules[context]) then
        for lnum in pairs(covered) do
          positive_lines[lnum] = true
        end
      end
    end
    if rules.symbol then
      for _, range in ipairs(track.symbol_ranges) do
        local row = symbols[range.line] or {}
        row[#row + 1] = { track = track, start_col = range.start_col, end_col = range.end_col }
        symbols[range.line] = row
        if has_style(rules.symbol) then
          positive_lines[range.line] = true
        end
      end
    end
  end

  local function render_line(idx, line)
    local length = #line
    local cuts = { 0, length }
    for _, range in ipairs(symbols[idx] or {}) do
      cuts[#cuts + 1] = math.max(0, math.min(length, range.start_col))
      cuts[#cuts + 1] = math.max(0, math.min(length, range.end_col))
    end
    table.sort(cuts)
    local spans = {}
    for i = 1, #cuts - 1 do
      local first, last = cuts[i], cuts[i + 1]
      if first < last then
        local focused, style = false, {}
        for _, track in ipairs(bs.tracks) do
          local rules = rules_for(track)
          local line_style = {}
          local whole = false
          for _, entry in ipairs({
            { "scope_head", "scope_head_set" },
            { "statement", "statement_set" },
            { "line", "path_set" },
          }) do
            if rules[entry[1]] and track[entry[2]][idx] then
              whole = true
              merge_style(line_style, rules[entry[1]])
            end
          end
          local symbol = false
          if rules.symbol then
            for _, range in ipairs(symbols[idx] or {}) do
              if range.track == track and range.start_col <= first and last <= range.end_col then
                symbol = true
                break
              end
            end
          end
          if whole or symbol then
            focused = true
            if symbol then
              merge_style(line_style, rules.symbol)
            end
            merge_style(style, line_style)
          end
        end
        local group
        if focused then
          group = style_group(bufnr, bs, style, render_cache)
        elseif do_dim then
          group = dim_config.dim_hl
        end
        local previous = spans[#spans]
        if previous and previous.group == group then
          previous.last = last
        else
          spans[#spans + 1] = { first = first, last = last, group = group, focused = focused }
        end
      end
    end
    if do_dim and #spans == 0 then
      for _, track in ipairs(bs.tracks) do
        local rules = rules_for(track)
        if
          rules.scope_head and track.scope_head_set[idx]
          or rules.statement and track.statement_set[idx]
          or rules.line and track.path_set[idx]
        then
          return
        end
      end
    end
    if do_dim and (#spans == 0 or #spans == 1 and not spans[1].focused) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, core.state.ns, idx - 1, 0, {
        line_hl_group = dim_config.dim_hl,
        priority = 1000,
      })
      return
    end
    for _, span in ipairs(spans) do
      range_mark(bufnr, idx - 1, span.first, span.last, span.group, span.focused and 1100 or 1000)
    end
  end

  if do_dim then
    for idx, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      render_line(idx, line)
    end
  else
    for lnum in pairs(positive_lines) do
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      render_line(lnum, line)
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
      run = api.on,
    },
    add = {
      run = api.add,
    },
    pin = {
      run = api.pin,
    },
    remove = {
      run = api.remove,
    },
    retarget = {
      run = api.retarget,
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
    ["next-track"] = {
      run = function()
        api.next_track(vim.v.count1)
      end,
    },
    ["prev-track"] = {
      run = function()
        api.prev_track(vim.v.count1)
      end,
    },
    refresh = {
      run = api.refresh,
    },
    quickfix = {
      run = function()
        local count = api.set_quickfix()
        if count == 0 then
          core.notify("TunnelVision: no active tracks", vim.log.levels.WARN)
        else
          core.notify(("TunnelVision: %d positions in the quickfix list"):format(count))
        end
      end,
    },
    dim = {
      values = { "reset", "none", "Comment" },
    },
    mode = {
      get = function()
        return api.status().mode
      end,
      set = function(value)
        api.on({ mode = value })
      end,
      values = { "static", "flow", "dynamic", "dynamic_flow" },
    },
    direction = {
      get = function()
        return api.status().direction
      end,
      set = function(value)
        local mode = api.status().mode
        api.on({ mode = mode == "dynamic_flow" and mode or "flow", flow_settings = { direction = value } })
      end,
      values = { "forward", "backward", "both" },
    },
    scope = {
      get = function()
        return api.status().scope
      end,
      set = function(value)
        api.on({ scope = value })
      end,
      values = { "function", "buffer" },
    },
    source = {
      get = function()
        return api.status().sources_label
      end,
      set = function(value)
        local sources = core.parse_source_command(value)
        if sources then
          api.on({ sources = sources })
        end
      end,
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
        local symbol = #status.tracks > 0
            and (" tracks=" .. table.concat(
              vim.tbl_map(function(track)
                return track.symbol .. (track.moving and "*" or "")
              end, status.tracks),
              ","
            ))
          or ""
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

  local function command(opts)
    local args = vim.split(vim.trim(opts.args or ""), "%s+", { trimempty = true })
    local sub = subcommands[args[1]]
    if not sub then
      core.notify(
        "TunnelVision: use one of on, add, pin, remove, retarget, off, toggle, next, prev, next-track, "
          .. "prev-track, refresh, quickfix, dim, mode, direction, scope, source, status",
        vim.log.levels.ERROR
      )
      return
    end

    if args[1] == "dim" then
      if args[3] then
        core.notify("TunnelVision: 'dim' takes a single value", vim.log.levels.ERROR)
      elseif not args[2] then
        local bs = core.state.bufs[vim.api.nvim_get_current_buf()]
        core.notify("TunnelVision dim: " .. vim.inspect(bs and bs.dim_override or core.state.config.dim))
      elseif args[2] == "reset" then
        api.set_buffer_dim(nil)
      elseif args[2]:sub(1, 1) == "#" and not args[2]:match("^#%x%x%x%x%x%x$") then
        core.notify("TunnelVision: dim hex color must be #RRGGBB", vim.log.levels.ERROR)
      else
        api.set_buffer_dim(args[2])
      end
      return
    end

    if sub.values then
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
      if args[1] ~= "source" and not vim.tbl_contains(sub.values, value) then
        core.notify(("TunnelVision: invalid %s '%s'"):format(args[1], value), vim.log.levels.ERROR)
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
  end

  for _, name in ipairs({ "TunnelVision", "Tunnelvision" }) do
    vim.api.nvim_create_user_command(name, command, {
      complete = complete,
      desc = "Control tunnel vision",
      nargs = "*",
    })
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
      state.dynamic_seq[args.buf] = nil
      core.clear_buf_state(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.augroup,
    callback = function()
      M.ensure_highlights()
      for bufnr, bs in pairs(core.state.bufs) do
        if bs.active and bs.config then
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
      if core.get_moving_track(args.buf) and bs and bs.active then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local symbol = core.symbol_at(args.buf, cursor)
        if core.should_dynamic_retarget(args.buf, symbol, cursor) then
          schedule_dynamic_activate(args.buf, symbol, cursor)
        else
          cancel_dynamic_activate(args.buf)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    callback = function(args)
      cancel_dynamic_activate(args.buf)
      if core.is_active(args.buf) then
        schedule_edit_refresh(args.buf)
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
