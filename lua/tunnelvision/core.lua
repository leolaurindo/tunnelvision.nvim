local M = {}

local defaults = {
  scope = "auto",
  mode = "static",
  flow_direction = "forward",
  symbol_source = "lsp_strict_fallback",
  fallback_warn = "once",
  include_lsp_highlights = true,
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  use_bracket_h = true,
  use_nN = false,
  use_leader_h = true,
  use_esc = true,
  notify = true,
}

---@class TunnelVisionAnchor
---@field row integer
---@field col integer

---@class TunnelVisionScope
---@field start_line integer
---@field end_line integer
---@field kind string

---@class TunnelVisionBufState
---@field active boolean
---@field symbol string|nil
---@field anchor TunnelVisionAnchor|nil
---@field scope TunnelVisionScope|nil
---@field path_set table<integer, boolean>
---@field path_order integer[]
---@field warned_lsp_fallback boolean
---@field last_compute_meta TunnelVisionComputeMeta|nil

---@class TunnelVisionComputeMeta
---@field used_lsp boolean
---@field used_fallback boolean
---@field fallback_reason string|nil

---@class TunnelVisionConfig
---@field scope "auto"|"function"|"file"|string
---@field mode "static"|"flow"|"dynamic"|string
---@field flow_direction "forward"|"both"|string
---@field symbol_source "lsp_strict_fallback"|"hybrid"|"lexical"|string
---@field fallback_warn "once"|"always"|"never"|string
---@field include_lsp_highlights boolean
---@field lsp_timeout_ms integer
---@field dim_hl string
---@field max_dim_lines integer
---@field use_bracket_h boolean
---@field use_nN boolean
---@field use_leader_h boolean
---@field use_esc boolean
---@field notify boolean

---@class TunnelVisionState
---@field ns integer
---@field bufs table<integer, TunnelVisionBufState>
---@field config TunnelVisionConfig

---@type TunnelVisionState
local state = {
  ns = vim.api.nvim_create_namespace("tunnelvision"),
  bufs = {},
  config = vim.deepcopy(defaults),
}

M.state = state

local render = function() end

local keywords = {}
for keyword in ([[
and break case catch class const continue defer do else elseif end enum except export
false finally fn for func function if implements import in interface is lambda let local match mod
namespace new nil not null of or package private public return self static struct super
switch then this throw true try type typeof union until use var void while with yield
repeat goto def pass as global nonlocal raise assert del True False None async await from
delete instanceof extends abstract final throws typedef sizeof extern
inline constexpr mutable noexcept static_assert thread_local this
range chan go impl trait mut ref where unsafe dyn crate pub
]]):gmatch("%S+") do
  keywords[keyword] = true
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
  render = fn or function() end
end

---@param bufnr integer
---@return TunnelVisionBufState
function M.get_buf_state(bufnr)
  local s = state.bufs[bufnr]
  if not s then
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
  end
  return s
end

function M.clear_buf_state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
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

--- Lightweight assignment parser used by flow mode; it handles single-target
--- assignments and intentionally skips complex left-hand-side forms.
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

--- Resolves scope from the cursor anchor using Tree-sitter function-like nodes,
--- with a safe fallback to whole-file scope when parsing is unavailable.
local function get_scope_range(bufnr, anchor, scope_mode)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if scope_mode == "file" then
    return 1, total, "file"
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok_parser and parser then
    local ok_tree, parsed = pcall(parser.parse, parser)
    if ok_tree and parsed and parsed[1] then
      local node = parsed[1]:root():named_descendant_for_range(anchor.row, anchor.col, anchor.row, anchor.col)
      while node do
        if is_function_like(node:type()) then
          local start_row, _, end_row, _ = node:range()
          return start_row + 1, end_row + 1, "function"
        end
        node = node:parent()
      end
    end
  end

  return 1, total, "file"
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

---@return TunnelVisionComputeMeta
local function new_compute_meta()
  return { used_lsp = false, used_fallback = false, fallback_reason = nil }
end

local function get_lsp_highlight_result(bufnr, anchor, scope)
  local out = {
    lines = {},
    used = false,
    reason = "disabled",
  }

  if not state.config.include_lsp_highlights then
    return out
  end

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

  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentHighlight", params, state.config.lsp_timeout_ms)
  if not responses then
    out.reason = "request_failed"
    return out
  end

  out.reason = "ok"
  out.used = true

  for _, resp in pairs(responses) do
    if resp and resp.result then
      for _, item in ipairs(resp.result) do
        local r = item.range
        if r and r.start and r["end"] then
          local from = r.start.line + 1
          local to = r["end"].line + 1
          for lnum = from, to do
            if lnum >= scope.start_line and lnum <= scope.end_line then
              out.lines[lnum] = true
            end
          end
        end
      end
    end
  end

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

--- Validates enum-like options (mode, flow_direction, symbol_source,
--- fallback_warn), coercing invalid values to safe defaults before state
--- is used.
function M.normalize_config(cfg)
  if not valid_modes[cfg.mode] then
    cfg.mode = "static"
  end
  if not valid_flow_directions[cfg.flow_direction] then
    cfg.flow_direction = "forward"
  end
  if not valid_symbol_sources[cfg.symbol_source] then
    cfg.symbol_source = "lsp_strict_fallback"
  end
  if not valid_fallback_warn[cfg.fallback_warn] then
    cfg.fallback_warn = "once"
  end
