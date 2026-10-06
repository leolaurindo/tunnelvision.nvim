-- Scope resolution and resolver caching coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local assert_equal = helpers.assert_equal
  local assert_sources = helpers.assert_sources
  local new_buffer = helpers.new_buffer
  local parser_or_skip = helpers.parser_or_skip
  local assert_default_visual_config = helpers.assert_default_visual_config

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")
  local config = require("tunnelvision.config")

  -- Function scope skips known call/header nodes and keeps broad grammar support.
  do
    local resolver = require("tunnelvision.resolver")
    local scope_buf = new_buffer({ "one", "two", "three", "four" }, "plaintext")
    local orig_get_parser = vim.treesitter.get_parser
    local leaf
    local function node(node_type, start_row, end_row, parent)
      return helpers.ts_node(node_type, { start_row, 0, end_row, 1 }, parent)
    end

    local parent = node("function_definition", 1, 2)
    local rejected = {
      "abstract_method_signature",
      "abstract_function_declarator",
      "explicit_function_specifier",
      "function_annotation",
      "function_call",
      "function_declarator",
      "function_modifier",
      "function_modifiers",
      "function_name",
      "function_parameters",
      "function_prototype",
      "function_signature",
      "function_signature_item",
      "function_specifier",
      "function_type",
      "function_type_parameters",
      "function_value_parameters",
      "default_method_clause",
      "delete_method_clause",
      "generic_function",
      "lambda_capture_initializer",
      "lambda_capture_specifier",
      "lambda_default_capture",
      "lambda_declarator",
      "lambda_parameters",
      "lambda_specifier",
      "method_call_expression",
      "method_elem",
      "method_index_expression",
      "method_invocation",
      "method_parameters",
      "method_reference",
      "method_signature",
      "preproc_function_def",
      "template_function",
      "template_method",
    }
    vim.treesitter.get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return {
                  named_descendant_for_range = function()
                    return leaf
                  end,
                }
              end,
            },
          }
        end,
      }
    end
    for _, node_type in ipairs(rejected) do
      leaf = node(node_type, 1, 1, parent)
      local scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, nil, "function")
      assert_true(scope.start_line == 2 and scope.end_line == 3, node_type .. " should defer to its function parent")
    end

    for _, node_type in ipairs({ "closure_expression", "custom_function_definition" }) do
      leaf = node(node_type, 1, 2)
      local scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, nil, "function")
      assert_true(scope.start_line == 2 and scope.end_line == 3, node_type .. " should remain a function scope")
    end

    leaf = node("function_definition", 1, 2)
    local function_scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, nil, "function")
    assert_true(function_scope.scope_mode == "function", "resolved scope should record its mode")
    assert_true(
      function_scope.changedtick == vim.api.nvim_buf_get_changedtick(scope_buf),
      "resolved scope should record its changed tick"
    )

    local buffer_scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, function_scope, "buffer")
    assert_true(
      buffer_scope.start_line == 1 and buffer_scope.end_line == 4,
      "scope mode changes should invalidate reuse"
    )
    assert_true(buffer_scope.scope_mode == "buffer", "changed scope mode should be recorded")

    vim.api.nvim_buf_set_lines(scope_buf, 0, 0, false, { "zero" })
    leaf = node("function_definition", 0, 3)
    local edited_scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, function_scope, "function")
    assert_true(edited_scope.start_line == 1 and edited_scope.end_line == 4, "edits should invalidate scope geometry")
    assert_true(edited_scope.changedtick ~= function_scope.changedtick, "edits should invalidate the scope tick")

    local outer = node("function_definition", 0, 4)
    local inner = node("function_definition", 1, 3, outer)
    leaf = node("identifier", 2, 2, inner)
    local outer_scope = {
      start_line = 1,
      end_line = 5,
      scope_mode = "function",
      changedtick = vim.api.nvim_buf_get_changedtick(scope_buf),
    }
    local nested_scope = resolver.resolve_scope(scope_buf, { row = 2, col = 0 }, outer_scope, "function")
    assert_true(
      nested_scope.start_line == 2 and nested_scope.end_line == 4,
      "nested functions should narrow reused scope"
    )

    core.configure({ notify = false, source = "word", mode = "dynamic", scope = "function" })
    core.activate(scope_buf, { silent = true, symbol = "value", cursor = { 3, 0 } })
    local nested_state = core.get_buf_state(scope_buf)
    assert_true(
      nested_state.scope.start_line == 2 and nested_state.scope.end_line == 4,
      "activation should use the nearest function scope"
    )
    core.set_scope("buffer")
    assert_true(nested_state.scope.start_line == 2, "default changes should not alter existing tracks")
    core.set_scope("function")

    nested_state.tracks[1].scope = outer_scope
    assert_true(
      core.should_dynamic_retarget(scope_buf, "value", { 3, 0 }),
      "dynamic movement should retarget into nested functions"
    )
    core.clear_buf_state(scope_buf)

    vim.treesitter.get_parser = function()
      error("parser unavailable")
    end
    local fallback_scope = resolver.resolve_scope(scope_buf, { row = 1, col = 0 }, nil, "function")
    assert_true(
      fallback_scope.start_line == 1 and fallback_scope.end_line == 5,
      "missing parsers should use buffer scope"
    )
    vim.treesitter.get_parser = orig_get_parser

    local lua_buf = new_buffer({
      "local outside = 1",
      "local function run(config)",
      "  print(config.host)",
      "end",
      "print(outside)",
    }, "lua")
    if parser_or_skip(lua_buf, "lua", "real Lua function scope") then
      local scope = resolver.resolve_scope(lua_buf, { row = 2, col = 9 }, nil, "function")
      assert_true(scope.start_line == 2 and scope.end_line == 4, "Lua calls should defer to the enclosing function")
    end

    local cpp_buf =
      new_buffer({ "int outside;", "void foo(int config) {", "  print(config);", "}", "int after;" }, "cpp")
    if parser_or_skip(cpp_buf, "cpp", "real C++ function scope") then
      local scope = resolver.resolve_scope(cpp_buf, { row = 1, col = 13 }, nil, "function")
      assert_true(scope.start_line == 2 and scope.end_line == 4, "C++ declarators should defer to function definitions")
    end
  end

  tunnelvision.setup()
  assert_default_visual_config("bare setup")

  tunnelvision.setup({ notify = false })
  assert_sources({ "lsp", "treesitter", "word" }, "default sources")
  assert_true(config.format_sources(core.state.config.sources) == "lsp,treesitter,word", "format_sources default")

  -- Resolver stages share scoped and touched lines within one activation.
  do
    local resolver = require("tunnelvision.resolver")
    local cache_buf = new_buffer({
      "outside before",
      "local alpha = 1",
      "",
      "local beta = alpha",
      "print(beta)",
      "outside after",
    })
    local anchor = { row = 1, col = 6 }
    local scope = { start_line = 2, end_line = 5 }
    local original_get_lines = vim.api.nvim_buf_get_lines
    local reads = 0
    vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
      if bufnr == cache_buf then
        reads = reads + 1
        assert_true(
          first >= scope.start_line - 1 and last ~= -1 and last <= scope.end_line,
          "line-cache reads must remain inside the active scope"
        )
      end
      return original_get_lines(bufnr, first, last, strict)
    end

    local path = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
      analyzers = { "text" },
      direction = "forward",
      keywords = resolver.build_keywords({}),
      mode = "flow",
      sources = { { kind = "single", name = "word" } },
    })
    assert_true(reads == 1 and path[5], "word and text flow should share one scoped line read")

    local custom_source = function()
      return { [2] = true, [3] = true, [5] = true }
    end
    local _, _, _, _, pending = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
      custom_sources = { custom_cache = custom_source },
      direction = "forward",
      keywords = {},
      mode = "static",
      pause_for_lsp = true,
      sources = { { kind = "combine", names = { "custom_cache", "lsp" } } },
    })
    assert_true(pending ~= nil, "cache invalidation test should suspend for LSP")
    local cached_reads = reads
    assert_equal(pending.get_lines(2, 3), { "local alpha = 1", "" }, "cache should retain empty lines")
    assert_true(reads == cached_reads, "cached suspended lines should not be fetched again")
    vim.api.nvim_buf_set_lines(cache_buf, 2, 3, false, { "alpha" })
    assert_equal(
      pending.get_lines(2, 3),
      { "local alpha = 1", "alpha" },
      "changedtick should invalidate cached contents"
    )
    assert_true(reads > cached_reads, "changedtick invalidation should refetch contents")
    local resumed_path, _, _, resumed_ranges = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
      lsp_result = resolver.make_lsp_result("ok", { [3] = true }, true, {
        { line = 3, start_col = 0, end_col = 99 },
      }),
      resolution_context = pending,
    })
    assert_true(resumed_path[3] and reads <= cached_reads + 2, "resume should reuse cached scoped reads")
    assert_equal(resumed_ranges, {
      { line = 2, start_col = 6, end_col = 11 },
      { line = 3, start_col = 0, end_col = 5 },
    }, "resume should use edited text and clamp to its current line")
    vim.api.nvim_buf_get_lines = original_get_lines
  end

  -- Tree-sitter consumers share one lazy changedtick snapshot per activation.
  do
    local resolver = require("tunnelvision.resolver")
    local orig_get_parser = vim.treesitter.get_parser
    local parse_count = 0
    local function counted_parser(bufnr)
      local parser = orig_get_parser(bufnr)
      return {
        parse = function()
          parse_count = parse_count + 1
          return parser:parse()
        end,
      }
    end
    vim.treesitter.get_parser = counted_parser

    local shared_buf = new_buffer({ "local function run(alpha)", "  local value = alpha", "  return alpha", "end" })
    tunnelvision.setup({
      notify = false,
      sources = { "treesitter" },
      scope = "function",
      mode = "static",
      highlights = { statement = true },
    })
    core.activate(shared_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 0 } })
    local shared_state = core.get_buf_state(shared_buf)
    assert_true(parse_count == 1, "scope, source, and structural context should share one parse")
    assert_true(shared_state.path_set[1] and shared_state.path_set[3], "shared snapshot should feed the source")
    assert_true(shared_state.statement_set[1] and shared_state.statement_set[3], "shared snapshot should feed context")
    vim.cmd("TunnelVision off")

    parse_count = 0
    tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { line = true } })
    core.activate(shared_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 0 } })
    assert_true(parse_count == 0, "activations without Tree-sitter consumers should not request a parser")
    vim.cmd("TunnelVision off")

    local parser_requests = 0
    vim.treesitter.get_parser = function()
      parser_requests = parser_requests + 1
      error("parser unavailable")
    end
    tunnelvision.setup({
      notify = false,
      sources = { "treesitter", "word" },
      scope = "function",
      mode = "static",
      highlights = { statement = true },
    })
    core.activate(shared_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 0 } })
    local fallback_state = core.get_buf_state(shared_buf)
    assert_true(parser_requests == 1, "an unavailable parser should be cached for all activation consumers")
    assert_true(
      fallback_state.last_compute_meta.used_source == "word"
        and fallback_state.last_compute_meta.fallback_reason == "unavailable",
      "a cached Tree-sitter failure should preserve source fallback"
    )
    assert_equal(
      fallback_state.statement_set,
      fallback_state.path_set,
      "a cached Tree-sitter failure should preserve structural fallback"
    )
    vim.cmd("TunnelVision off")

    parse_count = 0
    vim.treesitter.get_parser = counted_parser
    vim.api.nvim_buf_set_lines(shared_buf, 0, -1, false, { "local function run(alpha) end" })
    local activation_context = {}
    local old_scope = resolver.resolve_scope(shared_buf, { row = 0, col = 0 }, nil, "function", activation_context)
    vim.api.nvim_buf_set_lines(
      shared_buf,
      0,
      -1,
      false,
      { "-- before", "local function run(alpha)", "  return alpha", "end" }
    )
    local new_scope = resolver.resolve_scope(shared_buf, { row = 1, col = 0 }, nil, "function", activation_context)
    assert_true(parse_count == 2, "changedtick changes should replace the cached snapshot")
    assert_true(old_scope.start_line == 1 and old_scope.end_line == 1, "initial snapshot geometry")
    assert_true(new_scope.start_line == 2 and new_scope.end_line == 4, "edited buffers should not expose stale nodes")

    vim.treesitter.get_parser = orig_get_parser
  end

  local dynamic_buf = new_buffer({
    "local alpha = 1",
    "local beta = alpha + 1",
    "local gamma = beta + 1",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- alpha

  vim.cmd("TunnelVision mode dynamic")

  vim.api.nvim_win_set_cursor(0, { 2, 8 }) -- beta
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
  vim.api.nvim_win_set_cursor(0, { 3, 8 }) -- gamma
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })

  local waited = vim.wait(200, function()
    return core.get_buf_state(dynamic_buf).symbol == "gamma"
  end, 10)
  assert_true(waited, "dynamic debounce did not retarget to latest symbol")
  assert_true(core.get_buf_state(dynamic_buf).path_set[3], "dynamic retarget should recompute path for latest symbol")

  local no_op = core.activate(dynamic_buf, {
    config = core.get_buf_state(dynamic_buf).config,
    silent = true,
    symbol = "gamma",
    cursor = { 3, 8 },
    reuse_scope = true,
  })
  assert_true(no_op == false, "identical activate should no-op")

  vim.cmd("TunnelVision off")

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
