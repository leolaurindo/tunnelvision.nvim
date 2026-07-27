-- tunnelvision.context
--
-- Resolves structural highlight geometry. These lines are never navigation
-- targets, and Tree-sitter availability never affects source selection.

local M = {}

local STATEMENT_MAX_LINES = 50

local statement_types = {
  assignment = true,
  augmented_assignment = true,
  const_declaration = true,
  declaration = true,
  expression_statement = true,
  field_declaration = true,
  let_declaration = true,
  local_declaration = true,
  lexical_declaration = true,
  assignment_statement = true,
  return_statement = true,
  short_var_declaration = true,
  throw_statement = true,
  variable_declaration = true,
  yield_statement = true,
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
  else_clause = true,
  elif_clause = true,
  elseif_statement = true,
  else_statement = true,
}

local scope_head_types = {
  arrow_function = true,
  if_statement = true,
  if_expression = true,
  for_statement = true,
  for_expression = true,
  while_statement = true,
  while_expression = true,
  function_definition = true,
  function_declaration = true,
  function_item = true,
  method_declaration = true,
  method_definition = true,
  else_clause = true,
  elif_clause = true,
  elseif_statement = true,
  else_statement = true,
}

local function is_useful_statement(node_type)
  return statement_types[node_type] == true
end

local function statement_range(node)
  while node do
    local node_type = node:type()
    if is_useful_statement(node_type) then
      local start_row, _, end_row, end_col = node:range()
      local end_line = end_row + (end_col > 0 and 1 or 0)
      if not broad_types[node_type] and end_line - start_row <= STATEMENT_MAX_LINES then
        return start_row + 1, end_line
      end
      return nil
    end
    node = node:parent()
  end
end

local function add_range(out, start_line, end_line, scope, line_count)
  start_line = math.max(start_line, scope.start_line)
  end_line = math.min(end_line, scope.end_line, line_count)
  for lnum = start_line, end_line do
    out[lnum] = true
  end
end

local function parse_root(bufnr)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return nil
  end

  local ok_tree, parsed = pcall(parser.parse, parser)
  if not ok_tree or not parsed or not parsed[1] then
    return nil
  end
  local ok_root, root = pcall(parsed[1].root, parsed[1])
  return ok_root and root or nil
end

local function positions_by_line(path_set, symbol_ranges, bufnr)
  local positions = {}
  for _, range in ipairs(symbol_ranges) do
    if path_set[range.line] then
      positions[range.line] = positions[range.line] or {}
      positions[range.line][#positions[range.line] + 1] = range.start_col
    end
  end

  for lnum in pairs(path_set) do
    if not positions[lnum] then
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local first_nonblank = line:find("%S")
      positions[lnum] = { first_nonblank and first_nonblank - 1 or 0 }
    end
  end
  return positions
end

function M.evaluate(cfg, path_set, symbol_ranges, bufnr, scope)
  local statement_set = {}
  local scope_head_set = {}
  local fallback = { statement = false, scope_head = false }
  local wants_statement = cfg.highlights.statement ~= nil
  local wants_scope_heads = cfg.highlights.scope_head ~= nil
  if not wants_statement and not wants_scope_heads then
    return statement_set, scope_head_set, fallback
  end

  local root = parse_root(bufnr)
  if not root then
    if wants_statement then
      for lnum in pairs(path_set) do
        statement_set[lnum] = true
      end
      fallback.statement = true
    end
    fallback.scope_head = wants_scope_heads
    return statement_set, scope_head_set, fallback
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local ok = pcall(function()
    for lnum, columns in pairs(positions_by_line(path_set, symbol_ranges, bufnr)) do
      local found_statement = false
      for _, col in ipairs(columns) do
        local node = root:named_descendant_for_range(lnum - 1, col, lnum - 1, col)
        if wants_statement then
          local start_line, end_line = statement_range(node)
          if start_line then
            add_range(statement_set, start_line, end_line, scope, line_count)
            found_statement = true
          end
        end

        if wants_scope_heads then
          while node do
            if scope_head_types[node:type()] then
              local start_row = node:start()
              local head_line = start_row + 1
              if head_line >= scope.start_line and head_line <= scope.end_line then
                scope_head_set[head_line] = true
              end
            end
            node = node:parent()
          end
        end
      end
      if wants_statement and not found_statement then
        statement_set[lnum] = true
        fallback.statement = true
      end
    end
  end)

  if not ok then
    statement_set = {}
    scope_head_set = {}
    if wants_statement then
      for lnum in pairs(path_set) do
        statement_set[lnum] = true
      end
      fallback.statement = true
    end
    fallback.scope_head = wants_scope_heads
  end

  return statement_set, scope_head_set, fallback
end

return M
