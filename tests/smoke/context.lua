-- Structural context coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local new_buffer = helpers.new_buffer
  local parser_or_skip = helpers.parser_or_skip

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")

  -- Structural contexts use exact source columns and remain separate from paths.
  do
    tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
    local structural_buf = new_buffer({
      "local function classify(alpha)",
      "  local total =",
      "    alpha +",
      "    1",
      "  if alpha > 0 then",
      "    total = total + alpha",
      "  elseif alpha < 0 then",
      "    total = alpha",
      "  else",
      "    total = 0",
      "  end",
      "  return total",
      "end",
    })

    local parser = parser_or_skip(0, "lua", "real Lua structural contexts")
    if parser then
      vim.api.nvim_win_set_cursor(0, { 2, 10 })
      tunnelvision.on({ highlights = { statement = true, scope_head = true } })
      local bs = core.get_buf_state(structural_buf)

      assert_true(
        vim.deep_equal(
          bs.statement_set,
          { [2] = true, [3] = true, [4] = true, [6] = true, [8] = true, [10] = true, [12] = true }
        ),
        "statement context should include complete conservative statements from exact columns"
      )
      assert_true(
        vim.deep_equal(bs.scope_head_set, { [1] = true, [5] = true, [7] = true, [9] = true }),
        "scope-head context should include function and conditional clause ancestors"
      )
      for _, lnum in ipairs(bs.path_order) do
        assert_true(not bs.scope_head_set[lnum], "scope heads should not enter path navigation")
      end

      local parse_count = 0
      local orig_get_parser = vim.treesitter.get_parser
      vim.treesitter.get_parser = function()
        return {
          parse = function()
            parse_count = parse_count + 1
            return parser:parse()
          end,
        }
      end
      require("tunnelvision.context").evaluate(bs.config, bs.path_set, bs.symbol_ranges, structural_buf, bs.scope)
      vim.treesitter.get_parser = orig_get_parser
      assert_true(parse_count == 1, "structural contexts should parse once per evaluation")

      tunnelvision.on({ highlights = { scope_head = true }, force = true })
      bs = core.get_buf_state(structural_buf)
      assert_true(next(bs.statement_set) == nil, "statement context should remain disabled independently")
      assert_true(bs.scope_head_set[9], "scope-head context should remain enabled independently")
      vim.cmd("TunnelVision off")

      assert_true(
        tunnelvision.register_source("structural_custom", function()
          return { [10] = true }
        end),
        "structural custom source registers"
      )
      vim.api.nvim_win_set_cursor(0, { 1, 25 })
      tunnelvision.on({
        sources = { "structural_custom" },
        highlights = { statement = true, scope_head = true },
      })
      bs = core.get_buf_state(structural_buf)
      assert_true(bs.statement_set[10], "range-less custom path should use its first nonblank statement node")
      assert_true(bs.scope_head_set[9], "range-less custom path should retain its enclosing else head")
      vim.cmd("TunnelVision off")
      assert_true(next(bs.statement_set) == nil, "deactivation should clear statement context")
      assert_true(next(bs.scope_head_set) == nil, "deactivation should clear scope-head context")
    end
  end

  -- Grammar-neutral structural contracts cover columns and conservative boundaries.
  do
    local context = require("tunnelvision.context")
    local buf = new_buffer({ "alpha(", "  value", ")" })
    local next_id, seen_col = 0
    local function node(node_type, parent, range)
      next_id = next_id + 1
      local id = next_id
      return {
        id = function()
          return id
        end,
        type = function()
          return node_type
        end,
        parent = function()
          return parent
        end,
        range = function()
          return unpack(range or { 0, 0, 0, 8 })
        end,
      }
    end
    local chunk = node("chunk")
    local assignment = node("assignment_statement", nil, { 0, 0, 2, 0 })
    local cases = {
      { "exclusive statement", node("expression_statement", nil, { 0, 0, 2, 0 }), { [1] = true, [2] = true }, false },
      { "standalone call", node("function_call", chunk, { 0, 0, 2, 0 }), { [1] = true, [2] = true }, false },
      {
        "nested call",
        node("function_call", node("expression_list", assignment), { 0, 0, 0, 8 }),
        { [1] = true, [2] = true },
        false,
      },
      { "parameter", node("parameter_declaration", node("parameters")), { [1] = true }, false },
      { "bare parameter", node("identifier", node("parameters")), { [1] = true }, false },
      { "argument", node("identifier", node("arguments")), { [1] = true }, true },
      { "broad container", node("try_statement"), { [1] = true }, true },
    }
    for _, case in ipairs(cases) do
      local tree_root = {
        named_descendant_for_range = function(_, _, col)
          seen_col = col
          return case[2]
        end,
      }
      local statements, _, fallback = context.evaluate(
        { highlights = { statement = {} } },
        { [1] = true },
        { { line = 1, start_col = 3, end_col = 8 } },
        buf,
        { start_line = 1, end_line = 3 },
        {
          get_treesitter = function()
            return { root = tree_root }
          end,
        }
      )
      assert_true(seen_col == 3, case[1] .. " should use the exact source column")
      assert_true(vim.deep_equal(statements, case[3]), case[1] .. " structural boundary")
      assert_true(fallback.statement == case[4], case[1] .. " fallback")
    end
  end

  -- Structural evaluation reuses duplicate and shared ancestor work within one call.
  do
    local context = require("tunnelvision.context")
    local buf = new_buffer({ "function", "if", "alpha", "alpha", "other", "missing" })

    local function evaluate(highlights, selected_ranges)
      local parent_seen = {}
      local calls = { descendant = 0, statement_range = 0, statement_start = 0 }
      local definitions = {
        root = { id = 0, type = "chunk", row = 0 },
        ["function"] = { id = 1, type = "function_definition", row = 0, parent = "root" },
        ["if"] = { id = 2, type = "if_statement", row = 1, parent = "function" },
        statement = { id = 3, type = "assignment_statement", row = 2, parent = "if" },
        first = { id = 4, type = "identifier", row = 2, parent = "statement" },
        second = { id = 5, type = "identifier", row = 3, parent = "statement" },
        missing = { id = 6, type = "identifier", row = 5, parent = "if" },
      }
      local function node(name)
        local definition = definitions[name]
        local current = {}
        current.id = function()
          return definition.id
        end
        current.type = function()
          return definition.type
        end
        current.parent = function()
          assert_true(not parent_seen[name], "shared ancestor should not be entered twice: " .. name)
          parent_seen[name] = true
          return definition.parent and node(definition.parent)
        end
        current.range = function()
          if name == "statement" then
            calls.statement_range = calls.statement_range + 1
          end
          return definition.row, 0, definition.row == 2 and 4 or definition.row, 0
        end
        current.start = function()
          if name == "statement" then
            calls.statement_start = calls.statement_start + 1
          end
          return definition.row, 0
        end
        return current
      end

      local tree_root = node("root")
      local nodes = { ["2:1"] = "first", ["3:2"] = "second", ["5:0"] = "missing" }
      tree_root.named_descendant_for_range = function(_, row, col)
        calls.descendant = calls.descendant + 1
        return node(nodes[row .. ":" .. col])
      end

      local path = selected_ranges and { [3] = true, [4] = true } or { [3] = true, [4] = true, [6] = true }
      local ranges = selected_ranges
        or {
          { line = 3, start_col = 1 },
          { line = 3, start_col = 1 },
          { line = 4, start_col = 2 },
          { line = 6, start_col = 0 },
        }
      local statements, scope_heads, fallback = context.evaluate(
        { highlights = highlights },
        path,
        ranges,
        buf,
        { start_line = 2, end_line = 6 },
        {
          get_treesitter = function()
            return { root = tree_root }
          end,
        }
      )
      return statements, scope_heads, fallback, path, ranges, calls
    end

    local statements, scope_heads, fallback, path, ranges, calls = evaluate({ statement = {}, scope_head = {} })
    assert_true(vim.deep_equal(statements, { [3] = true, [4] = true, [6] = true }), "cached statement set")
    assert_true(vim.deep_equal(scope_heads, { [2] = true }), "cached and clipped scope-head set")
    assert_true(fallback.statement and not fallback.scope_head, "cached structural fallback")
    assert_true(vim.deep_equal(path, { [3] = true, [4] = true, [6] = true }), "context should not alter navigation")
    assert_true(#ranges == 4, "context should not alter navigation ranges")
    assert_true(calls.descendant == 3, "duplicate positions should share one descendant lookup")
    assert_true(
      calls.statement_range <= 1 and calls.statement_start <= 1,
      "shared statement geometry should not be repeated"
    )
    local parse_calls = 0
    statements, scope_heads, fallback = context.evaluate(
      { highlights = {} },
      { [1] = true },
      {},
      buf,
      { start_line = 1, end_line = 6 },
      {
        get_treesitter = function()
          parse_calls = parse_calls + 1
        end,
      }
    )
    assert_true(parse_calls == 0, "disabled structural contexts should do no parse work")
    assert_true(next(statements) == nil and next(scope_heads) == nil, "disabled structural contexts should stay empty")
    assert_true(not fallback.statement and not fallback.scope_head, "disabled structural fallback metadata")
  end

  -- Missing structural parsers fall back safely and obey warning policy.
  do
    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end

    local structural_fallback_buf = new_buffer({ "alpha = 1", "print(alpha)" }, "plaintext")
    local function warning_count(policy, notify)
      messages = {}
      tunnelvision.setup({
        notify = notify,
        source = "word",
        scope = "buffer",
        fallback_warn = policy,
        highlights = { statement = true, scope_head = true },
      })
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      tunnelvision.on()
      local bs = core.get_buf_state(structural_fallback_buf)
      assert_true(vim.deep_equal(bs.statement_set, bs.path_set), "missing parser should preserve matched geometry")
      assert_true(next(bs.scope_head_set) == nil, "missing parser should skip scope heads")
      core.activate(structural_fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 1 } })
      vim.cmd("TunnelVision off")
      return #messages
    end
    for _, case in ipairs({
      { "once", true, 2 },
      { "always", true, 4 },
      { "never", true, 0 },
      { "always", false, 0 },
    }) do
      assert_true(warning_count(case[1], case[2]) == case[3], "structural fallback_warn " .. case[1])
    end

    vim.notify = orig_notify
  end

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