end

function M.configure(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.normalize_config(state.config)
end

--- Main path algorithm: collect lexical and/or LSP matches according to
--- symbol_source, then optionally run flow propagation to expand related lines.
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
  local meta = new_compute_meta()

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
  else
    if lsp_result.used then
      add_set(path_set, lsp_result.lines)
      meta.used_lsp = true
    else
      add_set(path_set, lexical_set)
      meta.used_fallback = true
      meta.fallback_reason = lsp_result.reason
    end
  end

  if not use_flow then
    path_set[anchor.row + 1] = true
    return path_set, sorted_lines(path_set), meta
  end

  local changed, guard = true, 0
  -- Fixed-point propagation with a hard cap to avoid pathological loops.
  while changed and guard < 32 do
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

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set), meta
end

local function refresh_buffer(bufnr, bs)
  bs.path_set, bs.path_order, bs.last_compute_meta = compute_path(bufnr, bs.symbol, bs.anchor, bs.scope)
  render(bufnr)
end

local function fallback_warn_msg(reason)
  local cause = ({
    no_clients = "no LSP client attached",
    unsupported = "LSP server has no documentHighlight support",
    request_failed = "LSP highlight request failed or timed out",
    disabled = "LSP highlights are disabled",
  })[reason] or "LSP data unavailable"
  return ("TunnelVision: falling back to lexical matching (%s)"):format(cause)
end

function M.each_active_buffer(cb)
  for bufnr, bs in pairs(state.bufs) do
    if bs.active and vim.api.nvim_buf_is_valid(bufnr) then
      cb(bufnr, bs)
    end
  end
end

local function refresh_active_buffers()
  M.each_active_buffer(refresh_buffer)
end

--- Activates TunnelVision for a buffer: resolve symbol/cursor, compute scope
--- and path, persist buffer state, and render; opts.silent suppresses warnings.
function M.activate(bufnr, opts)
  opts = opts or {}
  local symbol = vim.fn.expand("<cword>")
  if not symbol or symbol == "" then
    if not opts.silent then
      M.notify("TunnelVision: no symbol under cursor", vim.log.levels.WARN)
    end
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local anchor = { row = cursor[1] - 1, col = cursor[2] }
  local start_line, end_line, scope_kind = get_scope_range(bufnr, anchor, state.config.scope)
  local scope = { start_line = start_line, end_line = end_line, kind = scope_kind }

  local bs = M.get_buf_state(bufnr)
  bs.active = true
  bs.symbol = symbol
  bs.anchor = anchor
  bs.scope = scope
  bs.path_set, bs.path_order, bs.last_compute_meta = compute_path(bufnr, symbol, anchor, scope)
  if state.config.symbol_source == "lsp_strict_fallback"
    and bs.last_compute_meta
    and bs.last_compute_meta.used_fallback
    and not opts.silent
  then
    local fallback_warn = state.config.fallback_warn
    local should_warn = fallback_warn == "always" or (fallback_warn == "once" and not bs.warned_lsp_fallback)
    if should_warn then
      M.notify(fallback_warn_msg(bs.last_compute_meta.fallback_reason), vim.log.levels.WARN)
      bs.warned_lsp_fallback = true
    end
  end
  render(bufnr)
end

function M.deactivate(bufnr)
  local bs = M.get_buf_state(bufnr)
  bs.active = false
  bs.symbol = nil
  bs.anchor = nil
  bs.scope = nil
  bs.path_set = {}
  bs.path_order = {}
  bs.warned_lsp_fallback = false
  bs.last_compute_meta = nil
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
end

function M.is_active(bufnr)
  local b = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local bs = state.bufs[b]
  return bs and bs.active or false
end

--- Moves to the next/previous path line, supports count repeats, and wraps
--- around when navigation reaches either end of the path order.
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

  local target_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { line, get_line_target_col(target_line, bs.symbol) })
  return true
end

function M.refresh(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local bs = state.bufs[b]
  if bs and bs.active then
    refresh_buffer(b, bs)
  end
end

function M.get_mode()
  return state.config.mode
end

--- Sets or toggles mode after validating command/config input; invalid values
--- are rejected before mutating plugin state.
function M.set_mode(mode)
  local next_mode = mode == "toggle" and (state.config.mode == "static" and "flow" or "static") or mode
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

function M.get_symbol_source()
  return state.config.symbol_source
end

--- Sets or toggles flow direction after validating input; state is only
--- mutated when the requested direction is accepted.
function M.set_flow_direction(direction)
  local next_direction = direction == "toggle" and (state.config.flow_direction == "forward" and "both" or "forward") or direction
  if not valid_flow_directions[next_direction] then
    M.notify("TunnelVision: flow direction must be forward, both, or toggle", vim.log.levels.ERROR)
    return
  end
  state.config.flow_direction = next_direction
  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
end

function M.set_symbol_source(source)
  local next_source = source
  if not valid_symbol_sources[next_source] then
    M.notify("TunnelVision: symbol source must be lsp_strict_fallback, hybrid, or lexical", vim.log.levels.ERROR)
    return
  end
  state.config.symbol_source = next_source
  refresh_active_buffers()
end

return M
