-- Structural context coverage.
return function(helpers)
  local assert_equal = helpers.assert_equal
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

      assert_equal(
        bs.statement_set,
        { [2] = true, [3] = true, [4] = true, [6] = true, [8] = true, [10] = true, [12] = true },
        "statement context should include complete conservative statements from exact columns"
      )
      assert_equal(
        bs.scope_head_set,
        { [1] = true, [5] = true, [7] = true, [9] = true },
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
    local seen_col
    local function node(node_type, parent, range)
      return helpers.ts_node(node_type, range or { 0, 0, 0, 8 }, parent)
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
      assert_equal(statements, case[3], case[1] .. " structural boundary")
      assert_true(fallback.statement == case[4], case[1] .. " fallback")
    end
  end

  -- Structural evaluation reuses duplicate and shared ancestor work within one call.
  do
    local context = require("tunnelvision.context")
    local buf = new_buffer({ "function", "if", "alpha", "alpha", "other", "missing" })

    local root = helpers.ts_node("chunk", { 0, 0, 6, 0 })
    local head = helpers.ts_node("function_definition", { 0, 0, 6, 0 }, root)
    local conditional = helpers.ts_node("if_statement", { 1, 0, 6, 0 }, head)
    local statement = helpers.ts_node("assignment_statement", { 2, 0, 4, 0 }, conditional)
    local nodes = {
      ["2:1"] = helpers.ts_node("identifier", { 2, 1, 2, 6 }, statement),
      ["3:2"] = helpers.ts_node("identifier", { 3, 2, 3, 7 }, statement),
      ["5:0"] = helpers.ts_node("identifier", { 5, 0, 5, 7 }, conditional),
    }
    local parent_seen, descendants, geometry = {}, 0, 0
    for _, current in ipairs({ root, head, conditional, statement, nodes["2:1"], nodes["3:2"], nodes["5:0"] }) do
      local parent = current.parent
      current.parent = function(self)
        assert_true(not parent_seen[self], "shared ancestor should not be entered twice")
        parent_seen[self] = true
        return parent(self)
      end
    end
    local range = statement.range
    statement.range = function(self)
      geometry = geometry + 1
      return range(self)
    end
    root.named_descendant_for_range = function(_, row, col)
      descendants = descendants + 1
      return nodes[row .. ":" .. col]
    end
    local path = { [3] = true, [4] = true, [6] = true }
    local ranges = {
      { line = 3, start_col = 1 },
      { line = 3, start_col = 1 },
      { line = 4, start_col = 2 },
      { line = 6, start_col = 0 },
    }
    local statements, scope_heads, fallback = context.evaluate(
      { highlights = { statement = {}, scope_head = {} } },
      path,
      ranges,
      buf,
      { start_line = 2, end_line = 6 },
      {
        get_treesitter = function()
          return { root = root }
        end,
      }
    )
    assert_equal(statements, { [3] = true, [4] = true, [6] = true }, "cached statement set")
    assert_equal(scope_heads, { [2] = true }, "cached and clipped scope-head set")
    assert_true(fallback.statement and not fallback.scope_head, "cached structural fallback")
    assert_equal(path, { [3] = true, [4] = true, [6] = true }, "context should not alter navigation")
    assert_true(#ranges == 4, "context should not alter navigation ranges")
    assert_true(descendants == 3 and geometry == 1, "duplicate positions and shared statements should reuse work")
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
    tunnelvision.setup({
      notify = true,
      sources = { "word" },
      scope = "buffer",
      highlights = { statement = true, scope_head = true },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    tunnelvision.on()
    local bs = core.get_buf_state(structural_fallback_buf)
    assert_equal(bs.statement_set, bs.path_set, "missing parser should preserve matched geometry")
    assert_true(next(bs.scope_head_set) == nil, "missing parser should skip scope heads")
    core.activate(structural_fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 1 } })
    assert_true(#messages == 0, "expected structural fallback should not warn")
    vim.cmd("TunnelVision off")
    vim.notify = orig_notify
  end

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
