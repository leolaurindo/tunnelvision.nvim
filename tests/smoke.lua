local function fail(msg)
  error("[tunnelvision smoke] " .. msg)
end

local function assert_true(cond, msg)
  if not cond then
    fail(msg)
  end
end

local function parser_or_skip(bufnr, language, coverage)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language)
  if ok and parser then
    return parser
  end
  if ({ cpp = true, go = true, rust = true })[language] then
    print(("tunnelvision smoke: SKIP %s: optional %s parser unavailable (%s)"):format(coverage, language, parser))
    return
  end
  fail(("required %s parser unavailable for %s: %s"):format(language, coverage, parser))
end

local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local tunnelvision = require("tunnelvision")
local core = require("tunnelvision.core")
local config = require("tunnelvision.config")

local function assert_ranges(actual, expected, msg)
  assert_true(vim.deep_equal(actual, expected), msg .. ": " .. vim.inspect(actual))
end

local function assert_sources(expected, msg)
  local got = tunnelvision.get_sources()
  assert_true(vim.deep_equal(got, expected), msg .. ": " .. vim.inspect(got))
end

local function assert_combine(step, expected, msg)
  assert_true(vim.deep_equal(step, { kind = "combine", names = expected }), msg .. ": " .. vim.inspect(step))
end

local function new_buffer(lines, filetype)
  vim.cmd("enew")
  vim.bo.filetype = filetype or "lua"
  if lines then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end
  return vim.api.nvim_get_current_buf()
end

local function assert_default_visual_config(msg)
  assert_true(config.format_sources(core.state.config.sources) == "lsp,treesitter,word", msg .. " sources")
  assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), msg .. " highlights")
  assert_true(core.state.config.dim == nil, msg .. " dim")
end

-- Function scope skips known call/header nodes and keeps broad grammar support.
do
  local resolver = require("tunnelvision.resolver")
  local scope_buf = new_buffer({ "one", "two", "three", "four" }, "plaintext")
  local orig_get_parser = vim.treesitter.get_parser
  local leaf
  local function node(node_type, start_row, end_row, parent)
    return {
      type = function()
        return node_type
      end,
      range = function()
        return start_row, 0, end_row, 1
      end,
      parent = function()
        return parent
      end,
    }
  end

  local parent = node("function_definition", 0, 3)
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
    assert_true(scope.start_line == 1 and scope.end_line == 4, node_type .. " should defer to its function parent")
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
  assert_true(buffer_scope.start_line == 1 and buffer_scope.end_line == 4, "scope mode changes should invalidate reuse")
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
  assert_true(
    nested_state.scope.start_line == 1 and nested_state.scope.end_line == 5,
    "buffer scope setter should refresh active geometry"
  )
  core.set_scope("function")
  assert_true(
    nested_state.scope.start_line == 2 and nested_state.scope.end_line == 4,
    "function scope setter should refresh active geometry"
  )

  nested_state.scope = outer_scope
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

  local cpp_buf = new_buffer({ "int outside;", "void foo(int config) {", "  print(config);", "}", "int after;" }, "cpp")
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

local forced_scope_buf = new_buffer({ "one", "two", "three" }, "plaintext")
tunnelvision.on({ source = "word", scope = "buffer", symbol = "two", cursor = { 2, 0 } })
local forced_state = core.get_buf_state(forced_scope_buf)
forced_state.scope = {
  start_line = 2,
  end_line = 2,
  scope_mode = "buffer",
  changedtick = vim.api.nvim_buf_get_changedtick(forced_scope_buf),
}
core.activate(forced_scope_buf, {
  config = forced_state.config,
  cursor = { 2, 0 },
  force = true,
  reuse_scope = true,
  silent = true,
  symbol = "two",
})
assert_true(
  forced_state.scope.start_line == 1 and forced_state.scope.end_line == 3,
  "force should recompute scope geometry"
)
tunnelvision.off()

-- Highlight rules normalize without deep-merging the default line context.
tunnelvision.setup({ notify = false, highlights = {} })
assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), "empty highlights should use line default")

tunnelvision.setup({ notify = false, highlights = { symbol = true } })
assert_true(vim.deep_equal(core.state.config.highlights, { symbol = {} }), "symbol rule should replace line default")

tunnelvision.setup({ notify = false, highlights = { line = false } })
assert_true(vim.deep_equal(core.state.config.highlights, {}), "false context should remain disabled")

tunnelvision.setup({
  notify = false,
  highlights = { statement = {}, line = { bold = true } },
})
assert_true(
  vim.deep_equal(core.state.config.highlights, { statement = {}, line = { bold = true } }),
  "enabled highlight rules should preserve empty and styled contexts"
)

tunnelvision.setup({
  notify = false,
  highlights = {
    scope_head = {
      fg = "#112233",
      bg = 0x445566,
      bg_opacity = 2,
      bold = true,
      italic = false,
      underline = true,
      undercurl = false,
      strikethrough = true,
    },
  },
})
assert_true(
  vim.deep_equal(core.state.config.highlights, {
    scope_head = {
      fg = "#112233",
      bg = 0x445566,
      bg_opacity = 1,
      bold = true,
      italic = false,
      underline = true,
      undercurl = false,
      strikethrough = true,
    },
  }),
  "all supported highlight style fields should normalize"
)

tunnelvision.setup({
  notify = false,
  highlights = {
    unknown = true,
    line = false,
    symbol = "bold",
    statement = { fg = false, bold = "yes", bg_opacity = "0.5", unknown = true },
  },
})
assert_true(
  vim.deep_equal(core.state.config.highlights, { statement = {} }),
  "invalid highlight rules should be ignored"
)

tunnelvision.setup({ notify = false, highlights = 42 })
assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), "invalid highlights should use line default")
tunnelvision.setup({ notify = false }) -- restore

tunnelvision.setup({
  notify = false,
  flow_settings = {
    direction = "backward",
    analyzers = { "text" },
    extra_keywords = { "keep" },
    max_depth = 3,
  },
})
local merged_flow = config.normalize_activation(core.state.config, { flow_settings = { max_depth = 1 } }, 0, {})
assert_true(merged_flow.flow_settings.direction == "backward", "one-shot flow settings preserve direction")
assert_true(
  vim.deep_equal(merged_flow.flow_settings.analyzers, { "text" }),
  "one-shot flow settings preserve analyzers"
)
assert_true(merged_flow.flow_settings.extra_keywords[1] == "keep", "one-shot flow settings preserve keywords")
assert_true(merged_flow.flow_settings.max_depth == 1, "one-shot flow settings override selected fields")
tunnelvision.setup({ notify = false })

-- Deprecated top-level flow fields fill only missing flow_settings fields
tunnelvision.setup({
  notify = false,
  direction = "both",
  extra_keywords = { "deprecated" },
  flow_settings = { extra_keywords = { "nested" } },
})
assert_true(
  core.state.config.flow_settings.direction == "both",
  "deprecated direction fills missing flow_settings.direction"
)
assert_true(
  core.state.config.flow_settings.extra_keywords[1] == "nested",
  "flow_settings.extra_keywords wins over deprecated extra_keywords"
)
tunnelvision.setup({ notify = false })

tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "combine sources")

tunnelvision.setup({ notify = false, source = "word" })
assert_sources({ "word" }, "legacy source should normalize to sources")

assert_true(vim.fn.exists(":TunnelVision") == 2, "missing command: TunnelVision")
assert_true(vim.fn.exists(":Tunnelvision") == 2, "missing command alias: Tunnelvision")

