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

local M = {}

local defaults = {
  mode = "static",
  direction = "forward",
  scope = "function",
  extra_keywords = {},
  source = "lsp_else_word",
  fallback_warn = "once",
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  lsp_timeout_ms = 150,
  notify = true,
}

local state = {
  ns = vim.api.nvim_create_namespace("tunnelvision"),
  bufs = {},
  config = vim.deepcopy(defaults),
  request_seq = 0,
}

state.keywords = resolver.build_keywords(defaults.extra_keywords)
M.state = state

local valid_modes = { static = true, flow = true, dynamic = true }
local valid_directions = { forward = true, both = true }
local valid_scopes = { ["function"] = true, buffer = true }
local valid_sources = { lsp_else_word = true, lsp = true, lsp_and_word = true, word = true }
local valid_fallback_warn = { once = true, always = true, never = true }

local render = function() end
local refresh_active_buffers = function() end

function M.notify(msg, level)
  if state.config.notify then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
end

function M.set_renderer(fn)
  if fn ~= nil and type(fn) ~= "function" then
    M.notify("TunnelVision: renderer must be a function", vim.log.levels.ERROR)
    return
  end
  render = fn or function() end
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
    warned_lsp_fallback = false,
    warned_lsp_strict = false,
    last_compute_meta = nil,
    pending = false,
    request_id = nil,
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

function M.normalize_config(cfg)
  if not valid_modes[cfg.mode] then
    cfg.mode = defaults.mode
  end
  if not valid_directions[cfg.direction] then
    cfg.direction = defaults.direction
  end
  if not valid_scopes[cfg.scope] then
    cfg.scope = defaults.scope
  end
  if not valid_sources[cfg.source] then
    cfg.source = defaults.source
  end
  if not valid_fallback_warn[cfg.fallback_warn] then
    cfg.fallback_warn = defaults.fallback_warn
  end
  cfg.extra_keywords = resolver.sanitize_keywords(cfg.extra_keywords)
  cfg.max_dim_lines = math.max(1, tonumber(cfg.max_dim_lines) or defaults.max_dim_lines)
  cfg.lsp_timeout_ms = math.max(1, tonumber(cfg.lsp_timeout_ms) or defaults.lsp_timeout_ms)
end

