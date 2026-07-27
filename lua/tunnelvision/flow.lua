-- Text-based flow analysis and expansion.

local M = {}

local FLOW_MAX_ITER = 32
local assign_ops = { "+=", "-=", "*=", "/=", "%=", ":=", "=" }
local compound_ops = { ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true }
local declaration_keywords = { ["local"] = true, let = true, const = true, var = true }

local function strip_strings_and_comments(line)
  local function mask(text)
    return (" "):rep(#text)
  end

  local stripped = line:gsub('".-"', mask):gsub("'.-'", mask)
  stripped = stripped:gsub("//.*$", mask)
  stripped = stripped:gsub("#.*$", mask)
  stripped = stripped:gsub("%-%-.*$", mask)
  return stripped
end

local function collect_tokens(text, line, keywords, offset)
  local tokens = {}
  local from = 1
  while true do
    local start_col, end_col = text:find("[%a_][%w_]*", from)
    if not start_col then
      return tokens
    end
    local name = text:sub(start_col, end_col)
    if not keywords[name] then
      tokens[#tokens + 1] = {
        name = name,
        line = line,
        start_col = (offset or 0) + start_col - 1,
        end_col = (offset or 0) + end_col,
      }
    end
    from = end_col + 1
  end
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

local function parse_lhs(text, line, keywords)
  local body, offset = text, 0
  local _, declaration_end, declaration = text:find("^%s*([%a_][%w_]*)%s+")
  local has_declaration = declaration_keywords[declaration]
  if has_declaration then
    body, offset = text:sub(declaration_end + 1), declaration_end
  end

  local lhs, from = {}, 1
  while from <= #body do
    local comma = body:find(",", from, true) or (#body + 1)
    local segment = body:sub(from, comma - 1)
    local leading, name = segment:match("^(%s*)([%a_][%w_]*)")
    local start_col = leading and #leading + 1 or nil
    local end_col = name and start_col + #name - 1 or nil
    local rest = end_col and segment:sub(end_col + 1) or ""
    if not has_declaration and comma > #body and rest:match("^%s+[%a_][%w_]*%s*$") then
      start_col, _, name = segment:find("([%a_][%w_]*)%s*$")
      end_col = start_col + #name - 1
      rest = ""
    end
    if not name or keywords[name] or not (rest:match("^%s*$") or rest:match("^%s*:%s*[%a_][%w_%.%[%]]*%s*$")) then
      return
    end
    lhs[#lhs + 1] = {
      name = name,
      line = line,
      start_col = offset + from + start_col - 2,
      end_col = offset + from + end_col - 1,
    }
    from = comma + 1
  end
  return #lhs > 0 and lhs or nil
end

local function parse_assignment(text, line, keywords)
  local assign_col, op = find_assign(text)
  if not assign_col then
    return
  end

  local lhs = parse_lhs(text:sub(1, assign_col - 1), line, keywords)
  if not lhs then
    return
  end

  local rhs = collect_tokens(text:sub(assign_col + #op), line, keywords, assign_col + #op - 1)
  if compound_ops[op] then
    for _, token in ipairs(lhs) do
      rhs[#rhs + 1] = token
    end
  end
  return { line = line, lhs = lhs, rhs = rhs }
end

function M.analyze_text(context)
  local analysis = { assignments = {}, occurrences = {} }
  local lines = vim.api.nvim_buf_get_lines(context.bufnr, context.scope.start_line - 1, context.scope.end_line, false)

  for index, raw in ipairs(lines) do
    local line = context.scope.start_line + index - 1
    local text = strip_strings_and_comments(raw)
    for _, token in ipairs(collect_tokens(text, line, context.keywords or {})) do
      analysis.occurrences[token.name] = analysis.occurrences[token.name] or {}
      analysis.occurrences[token.name][#analysis.occurrences[token.name] + 1] = token
    end
    local assignment = parse_assignment(text, line, context.keywords or {})
    if assignment then
      analysis.assignments[#analysis.assignments + 1] = assignment
    end
  end

  return analysis
end

local function is_identifier(node_type)
  return node_type:find("identifier", 1, true) or node_type == "variable" or node_type == "name"
end

local function is_function(node_type)
  if
    node_type:find("call", 1, true)
    or node_type:find("invocation", 1, true)
    or node_type:find("reference", 1, true)
    or node_type:find("parameter", 1, true)
    or node_type:find("function_type", 1, true)
  then
    return false
  end
  return node_type:find("function", 1, true)
    or node_type:find("method", 1, true)
    or node_type:find("lambda", 1, true)
    or node_type:find("arrow", 1, true)
    or node_type == "closure_expression"
    or node_type == "func_literal"
end

local function contains(node, row, col)
  local start_row, start_col, end_row, end_col = node:range()
  return (row > start_row or row == start_row and col >= start_col)
    and (row < end_row or row == end_row and col < end_col)
end

local function collect_ts_tokens(node, context)
  local tokens = {}
  local function walk(current)
    if is_function(current:type()) and not contains(current, context.anchor.row, context.anchor.col) then
      return
    end
    if is_identifier(current:type()) then
      local start_row, start_col, end_row, end_col = current:range()
      local name = vim.treesitter.get_node_text(current, context.bufnr)
      if start_row == end_row and name and not context.keywords[name] then
        tokens[#tokens + 1] = { name = name, line = start_row + 1, start_col = start_col, end_col = end_col }
      end
      return
    end
    for child in current:iter_children() do
      if child:named() then
        walk(child)
      end
    end
  end
  walk(node)
  return tokens
end

local function complex_target(node)
  local node_type = node:type()
  if
    node_type:find("index", 1, true)
    or node_type:find("field", 1, true)
    or node_type:find("member", 1, true)
    or node_type:find("subscript", 1, true)
    or node_type:find("table", 1, true)
    or node_type:find("object", 1, true)
    or node_type:find("array", 1, true)
  then
    return true
  end
  for child in node:iter_children() do
    if child:named() and complex_target(child) then
      return true
    end
  end
  return false
end

local function assignment_sides(node)
  local lhs, rhs = {}, {}
  for _, field in ipairs({ "left", "name", "pattern" }) do
    vim.list_extend(lhs, node:field(field) or {})
  end
  for _, field in ipairs({ "right", "value" }) do
    vim.list_extend(rhs, node:field(field) or {})
  end
  if #lhs == 0 and node:named_child_count() >= 2 then
    lhs = { node:named_child(0) }
    rhs = { node:named_child(1) }
  end
  return lhs, rhs
end

function M.analyze_treesitter(context)
  local ok, analysis = pcall(function()
    local parser = vim.treesitter.get_parser(context.bufnr)
    local tree = parser:parse()[1]
    if not tree then
      error("missing tree")
    end

    local result = { assignments = {}, occurrences = {} }
    local scope_start, scope_end = context.scope.start_line - 1, context.scope.end_line - 1
    local function walk(node, inside_assignment)
      local start_row, _, end_row = node:range()
      if end_row < scope_start or start_row > scope_end then
        return
      end
      if is_function(node:type()) and not contains(node, context.anchor.row, context.anchor.col) then
        return
      end
      if is_identifier(node:type()) then
        local token = collect_ts_tokens(node, context)[1]
        if token then
          result.occurrences[token.name] = result.occurrences[token.name] or {}
          result.occurrences[token.name][#result.occurrences[token.name] + 1] = token
        end
        return
      end

      local node_type = node:type()
      local is_assignment = node_type:find("assignment", 1, true)
        or node_type:find("declarator", 1, true)
        or node_type == "short_var_declaration"
        or node_type == "let_declaration"
      if is_assignment and not inside_assignment then
        local lhs_nodes, rhs_nodes = assignment_sides(node)
        local lhs, rhs = {}, {}
        for _, side in ipairs(lhs_nodes) do
          if complex_target(side) then
            lhs = {}
            break
          end
          vim.list_extend(lhs, collect_ts_tokens(side, context))
        end
        for _, side in ipairs(rhs_nodes) do
          vim.list_extend(rhs, collect_ts_tokens(side, context))
        end
        if #lhs > 0 then
          local text = vim.treesitter.get_node_text(node, context.bufnr) or ""
          if text:find("[+%-*/%%]=") then
            vim.list_extend(rhs, lhs)
          end
          result.assignments[#result.assignments + 1] = { line = lhs[1].line, lhs = lhs, rhs = rhs }
        end
      end

      for child in node:iter_children() do
        if child:named() then
          walk(child, inside_assignment or is_assignment)
        end
      end
    end
    walk(tree:root())
    return result
  end)
  return ok and analysis or nil, ok and nil or "unavailable"
end

function M.analyze(context, analyzers)
  analyzers = analyzers or { "treesitter", "text" }
  local meta = { flow_analyzers = vim.deepcopy(analyzers), flow_analyzer = nil, flow_fallback = false }
  local fallback_reason
  for index, analyzer in ipairs(analyzers) do
    local analysis, reason
    if analyzer == "treesitter" then
      analysis, reason = M.analyze_treesitter(context)
    elseif analyzer == "text" then
      analysis = M.analyze_text(context)
    end
    if analysis then
      meta.flow_analyzer = analyzer
      meta.flow_fallback = index > 1
      meta.flow_fallback_reason = fallback_reason
      return analysis, meta
    end
    fallback_reason = fallback_reason or reason
  end
  meta.flow_fallback_reason = fallback_reason
  return nil, meta
end

local function add_edge(edges, from, to)
  edges[from] = edges[from] or {}
  edges[from][to] = true
end

function M.expand(path_set, symbol_ranges, symbol, analysis, direction, max_depth)
  local edges = {}
  for _, assignment in ipairs(analysis.assignments) do
    for _, lhs in ipairs(assignment.lhs) do
      for _, rhs in ipairs(assignment.rhs) do
        if direction == "forward" or direction == "both" then
          add_edge(edges, rhs.name, lhs.name)
        end
        if direction == "backward" or direction == "both" then
          add_edge(edges, lhs.name, rhs.name)
        end
      end
    end
  end

  local depth_limit = math.min(max_depth or FLOW_MAX_ITER, FLOW_MAX_ITER)
  local tracked, queue = { [symbol] = 0 }, { symbol }
  local index = 1
  while queue[index] do
    local name = queue[index]
    index = index + 1
    if tracked[name] < depth_limit then
      for next_name in pairs(edges[name] or {}) do
        if tracked[next_name] == nil then
          tracked[next_name] = tracked[name] + 1
          queue[#queue + 1] = next_name
        end
      end
    end
  end

  local added_lines = 0
  for name in pairs(tracked) do
    for _, token in ipairs(analysis.occurrences[name] or {}) do
      if not path_set[token.line] then
        path_set[token.line] = true
        added_lines = added_lines + 1
      end
      symbol_ranges[#symbol_ranges + 1] = {
        line = token.line,
        start_col = token.start_col,
        end_col = token.end_col,
      }
    end
  end

  return tracked,
    {
      flow_expanded = true,
      flow_tracked_count = vim.tbl_count(tracked),
      flow_added_lines = added_lines,
    }
end

return M
