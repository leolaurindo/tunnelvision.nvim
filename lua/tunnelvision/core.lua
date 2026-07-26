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

local refresh_active_buffers = function() end

function M.notify(msg, level)
  if state.config.notify then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
end

function M.get_buf_state(bufnr)
  local s = state.bufs[bufnr]
  if s then
    return s
  end

  s = {
    active = false,
    symbol = nil,
    anchor = nil,
    scope = nil,
    path_set = {},
    path_order = {},
    context_set = {},
    warned_lsp_fallback = false,
    warned_lsp_strict = false,
    warned_large_buffer = false,
    last_compute_meta = nil,
    pending = false,
    request_id = nil,
    config = nil,
  }
  state.bufs[bufnr] = s
  return s
end

function M.clear_buf_state(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
  state.bufs[bufnr] = nil
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
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts)
  if opts.sources == nil then
    state.config.sources = nil
  end
  if opts.highlights ~= nil then
    state.config.highlights = opts.highlights
  end

  -- Compatibility: deprecated top-level flow options fill missing
  -- flow_settings fields. New nested fields win. No runtime warnings.
  if opts.direction ~= nil and (opts.flow_settings == nil or opts.flow_settings.direction == nil) then
    state.config.flow_settings.direction = state.config.direction
  end
  if opts.extra_keywords ~= nil and (opts.flow_settings == nil or opts.flow_settings.extra_keywords == nil) then
    state.config.flow_settings.extra_keywords = state.config.extra_keywords
  end
  config.normalize(state.config, state.custom_sources)
end

local function activation_config(bufnr, opts)
  local cfg = config.normalize_activation(opts.config or state.config, opts, bufnr, state.custom_sources)
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
    and a.dim_hl == b.dim_hl
    and vim.deep_equal(a.highlights, b.highlights)
    and vim.deep_equal(a.dim, b.dim)
    and vim.deep_equal(a.flow_settings.extra_keywords, b.flow_settings.extra_keywords)
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

  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
  return true
end

local function refresh_buffer(bufnr, bs, cfg)
  if not bs.active or not bs.symbol or not bs.anchor or not bs.scope then
    return
  end

  M.activate(bufnr, {
    config = cfg or bs.config,
    cursor = { bs.anchor.row + 1, bs.anchor.col },
    force = true,
    reuse_scope = true,
    silent = true,
    symbol = bs.symbol,
  })
end

refresh_active_buffers = function()
  for bufnr, bs in pairs(state.bufs) do
    if bs.active and vim.api.nvim_buf_is_valid(bufnr) then
      refresh_buffer(bufnr, bs)
    end
  end
end

local function refresh_active_buffers_with(cfg)
  for bufnr, bs in pairs(state.bufs) do
    if bs.active and vim.api.nvim_buf_is_valid(bufnr) then
      refresh_buffer(bufnr, bs, cfg)
    end
  end
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

local function apply_path(bufnr, bs, symbol, anchor, scope, opts, cfg, keywords, lsp_result)
  bs.pending = false
  bs.request_id = nil
  bs.path_set, bs.path_order, bs.last_compute_meta = resolver.compute_path(bufnr, symbol, anchor, scope, {
    direction = cfg.flow_settings.direction,
    custom_sources = state.custom_sources,
    keywords = keywords,
    lsp_result = lsp_result,
    mode = cfg.mode,
    sources = cfg.sources,
  })
  bs.context_set = require("tunnelvision.context").evaluate(cfg, bs.path_set, bufnr, symbol, anchor, scope)
  maybe_warn_fallback(bs, opts.silent, cfg)
  maybe_warn_strict_lsp(bs, opts.silent, cfg)
  require("tunnelvision.ui").apply_dim(bufnr)
end