local first_buf = new_buffer({
  "local value = 1",
  "local copy = value",
  "value = copy + value",
  "print(value)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- value

vim.cmd("Tunnelvision on")
assert_true(tunnelvision.is_active(0), "activation failed")

vim.api.nvim_win_set_cursor(0, { 2, 7 }) -- copy
vim.cmd("TunnelVision retarget")
assert_true(core.get_buf_state(first_buf).symbol == "copy", "retarget alias should re-run on current symbol")

local before = vim.api.nvim_win_get_cursor(0)[1]
vim.cmd("TunnelVision next")
local after_next = vim.api.nvim_win_get_cursor(0)[1]
assert_true(after_next ~= before, "next path jump did not move cursor")

vim.cmd("TunnelVision prev")
local after_prev = vim.api.nvim_win_get_cursor(0)[1]
assert_true(after_prev == before, "prev path jump did not return cursor")

assert_true(core.get_scope() == "function", "default scope should be function")
for _, case in ipairs({
  { "mode", "static", core.get_mode },
  { "mode", "flow", core.get_mode },
  { "mode", "dynamic", core.get_mode },
  { "mode", "static", core.get_mode },
  { "direction", "backward", core.get_direction },
  { "direction", "both", core.get_direction },
  { "direction", "forward", core.get_direction },
  { "scope", "buffer", core.get_scope },
  { "scope", "function", core.get_scope },
  { "source", "lsp_else_word", core.get_source },
  { "source", "lsp", core.get_source },
  { "source", "lsp_and_word", core.get_source },
  { "source", "word", core.get_source },
}) do
  vim.cmd(("TunnelVision %s %s"):format(case[1], case[2]))
  assert_true(case[3]() == case[2], ("%s %s not applied"):format(case[1], case[2]))
end
assert_true(
  vim.tbl_contains(vim.fn.getcompletion("TunnelVision direction b", "cmdline"), "backward"),
  "direction completion should include backward"
)

-- Fallback-chain command syntax
vim.cmd("TunnelVision source lsp,word")
assert_sources({ "lsp", "word" }, "comma-separated fallback chain lsp,word")

tunnelvision.setup({ notify = false })
local sources_copy = tunnelvision.get_sources()
sources_copy[1] = "word"
assert_sources({ "lsp", "treesitter", "word" }, "get_sources should return an isolated copy")
for _, value in ipairs({ "treesitter", "lsp,treesitter,word" }) do
  vim.cmd("TunnelVision source " .. value)
  assert_sources(vim.split(value, ",", { plain = true }), "Tree-sitter command source " .. value)
end
vim.cmd("TunnelVision source lsp,word")
assert_sources({ "lsp", "word" }, "restored to lsp,word")

-- Status display uses source= label
do
  local notify_msg
  local orig_notify = core.notify
  core.notify = function(msg)
    notify_msg = msg
  end
  vim.cmd("TunnelVision status")
  assert_true(notify_msg and notify_msg:find("source="), "status should use source= label")
  assert_true(notify_msg and notify_msg:find("source=lsp,word"), "status should show formatted source label")
  core.notify = orig_notify
end

-- Invalid comma values fail without corrupting config
do
  local notify_msg
  local orig_notify = core.notify
  core.notify = function(msg)
    notify_msg = msg
  end
  vim.cmd("TunnelVision source lsp,foo")
  assert_true(notify_msg and notify_msg:find("invalid source"), "invalid chain source should error")
  assert_sources({ "lsp", "word" }, "sources unchanged after invalid chain")
  core.notify = orig_notify
end

tunnelvision.set_sources({ "lsp", "word" })
assert_sources({ "lsp", "word" }, "set_sources should update sources")
assert_true(core.get_source() == "lsp_else_word", "set_sources should update legacy source view")
tunnelvision.set_sources({ "word" })
assert_sources({ "word" }, "set_sources word")

-- sources wins over source when both are provided
tunnelvision.setup({ notify = false, source = "word", sources = { tunnelvision.combine("lsp", "word") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "sources wins over deprecated source")
assert_true(
  tunnelvision.get_source() == "lsp_and_word",
  "get_source returns legacy for representable chain after sources win"
)

tunnelvision.setup({ notify = false, source = "lsp_else_word" })

-- Custom synchronous sources participate in source chains
do
  for _, case in ipairs({
    { "", function() end },
    { "custom_invalid", false },
    { "lsp", function() end },
    { "lsp_else_word", function() end },
  }) do
    assert_true(not tunnelvision.register_source(case[1], case[2]), "reserved or invalid custom source " .. case[1])
  end

  local seen_context
  assert_true(
    tunnelvision.register_source("custom_hit", function(ctx)
      seen_context = ctx
      ctx.anchor.row, ctx.scope.start_line = 99, 99
      return { [0] = true, [1.5] = true, [2] = true, [999] = true }
    end),
    "custom source registers"
  )
  assert_true(
    tunnelvision.register_source("custom_empty", function()
      return {}
    end),
    "empty custom source registers"
  )
  assert_true(
    tunnelvision.register_source("custom_error", function()
      error("custom source failure")
    end),
    "failing custom source registers"
  )

  tunnelvision.setup({
    notify = false,
    sources = { "custom_hit" },
    scope = "buffer",
    mode = "static",
    flow_settings = { extra_keywords = { "sentinel" } },
  })
  local custom_buf = new_buffer({
    "local alpha = 1",
    "local beta = alpha",
    "print(beta)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  local custom_state = core.get_buf_state(custom_buf)
  assert_true(
    custom_state.path_set[1] and custom_state.path_set[2] and vim.tbl_count(custom_state.path_set) == 2,
    "custom sources should filter invalid and out-of-scope lines"
  )
  assert_true(
    custom_state.anchor.row == 0
      and custom_state.scope.start_line == 1
      and seen_context.bufnr == custom_buf
      and seen_context.symbol == "alpha"
      and seen_context.mode == "static"
      and seen_context.direction == "forward"
      and seen_context.keywords.sentinel
      and seen_context.get_treesitter == nil,
    "custom sources should receive an isolated public context"
  )
  assert_true(
    #custom_state.symbol_ranges == 1 and custom_state.symbol_ranges[1].line == 2,
    "range-less custom results should synthesize ranges on returned lines"
  )
  vim.cmd("TunnelVision off")

  local function run_sources(sources)
    tunnelvision.on({ sources = sources, scope = "buffer", mode = "static" })
    local path = vim.deepcopy(core.get_buf_state(custom_buf).path_set)
    vim.cmd("TunnelVision off")
    return path
  end
  for _, name in ipairs({ "custom_empty", "custom_error" }) do
    assert_true(run_sources({ name, "word" })[2], name .. " should fall back to word matching")
  end
  assert_true(
    not run_sources({ tunnelvision.combine("custom_empty", "word") })[2],
    "failed strict combine should not leak member results"
  )

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  assert_true(
    tunnelvision.register_source("custom_late", function()
      return { [2] = true }
    end),
    "custom source should register after setup"
  )
  assert_true(run_sources({ "custom_late" })[2], "late custom source should work as a one-shot override")
  assert_sources({ "word" }, "late one-shot source should not mutate global sources")

  tunnelvision.setup({ notify = false, sources = { "custom_unavailable" } })
  assert_sources({ "lsp", "treesitter", "word" }, "unavailable custom source should normalize to the default fallback")
end

tunnelvision.setup({ notify = false, source = "lsp", scope = "buffer" })
local one_shot_buf = new_buffer({
  "local alpha = 1",
  "local beta = 2",
  "print(alpha)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 })

tunnelvision.on({ source = "word" })
assert_true(core.get_buf_state(one_shot_buf).path_set[3], "one-shot source should override activation source")
assert_true(core.get_source() == "lsp", "one-shot source should not mutate global source")
assert_sources({ "lsp" }, "one-shot source should not mutate global sources")
assert_true(core.get_buf_state(one_shot_buf).config.source == "word", "active buffer should keep one-shot source")
assert_true(
  core.get_buf_state(one_shot_buf).config.sources[1].name == "word",
  "active buffer should keep one-shot sources"
)
vim.cmd("TunnelVision off")

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

-- Source ranges use exact, sorted byte columns and preserve ignored-text offsets.
do
  tunnelvision.setup({ notify = false, source = "word", mode = "static", scope = "buffer" })
  local range_buf = new_buffer({
    "alpha + alpha_ + alpha -- alpha",
    '"alpha" .. alpha',
    "é alpha alpha",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tunnelvision.on()
  assert_ranges(core.get_buf_state(range_buf).symbol_ranges, {
    { line = 1, start_col = 0, end_col = 5 },
    { line = 1, start_col = 17, end_col = 22 },
    { line = 2, start_col = 11, end_col = 16 },
    { line = 3, start_col = 3, end_col = 8 },
    { line = 3, start_col = 9, end_col = 14 },
  }, "word ranges should retain exact byte positions and all valid occurrences")
  vim.cmd("TunnelVision off")
  assert_ranges(core.get_buf_state(range_buf).symbol_ranges, {}, "deactivation should clear symbol ranges")

  local resolver = require("tunnelvision.resolver")
  local _, _, _, normalized = resolver.compute_path(range_buf, "alpha", { row = 0, col = 0 }, {
    start_line = 1,
    end_line = 3,
  }, {
    direction = "forward",
    keywords = {},
    lsp_result = resolver.make_lsp_result("ok", { [1] = true }, true, {
      { line = 1, start_col = 17, end_col = 99 },
      { line = 1, start_col = 0, end_col = 5 },
      { line = 1, start_col = 0, end_col = 5 },
      { line = 1, start_col = 9, end_col = 9 },
    }),
    mode = "static",
    sources = { { kind = "single", name = "lsp" } },
  })
  assert_ranges(normalized, {
    { line = 1, start_col = 0, end_col = 5 },
    { line = 1, start_col = 17, end_col = 31 },
  }, "computed ranges should clamp, deduplicate, discard empties, and sort")

  local direct_path, direct_order, direct_meta, _, pending = resolver.compute_path(
    range_buf,
    "alpha",
    { row = 0, col = 0 },
    { start_line = 1, end_line = 3 },
    {
      direction = "forward",
      keywords = {},
      mode = "static",
      sources = { { kind = "single", name = "lsp" }, { kind = "single", name = "word" } },
    }
  )
  assert_true(pending == nil, "direct compute_path without LSP data should remain synchronous")
  assert_true(
    direct_path[1] and direct_path[2] and direct_path[3],
    "direct LSP fallback should include anchor and word matches"
  )
  assert_true(#direct_order == 3, "direct LSP fallback should return ordinary path order")
  assert_true(
    direct_meta.used_source == "word"
      and direct_meta.fallback_source == "lsp"
      and direct_meta.fallback_reason == "disabled",
    "direct LSP fallback should preserve disabled metadata"
  )
end

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
  assert_true(vim.deep_equal(pending.get_lines(2, 3), { "local alpha = 1", "" }), "cache should retain empty lines")
  assert_true(reads == cached_reads, "cached suspended lines should not be fetched again")
  vim.api.nvim_buf_set_lines(cache_buf, 2, 3, false, { "alpha" })
  assert_true(
    vim.deep_equal(pending.get_lines(2, 3), { "local alpha = 1", "alpha" }),
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
  assert_ranges(resumed_ranges, {
    { line = 2, start_col = 6, end_col = 11 },
    { line = 3, start_col = 0, end_col = 5 },
  }, "resume should use edited text and clamp to its current line")
  vim.api.nvim_buf_get_lines = original_get_lines
end

-- Tree-sitter consumers share one lazy changedtick snapshot per activation.
do
  local resolver = require("tunnelvision.resolver")
  local orig_get_parser = vim.treesitter.get_parser
  local orig_get_node_text = vim.treesitter.get_node_text
  local parse_count = 0
  local next_node_id = 0

  local function node(node_type, row, parent, text)
    next_node_id = next_node_id + 1
    local node_id = next_node_id
    return {
      id = function()
        return node_id
      end,
      type = function()
        return node_type
      end,
      start = function()
        return row, 0
      end,
      range = function()
        return row, 0, row, 5
      end,
      parent = function()
        return parent
      end,
      iter_children = function()
        return function() end
      end,
      text = text,
    }
  end

  local function make_root(start_row, end_row)
    local function_node = node("function_definition", start_row)
    function_node.range = function()
      return start_row, 0, end_row, 5
    end
    local assignments, identifiers = {}, {}
    for row = start_row, end_row do
      assignments[row] = node("assignment_statement", row, function_node)
      identifiers[#identifiers + 1] = node("identifier", row, assignments[row], "alpha")
    end
    local tree_root = node("chunk", start_row)
    tree_root.range = function()
      return start_row, 0, end_row, 5
    end
    tree_root.named_descendant_for_range = function(_, row)
      return identifiers[row - start_row + 1] or identifiers[1]
    end
    tree_root.iter_children = function()
      local index = 0
      return function()
        index = index + 1
        return identifiers[index]
      end
    end
    return tree_root
  end

  local current_root = make_root(0, 2)
  vim.treesitter.get_parser = function()
    return {
      parse = function()
        parse_count = parse_count + 1
        return { {
          root = function()
            return current_root
          end,
        } }
      end,
    }
  end
  vim.treesitter.get_node_text = function(current)
    return current.text
  end

  local shared_buf = new_buffer({ "alpha = 1", "alpha = 2", "alpha = 3" }, "shared-ts")
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
  assert_true(
    vim.deep_equal(fallback_state.statement_set, fallback_state.path_set),
    "a cached Tree-sitter failure should preserve structural fallback"
  )
  vim.cmd("TunnelVision off")

  parse_count = 0
  current_root = make_root(0, 0)
  vim.treesitter.get_parser = function()
    return {
      parse = function()
        parse_count = parse_count + 1
        return { {
          root = function()
            return current_root
          end,
        } }
      end,
    }
  end
  local activation_context = {}
  local old_scope = resolver.resolve_scope(shared_buf, { row = 0, col = 0 }, nil, "function", activation_context)
  current_root = make_root(1, 2)
  vim.api.nvim_buf_set_lines(shared_buf, 0, 1, false, { "edited alpha" })
  local new_scope = resolver.resolve_scope(shared_buf, { row = 1, col = 0 }, nil, "function", activation_context)
  assert_true(parse_count == 2, "changedtick changes should replace the cached snapshot")
  assert_true(old_scope.start_line == 1 and old_scope.end_line == 1, "initial snapshot geometry")
  assert_true(new_scope.start_line == 2 and new_scope.end_line == 3, "edited buffers should not expose stale nodes")

  vim.treesitter.get_parser = orig_get_parser
  vim.treesitter.get_node_text = orig_get_node_text
end

local dynamic_buf = new_buffer({
  "local alpha = 1",
  "local beta = alpha + 1",
  "local gamma = beta + 1",
})
vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- alpha

vim.cmd("TunnelVision mode dynamic")
vim.cmd("TunnelVision on")

vim.api.nvim_win_set_cursor(0, { 2, 8 }) -- beta
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
vim.api.nvim_win_set_cursor(0, { 3, 8 }) -- gamma
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })

local waited = vim.wait(200, function()
  return core.get_buf_state(dynamic_buf).symbol == "gamma"
end, 10)
assert_true(waited, "dynamic debounce did not retarget to latest symbol")
assert_true(core.get_buf_state(dynamic_buf).path_set[3], "dynamic retarget should recompute path for latest symbol")

local no_op = core.activate(dynamic_buf, { silent = true, symbol = "gamma", cursor = { 3, 8 }, reuse_scope = true })
assert_true(no_op == false, "identical activate should no-op")

vim.cmd("TunnelVision off")

do
  local cancellations = {}
  local lsp_buf
  local requests = {}
  local sync_cancel_callbacks = false
  local timers = {}
  local explicit_client_self = vim.fn.has("nvim-0.11") == 1
  local fake_clients = {
    { id = 1, offset_encoding = "utf-8", server_capabilities = {} },
    { id = 2, offset_encoding = "utf-16", server_capabilities = { documentHighlightProvider = true } },
    { id = 3, offset_encoding = "utf-8", server_capabilities = { documentHighlightProvider = true } },
    { id = 4, offset_encoding = "utf-32", server_capabilities = {} },
  }
  local function client_method(client, fn)
    if explicit_client_self then
      return function(self, ...)
        assert_true(self == client, "Neovim 0.11 client methods should receive explicit self")
        return fn(...)
      end
    end
    return fn
  end
  fake_clients[1].supports_method = client_method(fake_clients[1], function(method, context)
    local supported_context = explicit_client_self and type(context) == "number"
      or not explicit_client_self and type(context) == "table" and type(context.bufnr) == "number"
    assert_true(supported_context, "LSP support checks should use the version's client API")
    return method == "textDocument/documentHighlight"
  end)
  fake_clients[3].supports_method = client_method(fake_clients[3], function()
    return false
  end)
  fake_clients[4].supports_method = client_method(fake_clients[4], function(method)
    return method == "textDocument/documentHighlight"
  end)
  for _, client in ipairs({ fake_clients[1], fake_clients[2] }) do
    local cancel_client = client
    client.cancel_request = client_method(client, function(handle)
      cancellations[("%d:%d"):format(cancel_client.id, handle)] = true
      if sync_cancel_callbacks then
        requests[handle - 100].callback(nil, {
          { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } },
        })
      end
    end)
  end
  for _, client in ipairs(fake_clients) do
    local request_client = client
    client.request = client_method(client, function(method, params, callback, bufnr)
      local handle = 101 + #requests
      requests[#requests + 1] = {
        bufnr = bufnr,
        callback = callback,
        client_id = request_client.id,
        handle = handle,
        method = method,
        params = params,
      }
      if request_client.sync_result then
        callback(nil, request_client.sync_result)
      end
      return true, handle
    end)
  end

  local orig_defer_fn = vim.defer_fn
  vim.defer_fn = function(callback)
    timers[#timers + 1] = callback
  end
  local restore_clients
  if vim.lsp.get_clients then
    local orig_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return fake_clients
    end
    restore_clients = function()
      vim.lsp.get_clients = orig_get_clients
    end
  else
    local orig_buf_get_clients = vim.lsp.buf_get_clients
    vim.lsp.buf_get_clients = function()
      return fake_clients
    end
    restore_clients = function()
      vim.lsp.buf_get_clients = orig_buf_get_clients
    end
  end

  local function respond(request, result, err)
    request.callback(err, result, { client_id = request.client_id })
  end

  local function was_canceled(request)
    return cancellations[("%d:%d"):format(request.client_id, request.handle)]
  end

  local request_cursor, timer_cursor = 0, 0
  local function take_batch()
    local batch = {}
    for i = request_cursor + 1, #requests do
      batch[requests[i].client_id] = requests[i]
    end
    request_cursor = #requests
    timer_cursor = timer_cursor + 1
    assert_true(timers[timer_cursor] ~= nil, "each activation should create one global timeout")
    return batch, timers[timer_cursor]
  end

  lsp_buf = new_buffer({ "😀 alpha alpha", "plain alpha", "alpha", "beta" })
  local direct_result
  require("tunnelvision.resolver").request_lsp_highlight(
    lsp_buf,
    { row = 1, col = 6 },
    { start_line = 1, end_line = 4 },
    1000,
    function(result)
      direct_result = result
    end
  )
  local direct_batch = take_batch()
  respond(direct_batch[1], {
    { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } },
  })
  respond(direct_batch[2], {})
  respond(direct_batch[4], {})
  assert_true(direct_result and direct_result.used, "five-argument LSP request callback should remain compatible")
  assert_ranges(direct_result.ranges, {
    { line = 3, start_col = 0, end_col = 5 },
  }, "direct LSP request ranges")

  local request_count = #requests
  tunnelvision.setup({ notify = false, sources = { "word", "lsp" }, scope = "buffer" })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  local bs = core.get_buf_state(lsp_buf)
  assert_true(#requests == request_count and not bs.pending, "successful word before LSP should avoid requests")
  assert_true(bs.last_compute_meta.used_source == "word", "word-first resolution should select word")

  if parser_or_skip(lsp_buf, "lua", "Tree-sitter-first LSP demand") then
    tunnelvision.setup({ notify = false, sources = { "treesitter", "lsp" }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    assert_true(#requests == request_count and not bs.pending, "successful treesitter before LSP should avoid requests")
    assert_true(
      bs.last_compute_meta.used_source == "treesitter",
      "treesitter-first resolution should select treesitter"
    )
  end

  tunnelvision.setup({
    notify = false,
    sources = { tunnelvision.combine("custom_empty", "lsp"), "word" },
    scope = "buffer",
  })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  assert_true(#requests == request_count, "failed earlier combine member should not request a later LSP member")
  assert_true(bs.last_compute_meta.used_source == "word", "failed strict combine should use the next source")
  assert_true(
    bs.last_compute_meta.fallback_source == "custom_empty",
    "strict combine should preserve the first failed member metadata"
  )

  local custom_resume_calls = 0
  assert_true(
    tunnelvision.register_source("custom_resume", function()
      custom_resume_calls = custom_resume_calls + 1
      return { [1] = true }
    end),
    "resumable custom source registers"
  )
  tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("custom_resume", "lsp") }, scope = "buffer" })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  local resume_batch = take_batch()
  assert_true(bs.pending and custom_resume_calls == 1, "strict combine should pause when it reaches LSP")
  respond(resume_batch[1], {
    { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } },
  })
  respond(resume_batch[2], {})
  respond(resume_batch[4], {})
  assert_true(custom_resume_calls == 1, "resume should not rerun a completed custom source")
  assert_true(
    not bs.pending
      and bs.last_compute_meta.used_source == "combine(custom_resume,lsp)"
      and bs.path_set[1]
      and bs.path_set[2],
    "resumed strict combine should merge cached custom and LSP results"
  )

  tunnelvision.setup({ notify = false, sources = { "custom_empty", "lsp" }, scope = "buffer" })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  local fallback_batch = take_batch()
  assert_true(bs.pending, "failed earlier source should continue to LSP")
  respond(fallback_batch[1], {
    { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } },
  })
  respond(fallback_batch[2], {})
  respond(fallback_batch[4], {})
  assert_true(
    bs.last_compute_meta.used_source == "lsp"
      and bs.last_compute_meta.used_fallback
      and bs.last_compute_meta.fallback_source == "custom_empty",
    "LSP reached after an earlier failure should retain fallback metadata"
  )

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { line = { fg = 0x112233 } },
  })
  vim.api.nvim_win_set_cursor(0, { 2, 6 })
  vim.cmd("TunnelVision on")
  bs = core.get_buf_state(lsp_buf)
  local old_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
  local function mark_geometry(marks)
    return vim.tbl_map(function(mark)
      return { mark[2], mark[3], mark[4] }
    end, marks)
  end
  assert_true(#old_marks > 0, "word render should create styled extmarks")
  bs.last_compute_meta = { flow_analyzer = "text", flow_expanded = true, flow_tracked_count = 2 }

  tunnelvision.setup({
    notify = false,
    scope = "buffer",
    dim = "none",
    highlights = { line = { fg = 0xAABBCC } },
    lsp_timeout_ms = 1000,
  })
  core.activate(lsp_buf, { silent = true, symbol = "alpha", cursor = { 1, 5 } })
  local batch = take_batch()
  local timeout
  assert_true(batch[1] and batch[2] and batch[4] and not batch[3], "only supporting clients should be requested")
  for _, request in pairs(batch) do
    assert_true(request.method == "textDocument/documentHighlight", "per-client request method")
    assert_true(request.bufnr == lsp_buf, "per-client request buffer")
  end
  assert_true(batch[1].params.position.character == 5, "UTF-8 request should use byte offset")
  assert_true(batch[2].params.position.character == 3, "UTF-16 request should count astral code units")
  assert_true(batch[4].params.position.character == 2, "UTF-32 request should count astral characters")
  assert_true(bs.pending, "default LSP-first activation should be pending")
  local pending_status = tunnelvision.status()
  assert_true(
    pending_status.flow_analyzer == nil and not pending_status.flow_expanded and pending_status.flow_tracked_count == 0,
    "pending status should not expose stale flow metadata"
  )
  assert_true(
    vim.deep_equal(vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true }), old_marks),
    "pending LSP request should retain the previous render"
  )
  local ui = require("tunnelvision.ui")
  local resolver = require("tunnelvision.resolver")
  local orig_ensure_highlights = ui.ensure_highlights
  local orig_compute_path = resolver.compute_path
  local pending_config, rendered_config, request_id = bs.config, bs.rendered_config, bs.request_id
  local pending_config_setups = 0
  local compute_calls = 0
  ui.ensure_highlights = function(cfg)
    if cfg == pending_config then
      pending_config_setups = pending_config_setups + 1
    end
    return orig_ensure_highlights(cfg)
  end
  resolver.compute_path = function(...)
    compute_calls = compute_calls + 1
    return orig_compute_path(...)
  end
  local old_group = old_marks[1][4].hl_group
  vim.api.nvim_set_hl(0, old_group, {})
  assert_true(
    next(vim.api.nvim_get_hl(0, { name = old_group, link = false })) == nil,
    "colorscheme should clear old groups"
  )
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  ui.ensure_highlights = orig_ensure_highlights
  resolver.compute_path = orig_compute_path
  local recreated_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
  assert_true(
    vim.deep_equal(mark_geometry(recreated_marks), mark_geometry(old_marks)),
    "ColorScheme should preserve retained extmarks while LSP is pending"
  )
  local recreated_group = recreated_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = recreated_group, link = false }).fg == 0x112233,
    "pending ColorScheme should recreate the last rendered style"
  )
  assert_true(
    pending_config_setups == 0
      and compute_calls == 0
      and bs.pending
      and bs.request_id == request_id
      and bs.config == pending_config
      and bs.rendered_config == rendered_config,
    "pending ColorScheme should preserve pending config, request, and cached render state"
  )

  fake_clients[1].offset_encoding = "utf-16"
  respond(batch[1], {
    { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } },
  })
  assert_true(bs.pending, "partial LSP results should wait for remaining clients")
  respond(batch[4], {
    { range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 7 } } },
  })
  respond(batch[2], {
    { range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 8 } } },
    { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } },
  })
  fake_clients[1].offset_encoding = "utf-8"
  assert_true(not bs.pending, "terminal responses should clear pending state")
  local completed_group =
    vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })[1][4].hl_group
  assert_true(
    bs.rendered_config == pending_config
      and vim.api.nvim_get_hl(0, { name = completed_group, link = false }).fg == 0xAABBCC,
    "completed request should apply the pending style"
  )
  assert_ranges(bs.symbol_ranges, {
    { line = 1, start_col = 5, end_col = 10 },
    { line = 2, start_col = 6, end_col = 11 },
  }, "mixed response encodings should normalize and deduplicate byte ranges")

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  assert_true(batch[1].params.position.character == 6, "ASCII UTF-8 offset should remain unchanged")
  assert_true(batch[2].params.position.character == 6, "ASCII UTF-16 offset should remain unchanged")
  assert_true(batch[4].params.position.character == 6, "ASCII UTF-32 offset should remain unchanged")
  respond(batch[1], { { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } } })
  respond(batch[2], nil, { code = -1, message = "boom" })
  respond(batch[4], nil, { code = -1, message = "boom" })
  assert_true(not bs.pending and bs.path_set[2], "valid partial results should survive another client error")

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 3, 0 } })
  batch, timeout = take_batch()
  respond(batch[1], { { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } } })
  timeout()
  assert_true(was_canceled(batch[2]) and not was_canceled(batch[1]), "timeout should cancel only unresolved clients")
  assert_true(not bs.pending, "partial result should complete at the global timeout")
  assert_true(bs.path_set[3], "timed-out clients should not discard valid partial results")
  local timeout_ranges = vim.deepcopy(bs.symbol_ranges)
  respond(batch[2], { { range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 5 } } } })
  assert_ranges(bs.symbol_ranges, timeout_ranges, "late responses after timeout should be ignored")

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  for _, request in pairs(batch) do
    respond(request, nil, { code = -1, message = "boom" })
  end
  local fallback_meta = bs.last_compute_meta
  assert_true(not bs.pending and fallback_meta.used_source == "treesitter", "total errors should use fallback chain")
  assert_true(
    fallback_meta.failed_sources[1] == "lsp"
      and fallback_meta.fallback_source == "lsp"
      and fallback_meta.fallback_reason == "request_failed"
      and fallback_meta.used_fallback,
    "total errors should preserve fallback metadata"
  )

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch, timeout = take_batch()
  sync_cancel_callbacks = true
  timeout()
  sync_cancel_callbacks = false
  assert_true(
    was_canceled(batch[1]) and was_canceled(batch[2]) and bs.last_compute_meta.used_source == "treesitter",
    "reentrant total timeout should cancel its owned requests and fall back"
  )

  tunnelvision.setup({ notify = false, sources = { "lsp" }, scope = "buffer", lsp_timeout_ms = 1000 })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  for _, request in pairs(batch) do
    respond(request, nil, { code = -1, message = "boom" })
  end
  assert_true(bs.last_compute_meta.used_source == nil, "strict LSP total failure should not select a fallback")
  assert_true(not bs.path_set[1] and not bs.path_set[3], "strict LSP total failure should keep only the anchor")

  tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") }, scope = "buffer" })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  respond(batch[1], { { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } } })
  respond(batch[2], {})
  respond(batch[4], {})
  assert_true(bs.last_compute_meta.used_source == "combine(lsp,word)", "combined source should succeed")
  assert_true(bs.path_set[1] and bs.path_set[3], "combined source should include LSP and word lines")

  tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") }, scope = "buffer" })
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  for _, request in pairs(batch) do
    respond(request, {})
  end
  assert_true(bs.last_compute_meta.used_source == nil, "empty LSP should fail an all-or-nothing combined source")
  assert_true(bs.last_compute_meta.fallback_source == "lsp", "empty combined source should record its failed member")

  tunnelvision.setup({
    notify = false,
    sources = { tunnelvision.combine("lsp", "treesitter"), "word" },
    scope = "buffer",
  })
  vim.bo[lsp_buf].filetype = "plaintext"
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  respond(batch[1], { { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } } })
  respond(batch[2], {})
  respond(batch[4], {})
  assert_true(bs.last_compute_meta.used_source == "word", "later combined member failure should use next source")
  assert_true(bs.last_compute_meta.fallback_source == "treesitter", "combined failure should record later member")
  assert_true(
    bs.last_compute_meta.failed_sources[1] == "combine(lsp,treesitter)",
    "combined failure should record the failed step"
  )

  tunnelvision.setup({ notify = false, sources = { "lsp", "word" }, scope = "buffer" })
  fake_clients[4].sync_result = {}
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  respond(batch[1], {})
  respond(batch[2], {})
  fake_clients[4].sync_result = nil
  assert_true(bs.last_compute_meta.used_source == "word", "empty successful LSP response should follow source chain")
  assert_true(
    bs.last_compute_meta.fallback_reason == "no_matches",
    "empty successful response should report no_matches"
  )

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 5 } })
  local stale_batch = take_batch()
  local stale_request_id = bs.request_id
  respond(stale_batch[1], {})
  respond(stale_batch[4], {})
  local retained_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
  sync_cancel_callbacks = true
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  sync_cancel_callbacks = false
  local current_batch = take_batch()
  local current_request_id = bs.request_id
  assert_true(current_request_id ~= stale_request_id, "supersession should replace the request ID")
  assert_true(
    was_canceled(stale_batch[2]) and not was_canceled(stale_batch[1]),
    "supersession owns incomplete requests"
  )
  assert_true(bs.pending and bs.anchor.row == 1, "synchronous cancellation callbacks should leave replacement pending")
  assert_true(
    vim.deep_equal(vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true }), retained_marks),
    "synchronous cancellation callbacks should preserve the pending render"
  )
  respond(stale_batch[1], {})
  respond(stale_batch[2], {})
  respond(stale_batch[4], {})
  assert_true(
    bs.pending and bs.anchor.row == 1 and bs.request_id == current_request_id,
    "older completed requests should remain stale"
  )
  respond(
    current_batch[1],
    { { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } } }
  )
  respond(current_batch[2], {})
  respond(current_batch[4], {})
  assert_true(
    not bs.pending and bs.request_id == nil and bs.path_set[2],
    "current request should apply after stale response"
  )

  local current_ranges = vim.deepcopy(bs.symbol_ranges)
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  vim.api.nvim_buf_set_lines(lsp_buf, 1, 2, false, { "edited alpha" })
  respond(batch[1], {})
  respond(batch[2], {})
  respond(batch[4], {})
  assert_true(bs.pending, "pre-edit responses should remain stale")
  assert_ranges(bs.symbol_ranges, current_ranges, "pre-edit response should not render")

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch = take_batch()
  respond(batch[4], {})
  sync_cancel_callbacks = true
  vim.cmd("TunnelVision off")
  sync_cancel_callbacks = false
  assert_true(was_canceled(batch[1]) and was_canceled(batch[2]), "deactivation should cancel pending clients")
  for _, request in pairs(batch) do
    respond(request, {})
  end
  assert_true(not bs.active and not bs.pending, "late callbacks after deactivation should remain stale")

  local deleted_buf = new_buffer({ "alpha", "alpha" })
  core.activate(deleted_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 0 } })
  batch = take_batch()
  respond(batch[4], {})
  vim.api.nvim_buf_delete(deleted_buf, { force = true })
  assert_true(
    was_canceled(batch[1]) and was_canceled(batch[2]) and core.state.bufs[deleted_buf] == nil,
    "buffer deletion should cancel owned requests and clear state"
  )
  for _, request in pairs(batch) do
    respond(request, {})
  end
  assert_true(core.state.bufs[deleted_buf] == nil, "late callbacks after buffer deletion should stay stale")

  vim.defer_fn = orig_defer_fn
  restore_clients()
