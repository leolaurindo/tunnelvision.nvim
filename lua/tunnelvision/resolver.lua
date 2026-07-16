-- tunnelvision.resolver
--
-- Path analysis for TunnelVision.
--
-- Responsibilities:
-- - define keyword filtering used by word and flow analysis
-- - resolve the active analysis scope (function or buffer)
-- - query LSP documentHighlight data and normalize it to line sets
-- - compute the visible path from word matches, LSP matches, and flow heuristics
--
-- This module is intentionally stateless. It receives the current config-derived
-- inputs from tunnelvision.core and returns computed results without owning
-- buffer lifecycle or UI concerns.

local M = {}

local FLOW_MAX_ITER = 32
local assign_ops = { "+=", "-=", "*=", "/=", "%=", "=" }

-- Ignore language keywords when collecting identifiers so word/flow
-- matching focuses on user symbols instead of syntax tokens.
local base_keywords = {}
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
  base_keywords[word] = true
end

function M.build_keywords(extra_keywords)
  local merged = vim.deepcopy(base_keywords)
  for _, word in ipairs(extra_keywords or {}) do
    if type(word) == "string" and word ~= "" then
      merged[word] = true
    end
  end
  return merged
end

function M.sanitize_keywords(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end

  for _, word in ipairs(list) do
    if type(word) == "string" and word ~= "" then
      out[#out + 1] = word
    end
  end

  return out
end

local function line_has_word(line, word)
  if not line or line == "" or not word or word == "" then
    return false
  end
  return line:find("%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]") ~= nil
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

local function collect_identifiers(text, keywords)
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

local function parse_assignment(line, keywords)
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
  local rhs = collect_identifiers(rhs_text, keywords)
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

local function is_identifier_like(node_type)
  return node_type:find("identifier", 1, true)
    or node_type:find("name", 1, true)
    or node_type == "variable"
    or node_type == "field"
end

local function get_scope_range(bufnr, anchor, scope_mode)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if scope_mode == "buffer" then
    return 1, total
  end

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

function M.scope_contains_line(scope, line)
  return scope and line >= scope.start_line and line <= scope.end_line or false
end

function M.scopes_equal(a, b)
  return a and b and a.start_line == b.start_line and a.end_line == b.end_line or false
end

function M.anchors_equal(a, b)
  return a and b and a.row == b.row and a.col == b.col or false
end

function M.resolve_scope(bufnr, anchor, current_scope, scope_mode)
  local line = anchor.row + 1
  if M.scope_contains_line(current_scope, line) then
    return current_scope
  end

  local start_line, end_line = get_scope_range(bufnr, anchor, scope_mode)
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

function M.make_lsp_result(reason, lines, used)
  return {
    lines = lines or {},
    used = used or false,
    reason = reason or "disabled",
  }
end

local function collect_treesitter_lines(bufnr, symbol, scope)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return { lines = {}, used = false, reason = "unavailable" }
  end

  local ok_tree, parsed = pcall(parser.parse, parser)
  if not ok_tree or not parsed or not parsed[1] then
    return { lines = {}, used = false, reason = "unavailable" }
  end

  local root = parsed[1]:root()
  local lines = {}
  local scope_start = scope.start_line - 1
  local scope_end = scope.end_line - 1

  local function walk(node)
    if is_identifier_like(node:type()) then
      local text = vim.treesitter.get_node_text(node, bufnr)
      if text == symbol then
        local start_row = node:start()
        if start_row >= scope_start and start_row <= scope_end then
          lines[start_row + 1] = true
        end
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root)

  if next(lines) then
    return { lines = lines, used = true, reason = "ok" }
  end
  return { lines = {}, used = false, reason = "no_matches" }
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

local function has_lsp_results(responses)
  for _, resp in pairs(responses or {}) do
    if resp and resp.result ~= nil then
      return true
    end
  end
  return false
end

function M.get_lsp_status(bufnr)
  if vim.tbl_isempty(get_attached_clients(bufnr)) then
    return false, "no_clients"
  end

  if not has_document_highlight_provider(bufnr) then
    return false, "unsupported"
  end

  return true, "ok"
end

function M.request_lsp_highlight(bufnr, anchor, scope, timeout_ms, on_done)
  local done = false
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = anchor.row, character = anchor.col },
  }

  local function finish(result)
    if done then
      return
    end
    done = true
    on_done(result)
  end

  local ok = pcall(vim.lsp.buf_request_all, bufnr, "textDocument/documentHighlight", params, function(responses)
    if not responses or vim.tbl_isempty(responses) or not has_lsp_results(responses) then
      finish(M.make_lsp_result("request_failed"))
      return
    end

    finish(M.make_lsp_result("ok", collect_lsp_lines(responses, scope), true))
  end)
  if not ok then
    finish(M.make_lsp_result("request_failed"))
    return
  end

  vim.defer_fn(function()
    -- Some servers never answer documentHighlight requests. The `done` guard keeps
    -- the timeout path and the callback path from racing into duplicate updates.
    finish(M.make_lsp_result("request_failed"))
  end, timeout_ms)
