local M = {}

local defaults = {
  mode = "static",
  flow_direction = "forward",
  symbol_source = "lsp_strict_fallback",
  fallback_warn = "once",
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  lsp_timeout_ms = 150,
  notify = true,
}

local FLOW_MAX_ITER = 32

local state = {
  ns = vim.api.nvim_create_namespace("tunnelvision"),
  bufs = {},
  config = vim.deepcopy(defaults),
}

M.state = state

local render = function() end

-- Ignore language keywords when collecting identifiers so lexical/flow
-- matching focuses on user symbols instead of syntax tokens.
local keywords = {}
for word in
  ([[
and break case catch class const continue defer do else elseif end enum except export
false finally fn for func function if implements import in interface is lambda let local match mod
namespace new nil not null of or package private public return self static struct super
switch then this throw true try type typeof union until use var void while with yield
repeat goto def pass as global nonlocal raise assert del True False None async await from
delete instanceof extends abstract final throws typedef sizeof extern
inline constexpr mutable noexcept static_assert thread_local
range chan go impl trait mut ref where unsafe dyn crate pub
]]):gmatch("%S+")
do
  keywords[word] = true
end

local assign_ops = { "+=", "-=", "*=", "/=", "%=", "=" }
local valid_modes = { static = true, flow = true, dynamic = true }
local valid_flow_directions = { forward = true, both = true }
local valid_symbol_sources = { lsp_strict_fallback = true, hybrid = true, lexical = true }
local valid_fallback_warn = { once = true, always = true, never = true }

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
    last_compute_meta = nil,
  }
  state.bufs[bufnr] = s
  return s
end

