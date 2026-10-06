-- tunnelvision.core
--
-- Runtime orchestration for TunnelVision.
--
-- Responsibilities:
-- - own global and per-buffer plugin state
-- - validate and store user configuration
-- - activate/deactivate tracking for the current symbol
-- - coordinate async LSP requests and stale-response rejection
-- - refresh active buffers and support path navigation
-- - forward computed paths to the configured renderer
--
-- Non-goals:
-- - path computation details live in tunnelvision.resolver
-- - Neovim command/autocmd wiring lives in tunnelvision.ui

local resolver = require("tunnelvision.resolver")
local config = require("tunnelvision.config")

local M = {}

local state = {
  ns = vim.api.nvim_create_namespace("tunnelvision"),
  bufs = {},
  config = vim.deepcopy(config.defaults),
  custom_sources = {},
  request_seq = 0,
}

M.state = state

local function cancel_requests(bs)
  if bs then
    resolver.cancel_lsp_requests(bs.request_handles)
    bs.request_handles = {}
  end
end

function M.notify(msg, level)
  if state.config.notify then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
end

local warned_deprecated = {}

function M.warn_deprecated(category, message, enabled)
  if enabled == nil then
    enabled = state.config.notify
  end
  if enabled and not warned_deprecated[category] then
    warned_deprecated[category] = true
    vim.notify("TunnelVision: deprecated " .. message, vim.log.levels.WARN)
  end
end

function M.validate_options(opts, activation)
  local err = config.validate_options(opts, activation)
  if err then
    -- Invalid inputs must stay visible even when informational notices are disabled.
    vim.notify("TunnelVision: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.get_buf_state(bufnr)
  local s = state.bufs[bufnr]
  if s then
    return s
  end

  s = {
    active = false,
    tracks = {},
    refreshing = false,
    symbol = nil,
    anchor = nil,
    scope = nil,
    path_set = {},
    path_order = {},
    symbol_ranges = {},
    statement_set = {},
    scope_head_set = {},
    warned_lsp_fallback = false,
    warned_lsp_strict = false,
    warned_lsp_timeout = false,
    warned_large_buffer = false,
    last_compute_meta = nil,
    pending = false,
    request_id = nil,
    request_handles = {},
    config = nil,
    dim_override = nil,
    force_dim = false,
    render_groups = nil,
  }
  state.bufs[bufnr] = s
  return s
end

function M.clear_buf_state(bufnr)
  require("tunnelvision.ui").cancel_edit_refresh(bufnr)
  require("tunnelvision.ui").cancel_dynamic_activate(bufnr)
  local bs = state.bufs[bufnr]
  state.bufs[bufnr] = nil
  if bs then
    for _, track in ipairs(bs.tracks) do
      track.request_id = nil
      cancel_requests(track)
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
  require("tunnelvision.ui").clear_render_groups(bs)
  if bs and bs.dim_override ~= nil then
    pcall(vim.api.nvim_set_hl, 0, ("TunnelVisionDimBuffer%d"):format(bufnr), {})
  end
end

local function get_line_target_col(line, symbol)
  local symbol_col = line and symbol and symbol ~= "" and line:find("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]")
  if symbol_col then
    return symbol_col - 1
  end

  local first_nonblank = line and line:find("%S")
  return first_nonblank and first_nonblank - 1 or 0
end

M.combine = config.combine

function M.configure(opts)
  opts = opts or {}
  if not M.validate_options(opts, false) then
    return false
  end
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts)
  if opts.source ~= nil and opts.sources == nil then
    cfg.sources = nil
  end
  if opts.highlights ~= nil then
    cfg.highlights = opts.highlights
  end

  -- Compatibility: deprecated top-level flow options fill missing
  -- flow_settings fields. New nested fields win.
  if opts.direction ~= nil and (opts.flow_settings == nil or opts.flow_settings.direction == nil) then
    cfg.flow_settings.direction = cfg.direction
  end
  if opts.extra_keywords ~= nil and (opts.flow_settings == nil or opts.flow_settings.extra_keywords == nil) then
    cfg.flow_settings.extra_keywords = cfg.extra_keywords
  end
  config.normalize(cfg, state.custom_sources)
  state.config = cfg
  local deprecated = config.deprecated_inputs(opts)
  if #deprecated > 0 then
    M.warn_deprecated(
      "setup",
      "setup options: " .. table.concat(deprecated, ", ") .. "; see :help tunnelvision-migration",
      cfg.notify
    )
  end
  return true
