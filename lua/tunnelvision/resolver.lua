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

local flow = require("tunnelvision.flow")

local M = {}

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

local non_function_scope_types = {
  abstract_function_declarator = true,
  abstract_method_signature = true,
  default_method_clause = true,
  delete_method_clause = true,
  explicit_function_specifier = true,
  function_annotation = true,
  function_call = true,
  function_declarator = true,
  function_modifier = true,
  function_modifiers = true,
  function_name = true,
  function_parameters = true,
  function_prototype = true,
  function_signature = true,
  function_signature_item = true,
  function_specifier = true,
  function_type = true,
  function_type_parameters = true,
  function_value_parameters = true,
  generic_function = true,
  lambda_capture_initializer = true,
  lambda_capture_specifier = true,
  lambda_default_capture = true,
  lambda_declarator = true,
  lambda_parameters = true,
  lambda_specifier = true,
  method_call_expression = true,
  method_elem = true,
  method_index_expression = true,
  method_invocation = true,
  method_parameters = true,
  method_reference = true,
  method_signature = true,
  preproc_function_def = true,
  template_function = true,
  template_method = true,
}

local function is_function_like(node_type)
  return not non_function_scope_types[node_type]
    and (
      node_type:find("function", 1, true)
      or node_type:find("method", 1, true)
      or node_type:find("lambda", 1, true)
      or node_type:find("arrow", 1, true)
      or node_type == "closure_expression"
      or node_type == "func_literal"
    )
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
  return a
      and b
      and a.start_line == b.start_line
      and a.end_line == b.end_line
      and a.scope_mode == b.scope_mode
      and a.changedtick == b.changedtick
    or false
end

function M.anchors_equal(a, b)
  return a and b and a.row == b.row and a.col == b.col or false
end

function M.resolve_scope(bufnr, anchor, current_scope, scope_mode)
  local line = anchor.row + 1
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local reusable = current_scope
    and current_scope.scope_mode == scope_mode
    and current_scope.changedtick == changedtick
    and M.scope_contains_line(current_scope, line)

  if reusable and scope_mode == "buffer" then
    return current_scope
  end

  local start_line, end_line = get_scope_range(bufnr, anchor, scope_mode)
  if reusable and current_scope.start_line == start_line and current_scope.end_line == end_line then
    return current_scope
  end

  return {
    start_line = start_line,
    end_line = end_line,
    scope_mode = scope_mode,
    changedtick = changedtick,
  }
end

local function get_attached_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end
  return vim.lsp.buf_get_clients(bufnr)
end

local function supports_document_highlight(client, bufnr)
  if client.supports_method then
    local ok, supported = pcall(client.supports_method, "textDocument/documentHighlight", { bufnr = bufnr })
    if not ok then
      ok, supported = pcall(client.supports_method, client, "textDocument/documentHighlight", { bufnr = bufnr })
    end
    if ok and type(supported) == "boolean" then
      return supported
    end
  end

  local caps = client.server_capabilities or client.resolved_capabilities
  return caps and (caps.documentHighlightProvider or caps.document_highlight)
end

local function has_document_highlight_provider(bufnr)
  for _, client in pairs(get_attached_clients(bufnr)) do
    if supports_document_highlight(client, bufnr) then
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