function M.configure(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.normalize_config(state.config)
  state.keywords = resolver.build_keywords(state.config.extra_keywords)
end

function M.add_keywords(words)
  local incoming = resolver.sanitize_keywords(words)
  if #incoming == 0 then
    return false
  end

  local existing = {}
  state.config.extra_keywords = state.config.extra_keywords or {}
  for _, word in ipairs(state.config.extra_keywords) do
    existing[word] = true
  end

  local changed = false
  for _, word in ipairs(incoming) do
    if not existing[word] then
      state.config.extra_keywords[#state.config.extra_keywords + 1] = word
      existing[word] = true
      changed = true
    end
  end

  if not changed then
    return false
  end

  state.keywords = resolver.build_keywords(state.config.extra_keywords)
  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
  return true
end

local function refresh_buffer(bufnr, bs)
  if not bs.active or not bs.symbol or not bs.anchor or not bs.scope then
    return
  end

  M.activate(bufnr, {
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

local function fallback_warn_msg(reason)
  local cause = ({
    no_clients = "no LSP client attached",
    unsupported = "LSP server has no documentHighlight support",
    request_failed = "LSP highlight request failed or timed out",
    disabled = "LSP data unavailable",
  })[reason] or "LSP data unavailable"
  return ("TunnelVision: falling back to word matching (%s)"):format(cause)
end

local function strict_lsp_warn_msg(reason)
  local cause = ({
    no_clients = "no LSP client attached",
    unsupported = "LSP server has no documentHighlight support",
    request_failed = "LSP highlight request failed or timed out",
    disabled = "LSP data unavailable",
  })[reason] or "LSP data unavailable"
  return ("TunnelVision: strict LSP source has no highlights (%s)"):format(cause)
end

local function maybe_warn_fallback(bs, silent)
  if state.config.source ~= "lsp_else_word" or not bs.last_compute_meta or not bs.last_compute_meta.used_fallback then
    return
  end

  if silent then
    return
  end

  local fw = state.config.fallback_warn
  if fw == "always" or (fw == "once" and not bs.warned_lsp_fallback) then
    M.notify(fallback_warn_msg(bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
    bs.warned_lsp_fallback = true
  end
end

local function maybe_warn_strict_lsp(bs, silent)
  if state.config.source ~= "lsp" or not bs.last_compute_meta or bs.last_compute_meta.used_lsp then
    return
  end

  if silent or bs.warned_lsp_strict then
    return
  end

  M.notify(strict_lsp_warn_msg(bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
  bs.warned_lsp_strict = true
end

local function apply_path(bufnr, bs, symbol, anchor, scope, opts, lsp_result)
  bs.pending = false
  bs.request_id = nil
  bs.path_set, bs.path_order, bs.last_compute_meta = resolver.compute_path(bufnr, symbol, anchor, scope, {
    direction = state.config.direction,
    keywords = state.keywords,
    lsp_result = lsp_result,
    mode = state.config.mode,
    source = state.config.source,
  })
  maybe_warn_fallback(bs, opts.silent)
  maybe_warn_strict_lsp(bs, opts.silent)
  render(bufnr)
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

  local bs = M.get_buf_state(bufnr)
  local scope = resolver.resolve_scope(bufnr, anchor, opts.reuse_scope ~= false and bs.scope or nil, state.config.scope)
  local keep_render = bs.active and not bs.pending and next(bs.path_set) ~= nil
  if
    bs.active
    and bs.symbol == symbol
    and resolver.anchors_equal(bs.anchor, anchor)
    and resolver.scopes_equal(bs.scope, scope)
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
  if not keep_render then
    bs.path_set = {}
    bs.path_order = {}
    bs.last_compute_meta = nil
    bs.warned_lsp_strict = false
  end

  if state.config.source == "word" then
    apply_path(bufnr, bs, symbol, anchor, scope, opts, resolver.make_lsp_result("disabled"))
    return true
  end

  local available, reason = resolver.get_lsp_status(bufnr)
  if not available then
    apply_path(bufnr, bs, symbol, anchor, scope, opts, resolver.make_lsp_result(reason))
    return true
  end

  state.request_seq = state.request_seq + 1
  bs.pending = true
  bs.request_id = state.request_seq

  local request_id = bs.request_id
  -- Activation is async when LSP highlights are available. Track the request id
  -- and re-check the buffer state on completion so older responses cannot clobber
  -- a newer symbol, cursor position, or scope.
  resolver.request_lsp_highlight(bufnr, anchor, scope, state.config.lsp_timeout_ms, function(lsp_result)
    local current = state.bufs[bufnr]
    if not current or not current.active or current.request_id ~= request_id or current.symbol ~= symbol then
      return
    end
    if not resolver.anchors_equal(current.anchor, anchor) or not resolver.scopes_equal(current.scope, scope) then
      return
    end

    apply_path(bufnr, current, symbol, anchor, scope, opts, lsp_result)
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
    bs.last_compute_meta = nil
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

function M.get_mode()
  return state.config.mode
end

function M.set_mode(mode)
  if not valid_modes[mode] then
    M.notify("TunnelVision: mode must be static, flow, or dynamic", vim.log.levels.ERROR)
    return
  end
  state.config.mode = mode
  refresh_active_buffers()
end

function M.get_direction()
  return state.config.direction
end

function M.set_direction(direction)
  if not valid_directions[direction] then
    M.notify("TunnelVision: direction must be forward or both", vim.log.levels.ERROR)
    return
  end
  state.config.direction = direction
  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
end

function M.get_scope()
  return state.config.scope
end

function M.set_scope(scope)
  if not valid_scopes[scope] then
    M.notify("TunnelVision: scope must be function or buffer", vim.log.levels.ERROR)
    return
  end
  state.config.scope = scope
  refresh_active_buffers()
end

function M.get_source()
  return state.config.source
end

function M.set_source(source)
  if not valid_sources[source] then
    M.notify("TunnelVision: source must be lsp_else_word, lsp, lsp_and_word, or word", vim.log.levels.ERROR)
    return
  end
  state.config.source = source
  refresh_active_buffers()
end

function M.get_status(bufnr)
  local b = bufnr
  if not b or b == 0 then
    b = vim.api.nvim_get_current_buf()
  end

  local bs = state.bufs[b]
  return {
    active = bs and bs.active or false,
    pending = bs and bs.pending or false,
    symbol = bs and bs.symbol or nil,
    mode = state.config.mode,
    direction = state.config.direction,
    scope = state.config.scope,
    source = state.config.source,
  }
end

return M