function M.clear_buf_state(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
  state.bufs[bufnr] = nil
end

local function line_has_word(line, word)
  if not line or line == "" or not word or word == "" then
    return false
  end
  return line:find("%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]") ~= nil
end

local function get_line_target_col(line, symbol)
  local symbol_col = line and symbol and symbol ~= "" and line:find("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]")
  if symbol_col then
    return symbol_col - 1
  end
  local first_nonblank = line and line:find("%S")
  return first_nonblank and first_nonblank - 1 or 0
end

local function strip_strings_and_comments(line)
  local s = line
  s = s:gsub('".-"', '""')
  s = s:gsub("'.-'", "''")
  s = s:gsub("//.*$", "")
  s = s:gsub("#.*$", "")
  s = s:gsub("%-%-.*$", "")
  return s
end

local function collect_identifiers(text)
  local out = {}
  for id in text:gmatch("[%a_][%w_]*") do
    if not keywords[id] then
      out[id] = true
    end
  end
  return out
end

local function set_intersects(a, b)
  for name in pairs(a) do
    if b[name] then
      return true
    end
  end
  return false
end

local function add_set(dst, src)
  local changed = false
  for name in pairs(src) do
    if not dst[name] then
      dst[name] = true
      changed = true
    end
  end
  return changed
end

local function find_assign(line)
  for _, op in ipairs(assign_ops) do
    local start_col = line:find(op, 1, true)
    if start_col then
      if op ~= "=" then
        return start_col, op
      end
      local prev = start_col > 1 and line:sub(start_col - 1, start_col - 1) or ""
      local nxt = line:sub(start_col + 1, start_col + 1)
      if prev ~= "=" and prev ~= ">" and prev ~= "<" and prev ~= "!" and nxt ~= "=" then
        return start_col, op
      end
    end
  end
end

local function parse_assignment(line)
  local assign_col, op = find_assign(line)
  if not assign_col then
    return nil, nil
  end

  local lhs_text = line:sub(1, assign_col - 1)
  local rhs_text = line:sub(assign_col + #op)
  if lhs_text:find(",", 1, true) then
    return nil, nil
  end

  local lhs_name = lhs_text:match("^%s*local%s+([%a_][%w_]*)") or lhs_text:match("([%a_][%w_]*)%s*$")
  if not lhs_name or keywords[lhs_name] then
    return nil, nil
  end

  local lhs = { [lhs_name] = true }
  local rhs = collect_identifiers(rhs_text)
  if op ~= "=" then
    rhs[lhs_name] = true
  end
  return lhs, rhs
end

local function is_function_like(node_type)
  return node_type:find("function", 1, true)
    or node_type:find("method", 1, true)
    or node_type:find("lambda", 1, true)
    or node_type:find("arrow", 1, true)
    or node_type == "func_literal"
end

-- Resolve the analysis window for the current anchor.
--
-- If Tree-sitter is available, constrain to the nearest function-like node;
-- otherwise fall back to the full buffer range.
local function get_scope_range(bufnr, anchor)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok_parser and parser then
    local ok_tree, parsed = pcall(parser.parse, parser)
    if ok_tree and parsed and parsed[1] then
      local node = parsed[1]:root():named_descendant_for_range(anchor.row, anchor.col, anchor.row, anchor.col)
      while node do
        if is_function_like(node:type()) then
          local start_row, _, end_row, _ = node:range()
          return start_row + 1, end_row + 1
        end
        node = node:parent()
      end
    end
  end
  return 1, total
end

local function scope_contains_line(scope, line)
  return scope and line >= scope.start_line and line <= scope.end_line or false
end

local function scopes_equal(a, b)
  return a and b and a.start_line == b.start_line and a.end_line == b.end_line or false
end

local function anchors_equal(a, b)
  return a and b and a.row == b.row and a.col == b.col or false
end

local function resolve_scope(bufnr, anchor, current_scope)
  local line = anchor.row + 1
  if scope_contains_line(current_scope, line) then
    return current_scope
  end

  local start_line, end_line = get_scope_range(bufnr, anchor)
  return { start_line = start_line, end_line = end_line }
end

local function get_attached_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end
  return vim.lsp.buf_get_clients(bufnr)
end

local function has_document_highlight_provider(bufnr)
  for _, client in pairs(get_attached_clients(bufnr)) do
    local caps = client.server_capabilities or client.resolved_capabilities
    if caps and (caps.documentHighlightProvider or caps.document_highlight) then
      return true
    end
  end
  return false
end

local function collect_lsp_lines(responses, scope)
  local lines = {}
  for _, resp in pairs(responses or {}) do
    if resp and resp.result then
      for _, item in ipairs(resp.result) do
        local r = item.range
        if r and r.start and r["end"] then
          local from = r.start.line + 1
          local to = r["end"].line + 1
          for lnum = from, to do
            if lnum >= scope.start_line and lnum <= scope.end_line then
              lines[lnum] = true
            end
          end
        end
      end
    end
  end
  return lines
end

-- Query LSP documentHighlight for the anchor and normalize its status.
--
-- Returns a structured result with matched lines plus a reason code used by
-- strict-fallback warnings (ok, no_clients, unsupported, request_failed).
local function get_lsp_highlight_result(bufnr, anchor, scope)
  local out = { lines = {}, used = false, reason = "disabled" }

  if vim.tbl_isempty(get_attached_clients(bufnr)) then
    out.reason = "no_clients"
    return out
  end

  if not has_document_highlight_provider(bufnr) then
    out.reason = "unsupported"
    return out
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = anchor.row, character = anchor.col },
  }

  local responses =
    vim.lsp.buf_request_sync(bufnr, "textDocument/documentHighlight", params, state.config.lsp_timeout_ms)
  if not responses then
    out.reason = "request_failed"
    return out
  end

  out.used = true
  out.reason = "ok"
  out.lines = collect_lsp_lines(responses, scope)
  return out
end

