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

function M.compute_path(bufnr, symbol, anchor, scope, opts)
  local path_set = {}
  local word_set = {}
  local source = opts.source
  local use_flow = opts.mode == "flow" and source ~= "lsp"
  local tracked = { [symbol] = true }
  local line_info = {}
  local keywords = opts.keywords or {}
  local lsp_result = opts.lsp_result or M.make_lsp_result("disabled")

  local need_word = source ~= "lsp" and (source ~= "lsp_else_word" or not lsp_result.used)
  local meta = { used_lsp = false, used_fallback = false, fallback_reason = nil }

  if source == "lsp_else_word" and lsp_result.used and not use_flow then
    add_set(path_set, lsp_result.lines)
    path_set[anchor.row + 1] = true
    meta.used_lsp = true
    return path_set, sorted_lines(path_set), meta
  end

  if use_flow or need_word then
    local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
    for idx, raw in ipairs(lines) do
      local lnum = scope.start_line + idx - 1
      local cleaned = strip_strings_and_comments(raw)

      if need_word and line_has_word(cleaned, symbol) then
        word_set[lnum] = true
      end

      if use_flow then
        local lhs, rhs = parse_assignment(cleaned, keywords)
        line_info[#line_info + 1] = {
          lnum = lnum,
          ids = collect_identifiers(cleaned, keywords),
          lhs = lhs,
          rhs = rhs,
        }
      end
    end
  end

  if source == "word" then
    add_set(path_set, word_set)
  elseif source == "lsp_and_word" then
    add_set(path_set, word_set)
    add_set(path_set, lsp_result.lines)
    meta.used_lsp = lsp_result.used
  elseif source == "lsp" then
    add_set(path_set, lsp_result.lines)
    meta.used_lsp = lsp_result.used
    if not lsp_result.used then
      meta.fallback_reason = lsp_result.reason
    end
  elseif lsp_result.used then
    add_set(path_set, lsp_result.lines)
    meta.used_lsp = true
  else
    add_set(path_set, word_set)
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
        if opts.direction == "both" and lhs_hit and info.rhs then
          changed = add_set(tracked, info.rhs) or changed
        end
      end
    end
  end

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set), meta
end

return M