end

local function sorted_lines(path_set)
  local out = {}
  for lnum in pairs(path_set) do
    out[#out + 1] = lnum
  end
  table.sort(out)
  return out
end

local function sources_use(sources, source_name)
  for _, step in ipairs(sources) do
    if step.name == source_name then
      return true
    end
    for _, name in ipairs(step.names or {}) do
      if name == source_name then
        return true
      end
    end
  end
  return false
end

local function collect_word_context(bufnr, symbol, scope, keywords, collect_matches, collect_flow)
  local word_set = {}
  local line_info = {}

  if not collect_matches and not collect_flow then
    return word_set, line_info
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
  for idx, raw in ipairs(lines) do
    local lnum = scope.start_line + idx - 1
    local cleaned = strip_strings_and_comments(raw)
    if collect_matches and line_has_word(cleaned, symbol) then
      word_set[lnum] = true
    end
    if collect_flow then
      local lhs, rhs = parse_assignment(cleaned, keywords)
      line_info[#line_info + 1] = {
        lnum = lnum,
        ids = collect_identifiers(cleaned, keywords),
        lhs = lhs,
        rhs = rhs,
      }
    end
  end

  return word_set, line_info
end

local function collect_source_result(name, context)
  if name == "word" then
    local used = next(context.word_lines) ~= nil
    return {
      lines = context.word_lines,
      used = used,
      reason = used and nil or "no_matches",
      failed_source = name,
      has_word = true,
      used_word = true,
    }
  end
  if name == "lsp" then
    local lines = context.lsp_result.lines or {}
    local used = next(lines) ~= nil
    return {
      lines = lines,
      used = used,
      reason = not used and (context.lsp_result.reason == "ok" and "no_matches" or context.lsp_result.reason) or nil,
      used_lsp = true,
      failed_source = name,
    }
  end
  if name == "treesitter" then
    if not context.treesitter_result then
      context.treesitter_result = collect_treesitter_lines(context.bufnr, context.symbol, context.scope)
    end
    context.treesitter_result.failed_source = name
    return context.treesitter_result
  end
  local handler = context.custom_sources[name]
  if handler then
    local ok, result = pcall(handler, {
      anchor = { row = context.anchor.row, col = context.anchor.col },
      bufnr = context.bufnr,
      direction = context.direction,
      keywords = vim.deepcopy(context.keywords),
      mode = context.mode,
      scope = { start_line = context.scope.start_line, end_line = context.scope.end_line },
      symbol = context.symbol,
    })
    if not ok or type(result) ~= "table" then
      return {
        lines = {},
        used = false,
        reason = ok and "no_matches" or "error",
        failed_source = name,
        has_custom = true,
      }
    end

    local lines = {}
    local line_count = vim.api.nvim_buf_line_count(context.bufnr)
    for lnum, included in pairs(result) do
      if
        included
        and type(lnum) == "number"
        and lnum % 1 == 0
        and lnum >= context.scope.start_line
        and lnum <= context.scope.end_line
        and lnum <= line_count
      then
        lines[lnum] = true
      end
    end
    local used = next(lines) ~= nil
    return {
      lines = lines,
      used = used,
      reason = used and nil or "no_matches",
      failed_source = name,
      has_custom = true,
      used_custom = true,
    }
  end
  return { lines = {}, used = false, reason = "unavailable", failed_source = name }
end

local function collect_source_step(step, context)
  if step.kind == "single" then
    return collect_source_result(step.name, context)
  end

  local result = {
    lines = {},
    used = true,
    used_lsp = false,
    used_custom = false,
    used_word = false,
    has_custom = false,
    has_word = false,
  }
  for _, name in ipairs(step.names) do
    local source = collect_source_result(name, context)
    result.has_custom = result.has_custom or source.has_custom or false
    result.has_word = result.has_word or source.has_word or false
    if not source.used then
      return {
        lines = {},
        used = false,
        reason = source.reason,
        failed_source = source.failed_source,
        has_custom = result.has_custom,
        has_word = result.has_word,
      }
    end
    add_set(result.lines, source.lines)
    result.used_lsp = result.used_lsp or source.used_lsp or false
    result.used_custom = result.used_custom or source.used_custom or false
    result.used_word = result.used_word or source.used_word or false
  end
  return result
end

local function source_step_label(step)
  if step.kind == "combine" then
    return "combine(" .. table.concat(step.names, ",") .. ")"
  end
  return step.name
end

local function resolve_source_chain(sources, context)
  local path_set = {}
  local meta = {
    used_source = nil,
    failed_sources = {},
    fallback_source = nil,
    used_lsp = false,
    used_custom = false,
    used_word = false,
    flow_eligible = true,
    used_fallback = false,
    fallback_reason = nil,
  }

  for i, step in ipairs(sources) do
    local result = collect_source_step(step, context)
    if result.used then
      add_set(path_set, result.lines)
      meta.used_source = source_step_label(step)
      meta.used_lsp = result.used_lsp or false
      meta.used_custom = result.used_custom or false
      meta.used_word = result.used_word or false
      meta.flow_eligible = not meta.used_custom or meta.used_word
      meta.used_fallback = i > 1
      return path_set, meta
    end
    if step.kind == "combine" and result.has_custom then
      meta.flow_eligible = false
    elseif step.kind == "single" and step.name == "word" then
      meta.flow_eligible = true
    end
    meta.failed_sources[#meta.failed_sources + 1] = source_step_label(step)
    if not meta.fallback_reason then
      meta.fallback_reason = result.reason
      meta.fallback_source = result.failed_source
    end
  end

  return path_set, meta
end

local function expand_flow(path_set, symbol, line_info, direction)
  -- Flow expansion runs after source resolution, using the selected line set.
  -- Flow mode grows the tracked identifier set until it reaches a fixed point
  -- or hits a small safety bound. This keeps chained assignments like
  -- `a = b; c = a` connected without letting pathological buffers loop forever.
  local tracked = { [symbol] = true }
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
      if direction == "both" and lhs_hit and info.rhs then
        changed = add_set(tracked, info.rhs) or changed
      end
    end
  end
end

function M.compute_path(bufnr, symbol, anchor, scope, opts)
  local sources = opts.sources or {}
  local uses_word = sources_use(sources, "word")
  local use_flow = opts.mode == "flow" and uses_word
  local word_lines, line_info = collect_word_context(bufnr, symbol, scope, opts.keywords or {}, uses_word, use_flow)
  local path_set, meta = resolve_source_chain(sources, {
    anchor = anchor,
    bufnr = bufnr,
    custom_sources = opts.custom_sources or {},
    direction = opts.direction,
    keywords = opts.keywords or {},
    lsp_result = opts.lsp_result or M.make_lsp_result("disabled"),
    mode = opts.mode,
    scope = scope,
    symbol = symbol,
    word_lines = word_lines,
  })

  if use_flow and meta.flow_eligible then
    expand_flow(path_set, symbol, line_info, opts.direction)
  end

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set), meta
end

return M