local function lsp_character(line, byte, encoding)
  byte = math.max(0, math.min(byte or 0, #line))
  encoding = encoding or "utf-16"
  if encoding == "utf-8" then
    return byte
  end

  local ok, character = pcall(vim.str_utfindex, line, encoding, byte, false)
  if ok then
    return character
  end

  local utf32, utf16
  ok, utf32, utf16 = pcall(vim.str_utfindex, line, byte)
  if not ok then
    return byte
  end
  return encoding == "utf-16" and utf16 or utf32
end

local function collect_lsp_result(bufnr, responses, scope)
  local lines = {}
  local ranges = {}
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, resp in pairs(responses or {}) do
    if resp and resp.result then
      local encoding = resp.offset_encoding or "utf-16"
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

function M.cancel_lsp_requests(handles)
  for client_id, request_id in pairs(handles or {}) do
    local client
    if vim.lsp.get_client_by_id then
      local ok
      ok, client = pcall(vim.lsp.get_client_by_id, client_id)
      client = ok and client or nil
    end
    if client and client.cancel_request then
      local ok = pcall(client.cancel_request, request_id)
      if not ok then
        pcall(client.cancel_request, client, request_id)
      end
    end
    handles[client_id] = nil
  end
end

function M.request_lsp_highlight(bufnr, anchor, scope, timeout_ms, on_done)
  local clients = {}
  for _, client in pairs(get_attached_clients(bufnr)) do
    if supports_document_highlight(client, bufnr) then
      clients[#clients + 1] = client
    end
  end

  local done, pending = false, #clients
  local handles, responses, terminal = {}, {}, {}

  local function finish()
    if done then
      return
    end
    done = true
    if not vim.api.nvim_buf_is_valid(bufnr) then
      on_done(M.make_lsp_result("request_failed"))
      return
    end
    if not has_lsp_results(responses) then
      on_done(M.make_lsp_result("request_failed"))
      return
    end

    local lines, ranges = collect_lsp_result(bufnr, responses, scope)
    on_done(M.make_lsp_result("ok", lines, true, ranges))
  end

  local function complete(client, encoding, err, result)
    if done or terminal[client.id] then
      return
    end
    terminal[client.id] = true
    handles[client.id] = nil
    pending = pending - 1
    if not err and result ~= nil then
      responses[client.id] = { result = result, offset_encoding = encoding }
    end
    if pending == 0 then
      finish()
    end
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, anchor.row, anchor.row + 1, false)[1] or ""
  for _, client in ipairs(clients) do
    local request_client = client
    local encoding = request_client.offset_encoding
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = {
        line = anchor.row,
        character = lsp_character(line, anchor.col, encoding),
      },
    }
    local callback = function(err, result)
      complete(request_client, encoding, err, result)
    end
    local ok, sent, handle = pcall(request_client.request, "textDocument/documentHighlight", params, callback, bufnr)
    if not ok then
      ok, sent, handle =
        pcall(request_client.request, request_client, "textDocument/documentHighlight", params, callback, bufnr)
    end
    if ok and sent and not terminal[request_client.id] then
      handles[request_client.id] = handle
    else
      complete(request_client, encoding, true)
    end
  end

  if pending == 0 then
    finish()
  end
  vim.defer_fn(function()
    finish()
    M.cancel_lsp_requests(handles)
  end, timeout_ms)
  return handles
end

local function sorted_lines(path_set)
  local out = vim.tbl_keys(path_set)
  table.sort(out)
  return out
end

function M.collect_word_matches(bufnr, symbol, scope)
  local word_set = {}
  local word_ranges = {}

  local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
  for idx, raw in ipairs(lines) do
    local lnum = scope.start_line + idx - 1
    local cleaned = strip_strings_and_comments(raw)
    local ranges = collect_word_ranges(cleaned, symbol, lnum)
    if #ranges > 0 then
      word_set[lnum] = true
      add_ranges(word_ranges, ranges)
    end
  end

  return word_set, word_ranges
end

local function collect_source_result(name, context)
  if context.source_results[name] then
    return context.source_results[name]
  end

  local result
  if name == "word" then
    local lines, ranges = M.collect_word_matches(context.bufnr, context.symbol, context.scope)
    local used = next(lines) ~= nil
    result = {
      lines = lines,
      ranges = ranges,
      used = used,
      reason = used and nil or "no_matches",
      failed_source = name,
      used_word = true,
    }
  elseif name == "lsp" then
    if not context.lsp_result then
      return { pending_lsp = true }
    end
    local lines = context.lsp_result.lines or {}
    local used = next(lines) ~= nil
    result = {
      lines = lines,
      ranges = context.lsp_result.ranges or {},
      used = used,
      reason = not used and (context.lsp_result.reason == "ok" and "no_matches" or context.lsp_result.reason) or nil,
      used_lsp = true,
      failed_source = name,
    }
  elseif name == "treesitter" then
    result = collect_treesitter_lines(context.bufnr, context.symbol, context.scope)
    result.failed_source = name
  elseif context.custom_sources[name] then
    local handler = context.custom_sources[name]
    local ok, raw_result = pcall(handler, {
      anchor = { row = context.anchor.row, col = context.anchor.col },
      bufnr = context.bufnr,
      direction = context.direction,
      keywords = vim.deepcopy(context.keywords),
      mode = context.mode,
      scope = { start_line = context.scope.start_line, end_line = context.scope.end_line },
      symbol = context.symbol,
    })
    if not ok or type(raw_result) ~= "table" then
      result = {
        lines = {},
        ranges = {},
        used = false,
        reason = ok and "no_matches" or "error",
        failed_source = name,
        has_custom = true,
      }
    else
      local lines = {}
      local ranges = {}
      local buffer_lines = vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false)
      for lnum, included in pairs(raw_result) do
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
      result = {
        lines = lines,
        ranges = ranges,
        used = used,
        reason = used and nil or "no_matches",
        failed_source = name,
        has_custom = true,
        used_custom = true,
      }
    end
  else
    result = { lines = {}, ranges = {}, used = false, reason = "unavailable", failed_source = name }
  end

  context.source_results[name] = result
  return result
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
    if source.pending_lsp then
      return source
    end
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
    used_fallback = false,
    fallback_reason = nil,
  }

  for i, step in ipairs(sources) do
    local result = collect_source_step(step, context)
    if result.pending_lsp then
      return nil, nil, nil, context
    end
    if result.used then
      add_set(path_set, result.lines)
      add_ranges(ranges, result.ranges)
      meta.used_source = source_step_label(step)
      meta.used_lsp = result.used_lsp or false
      meta.used_custom = result.used_custom or false
      meta.used_word = result.used_word or false
      meta.used_fallback = i > 1
      return path_set, ranges, meta
    end
    meta.failed_sources[#meta.failed_sources + 1] = source_step_label(step)
    if not meta.fallback_reason then
      meta.fallback_reason = result.reason
      meta.fallback_source = result.failed_source
    end
  end

  return path_set, ranges, meta
end

function M.compute_path(bufnr, symbol, anchor, scope, opts)
  local lsp_result = opts.lsp_result
  if not opts.pause_for_lsp and not lsp_result then
    lsp_result = M.make_lsp_result("disabled")
  end
  local context = opts.resolution_context
    or {
      anchor = anchor,
      analyzers = opts.analyzers,
      bufnr = bufnr,
      custom_sources = opts.custom_sources or {},
      direction = opts.direction,
      keywords = opts.keywords or {},
      lsp_result = lsp_result,
      max_depth = opts.max_depth,
      mode = opts.mode,
      scope = scope,
      source_results = {},
      sources = opts.sources or {},
      symbol = symbol,
    }
  if opts.resolution_context and opts.lsp_result then
    context.lsp_result = opts.lsp_result
  end

  local path_set, ranges, meta, pending = resolve_source_chain(context.sources, context)
  if pending then
    return nil, nil, nil, nil, pending
  end
  path_set[anchor.row + 1] = true

  if context.mode == "flow" and meta.used_source then
    local analysis, flow_meta = flow.analyze({
      anchor = anchor,
      bufnr = bufnr,
      keywords = context.keywords,
      scope = scope,
      symbol = symbol,
    }, context.analyzers)
    for key, value in pairs(flow_meta) do
      meta[key] = value
    end
    if analysis then
      local _, expand_meta = flow.expand(path_set, ranges, symbol, analysis, context.direction, context.max_depth)
      for key, value in pairs(expand_meta) do
        meta[key] = value
      end
    else
      meta.flow_expanded = false
      meta.flow_tracked_count = 0
      meta.flow_added_lines = 0
    end
  end

  return path_set, sorted_lines(path_set), meta, normalize_ranges(bufnr, ranges)
end

return M
