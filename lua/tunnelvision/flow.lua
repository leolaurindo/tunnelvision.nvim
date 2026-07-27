-- Text-based flow analysis and expansion.

local M = {}

local FLOW_MAX_ITER = 32
local assign_ops = { "+=", "-=", "*=", "/=", "%=", "=" }

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

local function parse_assignment(text, line, keywords)
  local assign_col, op = find_assign(text)
  if not assign_col then
    return
  end

  local lhs_text = text:sub(1, assign_col - 1)
  if lhs_text:find(",", 1, true) then
    return
  end

  local declaration_name = lhs_text:match("^%s*local%s+([%a_][%w_]*)")
  local lhs_name = declaration_name or lhs_text:match("([%a_][%w_]*)%s*$")
  if not lhs_name or keywords[lhs_name] then
    return
  end

  local lhs_tokens = collect_tokens(lhs_text, line, keywords)
  local lhs
  local first, last, step = #lhs_tokens, 1, -1
  if declaration_name then
    first, last, step = 1, #lhs_tokens, 1
  end
  for i = first, last, step do
    if lhs_tokens[i].name == lhs_name then
      lhs = lhs_tokens[i]
      break
    end
  end
  if not lhs then
    return
  end

  local rhs = collect_tokens(text:sub(assign_col + #op), line, keywords, assign_col + #op - 1)
  if op ~= "=" then
    rhs[#rhs + 1] = lhs
  end
  return { line = line, lhs = { lhs }, rhs = rhs }
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

local function side_intersects(side, tracked)
  for _, token in ipairs(side) do
    if tracked[token.name] then
      return true
    end
  end
  return false
end

local function add_side(tracked, side)
  local changed = false
  for _, token in ipairs(side) do
    if not tracked[token.name] then
      tracked[token.name] = true
      changed = true
    end
  end
  return changed
end

local function line_facts(analysis)
  local by_line = {}
  for _, tokens in pairs(analysis.occurrences) do
    for _, token in ipairs(tokens) do
      by_line[token.line] = by_line[token.line] or { line = token.line, tokens = {} }
      by_line[token.line].tokens[#by_line[token.line].tokens + 1] = token
    end
  end
  for _, assignment in ipairs(analysis.assignments) do
    by_line[assignment.line] = by_line[assignment.line] or { line = assignment.line, tokens = {} }
    by_line[assignment.line].assignments = by_line[assignment.line].assignments or {}
    by_line[assignment.line].assignments[#by_line[assignment.line].assignments + 1] = assignment
  end

  local facts = vim.tbl_values(by_line)
  table.sort(facts, function(a, b)
    return a.line < b.line
  end)
  return facts
end

function M.expand(path_set, symbol_ranges, symbol, analysis, direction)
  local tracked = { [symbol] = true }
  local facts = line_facts(analysis)
  local changed, guard = true, 0
  while changed and guard < FLOW_MAX_ITER do
    changed = false
    guard = guard + 1
    for _, fact in ipairs(facts) do
      local line_hit = side_intersects(fact.tokens, tracked)
      for _, assignment in ipairs(fact.assignments or {}) do
        local lhs_hit = side_intersects(assignment.lhs, tracked)
        local rhs_hit = side_intersects(assignment.rhs, tracked)
        line_hit = line_hit or lhs_hit or rhs_hit
        if rhs_hit then
          changed = add_side(tracked, assignment.lhs) or changed
        end
        if direction == "both" and lhs_hit then
          changed = add_side(tracked, assignment.rhs) or changed
        end
      end
      if line_hit then
        path_set[fact.line] = true
      end
    end
  end

  for name in pairs(tracked) do
    for _, token in ipairs(analysis.occurrences[name] or {}) do
      if path_set[token.line] then
        symbol_ranges[#symbol_ranges + 1] = {
          line = token.line,
          start_col = token.start_col,
          end_col = token.end_col,
        }
      end
    end
  end

  return tracked
end

return M