function M.activate(bufnr, opts)
  opts = opts or {}
  local symbol = opts.symbol
  if symbol == nil then
    symbol = vim.fn.expand("<cword>")
  end
  if not symbol or symbol == "" then
    if not opts.silent then
      M.notify("TunnelVision: no symbol under cursor", vim.log.levels.WARN)
    end
    return false
  end

  local cursor = opts.cursor or vim.api.nvim_win_get_cursor(0)
  local anchor = { row = cursor[1] - 1, col = cursor[2] }
  local cfg, keywords = activation_config(bufnr, opts)

  local bs = M.get_buf_state(bufnr)
  local scope = resolver.resolve_scope(bufnr, anchor, opts.reuse_scope ~= false and bs.scope or nil, cfg.scope)
  local keep_render = bs.active and not bs.pending and next(bs.path_set) ~= nil
  if
    bs.active
    and bs.symbol == symbol
    and resolver.anchors_equal(bs.anchor, anchor)
    and resolver.scopes_equal(bs.scope, scope)
    and configs_equal(bs.config, cfg)
    and not opts.force
  then
    return false
  end

  bs.active = true
  bs.pending = false
  bs.symbol = symbol
  bs.anchor = anchor
  bs.scope = scope
  bs.request_id = nil
  bs.config = cfg
  if not keep_render then
    bs.path_set = {}
    bs.path_order = {}
    bs.context_set = {}
    bs.last_compute_meta = nil
    bs.warned_lsp_strict = false
  end

  if not config.sources_use_lsp(cfg.sources) then
    apply_path(bufnr, bs, symbol, anchor, scope, opts, cfg, keywords, resolver.make_lsp_result("disabled"))
    return true
  end

  local available, reason = resolver.get_lsp_status(bufnr)
  if not available then
    apply_path(bufnr, bs, symbol, anchor, scope, opts, cfg, keywords, resolver.make_lsp_result(reason))
    return true
  end

  state.request_seq = state.request_seq + 1
  bs.pending = true
  bs.request_id = state.request_seq

  local request_id = bs.request_id
  -- Activation is async when LSP highlights are available. Track the request id
  -- and re-check the buffer state on completion so older responses cannot clobber
  -- a newer symbol, cursor position, or scope.
  resolver.request_lsp_highlight(bufnr, anchor, scope, cfg.lsp_timeout_ms, function(lsp_result)
    local current = state.bufs[bufnr]
    if not current or not current.active or current.request_id ~= request_id or current.symbol ~= symbol then
      return
    end
    if not resolver.anchors_equal(current.anchor, anchor) or not resolver.scopes_equal(current.scope, scope) then
      return
    end

    apply_path(bufnr, current, symbol, anchor, scope, opts, cfg, keywords, lsp_result)
  end)

  return true
end

function M.deactivate(bufnr)
  local bs = state.bufs[bufnr]
  if bs then
    bs.active = false
    bs.pending = false
    bs.request_id = nil
    bs.symbol = nil
    bs.anchor = nil
    bs.scope = nil
    bs.path_set = {}
    bs.path_order = {}
    bs.context_set = {}
    bs.last_compute_meta = nil
    bs.warned_large_buffer = false
    bs.config = nil
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
end

function M.is_active(bufnr)
  local b = bufnr
  if not b or b == 0 then
    b = vim.api.nvim_get_current_buf()
  end
  local bs = state.bufs[b]
  return bs and bs.active or false
end

