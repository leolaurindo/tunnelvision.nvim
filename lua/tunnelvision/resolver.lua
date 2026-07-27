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

local function strip_strings_and_comments(line)
  local function mask(text)
    return (" "):rep(#text)
  end

  local s = line:gsub('".-"', mask):gsub("'.-'", mask)
  s = s:gsub("//.*$", mask)
  s = s:gsub("#.*$", mask)
  s = s:gsub("%-%-.*$", mask)
  return s
end

local function collect_word_ranges(line, word, lnum)
  local ranges = {}
  if not line or line == "" or not word or word == "" then
    return ranges
  end

  local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  local from = 1
  while true do
    local start_col, end_col = line:find(pattern, from)
    if not start_col then
      break
    end
    ranges[#ranges + 1] = { line = lnum, start_col = start_col - 1, end_col = end_col }
    from = end_col + 1
  end
  return ranges
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

local function add_ranges(dst, src)
  for _, range in ipairs(src or {}) do
    dst[#dst + 1] = range
  end
end

local function normalize_ranges(bufnr, ranges)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out, seen = {}, {}
  for _, range in ipairs(ranges) do
    if type(range) == "table" and type(range.line) == "number" then
      local lnum = math.max(1, math.min(line_count, math.floor(range.line)))
      local line_len = #(lines[lnum] or "")
      local start_col = math.max(0, math.min(line_len, math.floor(tonumber(range.start_col) or 0)))
      local end_col = math.max(0, math.min(line_len, math.floor(tonumber(range.end_col) or 0)))
      local key = lnum .. ":" .. start_col .. ":" .. end_col
      if end_col > start_col and not seen[key] then
        seen[key] = true
        out[#out + 1] = { line = lnum, start_col = start_col, end_col = end_col }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
      or (a.line == b.line and (a.start_col < b.start_col or (a.start_col == b.start_col and a.end_col < b.end_col)))
  end)
  return out
end

local function find_assign(line)
  for _, op in ipairs(assign_ops) do
    local start_col = line:find(op, 1, true)
    if start_col then
      local prev = line:sub(start_col - 1, start_col - 1)
      local next_char = line:sub(start_col + 1, start_col + 1)
      if op ~= "=" or (prev ~= "=" and prev ~= ">" and prev ~= "<" and prev ~= "!" and next_char ~= "=") then
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

local function get_treesitter_root(bufnr)
  local ok, root = pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local parsed = parser:parse()
    return parsed and parsed[1] and parsed[1]:root()
  end)
  return ok and root or nil
end

local function get_scope_range(bufnr, anchor, scope_mode)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if scope_mode == "buffer" then
    return 1, total
  end

  local root = get_treesitter_root(bufnr)
  if root then
    local node = root:named_descendant_for_range(anchor.row, anchor.col, anchor.row, anchor.col)
    while node do
      if is_function_like(node:type()) then
        local start_row, _, end_row, _ = node:range()
        return start_row + 1, end_row + 1
      end
      node = node:parent()
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

function M.make_lsp_result(reason, lines, used, ranges)
  return {
    lines = lines or {},
    ranges = ranges or {},
    used = used or false,
    reason = reason or "disabled",
  }
end

local function collect_treesitter_lines(bufnr, symbol, scope)
  local root = get_treesitter_root(bufnr)
  if not root then
    return { lines = {}, ranges = {}, used = false, reason = "unavailable" }
  end

  local lines = {}
  local ranges = {}
  local scope_start = scope.start_line - 1
  local scope_end = scope.end_line - 1

  local function walk(node)
    if is_identifier_like(node:type()) then
      local text = vim.treesitter.get_node_text(node, bufnr)
      if text == symbol then
        local start_row, start_col, _, end_col = node:range()
        if start_row >= scope_start and start_row <= scope_end then
          lines[start_row + 1] = true
          ranges[#ranges + 1] = {
            line = start_row + 1,
            start_col = start_col,
            end_col = end_col,
          }
        end
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root)

  local used = next(lines) ~= nil
  return { lines = lines, ranges = ranges, used = used, reason = used and "ok" or "no_matches" }
end

local function lsp_byteindex(line, character, encoding)
  character = math.max(0, character or 0)
  encoding = encoding or "utf-16"
  if encoding == "utf-8" then
    return math.min(character, #line)
  end

  local ok, byte = pcall(vim.str_byteindex, line, encoding, character, false)
  if ok then
    return byte
  end
  ok, byte = pcall(vim.str_byteindex, line, character, encoding == "utf-16")
  return ok and byte or #line
end

local function collect_lsp_result(bufnr, responses, scope)
  local lines = {}
  local ranges = {}
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for client_id, resp in pairs(responses or {}) do
    if resp and resp.result then
      local id = tonumber(client_id) or resp.client_id
      local client = id and vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(id) or nil
      local encoding = client and client.offset_encoding or "utf-16"
      for _, item in ipairs(resp.result) do
        local r = item.range
        if r and r.start and r["end"] then
          local from = r.start.line + 1
          local to = r["end"].line + 1
          for lnum = math.max(from, scope.start_line), math.min(to, scope.end_line) do
            lines[lnum] = true
            local text = buffer_lines[lnum] or ""
            local start_col = lnum == from and lsp_byteindex(text, r.start.character, encoding) or 0
            local end_col = lnum == to and lsp_byteindex(text, r["end"].character, encoding) or #text
            ranges[#ranges + 1] = { line = lnum, start_col = start_col, end_col = end_col }
          end
        end
      end
    end
  end
  return lines, ranges
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

    local lines, ranges = collect_lsp_result(bufnr, responses, scope)
    finish(M.make_lsp_result("ok", lines, true, ranges))
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
  local out = vim.tbl_keys(path_set)
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
  local word_ranges = {}
  local line_info = {}

  if not collect_matches and not collect_flow then
    return word_set, word_ranges, line_info
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
  for idx, raw in ipairs(lines) do
    local lnum = scope.start_line + idx - 1
    local cleaned = strip_strings_and_comments(raw)
    if collect_matches then
      local ranges = collect_word_ranges(cleaned, symbol, lnum)
      if #ranges > 0 then
        word_set[lnum] = true
        add_ranges(word_ranges, ranges)
      end
    end
    if collect_flow then
      local lhs, rhs = parse_assignment(cleaned, keywords)
      line_info[#line_info + 1] = {
        lnum = lnum,
        ids = collect_identifiers(cleaned, keywords),
        lhs = lhs,
        rhs = rhs,
        text = cleaned,
      }
    end
  end

  return word_set, word_ranges, line_info
end

local function collect_source_result(name, context)
  if name == "word" then
    local used = next(context.word_lines) ~= nil
    return {
      lines = context.word_lines,
      ranges = context.word_ranges,
      used = used,
      reason = used and nil or "no_matches",
      failed_source = name,
      used_word = true,
    }
  end
  if name == "lsp" then
    local lines = context.lsp_result.lines or {}
    local used = next(lines) ~= nil
    return {
      lines = lines,
      ranges = context.lsp_result.ranges or {},
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
        ranges = {},
        used = false,
        reason = ok and "no_matches" or "error",
        failed_source = name,
        has_custom = true,
      }
    end

    local lines = {}
    local ranges = {}
    local buffer_lines = vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false)
    for lnum, included in pairs(result) do
      if
        included
        and type(lnum) == "number"
        and lnum % 1 == 0
        and lnum >= context.scope.start_line
        and lnum <= context.scope.end_line
        and lnum <= #buffer_lines
      then
        lines[lnum] = true
        add_ranges(ranges, collect_word_ranges(buffer_lines[lnum], context.symbol, lnum))
      end
    end
    local used = next(lines) ~= nil
    return {
      lines = lines,
      ranges = ranges,
      used = used,
      reason = used and nil or "no_matches",
      failed_source = name,
      has_custom = true,
      used_custom = true,
    }
  end
  return { lines = {}, ranges = {}, used = false, reason = "unavailable", failed_source = name }
end

local function collect_source_step(step, context)
  if step.kind == "single" then
    return collect_source_result(step.name, context)
  end

  local result = {
    lines = {},
    ranges = {},
    used = true,
    has_custom = false,
  }
  for _, name in ipairs(step.names) do
    local source = collect_source_result(name, context)
    result.has_custom = result.has_custom or source.has_custom or false
    if not source.used then
      return {
        lines = {},
        ranges = {},
        used = false,
        reason = source.reason,
        failed_source = source.failed_source,
        has_custom = result.has_custom,
      }
    end
    add_set(result.lines, source.lines)
    add_ranges(result.ranges, source.ranges)
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
  local ranges = {}
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
      add_ranges(ranges, result.ranges)
      meta.used_source = source_step_label(step)
      meta.used_lsp = result.used_lsp or false
      meta.used_custom = result.used_custom or false
      meta.used_word = result.used_word or false
      meta.flow_eligible = not meta.used_custom or meta.used_word
      meta.used_fallback = i > 1
      return path_set, ranges, meta
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

  return path_set, ranges, meta
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
  return tracked
end

local function collect_flow_ranges(path_set, tracked, line_info)
  local ranges = {}
  for _, info in ipairs(line_info) do
    if path_set[info.lnum] then
      for id in pairs(info.ids) do
        if tracked[id] then
          add_ranges(ranges, collect_word_ranges(info.text, id, info.lnum))
        end
      end
    end
  end
  return ranges
end

function M.compute_path(bufnr, symbol, anchor, scope, opts)
  local sources = opts.sources or {}
  local uses_word = sources_use(sources, "word")
  local use_flow = opts.mode == "flow" and uses_word
  local word_lines, word_ranges, line_info =
    collect_word_context(bufnr, symbol, scope, opts.keywords or {}, uses_word, use_flow)
  local path_set, ranges, meta = resolve_source_chain(sources, {
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
    word_ranges = word_ranges,
  })

  if use_flow and meta.flow_eligible then
    local tracked = expand_flow(path_set, symbol, line_info, opts.direction)
    add_ranges(ranges, collect_flow_ranges(path_set, tracked, line_info))
  end

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set), meta, normalize_ranges(bufnr, ranges)
end

return M