end

-- Fallback warning policies remain stable when LSP is unavailable.
do
  local messages = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    messages[#messages + 1] = msg
  end

  local fallback_buf = new_buffer({
    "local alpha = 1",
    "print(alpha)",
  }, "plaintext")
  local function warning_count(policy, notify, source)
    messages = {}
    tunnelvision.setup({
      notify = notify,
      source = source or "lsp_else_word",
      fallback_warn = policy,
      scope = "buffer",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on()
    core.activate(fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 7 } })
    vim.cmd("TunnelVision off")
    return #messages
  end
  for _, case in ipairs({
    { "once", true, 1 },
    { "always", true, 2 },
    { "never", true, 0 },
    { "always", false, 0 },
  }) do
    local count = warning_count(case[1], case[2])
    assert_true(count == case[3], ("fallback_warn %s: expected %d, got %d"):format(case[1], case[3], count))
  end
  assert_true(
    warning_count("once", true, "lsp") == 1 and messages[1]:find("strict LSP source"),
    "strict LSP should warn when clients are unavailable"
  )
  vim.notify = orig_notify
end

-- Treesitter fallback behavior (plaintext has no parser)
tunnelvision.setup({ notify = false })
local ts_fb_buf = new_buffer({
  "local alpha = 1",
  "local beta = 2",
  "print(alpha)",
}, "plaintext")
vim.api.nvim_win_set_cursor(0, { 1, 7 })

-- sources = { "treesitter" } should only keep the anchor line
tunnelvision.on({ sources = { "treesitter" } })
assert_true(next(core.get_buf_state(ts_fb_buf).path_set) ~= nil, "treesitter-only should keep anchor")
assert_true(core.get_buf_state(ts_fb_buf).path_set[1], "treesitter-only anchor at line 1")
assert_true(not core.get_buf_state(ts_fb_buf).path_set[3], "treesitter-only should not match line 3")
local ts_meta = core.get_buf_state(ts_fb_buf).last_compute_meta
assert_true(ts_meta.fallback_reason == "unavailable", "treesitter-only fallback reason is unavailable")
vim.cmd("TunnelVision off")

-- sources = { "treesitter", "word" } falls back to word matching
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ sources = { "treesitter", "word" } })
assert_true(core.get_buf_state(ts_fb_buf).path_set[3], "treesitter,word falls back to word matching")
assert_true(
  core.get_buf_state(ts_fb_buf).last_compute_meta.fallback_reason == "unavailable",
  "treesitter,word fallback reason is unavailable"
)
vim.cmd("TunnelVision off")