function M.jump_in_path(direction, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = M.get_buf_state(bufnr)
  if not bs.active or bs.pending or #bs.path_order == 0 then
    return false
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _ = 1, math.max(1, count or 1) do
    local target
    if direction > 0 then
      for _, lnum in ipairs(bs.path_order) do
        if lnum > line then
          target = lnum
          break
        end
      end
      line = target or bs.path_order[1]
    else
      for i = #bs.path_order, 1, -1 do
        if bs.path_order[i] < line then
          target = bs.path_order[i]
          break
        end
      end
      line = target or bs.path_order[#bs.path_order]
    end
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total < 1 then
    return false
  end

  line = math.max(1, math.min(line, total))
  local target_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local ok = pcall(vim.api.nvim_win_set_cursor, 0, { line, get_line_target_col(target_line, bs.symbol) })
  return ok
end

function M.refresh(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local bs = state.bufs[b]
  if bs and bs.active and bs.anchor and vim.api.nvim_buf_is_valid(b) then
    refresh_buffer(b, bs)
  end
end

function M.refresh_all()
  refresh_active_buffers()
end

function M.should_dynamic_retarget(bufnr, symbol, cursor)
  local bs = state.bufs[bufnr]
  if not bs or not bs.active or not symbol or symbol == "" then
    return false
  end

  if symbol ~= bs.symbol then
    return true
  end

  return not resolver.scope_contains_line(bs.scope, cursor[1])
end

function M.get_active_mode(bufnr)
  local bs = state.bufs[bufnr]
  return bs and bs.config and bs.config.mode or state.config.mode
end

function M.get_mode()
  return state.config.mode
end

function M.set_mode(mode)
  if not config.valid_modes[mode] then
    M.notify("TunnelVision: mode must be static, flow, or dynamic", vim.log.levels.ERROR)
    return
  end
  state.config.mode = mode
  refresh_active_buffers_with(state.config)
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
    M.notify("TunnelVision: direction must be forward or both", vim.log.levels.ERROR)
    return
  end
  state.config.flow_settings.direction = direction
  if state.config.mode == "flow" then
    refresh_active_buffers_with(state.config)
  end
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
  refresh_active_buffers_with(state.config)
end

function M.get_sources()
  return config.get_sources_copy(state.config.sources)
end

function M.set_sources(sources)
  local normalized = config.normalize_sources(sources, state.custom_sources)
  state.config.sources = normalized
  state.config.source = config.legacy_source_from_sources(normalized) or config.defaults.source
  refresh_active_buffers_with(state.config)
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
-- otherwise returns nil. No runtime deprecation warnings.
function M.get_source()
  return config.legacy_source_from_sources(state.config.sources)
end

function M.get_sources_label()
  return config.format_sources(state.config.sources)
end

-- UI-facing source setter that accepts both legacy values and
-- comma-separated fallback chains (e.g. "lsp,word").
-- Invalid values produce a notify error and leave config unchanged.
function M.set_source_command(value)
  if config.valid_sources[value] then
    M.set_source(value)
    return
  end

  -- Single non-legacy source name (e.g. "treesitter")
  if config.valid_source_names[value] then
    M.set_sources({ value })
    return
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
    M.set_sources(names)
    return
  end

  M.notify(
    "TunnelVision: source must be lsp_else_word, lsp, lsp_and_word, word, treesitter,"
      .. " or a comma-separated chain like lsp,word or treesitter,word",
    vim.log.levels.ERROR
  )
end

-- Compatibility API (deprecated). Maps legacy source values to normalized
-- sources and refreshes active buffers. No runtime deprecation warnings.
function M.set_source(source)
  if not config.valid_sources[source] then
    M.notify("TunnelVision: source must be lsp_else_word, lsp, lsp_and_word, or word", vim.log.levels.ERROR)
    return
  end
  state.config.sources = config.normalize_sources(config.sources_from_legacy_source(source), state.custom_sources)
  state.config.source = source
  refresh_active_buffers_with(state.config)
end

function M.get_status(bufnr)
  local b = bufnr
  if not b or b == 0 then
    b = vim.api.nvim_get_current_buf()
  end

  local bs = state.bufs[b]
  local cfg = bs and bs.config or state.config
  return {
    active = bs and bs.active or false,
    pending = bs and bs.pending or false,
    symbol = bs and bs.symbol or nil,
    mode = cfg.mode,
    direction = cfg.flow_settings.direction,
    scope = cfg.scope,
    source = config.legacy_source_from_sources(cfg.sources),
    sources = config.get_sources_copy(cfg.sources),
    sources_label = config.format_sources(cfg.sources),
  }
end

return M