end

local function activation_config(opts)
  local cfg = config.normalize_activation(
    opts.config or opts.track and opts.track.config or state.config,
    opts,
    state.custom_sources
  )
  return cfg, resolver.build_keywords(cfg.flow_settings.extra_keywords)
end

local function configs_equal(a, b)
  return a
    and b
    and a.mode == b.mode
    and a.flow_settings.direction == b.flow_settings.direction
    and a.scope == b.scope
    and vim.deep_equal(a.sources, b.sources)
    and a.fallback_warn == b.fallback_warn
    and a.lsp_timeout_ms == b.lsp_timeout_ms
    and vim.deep_equal(a.highlights, b.highlights)
    and a.request_dim == b.request_dim
    and vim.deep_equal(a.flow_settings.extra_keywords, b.flow_settings.extra_keywords)
    and vim.deep_equal(a.flow_settings.analyzers, b.flow_settings.analyzers)
    and a.flow_settings.max_depth == b.flow_settings.max_depth
end

-- Compatibility alias for the historical top-level flow API.
-- Mutates flow_settings.extra_keywords internally.
function M.add_keywords(words)
  local incoming = resolver.sanitize_keywords(words)
  if #incoming == 0 then
    return false
  end

  local existing = {}
  state.config.flow_settings.extra_keywords = state.config.flow_settings.extra_keywords or {}
  for _, word in ipairs(state.config.flow_settings.extra_keywords) do
    existing[word] = true
  end

  local changed = false
  for _, word in ipairs(incoming) do
    if not existing[word] then
      state.config.flow_settings.extra_keywords[#state.config.flow_settings.extra_keywords + 1] = word
      existing[word] = true
      changed = true
    end
  end

  if not changed then
    return false
  end

  return true
end

local function sync_buffer(bufnr, bs, defer_render, completed)
  if bs.refreshing then
    for _, track in ipairs(bs.tracks) do
      if track.pending then
        bs.pending = true
        bs.request_id = bs.tracks[#bs.tracks].request_id
        return
      end
    end
    bs.refreshing = false
  end
  local selected = bs.tracks[#bs.tracks]
  bs.active = selected ~= nil
  for _, key in ipairs({ "symbol", "anchor", "scope", "config", "last_compute_meta", "request_id" }) do
    bs[key] = selected and selected[key] or nil
  end
  bs.pending = false
  bs.path_set, bs.path_order, bs.symbol_ranges = {}, {}, {}
  bs.statement_set, bs.scope_head_set = {}, {}
  local seen = {}
  for _, track in ipairs(bs.tracks) do
    bs.pending = bs.pending or track.pending
    for _, key in ipairs({ "path_set", "statement_set", "scope_head_set" }) do
      for line in pairs(track[key]) do
        bs[key][line] = true
      end
    end
    for _, range in ipairs(track.symbol_ranges) do
      bs.symbol_ranges[#bs.symbol_ranges + 1] = range
    end
  end
  table.sort(bs.symbol_ranges, function(a, b)
    return a.line == b.line and a.start_col < b.start_col or a.line < b.line
  end)
  for _, range in ipairs(bs.symbol_ranges) do
    if not seen[range.line] then
      bs.path_order[#bs.path_order + 1] = range.line
      seen[range.line] = true
    end
  end
  -- Paths without ranges (custom sources and flow-added lines) still navigate.
  for line in pairs(bs.path_set) do
    if not seen[line] then
      bs.path_order[#bs.path_order + 1] = line
    end
  end
  table.sort(bs.path_order)
  if bs.active and not defer_render and (completed or not bs.pending) then
    require("tunnelvision.ui").render(bufnr)
  end
end

local function refresh_track(bufnr, track)
  local row = math.min(track.anchor.row + 1, vim.api.nvim_buf_line_count(bufnr))
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  M.activate(bufnr, {
    config = track.config,
    cursor = { row, math.min(track.anchor.col, #line) },
    force = true,
    reuse_scope = true,
    silent = true,
    symbol = track.symbol,
    track = track,
  })
end

local function lsp_warn_msg(kind, reason)
  local cause = ({
    no_clients = "no LSP client attached",
    unsupported = "LSP server has no documentHighlight support",
    request_failed = "LSP highlight request failed or timed out",
    disabled = "LSP data unavailable",
  })[reason] or "LSP data unavailable"

  if kind == "fallback" then
    return ("TunnelVision: falling back to word matching (%s)"):format(cause)
  end

  return ("TunnelVision: strict LSP source has no highlights (%s)"):format(cause)
end

local function maybe_warn_fallback(bs, silent, cfg)
  if
    config.legacy_source_from_sources(cfg.sources) ~= "lsp_else_word"
    or not bs.last_compute_meta
    or not bs.last_compute_meta.used_fallback
  then
    return
  end

  if silent then
    return
  end

  local fw = cfg.fallback_warn
  if fw == "always" or (fw == "once" and not bs.warned_lsp_fallback) then
    M.notify(lsp_warn_msg("fallback", bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
    bs.warned_lsp_fallback = true
  end
end

local function maybe_warn_strict_lsp(bs, silent, cfg)
  if
    config.legacy_source_from_sources(cfg.sources) ~= "lsp"
    or not bs.last_compute_meta
    or bs.last_compute_meta.used_lsp
  then
    return
  end

  if silent or bs.warned_lsp_strict then
    return
  end

  M.notify(lsp_warn_msg("strict", bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
  bs.warned_lsp_strict = true
end

local function apply_path(bufnr, bs, track, opts, cfg, path_set, path_order, meta, ranges, context)
  track.pending = false
  track.request_id = nil
  track.request_handles = {}
  track.path_set, track.path_order, track.last_compute_meta, track.symbol_ranges = path_set, path_order, meta, ranges
  track.statement_set, track.scope_head_set =
    require("tunnelvision.context").evaluate(cfg, track.path_set, track.symbol_ranges, bufnr, track.scope, context)
  -- Retain the rendered policy while a later asynchronous retarget is pending.
  track.rendered_highlights = cfg.highlights
  track.rendered_request_dim = cfg.request_dim
  maybe_warn_fallback(track, opts.silent, cfg)
  maybe_warn_strict_lsp(track, opts.silent, cfg)
  sync_buffer(bufnr, bs, opts.defer_render, true)
end

local function resolve_path(bufnr, bs, track, symbol, anchor, scope, opts, cfg, keywords, context)
  local resolution_context = context
  local function resolve(lsp_result)
    local path_set, path_order, meta, ranges, pending = resolver.compute_path(bufnr, symbol, anchor, scope, {
      direction = cfg.flow_settings.direction,
      analyzers = cfg.flow_settings.analyzers,
      max_depth = cfg.flow_settings.max_depth,
      custom_sources = state.custom_sources,
      keywords = keywords,
      lsp_result = lsp_result,
      mode = cfg.mode,
      pause_for_lsp = true,
      resolution_context = resolution_context,
      sources = cfg.sources,
    })
    if not pending then
      apply_path(bufnr, bs, track, opts, cfg, path_set, path_order, meta, ranges, resolution_context)
      return
    end

    resolution_context = pending
    local available, reason = resolver.get_lsp_status(bufnr)
    if not available then
      resolve(resolver.make_lsp_result(reason))
      return
    end

    state.request_seq = state.request_seq + 1
    track.pending = true
    track.request_id = state.request_seq
    sync_buffer(bufnr, bs, opts.defer_render)
    local request_id = track.request_id
    local handles = resolver.request_lsp_highlight(bufnr, anchor, scope, cfg.lsp_timeout_ms, function(result)
      local current = state.bufs[bufnr]
      if
        not current
        or not current.active
        or track.request_id ~= request_id
        or track.symbol ~= symbol
        or not vim.tbl_contains(current.tracks, track)
        or not resolver.anchors_equal(track.anchor, anchor)
        or not resolver.scopes_equal(track.scope, scope)
        or vim.api.nvim_buf_get_changedtick(bufnr) ~= scope.changedtick
      then
        return
      end

      if result.timed_out and state.config.notify and not bs.warned_lsp_timeout then
        bs.warned_lsp_timeout = true
        M.notify(
          "TunnelVision: LSP documentHighlight timed out; future activations will retry LSP. "
            .. 'To prioritize local matches, use setup({ sources = { "treesitter", "word", "lsp" } }). '
            .. "See :help tunnelvision-troubleshooting",
          vim.log.levels.WARN
        )
      end
      resolve(result)
    end, pending)
    if track.request_id == request_id then
      track.request_handles = handles
    end
  end

  resolve()
end

local function symbol_at(bufnr, cursor)
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local col = cursor[2] + 1
  local start_col, end_col
  for first, _, last in line:gmatch("()([%w_]+)()") do
    if first <= col and col < last then
      start_col, end_col = first, last
      break
    end
  end
  if start_col then
    return line:sub(start_col, end_col - 1)
  end
  return nil
end

M.symbol_at = symbol_at

function M.valid_target(bufnr, opts)
  if type(opts) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if opts.symbol ~= nil and (type(opts.symbol) ~= "string" or opts.symbol == "") then
    return false
  end
  local cursor = opts.cursor
  if cursor == nil then
    return true
  end
  if
    type(cursor) ~= "table"
    or type(cursor[1]) ~= "number"
    or type(cursor[2]) ~= "number"
    or cursor[1] % 1 ~= 0
    or cursor[2] % 1 ~= 0
    or cursor[1] < 1
    or cursor[1] > vim.api.nvim_buf_line_count(bufnr)
    or cursor[2] < 0
  then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  return cursor[2] <= #line
end

function M.activate(bufnr, opts)
  opts = opts or {}
  if not M.validate_options(opts, true) then
    return false
  end
  local deprecated = config.deprecated_inputs(opts)
  if #deprecated > 0 then
    M.warn_deprecated(
      "use",
      "activation options: " .. table.concat(deprecated, ", ") .. "; see :help tunnelvision-migration"
    )
  end
  if not M.valid_target(bufnr, opts) then
    M.notify("TunnelVision: invalid symbol or cursor", vim.log.levels.WARN)
    return false
  end
  local cursor = opts.cursor or vim.api.nvim_win_get_cursor(0)
  local under_cursor = symbol_at(bufnr, cursor)
  local symbol = opts.symbol or under_cursor
  if
    not opts.symbol
    and under_cursor
    and bufnr == vim.api.nvim_get_current_buf()
    and vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0))
  then
    symbol = vim.fn.expand("<cword>")
  end
  if not symbol or symbol == "" then
    if not opts.silent then
      M.notify("TunnelVision: no symbol under cursor", vim.log.levels.WARN)
    end
    return false
  end

  require("tunnelvision.ui").cancel_edit_refresh(bufnr)
  require("tunnelvision.ui").cancel_dynamic_activate(bufnr)
  local anchor = { row = cursor[1] - 1, col = cursor[2] }
  local cfg, keywords = activation_config(opts)
  local context = { bufnr = bufnr }
  local bs = M.get_buf_state(bufnr)
  if not opts.track and not bs.refreshing then
    for _, existing in ipairs(bs.tracks) do
      if existing.scope.changedtick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
        M.refresh(bufnr)
        break
      end
    end
  end
  local moving = cfg.mode == "dynamic" or cfg.mode == "dynamic_flow"
  if opts.pin then
    moving = false
    cfg.mode = (cfg.mode == "dynamic_flow" or cfg.mode == "flow") and "flow" or "static"
  end
  local track = opts.track
  local scope = resolver.resolve_scope(
    bufnr,
    anchor,
    track and opts.reuse_scope ~= false and track.scope or nil,
    cfg.scope,
    context
  )
  if not track then
    for _, candidate in ipairs(bs.tracks) do
      local same_occurrence = candidate.anchor.row == anchor.row and candidate.anchor.col == anchor.col
      for _, range in ipairs(candidate.symbol_ranges) do
        if range.line == cursor[1] and range.start_col <= cursor[2] and cursor[2] < range.end_col then
          same_occurrence = true
          break
        end
      end
      if
        candidate.symbol == symbol
        and candidate.moving == moving
        and resolver.scopes_equal(candidate.scope, scope)
        and (same_occurrence or opts.force)
      then
        if not opts.force and configs_equal(candidate.config, cfg) then
          return false
        end
        track = candidate
        break
      end
    end
  end
  if not track then
    if moving then
      for i = #bs.tracks, 1, -1 do
        if bs.tracks[i].moving then
          bs.tracks[i].request_id = nil
          cancel_requests(bs.tracks[i])
          table.remove(bs.tracks, i)
        end
      end
    end
    track = {
      path_set = {},
      path_order = {},
      symbol_ranges = {},
      statement_set = {},
      scope_head_set = {},
      request_handles = {},
      moving = moving,
    }
    bs.tracks[#bs.tracks + 1] = track
  end
  track.pending, track.request_id = true, nil
  cancel_requests(track)
  track.symbol, track.anchor, track.scope, track.config = symbol, anchor, scope, cfg
  track.moving = moving
  sync_buffer(bufnr, bs, true)
  resolve_path(bufnr, bs, track, symbol, anchor, scope, opts, cfg, keywords, context)
  return true
end

function M.activate_many(bufnr, positions, opts)
  if type(positions) ~= "table" or type(opts or {}) ~= "table" then
    return false
  end
  if not M.validate_options(opts or {}, true) then
    return false
  end
  for _, cursor in ipairs(positions) do
    if not M.valid_target(bufnr, vim.tbl_extend("force", opts or {}, { cursor = cursor })) then
      return false
    end
  end
  local changed, calls = false, {}
  for index, cursor in ipairs(positions) do
    local call = vim.tbl_extend("force", opts or {}, { cursor = cursor, defer_render = true })
    if #positions > 1 and index < #positions and call.pin == nil then
      call.pin = true
    end
    calls[#calls + 1] = call
    changed = M.activate(bufnr, call) or changed
  end
  for _, call in ipairs(calls) do
    call.defer_render = false
  end
  if changed then
    local bs = state.bufs[bufnr]
    if bs and bs.active and (not bs.pending or next(bs.path_set)) then
      require("tunnelvision.ui").render(bufnr)
    end
  end
  return changed
end

function M.remove(bufnr, cursor)
  require("tunnelvision.ui").cancel_dynamic_activate(bufnr)
  local bs = state.bufs[bufnr]
  if not bs or #bs.tracks == 0 then
    return false
  end
  cursor = cursor or vim.api.nvim_win_get_cursor(0)
  local index
  local symbol = symbol_at(bufnr, cursor)
  for i = #bs.tracks, 1, -1 do
    local track = bs.tracks[i]
    if track.anchor.row == cursor[1] - 1 and track.symbol == symbol then
      index = i
    end
    for _, range in ipairs(track.symbol_ranges) do
      if range.line == cursor[1] and range.start_col <= cursor[2] and cursor[2] < range.end_col then
        index = i
        break
      end
    end
    if index then
      break
    end
  end
  index = index or #bs.tracks
  bs.tracks[index].request_id = nil
  cancel_requests(bs.tracks[index])
  table.remove(bs.tracks, index)
  bs.refreshing = false
  if #bs.tracks == 0 then
    M.deactivate(bufnr)
  else
    sync_buffer(bufnr, bs, false, true)
  end
  return true
end

function M.deactivate(bufnr)
  require("tunnelvision.ui").cancel_edit_refresh(bufnr)
  require("tunnelvision.ui").cancel_dynamic_activate(bufnr)
  local bs = state.bufs[bufnr]
  if bs then
    for _, track in ipairs(bs.tracks) do
      track.request_id = nil
    end
    for _, track in ipairs(bs.tracks) do
      cancel_requests(track)
    end
    bs.tracks = {}
    bs.refreshing = false
    bs.warned_large_buffer = false
    sync_buffer(bufnr, bs)
    require("tunnelvision.ui").clear_render_groups(bs)
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
end

function M.set_buffer_dim(dim, bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(b) or dim ~= nil and type(dim) ~= "string" and type(dim) ~= "table" then
    return false
  end
  local bs = M.get_buf_state(b)
  if dim == nil and bs.dim_override ~= nil then
    pcall(vim.api.nvim_set_hl, 0, ("TunnelVisionDimBuffer%d"):format(b), {})
  end
  bs.dim_override = dim and config.normalize_dim(vim.deepcopy(dim)) or nil
  if dim == nil then
    bs.force_dim = false
  end
  if bs.active then
    require("tunnelvision.ui").render(b)
  end
  return true
end

function M.force_buffer_dim(enabled, bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(b) or type(enabled) ~= "boolean" then
    return false
  end
  local bs = M.get_buf_state(b)
  bs.force_dim = enabled
  if bs.active then
    require("tunnelvision.ui").render(b)
  end
  return true
end

function M.is_active(bufnr)
  local b = bufnr
  if not b or b == 0 then
    b = vim.api.nvim_get_current_buf()
  end
  local bs = state.bufs[b]
  return bs and bs.active or false
end

local function occurrences(bs, bufnr)
  local targets, seen, lines = {}, {}, {}
  for _, track in ipairs(bs.tracks) do
    for _, range in ipairs(track.symbol_ranges) do
      local key = range.line .. ":" .. range.start_col
      lines[range.line] = true
      if not seen[key] then
        seen[key] = true
        targets[#targets + 1] = { range.line, range.start_col }
      end
    end
  end
  -- Custom sources may provide lines without any occurrence ranges.
  for _, track in ipairs(bs.tracks) do
    for _, line in ipairs(track.path_order) do
      if not lines[line] then
        lines[line] = true
        local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
        local col = get_line_target_col(text, track.symbol)
        local key = line .. ":" .. col
        if not seen[key] then
          seen[key] = true
          targets[#targets + 1] = { line, col }
        end
      end
    end
  end
  table.sort(targets, function(a, b)
    return a[1] == b[1] and a[2] < b[2] or a[1] < b[1]
  end)
  return targets
end

-- Vim records jumps internally and exposes no way to push an entry
-- (`setjumplist()` does not exist), so jump with a line-wise `{line}G`, which Vim
-- counts as a jump, then place the exact column. Moves within one line are not
-- jumps to Vim, so they stay out of the jumplist, as with `n`.
local function move_cursor(cursor)
  if not pcall(vim.cmd, ("normal! %dG"):format(cursor[1])) then
    return false
  end
  return pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end

local function jump_to_targets(direction, count, targets)
  if #targets == 0 then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local index
  for _ = 1, math.max(1, count or 1) do
    index = nil
    if direction > 0 then
      for i, target in ipairs(targets) do
        if target[1] > cursor[1] or target[1] == cursor[1] and target[2] > cursor[2] then
          index = i
          break
        end
      end
      index = index or 1
    else
      for i = #targets, 1, -1 do
        local target = targets[i]
        if target[1] < cursor[1] or target[1] == cursor[1] and target[2] < cursor[2] then
          index = i
          break
        end
      end
      index = index or #targets
    end
    cursor = targets[index]
  end
  return move_cursor(cursor)
end

function M.jump_in_path(direction, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = M.get_buf_state(bufnr)
  if not bs.active then
    return false
  end
  return jump_to_targets(direction, count, occurrences(bs, bufnr))
end

local function track_occurrences(track, bufnr)
  local targets, seen, lines = {}, {}, {}
  for _, range in ipairs(track.symbol_ranges) do
    local key = range.line .. ":" .. range.start_col
    lines[range.line] = true
    if not seen[key] then
      seen[key] = true
      targets[#targets + 1] = { range.line, range.start_col }
    end
  end
  for _, line in ipairs(track.path_order) do
    if not lines[line] then
      local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      local col = get_line_target_col(text, track.symbol)
      local key = line .. ":" .. col
      if not seen[key] then
        seen[key] = true
        targets[#targets + 1] = { line, col }
      end
    end
  end
  table.sort(targets, function(a, b)
    return a[1] == b[1] and a[2] < b[2] or a[1] < b[1]
  end)
  return targets
end

function M.jump_in_track(direction, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = M.get_buf_state(bufnr)
  if not bs.active or #bs.tracks == 0 then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local symbol = symbol_at(bufnr, cursor)
  local selected
  for i = #bs.tracks, 1, -1 do
    local track = bs.tracks[i]
    if track.anchor.row == cursor[1] - 1 and track.symbol == symbol then
      selected = track
      break
    end
    for _, range in ipairs(track.symbol_ranges) do
      if range.line == cursor[1] and range.start_col <= cursor[2] and cursor[2] < range.end_col then
        selected = track
        break
      end
    end
    if selected then
      break
    end
  end
  if not selected then
    for i = #bs.tracks, 1, -1 do
      if vim.tbl_contains(bs.tracks[i].path_order, cursor[1]) then
        selected = bs.tracks[i]
        break
      end
    end
  end
  selected = selected or bs.tracks[#bs.tracks]
  return jump_to_targets(direction, count, track_occurrences(selected, bufnr))
end

function M.occurrences(bufnr)
  local bs = state.bufs[bufnr]
  if not bs or not bs.active then
    return {}
  end
  local result = {}
  local seen = {}
  for _, track in ipairs(bs.tracks) do
    for _, range in ipairs(track.symbol_ranges) do
      local key = range.line .. ":" .. range.start_col
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = { range.line, range.start_col }
      end
    end
  end
  table.sort(result, function(a, b)
    return a[1] == b[1] and a[2] < b[2] or a[1] < b[1]
  end)
  return result
end

function M.set_quickfix(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local bs = state.bufs[b]
  if not bs or not bs.active or not vim.api.nvim_buf_is_valid(b) then
    return 0
  end

  local items = {}
  -- Same union and dedupe as `next`/`prev`: overlapping tracks share an entry.
  for _, target in ipairs(occurrences(bs, b)) do
    items[#items + 1] = {
      bufnr = b,
      lnum = target[1],
      col = target[2] + 1,
      text = vim.api.nvim_buf_get_lines(b, target[1] - 1, target[1], false)[1] or "",
    }
  end
  if #items == 0 then
    return 0
  end

  local name = vim.api.nvim_buf_get_name(b)
  local title = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  vim.fn.setqflist({}, " ", { title = "TunnelVision: " .. title, items = items })
  return #items
end

function M.refresh(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local bs = state.bufs[b]
  if bs and bs.active and vim.api.nvim_buf_is_valid(b) then
    bs.refreshing = true
    bs.pending = true
    for _, track in ipairs(bs.tracks) do
      track.request_id = nil
      track.pending = true
      cancel_requests(track)
    end
    for _, track in ipairs(bs.tracks) do
      refresh_track(b, track)
    end
  end
end

function M.should_dynamic_retarget(bufnr, symbol, cursor)
  local track = M.get_moving_track(bufnr)
  if not track or not symbol or symbol == "" then
    return false
  end
  if symbol ~= track.symbol then
    return true
  end
  local anchor = { row = cursor[1] - 1, col = cursor[2] }
  local scope = resolver.resolve_scope(bufnr, anchor, track.scope, track.config.scope)
  return not resolver.scopes_equal(track.scope, scope)
end

function M.get_moving_track(bufnr)
  local bs = state.bufs[bufnr]
  for _, track in ipairs(bs and bs.tracks or {}) do
    if track.moving then
      return track
    end
  end
end

function M.get_active_mode(bufnr)
  local track = M.get_moving_track(bufnr)
  return track and track.config.mode or state.config.mode
end

function M.get_mode()
  return state.config.mode
end

function M.set_mode(mode)
  if not config.valid_modes[mode] then
    M.notify("TunnelVision: mode must be static, flow, dynamic, or dynamic_flow", vim.log.levels.ERROR)
    return
  end
  state.config.mode = mode
end

-- Compatibility alias for the historical top-level flow API.
-- Returns flow_settings.direction.
function M.get_direction()
  return state.config.flow_settings.direction
end

-- Compatibility alias for the historical top-level flow API.
-- Mutates flow_settings.direction.
function M.set_direction(direction)
  if not config.valid_directions[direction] then
    M.notify("TunnelVision: direction must be forward, backward, or both", vim.log.levels.ERROR)
    return
  end
  state.config.flow_settings.direction = direction
end

function M.get_scope()
  return state.config.scope
end

function M.set_scope(scope)
  if not config.valid_scopes[scope] then
    M.notify("TunnelVision: scope must be function or buffer", vim.log.levels.ERROR)
    return
  end
  state.config.scope = scope
end

function M.get_sources()
  return config.get_sources_copy(state.config.sources)
end

function M.set_sources(sources)
  local normalized = config.normalize_sources(sources, state.custom_sources)
  state.config.sources = normalized
  state.config.source = config.legacy_source_from_sources(normalized) or config.defaults.source
end

function M.register_source(name, handler)
  if
    type(name) ~= "string"
    or name == ""
    or type(handler) ~= "function"
    or config.valid_source_names[name]
    or config.valid_sources[name]
  then
    return false
  end

  state.custom_sources[name] = handler
  return true
end

-- Compatibility API (deprecated). Returns the legacy source string when the
-- current normalized sources can be represented by a single legacy value,
-- otherwise returns nil.
function M.get_source()
  M.warn_deprecated("use", "get_source(); use get_sources()")
  return config.legacy_source_from_sources(state.config.sources)
end

function M.get_sources_label()
  return config.format_sources(state.config.sources)
end

-- Parse a command source without changing setup defaults.
function M.parse_source_command(value)
  if config.valid_sources[value] then
    if value == "lsp_else_word" or value == "lsp_and_word" then
      M.warn_deprecated("use", "source value " .. value .. "; use a source chain")
    end
    return config.sources_from_legacy_source(value)
  end
  if config.valid_source_names[value] then
    return { value }
  end

  local parts = vim.split(value, ",")
  if #parts > 1 then
    local names = {}
    for _, part in ipairs(parts) do
      local name = vim.trim(part)
      if not config.valid_source_names[name] then
        M.notify("TunnelVision: invalid source name '" .. name .. "'", vim.log.levels.ERROR)
        return
      end
      names[#names + 1] = name
    end
    return names
  end

  M.notify(
    "TunnelVision: source must be lsp_else_word, lsp, lsp_and_word, word, treesitter,"
      .. " or a comma-separated chain like lsp,word or treesitter,word",
    vim.log.levels.ERROR
  )
end

-- Compatibility API (deprecated). Maps legacy source values to normalized
-- sources.
function M.set_source(source)
  M.warn_deprecated("use", "set_source(); use set_sources()")
  if not config.valid_sources[source] then
    M.notify("TunnelVision: source must be lsp_else_word, lsp, lsp_and_word, or word", vim.log.levels.ERROR)
    return
  end
  state.config.sources = config.normalize_sources(config.sources_from_legacy_source(source), state.custom_sources)
  state.config.source = source
end

function M.get_status(bufnr)
  local b = bufnr
  if not b or b == 0 then
    b = vim.api.nvim_get_current_buf()
  end

  local bs = state.bufs[b]
  local cfg = bs and bs.config or state.config
  local meta = bs and not bs.pending and bs.last_compute_meta or {}
  return {
    active = bs and bs.active or false,
    tracks = vim.tbl_map(function(track)
      return { symbol = track.symbol, mode = track.config.mode, moving = track.moving, pending = track.pending }
    end, bs and bs.tracks or {}),
    pending = bs and bs.pending or false,
    symbol = bs and bs.symbol or nil,
    mode = cfg.mode,
    direction = cfg.flow_settings.direction,
    analyzers = vim.deepcopy(cfg.flow_settings.analyzers),
    max_depth = cfg.flow_settings.max_depth,
    scope = cfg.scope,
    source = config.legacy_source_from_sources(cfg.sources),
    sources = config.get_sources_copy(cfg.sources),
    sources_label = config.format_sources(cfg.sources),
    flow_analyzer = meta.flow_analyzer,
    flow_analyzers = vim.deepcopy(meta.flow_analyzers),
    flow_expanded = meta.flow_expanded or false,
    flow_tracked_count = meta.flow_tracked_count or 0,
    flow_added_lines = meta.flow_added_lines or 0,
    flow_fallback = meta.flow_fallback or false,
    flow_fallback_reason = meta.flow_fallback_reason,
  }
end

return M