-- tv.combine("lsp", "treesitter"), "word" falls back to word when treesitter unavailable
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ sources = { tunnelvision.combine("lsp", "treesitter"), "word" } })
assert_true(core.get_buf_state(ts_fb_buf).path_set[3], "combine(lsp,treesitter),word falls back to word")
local combined_meta = core.get_buf_state(ts_fb_buf).last_compute_meta
assert_true(combined_meta.used_source == "word", "combined fallback metadata records selected word source")
assert_true(
  combined_meta.failed_sources[1] == "combine(lsp,treesitter)",
  "combined fallback metadata records failed combined step"
)
assert_true(combined_meta.fallback_source == "lsp", "combined fallback metadata records failed member")
vim.cmd("TunnelVision off")
tunnelvision.setup({ notify = false, source = "lsp_else_word" })

-- Treesitter source matches identifier nodes when parser is available
do
  tunnelvision.setup({ notify = false })
  local ts_buf = new_buffer({
    "local alpha = 1",
    "local beta = 2",
    "print(alpha)",
  })

  if parser_or_skip(0, "lua", "real Lua Tree-sitter source and flow") then
    -- sources = { "treesitter" } returns identifier lines
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on({ sources = { "treesitter" } })
    assert_true(core.get_buf_state(ts_buf).path_set[1], "treesitter should match line 1 (declaration)")
    assert_true(core.get_buf_state(ts_buf).path_set[3], "treesitter should match line 3 (usage)")
    assert_true(not core.get_buf_state(ts_buf).path_set[2], "treesitter should not match line 2 (different symbol)")
    assert_ranges(core.get_buf_state(ts_buf).symbol_ranges, {
      { line = 1, start_col = 6, end_col = 11 },
      { line = 3, start_col = 6, end_col = 11 },
    }, "treesitter should retain exact identifier node ranges")
    assert_true(
      core.get_buf_state(ts_buf).last_compute_meta.fallback_reason == nil,
      "treesitter should not set fallback_reason on success"
    )
    vim.cmd("TunnelVision off")

    local ts_flow_buf = new_buffer({
      "local alpha = 1",
      "local beta = alpha",
      "print(beta)",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on({ sources = { "treesitter" }, scope = "buffer", mode = "flow" })
    assert_true(core.get_buf_state(ts_flow_buf).path_set[3], "treesitter-only source should enable flow expansion")
    assert_ranges(core.get_buf_state(ts_flow_buf).symbol_ranges, {
      { line = 1, start_col = 6, end_col = 11 },
      { line = 2, start_col = 6, end_col = 10 },
      { line = 2, start_col = 13, end_col = 18 },
      { line = 3, start_col = 6, end_col = 10 },
    }, "treesitter-only flow should retain source and propagated ranges")
    vim.cmd("TunnelVision off")

    local ts_analysis = require("tunnelvision.flow").analyze_treesitter({
      anchor = { row = 0, col = 6 },
      bufnr = ts_flow_buf,
      keywords = require("tunnelvision.resolver").build_keywords({}),
      scope = { start_line = 1, end_line = 3 },
      symbol = "alpha",
    })
    assert_true(ts_analysis and #ts_analysis.assignments >= 2, "treesitter analyzer should extract assignments")
    assert_ranges(ts_analysis.assignments[2].lhs, {
      { name = "beta", line = 2, start_col = 6, end_col = 10 },
    }, "treesitter analyzer should retain exact LHS ranges")

    local nested_flow_buf = new_buffer({
      "local alpha = 1",
      "local function nested()",
      "  local nested_value = alpha",
      "  print(nested_value)",
      "end",
      "local callback = function()",
      "  local leaked = alpha",
      "end",
      "local beta = alpha",
    })
    local nested_analysis = require("tunnelvision.flow").analyze_treesitter({
      anchor = { row = 0, col = 6 },
      bufnr = nested_flow_buf,
      keywords = require("tunnelvision.resolver").build_keywords({}),
      scope = { start_line = 1, end_line = 9 },
      symbol = "alpha",
    })
    assert_true(not nested_analysis.occurrences.nested_value, "treesitter analyzer should skip nested functions")
    assert_true(not nested_analysis.occurrences.leaked, "treesitter analyzer should skip function expressions")
    assert_true(#nested_analysis.occurrences.alpha == 2, "nested functions should not leak identifier occurrences")

    -- Treesitter excludes string-only occurrences
    local str_buf = new_buffer({
      'local msg = "alpha is here"',
      "-- alpha in a comment",
      "local copy = alpha",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 10 })
    tunnelvision.on({ sources = { "treesitter" } })
    -- alpha on line 3 is an identifier reference
    assert_true(core.get_buf_state(str_buf).path_set[3], "treesitter should match identifier alpha on line 3")
    -- alpha on line 1 is inside a string literal, not an identifier node
    assert_true(
      not core.get_buf_state(str_buf).path_set[1],
      "treesitter should not match alpha inside string on line 1"
    )
    assert_true(
      not core.get_buf_state(str_buf).path_set[2],
      "treesitter should not match alpha inside comment on line 2"
    )
    vim.cmd("TunnelVision off")

    -- Treesitter respects scope = "function" vs scope = "buffer"
    local scope_buf = new_buffer({
      "local function foo()",
      "  local alpha = 1",
      "  print(alpha)",
      "end",
      "local alpha = 2",
    })
    -- scope = "function" with cursor inside foo() should only find alpha inside the function
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    tunnelvision.on({ sources = { "treesitter" }, scope = "function" })
    assert_true(core.get_buf_state(scope_buf).path_set[2], "treesitter function scope should match alpha on line 2")
    assert_true(core.get_buf_state(scope_buf).path_set[3], "treesitter function scope should match alpha on line 3")
    -- line 5 (outside function) may or may not be included depending on scope resolution;
    -- we just verify function scope is narrower than buffer scope
    local function_scope_matches = vim.tbl_count(core.get_buf_state(scope_buf).path_set)
    vim.cmd("TunnelVision off")

    -- scope = "buffer" should find alpha everywhere
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    tunnelvision.on({ sources = { "treesitter" }, scope = "buffer" })
    assert_true(core.get_buf_state(scope_buf).path_set[5], "treesitter buffer scope should match alpha on line 5")
    local buffer_scope_matches = vim.tbl_count(core.get_buf_state(scope_buf).path_set)
    assert_true(
      buffer_scope_matches >= function_scope_matches,
      "buffer scope should match at least as many lines as function scope"
    )
    vim.cmd("TunnelVision off")

    -- combine(lsp, treesitter) fails the combined step when LSP is unavailable
    local combine_buf = new_buffer({
      "local alpha = 1",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on({ sources = { tunnelvision.combine("lsp", "treesitter"), "word" } })
    -- LSP is unavailable, so combine fails, falls back to word
    assert_true(core.get_buf_state(combine_buf).path_set[1], "combine(lsp,treesitter) fallback should keep anchor")
    assert_true(
      core.get_buf_state(combine_buf).last_compute_meta.used_fallback,
      "combine(lsp,treesitter) should trigger fallback when LSP unavailable"
    )
    vim.cmd("TunnelVision off")
  end
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

-- === Dim API cleanup tests ===

-- Restore to baseline before dim form tests
tunnelvision.setup({ notify = false })

-- dim = nil uses Comment-derived default
tunnelvision.setup({ notify = false, dim = nil })
local nil_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
assert_true(nil_hl and comment_hl and nil_hl.fg == comment_hl.fg, "dim = nil should derive from Comment fg")

-- dim = "#445566" sets foreground color
tunnelvision.setup({ notify = false, dim = "#445566" })
local hex_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(hex_hl and hex_hl.fg == 0x445566, "dim = '#445566' should set fg")

-- dim = { fg = "#667788", italic = false } works
tunnelvision.setup({ notify = false, dim = { fg = "#667788", italic = false } })
local table_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(table_hl and table_hl.fg == 0x667788, "dim = { fg = ... } table form should set fg")
assert_true(
  table_hl and (table_hl.italic == nil or table_hl.italic == false),
  "dim = { italic = false } should not be italic"
)

vim.api.nvim_set_hl(0, "CompatDim", { fg = 0x998877 })
tunnelvision.setup({ notify = false, dim = "CompatDim" })
local copied_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(copied_hl.fg == 0x998877 and copied_hl.link == nil, "dim groups should be copied, not linked")

tunnelvision.setup({ notify = false, dim_hl = "CompatDim" })
assert_true(core.state.config.dim_hl == "CompatDim", "deprecated setup dim_hl should remain public")
tunnelvision.setup({ notify = false, dim = "#AABBCC", dim_hl = "CompatDim" })
assert_true(
  vim.api.nvim_get_hl(0, { name = "CompatDim", link = false }).fg == 0xAABBCC,
  "dim should apply to the deprecated dim_hl target"
)

tunnelvision.setup({ notify = false, dim = "DefinitelyMissingTunnelVisionDimGroup" })
assert_true(
  vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false }).fg == comment_hl.fg,
  "missing dim groups should use the Comment fallback"
)

-- one-shot dim = "#AA33CC" works
local oneshot_hex_buf = new_buffer({
  "local alpha = 1",
  "print(alpha)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = "#AA33CC" })
local oneshot_hex_hl =
  vim.api.nvim_get_hl(0, { name = core.get_buf_state(oneshot_hex_buf).config.dim_hl, link = false })
assert_true(oneshot_hex_hl and oneshot_hex_hl.fg == 0xAA33CC, "one-shot dim = '#AA33CC' should set fg")
vim.cmd("TunnelVision off")

vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim_hl = "CompatDim" })
assert_true(
  core.get_buf_state(oneshot_hex_buf).config.dim_hl == "CompatDim",
  "deprecated one-shot dim_hl should select its public group"
)
vim.cmd("TunnelVision off")

-- one-shot dim without one-shot dim_hl uses buffer-specific dim group
tunnelvision.setup({ notify = false, dim = { fg = 0x445566 } })
local buf_a = new_buffer({
  "local alpha = 1",
  "print(alpha)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = "#BB44DD" })
local buf_a_dim_hl = core.get_buf_state(buf_a).config.dim_hl
assert_true(
  buf_a_dim_hl:match("TunnelVisionDim%d+$"),
  "one-shot dim without one-shot dim_hl should use buffer-specific group"
)
-- Global dim should still use global group
local global_dim_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(global_dim_hl and global_dim_hl.fg == 0x445566, "global dim should be unchanged by buffer-specific group")
-- Buffer-specific group should have the one-shot color
local buf_a_hl = vim.api.nvim_get_hl(0, { name = buf_a_dim_hl, link = false })
assert_true(buf_a_hl and buf_a_hl.fg == 0xBB44DD, "buffer-specific dim group should have one-shot color")
vim.cmd("TunnelVision off")

-- invalid dim falls back to Comment-derived behavior
tunnelvision.setup({ notify = false, dim = 42 })
local invalid_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(invalid_hl and invalid_hl.fg == comment_hl.fg, "invalid dim = 42 should fall back to Comment-derived fg")

tunnelvision.setup({ notify = false }) -- restore

-- colorscheme refresh preserves configured dim behavior
tunnelvision.setup({ notify = false, dim = "Comment" })
vim.cmd("colorscheme default")
local cs_copy_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
local cs_comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
assert_true(
  cs_copy_hl and cs_comment_hl and cs_copy_hl.fg == cs_comment_hl.fg,
  "colorscheme refresh should re-copy from Comment group for dim = 'Comment'"
)

tunnelvision.setup({ notify = false, dim = "#778899" })
vim.cmd("colorscheme default")
assert_true(
  vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false }).fg == 0x778899,
  "colorscheme refresh should preserve hex dim colors"
)

tunnelvision.setup({ notify = false }) -- restore
vim.cmd("TunnelVision off")
assert_true(not core.is_active(0), "deactivation failed")

-- One-shot highlight rules inherit or replace the setup rules.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  local highlight_buf = new_buffer({
    "local alpha = 1",
    "print(alpha)",
    "local beta = 2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })

  tunnelvision.on()
  local bs = core.get_buf_state(highlight_buf)
  assert_true(vim.deep_equal(bs.config.highlights, { symbol = {} }), "missing one-shot highlights should inherit")

  assert_true(
    core.activate(highlight_buf, {
      source = "word",
      scope = "buffer",
      highlights = { statement = true },
      symbol = "alpha",
      cursor = { 1, 7 },
    }),
    "changed one-shot highlights should invalidate config equality"
  )
  bs = core.get_buf_state(highlight_buf)
  assert_true(
    vim.deep_equal(bs.config.highlights, { statement = {} }),
    "non-empty one-shot highlights should replace setup rules"
  )

  core.activate(highlight_buf, {
    source = "word",
    scope = "buffer",
    highlights = {},
    symbol = "alpha",
    cursor = { 1, 7 },
    force = true,
  })
  assert_true(
    vim.deep_equal(core.get_buf_state(highlight_buf).config.highlights, { line = {} }),
    "empty one-shot highlights should use line default"
  )

  core.activate(highlight_buf, {
    source = "word",
    highlights = { unknown = true, symbol = 42, line = { bold = "yes" } },
    symbol = "alpha",
    cursor = { 1, 7 },
    force = true,
  })
  assert_true(
    vim.deep_equal(core.get_buf_state(highlight_buf).config.highlights, { line = {} }),
    "invalid one-shot highlight rules should normalize safely"
  )
  vim.cmd("TunnelVision off")
end

-- The renderer dims only the visible union's complement and composes styles.
do
  local ui = require("tunnelvision.ui")
  local orig_ensure_highlights = ui.ensure_highlights
  local orig_get_hl = vim.api.nvim_get_hl
  local orig_set_hl = vim.api.nvim_set_hl
  local normal_bg_calls = 0
  local function reset_highlight_calls()
    normal_bg_calls = 0
  end
  vim.api.nvim_get_hl = function(namespace, opts)
    if opts.name == "Normal" then
      normal_bg_calls = normal_bg_calls + 1
    end
    return orig_get_hl(namespace, opts)
  end
  local function capture_setups(action)
    local setups = {}
    ui.ensure_highlights = function(cfg)
      setups[cfg or false] = (setups[cfg or false] or 0) + 1
      return orig_ensure_highlights(cfg)
    end
    action()
    ui.ensure_highlights = orig_ensure_highlights
    return setups
  end
  local function marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, core.state.ns, 0, -1, { details = true })
  end

  local function mark_priority(details)
    -- Neovim 0.9 omits priority from line-highlight extmark details.
    return details.priority or (details.line_hl_group and 1000)
  end

  local function mark_snapshot(bufnr)
    local out = {}
    for _, mark in ipairs(marks(bufnr)) do
      local details = mark[4]
      out[#out + 1] = {
        mark[2],
        mark[3],
        details.end_col,
        details.hl_group,
        details.line_hl_group,
        mark_priority(details),
      }
    end
    return out
  end

  local render_buf = new_buffer({ "xx alpha yy alpha zz", "local beta = 1" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })

  tunnelvision.setup()
  reset_highlight_calls()
  tunnelvision.on({ scope = "buffer", silent = true })
  local default_snapshot = mark_snapshot(render_buf)
  assert_true(#default_snapshot == 1, "default renderer should add only the unrelated-line dim mark")
  assert_true(default_snapshot[1][5] == "TunnelVisionDim", "default renderer should use line dimming")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  reset_highlight_calls()
  local bs = core.get_buf_state(render_buf)
  local setups = capture_setups(function()
    ui.render(render_buf)
  end)
  assert_true(
    setups[bs.config] == 1 and vim.tbl_count(setups) == 1,
    "each render should setup only its effective highlights once"
  )
  local symbol_marks = marks(render_buf)
  assert_true(#symbol_marks == 4, "empty symbol style should create three complement dims and one line dim")
  assert_true(
    symbol_marks[1][3] == 0 and symbol_marks[1][4].end_col == 3 and symbol_marks[1][4].hl_group == "TunnelVisionDim",
    "symbol renderer should dim bytes before the first range"
  )
  assert_true(
    symbol_marks[2][3] == 8 and symbol_marks[2][4].end_col == 12,
    "symbol renderer should dim bytes between ranges"
  )
  assert_true(
    symbol_marks[3][3] == 17 and symbol_marks[3][4].end_col == 20,
    "symbol renderer should dim bytes after the last range"
  )
  assert_true(symbol_marks[4][4].line_hl_group == "TunnelVisionDim", "unrelated lines should retain whole-line dimming")
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), {
      { 0, 0, 3, "TunnelVisionDim", nil, 1000 },
      { 0, 8, 12, "TunnelVisionDim", nil, 1000 },
      { 0, 17, 20, "TunnelVisionDim", nil, 1000 },
      { 1, 0, nil, nil, "TunnelVisionDim", 1000 },
    }),
    "empty styles should preserve exact visible geometry: " .. vim.inspect(mark_snapshot(render_buf))
  )

  bs.symbol_ranges = {
    { line = 1, start_col = 3, end_col = 8 },
    { line = 1, start_col = 4, end_col = 6 },
    { line = 1, start_col = 12, end_col = 17 },
  }
  require("tunnelvision.ui").render(render_buf)
  symbol_marks = marks(render_buf)
  assert_true(#symbol_marks == 4, "overlapping symbol ranges should render as one visible interval")
  assert_true(
    symbol_marks[2][3] == 8 and symbol_marks[2][4].end_col == 12,
    "nested symbol ranges should not move complement dimming inside a visible range"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    highlights = {
      scope_head = { fg = 0x111111, bold = true },
      statement = { fg = 0x222222, italic = true },
      line = { fg = 0x333333, bold = false, underline = true },
      symbol = { fg = 0x444444, italic = false, strikethrough = true },
    },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  bs = core.get_buf_state(render_buf)
  bs.scope_head_set = { [1] = true }
  bs.statement_set = { [1] = true }
  ui.clear_render_groups(bs)
  reset_highlight_calls()
  ui.render(render_buf)
  local composed_marks = marks(render_buf)
  assert_true(#composed_marks == 6, "composed whole-line styles should split around two symbol ranges")
  local line_group = composed_marks[1][4].hl_group
  local symbol_group = composed_marks[2][4].hl_group
  local line_hl = vim.api.nvim_get_hl(0, { name = line_group, link = false })
  local symbol_hl = vim.api.nvim_get_hl(0, { name = symbol_group, link = false })
  assert_true(
    line_hl.fg == 0x333333 and line_hl.italic and line_hl.underline,
    "whole-line attributes should compose in order"
  )
  assert_true(not line_hl.bold, "line boolean should override a broader plugin boolean")
  assert_true(
    symbol_hl.fg == 0x444444 and not symbol_hl.italic and symbol_hl.underline and symbol_hl.strikethrough,
    "symbol attributes should override conflicts and inherit other attributes"
  )
  assert_true(composed_marks[4][4].hl_group == symbol_group, "equal effective symbol styles should reuse a group")
  assert_true(mark_priority(composed_marks[1][4]) == 1100, "positive styles should use positive priority")
  assert_true(
    line_group:match("^TunnelVisionHighlight" .. render_buf .. "_"),
    "positive groups should be buffer-specific"
  )
  assert_true(mark_priority(composed_marks[6][4]) == 1000, "dim priority should remain below positive styles")
  local composed_snapshot = mark_snapshot(render_buf)
  assert_true(
    vim.deep_equal(composed_snapshot, {
      { 0, 0, 3, line_group, nil, 1100 },
      { 0, 3, 8, symbol_group, nil, 1100 },
      { 0, 8, 12, line_group, nil, 1100 },
      { 0, 12, 17, symbol_group, nil, 1100 },
      { 0, 17, 20, line_group, nil, 1100 },
      { 1, 0, nil, nil, "TunnelVisionDim", 1000 },
    }),
    "composed styles should preserve exact extmark geometry and order"
  )
  reset_highlight_calls()
  local redefined = false
  vim.api.nvim_set_hl = function(namespace, group, attrs)
    redefined = redefined or group == line_group or group == symbol_group
    return orig_set_hl(namespace, group, attrs)
  end
  ui.render(render_buf)
  vim.api.nvim_set_hl = orig_set_hl
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), composed_snapshot),
    "composed rerender should preserve extmarks"
  )
  assert_true(not redefined, "rerender should not redefine equal existing highlight groups")
  vim.cmd("TunnelVision off")

  local collision_buf = new_buffer({ "first", "other" })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    highlights = {
      scope_head = { fg = "#112233;bg=number:4478310" },
      line = { fg = "#112233", bg = 0x445566 },
    },
  })
  tunnelvision.on()
  local collision_bs = core.get_buf_state(collision_buf)
  collision_bs.symbol_ranges = {}
  collision_bs.statement_set = {}

  local function assert_collision_order(valid_line, invalid_line)
    collision_bs.path_set = { [valid_line] = true }
    collision_bs.scope_head_set = { [invalid_line] = true }
    ui.clear_render_groups(collision_bs)
    ui.render(collision_buf)
    local collision_marks = marks(collision_buf)
    assert_true(#collision_marks == 1, "invalid colliding style should not suppress or reuse the valid group")
    local group = collision_marks[1][4].hl_group
    assert_true(
      vim.deep_equal(mark_snapshot(collision_buf), { { valid_line - 1, 0, 5, group, nil, 1100 } }),
      "colliding styles should preserve the valid extmark in either resolution order: "
        .. vim.inspect(mark_snapshot(collision_buf))
    )
    local attrs = vim.api.nvim_get_hl(0, { name = group, link = false })
    assert_true(
      attrs.fg == 0x112233 and attrs.bg == 0x445566,
      "invalid colliding style should not alter valid attributes"
    )
  end

  assert_collision_order(2, 1)
  assert_collision_order(1, 2)
  vim.cmd("TunnelVision off")
  vim.api.nvim_buf_delete(collision_buf, { force = true })
  vim.api.nvim_set_current_buf(render_buf)

  vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = 0xFF0000, bg_opacity = 0.5, bold = true } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  bs = core.get_buf_state(render_buf)
  local opacity_marks = marks(render_buf)
  assert_true(#opacity_marks == 2, "dim none should retain positive symbol marks")
  local opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x800080,
    "background opacity should blend deterministically against Normal"
  )
  local opacity_snapshot = mark_snapshot(render_buf)
  reset_highlight_calls()
  ui.render(render_buf)
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), opacity_snapshot),
    "repeated opacity style should preserve extmarks"
  )
  assert_true(normal_bg_calls == 1, "opacity styles should share one Normal background lookup per render")

  local opacity_config = bs.config
  local second_buf = new_buffer({ "local alpha = 1", "print(alpha)" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  reset_highlight_calls()
  tunnelvision.on({ highlights = { line = { underline = true } } })
  local second_bs = core.get_buf_state(second_buf)
  local second_config = second_bs.config
  assert_true(not vim.deep_equal(second_config.highlights, core.state.config.highlights), "one-shot rules stay local")

  local resolver = require("tunnelvision.resolver")
  local orig_compute_path = resolver.compute_path
  local compute_calls = 0
  resolver.compute_path = function(...)
    compute_calls = compute_calls + 1
    return orig_compute_path(...)
  end
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x00FF00 })
  reset_highlight_calls()
  local expected_setups = { [false] = 1 }
  for _, state in pairs(core.state.bufs) do
    if state.active and not state.pending then
      expected_setups[state.config] = (expected_setups[state.config] or 0) + 1
    end
  end
  setups = capture_setups(function()
    vim.api.nvim_exec_autocmds("ColorScheme", {})
  end)
  resolver.compute_path = orig_compute_path
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(compute_calls == 0, "ColorScheme should rerender without recomputing sources")
  assert_true(
    bs.config == opacity_config and second_bs.config == second_config,
    "ColorScheme should preserve each active buffer config"
  )
  assert_true(
    vim.deep_equal(setups, expected_setups),
    "ColorScheme should setup global and active configs without extras"
  )
  assert_true(normal_bg_calls == 1, "ColorScheme rerenders should perform one fresh Normal lookup for opacity")
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x808000,
    "ColorScheme should rebuild opacity-derived groups"
  )

  vim.api.nvim_set_current_buf(second_buf)
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  vim.api.nvim_set_current_buf(render_buf)
  vim.api.nvim_buf_delete(second_buf, { force = true })

  vim.api.nvim_set_hl(0, "Normal", {})
  reset_highlight_calls()
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0xFF0000,
    "missing Normal background should safely retain the configured background"
  )
  assert_true(normal_bg_calls == 1, "missing Normal backgrounds should still be looked up only once per render")
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  assert_true(#marks(render_buf) == 0, "deactivation should clear every renderer mark")
  assert_true(
    next(vim.api.nvim_get_hl(0, { name = opacity_group, link = false })) == nil,
    "deactivation should clear buffer-specific highlight definitions"
  )
  vim.cmd("colorscheme default")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = "DefinitelyNotAColor", bg_opacity = 0.5 } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  assert_true(pcall(tunnelvision.on), "invalid positive colors should not abort activation")
  assert_true(#marks(render_buf) == 0, "invalid positive colors should preserve visibility without style marks")
  vim.cmd("TunnelVision off")

  vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = "red", bg_opacity = 0.5 } },
  })
  tunnelvision.on()
  local named_group = marks(render_buf)[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = named_group, link = false }).bg == 0x800080,
    "named background colors should support pseudo-opacity"
  )
  vim.cmd("TunnelVision off")
  vim.cmd("colorscheme default")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    max_dim_lines = 2,
    highlights = { line = { bold = true } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  tunnelvision.on()
  reset_highlight_calls()
  assert_true(
    core.activate(render_buf, { max_dim_lines = 1, symbol = "alpha", cursor = { 1, 4 } }),
    "one-shot max_dim_lines should invalidate same-target rendering"
  )
  assert_true(core.get_buf_state(render_buf).config.max_dim_lines == 1, "one-shot max_dim_lines should normalize")
  local large_marks = marks(render_buf)
  assert_true(#large_marks == 1, "large-buffer dim skipping should retain positive path styles")
  assert_true(large_marks[1][4].hl_group ~= nil, "large-buffer positive style should use a range highlight")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { line = { bold = true } },
  })
  tunnelvision.on()
  local deleted_buf = render_buf
  new_buffer({ "local alpha = 1", "print(alpha)", "local beta = 2" })
  reset_highlight_calls()
  vim.api.nvim_buf_delete(deleted_buf, { force = true })
  assert_true(core.state.bufs[deleted_buf] == nil, "buffer deletion should clear renderer state")
  ui.ensure_highlights = orig_ensure_highlights
  vim.api.nvim_get_hl = orig_get_hl
  vim.api.nvim_set_hl = orig_set_hl
