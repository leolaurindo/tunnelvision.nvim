-- tunnelvision.context
--
-- Resolves structural highlight geometry. These lines are never navigation
-- targets, and Tree-sitter availability never affects source selection.

local M = {}

local STATEMENT_MAX_LINES = 50

local statement_types = {
  assignment = true,
  assignment_statement = true,
  augmented_assignment = true,
  class_parameter = true,
  const_declaration = true,
  declaration = true,
  default_parameter = true,
  expression_statement = true,
  field_declaration = true,
  formal_parameter = true,
  let_declaration = true,
  local_declaration = true,
  lexical_declaration = true,
  optional_parameter = true,
  optional_parameter_declaration = true,
  parameter = true,
  parameter_declaration = true,
  parameter_with_optional_type = true,
  receiver_parameter = true,
  required_parameter = true,
  self_parameter = true,
  spread_parameter = true,
  return_statement = true,
  short_var_declaration = true,
  throw_statement = true,
  typed_default_parameter = true,
  typed_parameter = true,
  variable_declaration = true,
  variadic_parameter = true,
  variadic_parameter_declaration = true,
  yield_statement = true,
}

local standalone_call_parents = { block = true, chunk = true }
local parameter_containers = {
  formal_parameters = true,
  function_value_parameters = true,
  lambda_parameters = true,
  parameter_list = true,
  parameters = true,
  value_parameters = true,
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

local function add_range(out, start_line, end_line, scope, line_count)
  start_line = math.max(start_line, scope.start_line)
  end_line = math.min(end_line, scope.end_line, line_count)
  for lnum = start_line, end_line do
    out[lnum] = true
  end
end

local function parse_root(bufnr, context)
  if context and context.get_treesitter then
    local snapshot = context.get_treesitter()
    return snapshot and snapshot.root
  end

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
  local seen = {}
  for _, range in ipairs(symbol_ranges) do
    if path_set[range.line] then
      positions[range.line] = positions[range.line] or {}
      seen[range.line] = seen[range.line] or {}
      if not seen[range.line][range.start_col] then
        positions[range.line][#positions[range.line] + 1] = range.start_col
        seen[range.line][range.start_col] = true
      end
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

local function analyze_node(start_node, wants_statement, wants_scope_heads, cache, types, node_key)
  local chain = {}
  local node = start_node
  local result
  while node do
    local key = node_key(node)
    result = cache[key]
    if result then
      break
    end
    local node_type = types[key]
    if not node_type then
      node_type = node:type()
      types[key] = node_type
    end
    local parent = node:parent()
    local is_statement = false
    if wants_statement then
      is_statement = statement_types[node_type]
      if not is_statement and parent then
        local parent_key = node_key(parent)
        local parent_type = types[parent_key]
        if not parent_type then
          parent_type = parent:type()
          types[parent_key] = parent_type
        end
        is_statement = node_type == "function_call" and standalone_call_parents[parent_type]
          or parameter_containers[parent_type]
      end
    end
    chain[#chain + 1] = { node = node, key = key, type = node_type, is_statement = is_statement }
    if is_statement and not wants_scope_heads then
      break
    end
    node = parent
  end

  result = result or {}
  for i = #chain, 1, -1 do
    local current = chain[i]
    local statement = current.is_statement and current.node or result.statement

    local scope_heads = result.scope_heads
    if wants_scope_heads and scope_head_types[current.type] then
      local start_row = current.node:start()
      scope_heads = { line = start_row + 1, next = scope_heads }
    end
    result = { statement = statement, scope_heads = scope_heads }
    cache[current.key] = result
  end
  return result
end

function M.evaluate(cfg, path_set, symbol_ranges, bufnr, scope, context)
  local statement_set = {}
  local scope_head_set = {}
  local fallback = { statement = false, scope_head = false }
  local wants_statement = cfg.highlights.statement ~= nil
  local wants_scope_heads = cfg.highlights.scope_head ~= nil
  if not wants_statement and not wants_scope_heads then
    return statement_set, scope_head_set, fallback
  end

  local root = parse_root(bufnr, context)
  local ok = root
    and pcall(function()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local cache = {}
      local ranges = {}
      local types = {}
      local statement_ranges = {}
      local id_keys = {}
      local function node_key(node)
        local ok_id, id = pcall(function()
          return node:id()
        end)
        if not ok_id or id == nil then
          return node
        end
        if not id_keys[id] then
          id_keys[id] = {}
        end
        return id_keys[id]
      end
      for lnum, columns in pairs(positions_by_line(path_set, symbol_ranges, bufnr)) do
        local found_statement = false
        for _, col in ipairs(columns) do
          local node = root:named_descendant_for_range(lnum - 1, col, lnum - 1, col)
          local result = analyze_node(node, wants_statement, wants_scope_heads, cache, types, node_key)
          if wants_statement and result.statement then
            local range_key = node_key(result.statement)
            local range = ranges[range_key]
            if range == nil then
              local start_row, _, end_row, end_col = result.statement:range()
              local end_line = end_row + (end_col > 0 and 1 or 0)
              range = end_line - start_row <= STATEMENT_MAX_LINES and { start_row + 1, end_line } or false
              ranges[range_key] = range
            end
            if range then
              local start_line, end_line = unpack(range)
              statement_ranges[start_line] = statement_ranges[start_line] or {}
              statement_ranges[start_line][end_line] = true
              found_statement = true
            end
          end

          if wants_scope_heads then
            local scope_head = result.scope_heads
            while scope_head do
              if scope_head.line >= scope.start_line and scope_head.line <= scope.end_line then
                scope_head_set[scope_head.line] = true
              end
              scope_head = scope_head.next
            end
          end
        end
        if wants_statement and not found_statement then
          statement_set[lnum] = true
          fallback.statement = true
        end
      end
      for start_line, end_lines in pairs(statement_ranges) do
        for end_line in pairs(end_lines) do
          add_range(statement_set, start_line, end_line, scope, line_count)
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
