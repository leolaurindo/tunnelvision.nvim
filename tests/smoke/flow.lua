-- Flow analysis and analyzer coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local assert_ranges = helpers.assert_ranges
  local new_buffer = helpers.new_buffer
  local parser_or_skip = helpers.parser_or_skip

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")

  tunnelvision.setup({ notify = false, source = "word", mode = "flow", scope = "buffer" })
  local flow_keywords_buf = new_buffer({
    "local alpha = 1",
    "local sentinel = alpha + 1",
    "local result = sentinel + 1",
  })

  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  vim.cmd("TunnelVision on")
  assert_true(core.get_buf_state(flow_keywords_buf).path_set[3], "flow baseline should propagate through sentinel")

  vim.cmd("TunnelVision off")
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  tunnelvision.on({ direction = "both", extra_keywords = { "sentinel" } })
  local deprecated_flow = core.get_buf_state(flow_keywords_buf)
  assert_true(
    deprecated_flow.config.flow_settings.direction == "both"
      and deprecated_flow.config.flow_settings.extra_keywords[1] == "sentinel"
      and not deprecated_flow.path_set[3],
    "deprecated one-shot flow fields should remain effective"
  )
  vim.cmd("TunnelVision off")
  tunnelvision.on({
    direction = "forward",
    extra_keywords = { "deprecated" },
    flow_settings = { direction = "both", extra_keywords = { "sentinel" } },
  })
  local nested_flow = core.get_buf_state(flow_keywords_buf).config.flow_settings
  assert_true(
    nested_flow.direction == "both" and nested_flow.extra_keywords[1] == "sentinel",
    "nested one-shot flow_settings should win over deprecated fields"
  )
  vim.cmd("TunnelVision off")
  tunnelvision.setup({ notify = false, source = "word", mode = "flow", scope = "buffer" })
  assert_true(tunnelvision.add_keywords({ "sentinel" }), "add_keywords should append new identifiers")
  assert_true(not tunnelvision.add_keywords({ "sentinel" }), "add_keywords should ignore duplicates")
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  vim.cmd("TunnelVision on")
  assert_true(
    not core.get_buf_state(flow_keywords_buf).path_set[3],
    "add_keywords should stop propagation through ignored identifiers"
  )

  vim.cmd("TunnelVision off")
  tunnelvision.setup({ notify = false, source = "word" })

  -- Flow adds propagated identifiers while static mode retains only source ranges.
  do
    tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
    local flow_range_buf = new_buffer({
      "local alpha = 1",
      "local beta = alpha",
      "local gamma = beta",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on({ mode = "static" })
    assert_ranges(core.get_buf_state(flow_range_buf).symbol_ranges, {
      { line = 1, start_col = 6, end_col = 11 },
      { line = 2, start_col = 13, end_col = 18 },
    }, "static ranges should exclude unrelated identifiers on selected lines")
    tunnelvision.on({ mode = "flow" })
    assert_ranges(core.get_buf_state(flow_range_buf).symbol_ranges, {
      { line = 1, start_col = 6, end_col = 11 },
      { line = 2, start_col = 6, end_col = 10 },
      { line = 2, start_col = 13, end_col = 18 },
      { line = 3, start_col = 6, end_col = 11 },
      { line = 3, start_col = 14, end_col = 18 },
    }, "flow ranges should include propagated tracked identifiers")
    vim.cmd("TunnelVision off")

    local resolver = require("tunnelvision.resolver")
    local flow = require("tunnelvision.flow")
    local analysis = flow.analyze_text({
      anchor = { row = 0, col = 6 },
      bufnr = flow_range_buf,
      keywords = resolver.build_keywords({}),
      scope = { start_line = 1, end_line = 3 },
      symbol = "alpha",
    })
    assert_ranges(analysis.assignments[2].lhs, {
      { name = "beta", line = 2, start_col = 6, end_col = 10 },
    }, "text analyzer should retain exact LHS token ranges")

    local declarations_buf = new_buffer({
      "local typed: number = source",
      "local left, right = typed, source",
      "left += right",
      "obj.field = source",
      "items[index] = source",
    })
    local declarations = flow.analyze_text({
      anchor = { row = 0, col = 6 },
      bufnr = declarations_buf,
      keywords = resolver.build_keywords({}),
      scope = { start_line = 1, end_line = 5 },
      symbol = "typed",
    })
    local expected_lhs = { { "typed" }, { "left", "right" }, { "left" } }
    assert_true(#declarations.assignments == #expected_lhs, "text flow should reject complex assignment targets")
    for i, names in ipairs(expected_lhs) do
      for j, name in ipairs(names) do
        assert_true(declarations.assignments[i].lhs[j].name == name, "text declaration should retain " .. name)
      end
    end
    assert_true(declarations.assignments[3].rhs[2].name == "left", "compound assignment should depend on its LHS")

    local function token(name)
      return { name = name, line = 1, start_col = 0, end_col = #name }
    end
    local alpha, beta, gamma = token("alpha"), token("beta"), token("gamma")
    local same_line = {
      assignments = {
        { line = 1, lhs = { beta }, rhs = { alpha } },
        { line = 1, lhs = { gamma }, rhs = { beta } },
      },
      occurrences = { alpha = { alpha }, beta = { beta }, gamma = { gamma } },
    }
    assert_true(flow.expand({}, {}, "alpha", same_line, "forward").gamma, "same-line assignments should chain")
    local analyzer_buf = new_buffer({ "local alpha = 1", "local beta = alpha", "print(beta)" }, "plaintext")
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.setup({ notify = false, mode = "flow", source = "word", scope = "buffer" })
    tunnelvision.on({ flow_settings = { analyzers = { "treesitter" } } })
    assert_true(not core.get_buf_state(analyzer_buf).path_set[3], "strict treesitter analyzer should not use text")
    tunnelvision.on({ flow_settings = { analyzers = { "treesitter", "text" } } })
    local analyzer_state = core.get_buf_state(analyzer_buf)
    assert_true(analyzer_state.path_set[3], "analyzer chain should fall back to text")
    assert_true(
      analyzer_state.last_compute_meta.flow_analyzer == "text" and analyzer_state.last_compute_meta.flow_fallback,
      "analyzer fallback metadata"
    )
    local flow_status = tunnelvision.status()
    assert_true(
      flow_status.flow_analyzer == "text"
        and flow_status.flow_fallback
        and flow_status.flow_tracked_count == 2
        and flow_status.flow_added_lines == 1,
      "status should expose successful fallback flow counts"
    )
    vim.cmd("TunnelVision off")

    local backward = flow.expand({}, {}, "gamma", analysis, "backward")
    assert_true(backward.alpha and backward.beta, "backward flow should follow inputs")
    local forward = flow.expand({}, {}, "gamma", analysis, "forward")
    assert_true(not forward.alpha and not forward.beta, "forward flow should not follow inputs")
    local both = flow.expand({}, {}, "beta", analysis, "both")
    assert_true(both.alpha and both.gamma, "both flow should follow both directions")
    local shallow = flow.expand({}, {}, "alpha", analysis, "forward", 1)
    assert_true(shallow.beta and not shallow.gamma, "max_depth should limit flow hops")

    local guarded_lines = { "print(v33)" }
    for i = 33, 1, -1 do
      guarded_lines[#guarded_lines + 1] = ("v%d = v%d"):format(i, i - 1)
    end
    guarded_lines[#guarded_lines + 1] = "v0 = 1"
    local guarded_buf = new_buffer(guarded_lines)
    local guarded = flow.analyze_text({
      anchor = { row = #guarded_lines - 1, col = 0 },
      bufnr = guarded_buf,
      keywords = resolver.build_keywords({}),
      scope = { start_line = 1, end_line = #guarded_lines },
      symbol = "v0",
    })
    local guarded_path = { [#guarded_lines] = true }
    local guarded_symbols = flow.expand(guarded_path, {}, "v0", guarded, "forward")
    assert_true(guarded_symbols.v32 and not guarded_symbols.v33 and not guarded_path[1], "flow should stop at 32 hops")
  end

  -- Word scans stay lazy and cached while flow collects identifiers independently.
  do
    local resolver = require("tunnelvision.resolver")
    local flow_buf = new_buffer({
      "local alpha = 1",
      "local beta = alpha",
      "local gamma = beta",
    })
    local anchor = { row = 0, col = 6 }
    local scope = { start_line = 1, end_line = 3 }
    local scans = 0
    local collect_word_matches = resolver.collect_word_matches
    resolver.collect_word_matches = function(...)
      scans = scans + 1
      return collect_word_matches(...)
    end

    local function compute(sources)
      return resolver.compute_path(
        flow_buf,
        "alpha",
        anchor,
        scope,
        vim.tbl_extend("force", {
          analyzers = { "text" },
          direction = "forward",
          keywords = resolver.build_keywords({}),
          lsp_result = resolver.make_lsp_result("ok", { [1] = true }, true, {
            { line = 1, start_col = 6, end_col = 11 },
          }),
          mode = "flow",
          sources = sources,
        }, {})
      )
    end

    scans = 0
    local path = compute({
      { kind = "single", name = "lsp" },
      { kind = "single", name = "word" },
    })
    assert_true(scans == 0 and path[3], "successful LSP flow should not eagerly scan word")

    resolver.collect_word_matches = collect_word_matches
  end

  do
    local go_buf = new_buffer({
      "alpha := 1",
      "beta := alpha",
      "callback := func() { nested := alpha }",
      "println(beta)",
    }, "go")
    if parser_or_skip(go_buf, "go", "real Go Tree-sitter flow") then
      local go_analysis = require("tunnelvision.flow").analyze_treesitter({
        anchor = { row = 0, col = 0 },
        bufnr = go_buf,
        keywords = require("tunnelvision.resolver").build_keywords({}),
        scope = { start_line = 1, end_line = 4 },
        symbol = "alpha",
      })
      assert_true(#go_analysis.assignments == 3, "treesitter analyzer should parse Go short declarations")
      local go_path = {}
      local go_tracked = require("tunnelvision.flow").expand(go_path, {}, "alpha", go_analysis, "forward")
      assert_true(go_path[4], "Go short declarations should propagate flow")
      assert_true(not go_tracked.callback, "Go function literals should not leak dependencies")
    end
  end

  do
    local rust_buf = new_buffer({ "let alpha = 1;", "let beta = alpha;", 'println!("{}", beta);' }, "rust")
    if parser_or_skip(rust_buf, "rust", "real Rust Tree-sitter flow") then
      local rust_analysis = require("tunnelvision.flow").analyze_treesitter({
        anchor = { row = 0, col = 4 },
        bufnr = rust_buf,
        keywords = require("tunnelvision.resolver").build_keywords({}),
        scope = { start_line = 1, end_line = 3 },
        symbol = "alpha",
      })
      local rust_path = {}
      require("tunnelvision.flow").expand(rust_path, {}, "alpha", rust_analysis, "forward")
      assert_true(rust_path[3], "Rust let declarations should propagate flow")
    end
  end
  tunnelvision.setup({ notify = false, source = "lsp_else_word" })

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