end

-- dim = "none" clears existing marks and skips dim rendering.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on()
  assert_true(#vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) > 0, "default dim should create extmarks")

  tunnelvision.on({ dim = "none" })
  assert_true(
    #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
    "one-shot dim none should clear and skip dim extmarks"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", dim = "none" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on()
  assert_true(
    #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
    "setup dim none should create no dim extmarks"
  )
  vim.cmd("TunnelVision off")
end

-- Tree-sitter source prunes complete out-of-scope subtrees without changing results.
do
  local resolver = require("tunnelvision.resolver")
  local orig_get_parser = vim.treesitter.get_parser
  local orig_get_node_text = vim.treesitter.get_node_text
  local calls

  local function node(name, node_type, range, text, children)
    local result = {
      type = function()
        calls.types[name] = (calls.types[name] or 0) + 1
        return node_type
      end,
      iter_children = function()
        calls.children[name] = (calls.children[name] or 0) + 1
        local index = 0
        return function()
          index = index + 1
          return (children or {})[index]
        end
      end,
      text = text,
    }
    result.range = function()
      calls.ranges[name] = (calls.ranges[name] or 0) + 1
      return unpack(range)
    end
    return result
  end

  local function ranged(name, node_type, start_row, start_col, end_row, end_col, text, children)
    return node(name, node_type, { start_row, start_col, end_row, end_col }, text, children)
  end

  local before_id = ranged("before_id", "identifier", 0, 0, 0, 5, "alpha")
  local exclusive_id = ranged("exclusive_id", "identifier", 1, 0, 1, 5, "alpha")
  local zero_id = ranged("zero_id", "identifier", 2, 0, 2, 5, "alpha")
  local span_start = ranged("span_start", "identifier", 2, 6, 2, 11, "alpha")
  local span_end = ranged("span_end", "identifier", 4, 6, 4, 11, "alpha")
  local intersect_id = ranged("intersect_id", "identifier", 4, 13, 4, 18, "alpha")
  local after_id = ranged("after_id", "identifier", 6, 0, 6, 5, "alpha")
  local ts_root = ranged("root", "chunk", 0, 0, 8, 0, nil, {
    ranged("before", "parent", 0, 0, 1, 5, nil, { before_id }),
    ranged("exclusive", "parent", 0, 0, 2, 0, nil, { exclusive_id }),
    ranged("zero", "parent", 2, 0, 2, 0, nil, { zero_id }),
    ranged("spanning", "parent", 1, 0, 6, 0, nil, { span_start, span_end }),
    ranged("intersecting", "parent", 4, 0, 5, 0, nil, { intersect_id }),
    ranged("after", "parent", 5, 0, 7, 0, nil, { after_id }),
  })
  vim.treesitter.get_parser = function()
    return {
      parse = function()
        return { {
          root = function()
            return ts_root
          end,
        } }
      end,
    }
  end
  vim.treesitter.get_node_text = function(current)
    return current.text
  end
  local prune_buf = new_buffer(vim.fn["repeat"]({ (" "):rep(30) }, 8), "prune-ts")
  local source = { { kind = "single", name = "treesitter" } }
  local function compute(scope)
    calls = { types = {}, ranges = {}, children = {} }
    return resolver.compute_path(prune_buf, "alpha", { row = 2, col = 6 }, scope, {
      direction = "forward",
      keywords = {},
      mode = "static",
      sources = source,
    })
  end

  local path, _, _, ranges = compute({ start_line = 3, end_line = 5 })
  assert_true(vim.deep_equal(path, { [3] = true, [5] = true }), "pruned path: " .. vim.inspect(path))
  assert_ranges(ranges, {
    { line = 3, start_col = 6, end_col = 11 },
    { line = 5, start_col = 6, end_col = 11 },
    { line = 5, start_col = 13, end_col = 18 },
  }, "pruned ranges")
  for _, name in ipairs({ "before_id", "exclusive_id", "zero_id", "after_id" }) do
    assert_true(
      not calls.ranges[name] and not calls.types[name] and not calls.children[name],
      name .. " should not be entered"
    )
  end
  vim.treesitter.get_parser = orig_get_parser
  vim.treesitter.get_node_text = orig_get_node_text
end

print("tunnelvision smoke: OK")
