-- tunnelvision.context
--
-- Computes extra visible lines that should remain undimmed alongside the
-- source/flow path. These lines are never used for navigation.
--
-- Responsibilities:
-- - evaluate visible_context config ("line", "statement", or function)
-- - clamp and validate returned ranges
--
-- This module is intentionally stateless.

local M = {}

local STATEMENT_MAX_LINES = 50

local statement_types = {
  declaration = true,
  field_declaration = true,
  variable_declaration = true,
  local_declaration = true,
  lexical_declaration = true,
  expression_statement = true,
  assignment_statement = true,
  return_statement = true,
  throw_statement = true,
}

local broad_types = {
  block = true,
  compound_statement = true,
  function_definition = true,
  function_declaration = true,
  method_declaration = true,
  class_declaration = true,
  struct_declaration = true,
  if_statement = true,
  for_statement = true,
  while_statement = true,
  switch_statement = true,
}

local scope_head_types = {
  if_statement = true,
  for_statement = true,
  while_statement = true,
  function_definition = true,
  function_declaration = true,
  method_declaration = true,
  else_clause = true,
  elif_clause = true,
  elseif_statement = true,
  else_statement = true,
}

local function is_useful_statement(node_type)
  if statement_types[node_type] then
    return true
  end
  return node_type:match("_declaration$") ~= nil or node_type:match("_statement$") ~= nil
end

local function is_too_broad(node_type, span)
  return broad_types[node_type] or span > STATEMENT_MAX_LINES
end

local function statement_range_for_line(bufnr, lnum, anchor)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return nil
  end
  local ok_tree, parsed = pcall(parser.parse, parser)
  if not ok_tree or not parsed or not parsed[1] then
    return nil
  end

  local col = (lnum == anchor.row + 1) and anchor.col or 0
  local node = parsed[1]:root():named_descendant_for_range(lnum - 1, col, lnum - 1, col)
  if not node then
    return nil
  end

  while node do
    local ntype = node:type()
    if is_useful_statement(ntype) then
      local start_row, _, end_row, _ = node:range()
      local span = end_row - start_row + 1
      if not is_too_broad(ntype, span) then
        return { start_line = start_row + 1, end_line = end_row + 1 }
      end
      return nil
    end
    node = node:parent()
  end

  return nil
end

local function clamp_range(range, scope, line_count)
  if type(range) ~= "table" or type(range.start_line) ~= "number" or type(range.end_line) ~= "number" then
    return nil
  end
  local start_line = math.max(range.start_line, scope.start_line)
  local end_line = math.min(range.end_line, scope.end_line)
  if start_line > end_line then
    return nil
  end
  if start_line > line_count then
    return nil
  end
  return { start_line = start_line, end_line = math.min(end_line, line_count) }
end

local function add_range(out, range)
  for lnum = range.start_line, range.end_line do
    out[lnum] = true
  end
end

local function collect_scope_heads(path_set, bufnr, scope)
  local heads = {}

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return heads
  end
  local ok_tree, parsed = pcall(parser.parse, parser)
  if not ok_tree or not parsed or not parsed[1] then
    return heads
  end

  for lnum in pairs(path_set) do
    local node = parsed[1]:root():named_descendant_for_range(lnum - 1, 0, lnum - 1, 0)
    while node do
      if scope_head_types[node:type()] then
        local start_row = node:start()
        local head_line = start_row + 1
        if head_line >= scope.start_line and head_line <= scope.end_line and head_line ~= lnum then
          heads[head_line] = true
        end
      end
      node = node:parent()
    end
  end

  return heads
end

function M.evaluate(cfg, path_set, bufnr, symbol, anchor, scope)
  local context_set = {}

  if cfg.visible_context == "statement" then
    for lnum in pairs(path_set) do
      local range = statement_range_for_line(bufnr, lnum, anchor)
      if range then
        local clamped = clamp_range(range, scope, vim.api.nvim_buf_line_count(bufnr))
        if clamped then
          add_range(context_set, clamped)
        end
      end
    end
  elseif type(cfg.visible_context) == "function" then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local any_node = false
    local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if parser_ok and parser then
      local ok_tree, parsed = pcall(parser.parse, parser)
      if ok_tree and parsed and parsed[1] then
        any_node = true
      end
    end

    for lnum in pairs(path_set) do
      local node = nil
      if any_node then
        local ok_tree, parsed = pcall(parser.parse, parser)
        if ok_tree and parsed and parsed[1] then
          local col = (lnum == anchor.row + 1) and anchor.col or 0
          node = parsed[1]:root():named_descendant_for_range(lnum - 1, col, lnum - 1, col)
        end
      end

      local context = {
        bufnr = bufnr,
        symbol = symbol,
        line = lnum,
        col = (lnum == anchor.row + 1) and anchor.col or nil,
        scope = { start_line = scope.start_line, end_line = scope.end_line },
        node = node,
      }

      local ok, range = pcall(cfg.visible_context, context)
      if ok then
        local clamped = clamp_range(range, scope, line_count)
        if clamped then
          add_range(context_set, clamped)
        end
      end
    end
  end

  if cfg.preserve_scope_heads then
    local heads = collect_scope_heads(path_set, bufnr, scope)
    for lnum in pairs(heads) do
      context_set[lnum] = true
    end
  end

  return context_set
end

return M