local function sorted_lines(path_set)
  local out = {}
  for lnum in pairs(path_set) do
    out[#out + 1] = lnum
  end
  table.sort(out)
  return out
end

function M.normalize_config(cfg)
  if not valid_modes[cfg.mode] then
    cfg.mode = defaults.mode
  end
  if not valid_flow_directions[cfg.flow_direction] then
    cfg.flow_direction = defaults.flow_direction
  end
  if not valid_symbol_sources[cfg.symbol_source] then
    cfg.symbol_source = defaults.symbol_source
  end
  if not valid_fallback_warn[cfg.fallback_warn] then
    cfg.fallback_warn = defaults.fallback_warn
  end
  cfg.max_dim_lines = math.max(1, tonumber(cfg.max_dim_lines) or defaults.max_dim_lines)
  cfg.lsp_timeout_ms = math.max(1, tonumber(cfg.lsp_timeout_ms) or defaults.lsp_timeout_ms)
end

function M.configure(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.normalize_config(state.config)
end

-- Build the tracked path for a symbol within the current scope.
--
-- Strategy selection:
-- - lexical: pure word-boundary matching
-- - hybrid: lexical union LSP documentHighlight
-- - lsp_strict_fallback: LSP first, lexical only on failure
--
-- In flow mode, this also propagates dependencies through simple
-- assignment relations until convergence (bounded by FLOW_MAX_ITER).
--
-- Returns:
--   path_set   : set of line numbers to keep visible
--   path_order : sorted path_set line numbers
--   meta       : source usage/fallback information for notifications
local function compute_path(bufnr, symbol, anchor, scope)
  local path_set = {}
  local lexical_set = {}
  local use_flow = state.config.mode == "flow"
  local source = state.config.symbol_source
  local tracked = { [symbol] = true }
  local line_info = {}
  local lsp_result = { lines = {}, used = false, reason = "disabled" }

  if source ~= "lexical" then
    lsp_result = get_lsp_highlight_result(bufnr, anchor, scope)
  end

  local need_lexical = source ~= "lsp_strict_fallback" or not lsp_result.used
  local meta = { used_lsp = false, used_fallback = false, fallback_reason = nil }

  if source == "lsp_strict_fallback" and lsp_result.used and not use_flow then
    add_set(path_set, lsp_result.lines)
    path_set[anchor.row + 1] = true
    meta.used_lsp = true
    return path_set, sorted_lines(path_set), meta
  end

  if use_flow or need_lexical then
    local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
    for idx, raw in ipairs(lines) do
      local lnum = scope.start_line + idx - 1
      local cleaned = strip_strings_and_comments(raw)

      if need_lexical and line_has_word(cleaned, symbol) then
        lexical_set[lnum] = true
      end

      if use_flow then
        local lhs, rhs = parse_assignment(cleaned)
        line_info[#line_info + 1] = {
          lnum = lnum,
          ids = collect_identifiers(cleaned),
          lhs = lhs,
          rhs = rhs,
        }
      end
    end
  end

  if source == "lexical" then
    add_set(path_set, lexical_set)
  elseif source == "hybrid" then
    add_set(path_set, lexical_set)
    add_set(path_set, lsp_result.lines)
    meta.used_lsp = lsp_result.used
  elseif lsp_result.used then
    add_set(path_set, lsp_result.lines)
    meta.used_lsp = true
  else
    add_set(path_set, lexical_set)
    meta.used_fallback = true
    meta.fallback_reason = lsp_result.reason
  end

  if use_flow then
    local changed, guard = true, 0
    while changed and guard < FLOW_MAX_ITER do
      changed = false
      guard = guard + 1

      for _, info in ipairs(line_info) do
        local lhs_hit = info.lhs and set_intersects(info.lhs, tracked) or false
        local rhs_hit = info.rhs and set_intersects(info.rhs, tracked) or false

        if lhs_hit or rhs_hit or set_intersects(info.ids, tracked) then
          path_set[info.lnum] = true
        end
        if rhs_hit and info.lhs then
          changed = add_set(tracked, info.lhs) or changed
        end
        if state.config.flow_direction == "both" and lhs_hit and info.rhs then
          changed = add_set(tracked, info.rhs) or changed
        end
      end
    end
  end

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set), meta
end

local function refresh_buffer(bufnr, bs)
  if not bs.active or not bs.symbol or not bs.anchor or not bs.scope then
    return
  end
  bs.path_set, bs.path_order, bs.last_compute_meta = compute_path(bufnr, bs.symbol, bs.anchor, bs.scope)
  render(bufnr)
end

local function refresh_active_buffers()
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
  return ("TunnelVision: falling back to lexical matching (%s)"):format(cause)
end

-- Activate tracking for the symbol under cursor and recompute buffer state.
--
-- This captures anchor/scope, computes the path, stores per-buffer runtime
-- data, and triggers rendering. In strict mode it can warn when LSP lookup
-- fails and lexical fallback is used.
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
  local scope = resolve_scope(bufnr, anchor, opts.reuse_scope ~= false and bs.scope or nil)
  if bs.active and bs.symbol == symbol and anchors_equal(bs.anchor, anchor) and scopes_equal(bs.scope, scope) then
    return false
  end

  bs.active = true
  bs.symbol = symbol
  bs.anchor = anchor
  bs.scope = scope
  bs.path_set, bs.path_order, bs.last_compute_meta = compute_path(bufnr, symbol, anchor, scope)

  if
    state.config.symbol_source == "lsp_strict_fallback"
    and bs.last_compute_meta
    and bs.last_compute_meta.used_fallback
    and not opts.silent
  then
    local fw = state.config.fallback_warn
    if fw == "always" or (fw == "once" and not bs.warned_lsp_fallback) then
      M.notify(fallback_warn_msg(bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
      bs.warned_lsp_fallback = true
    end
  end

  render(bufnr)
  return true
end

function M.deactivate(bufnr)
  local bs = state.bufs[bufnr]
  if bs then
    bs.active = false
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

-- Jump across the precomputed path with wrap-around behavior.
--
-- direction > 0 moves forward, direction < 0 moves backward.
-- count repeats the jump step count times.
-- Cursor lands on the symbol column when available, otherwise first nonblank.
-- Returns false when tracking is inactive or no path is available.
function M.jump_in_path(direction, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = M.get_buf_state(bufnr)
  if not bs.active or #bs.path_order == 0 then
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
  if bs and bs.active and vim.api.nvim_buf_is_valid(b) then
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

  return not scope_contains_line(bs.scope, cursor[1])
end

function M.get_mode()
  return state.config.mode
end

function M.set_mode(mode)
  local next_mode = mode
  if mode == "toggle" then
    local cycle = { static = "flow", flow = "dynamic", dynamic = "static" }
    next_mode = cycle[state.config.mode] or "static"
  end
  if not valid_modes[next_mode] then
    M.notify("TunnelVision: mode must be static, flow, dynamic, or toggle", vim.log.levels.ERROR)
    return
  end
  state.config.mode = next_mode
  refresh_active_buffers()
end

function M.get_flow_direction()
  return state.config.flow_direction
end

function M.set_flow_direction(direction)
  local next_direction = direction == "toggle" and (state.config.flow_direction == "forward" and "both" or "forward")
    or direction
  if not valid_flow_directions[next_direction] then
    M.notify("TunnelVision: flow direction must be forward, both, or toggle", vim.log.levels.ERROR)
    return
  end
  state.config.flow_direction = next_direction
  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
end

function M.get_symbol_source()
  return state.config.symbol_source
end

function M.set_symbol_source(source)
  if source == "toggle" then
    local cycle = { lsp_strict_fallback = "hybrid", hybrid = "lexical", lexical = "lsp_strict_fallback" }
    source = cycle[state.config.symbol_source] or "lsp_strict_fallback"
  end
  if not valid_symbol_sources[source] then
    M.notify(
      "TunnelVision: symbol source must be lsp_strict_fallback, hybrid, lexical, or toggle",
      vim.log.levels.ERROR
    )
    return
  end
  state.config.symbol_source = source
  refresh_active_buffers()
end

return M
