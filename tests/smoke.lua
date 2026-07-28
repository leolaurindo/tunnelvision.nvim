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
  assert_true(config.format_sources(core.state.config.sources) == "lsp,word", msg .. " sources")
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
assert_sources({ "lsp", "word" }, "default sources")
assert_true(config.format_sources(core.state.config.sources) == "lsp,word", "format_sources default")

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

-- flow_settings defaults
assert_true(core.state.config.flow_settings.direction == "forward", "default flow_settings.direction")
assert_true(vim.deep_equal(core.state.config.flow_settings.extra_keywords, {}), "default flow_settings.extra_keywords")
assert_true(
  vim.deep_equal(core.state.config.flow_settings.analyzers, { "treesitter", "text" }),
  "default flow_settings.analyzers"
)
assert_true(core.state.config.flow_settings.max_depth == nil, "default flow_settings.max_depth")

tunnelvision.setup({ notify = false, flow_settings = { analyzers = { "text" } } })
assert_true(vim.deep_equal(core.state.config.flow_settings.analyzers, { "text" }), "configured flow analyzers")
tunnelvision.setup({ notify = false, flow_settings = { analyzers = { "invalid" } } })
assert_true(
  vim.deep_equal(core.state.config.flow_settings.analyzers, { "treesitter", "text" }),
  "invalid flow analyzers use defaults"
)
tunnelvision.setup({ notify = false })
tunnelvision.setup({ notify = false, flow_settings = { max_depth = 2 } })
assert_true(core.state.config.flow_settings.max_depth == 2, "configured flow max_depth")
tunnelvision.setup({ notify = false, flow_settings = { max_depth = 0 } })
assert_true(core.state.config.flow_settings.max_depth == nil, "invalid flow max_depth")
tunnelvision.setup({ notify = false, flow_settings = { max_depth = 0.5 } })
assert_true(core.state.config.flow_settings.max_depth == nil, "fractional flow max_depth below one")
tunnelvision.setup({ notify = false })

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

-- setup with flow_settings
tunnelvision.setup({ notify = false, flow_settings = { direction = "both", extra_keywords = { "x" } } })
assert_true(core.state.config.flow_settings.direction == "both", "flow_settings.direction from setup")
assert_true(core.state.config.flow_settings.extra_keywords[1] == "x", "flow_settings.extra_keywords from setup")
tunnelvision.setup({ notify = false }) -- restore

-- Deprecated top-level direction maps to flow_settings
tunnelvision.setup({ notify = false, direction = "both" })
assert_true(core.state.config.flow_settings.direction == "both", "deprecated direction maps to flow_settings")
tunnelvision.setup({ notify = false })

-- flow_settings wins over deprecated top-level when both provided
tunnelvision.setup({ notify = false, direction = "forward", flow_settings = { direction = "both" } })
assert_true(
  core.state.config.flow_settings.direction == "both",
  "flow_settings.direction wins over deprecated direction"
)
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

-- add_keywords mutates flow_settings.extra_keywords
tunnelvision.setup({ notify = false })
assert_true(tunnelvision.add_keywords({ "sentinel" }), "add_keywords appends to flow_settings")
assert_true(core.state.config.flow_settings.extra_keywords[1] == "sentinel", "add_keywords stored in flow_settings")
-- Reset: clear extra_keywords for subsequent tests
core.state.config.flow_settings.extra_keywords = {}

-- set_direction updates flow_settings.direction
core.set_direction("both")
assert_true(core.state.config.flow_settings.direction == "both", "set_direction updates flow_settings.direction")
core.set_direction("forward")
assert_true(core.state.config.flow_settings.direction == "forward", "set_direction restores flow_settings.direction")

-- One-shot activation flow_settings works
tunnelvision.setup({ notify = false, mode = "flow", source = "word", scope = "buffer" })
local fs_oneshot_buf = new_buffer({
  "local alpha = 1",
  "local beta = alpha + 1",
  "local gamma = beta + 1",
})
vim.api.nvim_win_set_cursor(0, { 1, 8 })
tunnelvision.on({
  flow_settings = { direction = "both", extra_keywords = { "gamma" } },
})
-- With direction="both" and gamma as keyword, beta should also be tracked
assert_true(
  core.get_buf_state(fs_oneshot_buf).path_set[2],
  "one-shot flow_settings.direction both tracks lhs dependencies"
)
vim.cmd("TunnelVision off")

-- Deprecated one-shot direction still works
vim.api.nvim_win_set_cursor(0, { 1, 8 })
tunnelvision.on({ direction = "both" })
assert_true(core.get_buf_state(fs_oneshot_buf).path_set[2], "deprecated one-shot direction maps to flow_settings")
vim.cmd("TunnelVision off")

-- Deprecated one-shot fields fill missing flow_settings fields
vim.api.nvim_win_set_cursor(0, { 1, 8 })
tunnelvision.on({ direction = "both", flow_settings = { extra_keywords = { "gamma" } } })
assert_true(
  core.get_buf_state(fs_oneshot_buf).config.flow_settings.direction == "both",
  "deprecated one-shot direction fills missing flow_settings.direction"
)
assert_true(
  core.get_buf_state(fs_oneshot_buf).config.flow_settings.extra_keywords[1] == "gamma",
  "one-shot flow_settings.extra_keywords is preserved"
)
vim.cmd("TunnelVision off")

-- flow_settings.direction wins over deprecated direction in one-shot
vim.api.nvim_win_set_cursor(0, { 1, 8 })
tunnelvision.on({ direction = "forward", flow_settings = { direction = "both" } })
assert_true(core.get_buf_state(fs_oneshot_buf).path_set[2], "one-shot flow_settings.direction wins over deprecated")
vim.cmd("TunnelVision off")
assert_true(vim.api.nvim_buf_is_valid(0), "buffer still valid after one-shot tests")
tunnelvision.setup({ notify = false }) -- restore

assert_true(config.format_sources({ { kind = "single", name = "lsp" } }) == "lsp", "format_sources single")
assert_true(
  config.format_sources({ { kind = "combine", names = { "lsp", "word" } } }) == "combine(lsp,word)",
  "format_sources combine"
)
assert_true(
  config.format_sources({ { kind = "combine", names = { "lsp", "word" } }, { kind = "single", name = "word" } })
    == "combine(lsp,word),word",
  "format_sources mixed chain"
)

local source_copy = tunnelvision.get_sources()
source_copy[1] = "word"
assert_sources({ "lsp", "word" }, "get_sources should return a copy")

tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "combine sources")

tunnelvision.setup({ notify = false, source = "word" })
assert_sources({ "word" }, "legacy source should normalize to sources")

assert_true(vim.fn.exists(":TunnelVision") == 2, "missing command: TunnelVision")

local first_buf = new_buffer({
  "local value = 1",
  "local copy = value",
  "value = copy + value",
  "print(value)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- value

vim.cmd("TunnelVision on")
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

-- Treesitter source validation
tunnelvision.setup({ notify = false, sources = { "treesitter" } })
assert_sources({ "treesitter" }, "treesitter source validates")
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for treesitter-only chain")

-- tv.combine("lsp", "treesitter") validates
tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "treesitter") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "treesitter" }, "combine(lsp,treesitter) validates")
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for combine chain with treesitter")

tunnelvision.setup({ notify = false })
for _, sources in ipairs({
  { "treesitter" },
  { "treesitter", "word" },
  { "lsp", "treesitter", "word" },
}) do
  local value = table.concat(sources, ",")
  vim.cmd("TunnelVision source " .. value)
  assert_sources(sources, "command source " .. value)
end
assert_true(tunnelvision.status().sources_label == "lsp,treesitter,word", "status source label shows command value")

-- Restore to known state for subsequent tests
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

-- Combine display via Lua setup
vim.cmd("TunnelVision off")
tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") } })
do
  local msgs = {}
  local orig_notify = core.notify
  core.notify = function(msg)
    msgs[#msgs + 1] = msg
  end
  vim.cmd("TunnelVision status")
  vim.cmd("TunnelVision source")
  core.notify = orig_notify
  assert_true(msgs[1]:find("source=combine%(lsp,word%)"), "status should show combine source label")
  assert_true(msgs[2]:find("combine%(lsp,word%)"), "query source should show combine label")
end
tunnelvision.setup({ notify = false, source = "lsp_else_word" }) -- restore

tunnelvision.set_sources({ "lsp", "word" })
assert_sources({ "lsp", "word" }, "set_sources should update sources")
assert_true(core.get_source() == "lsp_else_word", "set_sources should update legacy source view")
tunnelvision.set_sources({ "word" })
assert_sources({ "word" }, "set_sources word")

-- Legacy source mapping tests
tunnelvision.setup({ notify = false })
assert_true(tunnelvision.get_source() == "lsp_else_word", "default get_source returns lsp_else_word")
tunnelvision.setup({ notify = false, source = "lsp" })
assert_sources({ "lsp" }, "legacy source lsp maps to sources")
assert_true(tunnelvision.get_source() == "lsp", "get_source returns lsp")
tunnelvision.setup({ notify = false, source = "lsp_and_word" })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "legacy source lsp_and_word maps to combine")
assert_true(tunnelvision.get_source() == "lsp_and_word", "get_source returns lsp_and_word")
tunnelvision.setup({ notify = false, source = "word" })
assert_sources({ "word" }, "legacy source word maps to sources")

-- sources wins over source when both are provided
tunnelvision.setup({ notify = false, source = "word", sources = { tunnelvision.combine("lsp", "word") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "sources wins over deprecated source")
assert_true(
  tunnelvision.get_source() == "lsp_and_word",
  "get_source returns legacy for representable chain after sources win"
)

-- get_source returns nil for custom chains that cannot be represented
tunnelvision.set_sources({ tunnelvision.combine("lsp", "word"), "word" })
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for unrepresentable chain")
assert_true(tunnelvision.status().source == nil, "status source returns nil for unrepresentable chain")
assert_true(tunnelvision.status().sources_label == "combine(lsp,word),word", "status sources_label for custom chain")
assert_true(
  core.get_sources_label() == "combine(lsp,word),word",
  "get_sources_label returns global label for custom chain"
)
-- Restore to known state
tunnelvision.setup({ notify = false, source = "lsp_else_word" })
assert_true(tunnelvision.get_source() == "lsp_else_word", "restored to lsp_else_word")

-- No deprecation notification when using legacy source config path
do
  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    notify_calls[#notify_calls + 1] = msg
  end
  tunnelvision.setup({ notify = true, source = "word" })
  for _, msg in ipairs(notify_calls) do
    assert_true(not msg:lower():find("deprecated"), "no deprecation warning for legacy source config: " .. msg)
  end
  vim.notify = orig_notify
end

-- Custom synchronous sources participate in source chains
do
  assert_true(not tunnelvision.register_source("", function() end), "empty custom source name is rejected")
  assert_true(not tunnelvision.register_source("custom_invalid"), "custom source handler must be a function")
  assert_true(not tunnelvision.register_source("lsp", function() end), "built-in source cannot be overridden")
  assert_true(
    not tunnelvision.register_source("lsp_else_word", function() end),
    "legacy source value cannot be overridden"
  )

  tunnelvision.setup({ notify = false, sources = { "custom_missing" } })
  assert_sources({ "lsp", "word" }, "unregistered custom source falls back to default normalization")

  local handler_context
  assert_true(
    tunnelvision.register_source("custom_hit", function(ctx)
      handler_context = ctx
      ctx.anchor.row = 99
      ctx.scope.start_line = 99
      return { [0] = true, [1.5] = true, [2] = true, [999] = true }
    end),
    "custom source registers"
  )
  for name, handler in pairs({
    custom_empty = function()
      return {}
    end,
    custom_without_symbol = function()
      return { [3] = true }
    end,
    custom_error = function()
      error("custom source failure")
    end,
  }) do
    assert_true(tunnelvision.register_source(name, handler), name .. " registers")
  end

  tunnelvision.setup({
    notify = false,
    sources = { "custom_hit" },
    scope = "buffer",
    mode = "flow",
    flow_settings = { direction = "both", extra_keywords = { "sentinel" } },
  })
  local custom_buf = new_buffer({
    "local alpha = 1",
    "local beta = alpha",
    "print(beta)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  local custom_state = core.get_buf_state(custom_buf)
  assert_true(custom_state.path_set[2], "custom source adds valid returned line")
  assert_true(custom_state.path_set[3], "custom source enables flow expansion")
  assert_true(vim.tbl_count(custom_state.path_set) == 3, "custom source flow ignores invalid returned lines")
  assert_ranges(custom_state.symbol_ranges, {
    { line = 1, start_col = 6, end_col = 11 },
    { line = 2, start_col = 6, end_col = 10 },
    { line = 2, start_col = 13, end_col = 18 },
    { line = 3, start_col = 6, end_col = 10 },
  }, "custom source should retain source ranges and add flow ranges")
  assert_true(custom_state.anchor.row == 0 and custom_state.scope.start_line == 1, "custom context is isolated")
  assert_true(handler_context.bufnr == custom_buf and handler_context.symbol == "alpha", "custom context identity")
  assert_true(handler_context.mode == "flow" and handler_context.direction == "both", "custom context mode")
  assert_true(handler_context.keywords.sentinel, "custom context keywords")
  assert_true(handler_context.get_treesitter == nil, "custom sources should not receive internal activation context")
  vim.cmd("TunnelVision off")

  for _, case in ipairs({
    { sources = { "custom_without_symbol" }, mode = "static", present = { 3 }, ranges = {} },
    { sources = { "custom_hit", "word" }, present = { 2, 3 } },
    { sources = { "custom_empty", "word" }, present = { 3 }, used_source = "word" },
    { sources = { "custom_error", "word" }, present = { 3 } },
    { sources = { tunnelvision.combine("custom_hit", "word") }, present = { 2, 3 } },
  }) do
    tunnelvision.on({ sources = case.sources, scope = "buffer", mode = case.mode })
    local bs = core.get_buf_state(custom_buf)
    for _, lnum in ipairs(case.present) do
      assert_true(bs.path_set[lnum], "custom source should include line " .. lnum)
    end
    for _, lnum in ipairs(case.absent or {}) do
      assert_true(not bs.path_set[lnum], "custom source should exclude line " .. lnum)
    end
    if case.ranges then
      assert_ranges(bs.symbol_ranges, case.ranges, "range-less custom result")
    end
    if case.used_source then
      assert_true(bs.last_compute_meta.used_source == case.used_source, "custom fallback metadata")
    end
    vim.cmd("TunnelVision off")
  end

  tunnelvision.on({ sources = { tunnelvision.combine("custom_empty", "word") }, scope = "buffer" })
  assert_true(
    not core.get_buf_state(custom_buf).path_set[3],
    "failed custom combine does not flow-expand member word lines"
  )
  assert_true(core.get_buf_state(custom_buf).last_compute_meta.used_source == nil, "failed source does not run flow")
  vim.cmd("TunnelVision off")

  tunnelvision.on({
    sources = { tunnelvision.combine("custom_empty", "word"), "word" },
    scope = "buffer",
  })
  assert_true(core.get_buf_state(custom_buf).path_set[3], "word fallback after failed custom combine expands flow")
  vim.cmd("TunnelVision off")

  tunnelvision.on({
    sources = { tunnelvision.combine("custom_empty", "word"), "custom_hit" },
    scope = "buffer",
  })
  local failed_combine_state = core.get_buf_state(custom_buf)
  assert_true(failed_combine_state.path_set[2], "failed custom combine uses later source")
  assert_true(failed_combine_state.path_set[3], "later custom source independently enables flow")
  assert_ranges(failed_combine_state.symbol_ranges, {
    { line = 1, start_col = 6, end_col = 11 },
    { line = 2, start_col = 6, end_col = 10 },
    { line = 2, start_col = 13, end_col = 18 },
    { line = 3, start_col = 6, end_col = 10 },
  }, "failed combine should retain only later source and flow ranges")
  assert_true(
    failed_combine_state.last_compute_meta.fallback_source == "custom_empty",
    "custom combine failure metadata"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  assert_true(
    tunnelvision.register_source("custom_late", function()
      return { [2] = true }
    end),
    "custom source registers after setup"
  )
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on({ sources = { "custom_late" } })
  assert_true(core.get_buf_state(custom_buf).path_set[2], "late custom source works as one-shot override")
  assert_sources({ "word" }, "one-shot late custom source does not change global sources")
  vim.cmd("TunnelVision off")

  tunnelvision.set_sources({ "custom_late" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  assert_true(core.get_buf_state(custom_buf).path_set[2], "late custom source works with set_sources")
  vim.cmd("TunnelVision off")
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

tunnelvision.on({ sources = { "word" } })
assert_true(core.get_buf_state(one_shot_buf).path_set[3], "one-shot sources should override activation sources")
assert_sources({ "lsp" }, "one-shot sources should not mutate global sources")
assert_true(
  core.get_buf_state(one_shot_buf).config.sources[1].name == "word",
  "active buffer should keep one-shot sources override"
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
tunnelvision.setup({
  notify = false,
  source = "word",
  mode = "flow",
  scope = "buffer",
  flow_settings = { extra_keywords = { "sentinel" } },
})
vim.api.nvim_win_set_cursor(0, { 1, 8 })
vim.cmd("TunnelVision on")
assert_true(
  not core.get_buf_state(flow_keywords_buf).path_set[3],
  "flow_settings.extra_keywords should stop propagation through ignored identifiers"
)

vim.cmd("TunnelVision off")
tunnelvision.setup({
  notify = false,
  source = "word",
  mode = "flow",
  scope = "buffer",
  extra_keywords = { "sentinel" },
})
vim.api.nvim_win_set_cursor(0, { 1, 8 })
vim.cmd("TunnelVision on")
assert_true(
  not core.get_buf_state(flow_keywords_buf).path_set[3],
  "deprecated extra_keywords should stop propagation through ignored identifiers"
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
  local lsp_path, _, lsp_meta, lsp_ranges = resolver.compute_path(flow_range_buf, "alpha", { row = 0, col = 6 }, {
    start_line = 1,
    end_line = 3,
  }, {
    direction = "forward",
    keywords = {},
    lsp_result = resolver.make_lsp_result("ok", { [1] = true }, true, {
      { line = 1, start_col = 6, end_col = 11 },
    }),
    mode = "flow",
    sources = { { kind = "single", name = "lsp" } },
  })
  assert_true(lsp_meta.used_source == "lsp" and lsp_path[3], "LSP-only source should enable flow expansion")
  assert_ranges(lsp_ranges, {
    { line = 1, start_col = 6, end_col = 11 },
    { line = 2, start_col = 6, end_col = 10 },
    { line = 2, start_col = 13, end_col = 18 },
    { line = 3, start_col = 6, end_col = 11 },
    { line = 3, start_col = 14, end_col = 18 },
  }, "LSP-only flow should preserve source ranges and add propagated ranges")

  local failed_path, _, failed_meta, failed_ranges = resolver.compute_path(
    flow_range_buf,
    "alpha",
    { row = 0, col = 6 },
    { start_line = 1, end_line = 3 },
    {
      direction = "forward",
      keywords = {},
      lsp_result = resolver.make_lsp_result("request_failed"),
      mode = "flow",
      sources = { { kind = "single", name = "lsp" } },
    }
  )
  assert_true(failed_meta.used_source == nil, "failed strict source should remain unselected")
  assert_true(
    failed_path[1] and not failed_path[2] and not failed_path[3],
    "failed strict source should keep only anchor"
  )
  assert_ranges(failed_ranges, {}, "failed strict source should not create flow ranges")

  local flow = require("tunnelvision.flow")
  local analysis = flow.analyze_text({
    anchor = { row = 0, col = 6 },
    bufnr = flow_range_buf,
    keywords = resolver.build_keywords({}),
    scope = { start_line = 1, end_line = 3 },
    symbol = "alpha",
  })
  assert_true(#analysis.assignments == 3, "text analyzer should collect assignments")
  assert_ranges(analysis.assignments[2].lhs, {
    { name = "beta", line = 2, start_col = 6, end_col = 10 },
  }, "text analyzer should retain exact LHS token ranges")
  assert_ranges(analysis.assignments[2].rhs, {
    { name = "alpha", line = 2, start_col = 13, end_col = 18 },
  }, "text analyzer should retain exact RHS token ranges")
  assert_ranges(analysis.occurrences.alpha, {
    { name = "alpha", line = 1, start_col = 6, end_col = 11 },
    { name = "alpha", line = 2, start_col = 13, end_col = 18 },
  }, "text analyzer should retain exact occurrence ranges")

  local typed_buf = new_buffer({ "local alpha: alpha = source" })
  local typed_analysis = flow.analyze_text({
    anchor = { row = 0, col = 6 },
    bufnr = typed_buf,
    keywords = resolver.build_keywords({}),
    scope = { start_line = 1, end_line = 1 },
    symbol = "alpha",
  })
  assert_ranges(typed_analysis.assignments[1].lhs, {
    { name = "alpha", line = 1, start_col = 6, end_col = 11 },
  }, "text analyzer should use the declared identifier range")

  local expanded_path, expanded_ranges = { [1] = true }, {}
  local tracked = flow.expand(expanded_path, expanded_ranges, "alpha", analysis, "forward")
  assert_true(tracked.gamma and expanded_path[3], "flow module should expand analyzer results")
  assert_true(#expanded_ranges == 5, "flow module should add every tracked occurrence range")

  local function token(name, start_col, end_col)
    return { name = name, line = 1, start_col = start_col, end_col = end_col }
  end
  local alpha, beta, gamma = token("alpha", 0, 5), token("beta", 8, 12), token("gamma", 15, 20)
  local same_line = {
    assignments = {
      { line = 1, lhs = { beta }, rhs = { alpha } },
      { line = 1, lhs = { gamma }, rhs = { beta } },
    },
    occurrences = { alpha = { alpha }, beta = { beta }, gamma = { gamma } },
  }
  local same_line_tracked = flow.expand({}, {}, "alpha", same_line, "forward")
  assert_true(same_line_tracked.gamma, "flow interface should retain multiple assignments on one line")

  local text_cases_buf = new_buffer({
    "let first = source",
    "const typed: number = first",
    "var third = typed",
    "short := third",
    "short += first",
    "local left, right = short, third",
    "obj.field = source",
    "items[index] = source",
  })
  local text_cases = flow.analyze_text({
    anchor = { row = 0, col = 4 },
    bufnr = text_cases_buf,
    keywords = resolver.build_keywords({}),
    scope = { start_line = 1, end_line = 8 },
    symbol = "first",
  })
  assert_true(#text_cases.assignments == 6, "text analyzer should skip complex assignment targets")
  assert_ranges(text_cases.assignments[1].lhs, {
    { name = "first", line = 1, start_col = 4, end_col = 9 },
  }, "text analyzer should parse let declarations")
  assert_ranges(text_cases.assignments[2].lhs, {
    { name = "typed", line = 2, start_col = 6, end_col = 11 },
  }, "text analyzer should parse typed const declarations")
  assert_ranges(text_cases.assignments[3].lhs, {
    { name = "third", line = 3, start_col = 4, end_col = 9 },
  }, "text analyzer should parse var declarations")
  assert_ranges(text_cases.assignments[4].lhs, {
    { name = "short", line = 4, start_col = 0, end_col = 5 },
  }, "text analyzer should parse short declarations")
  assert_ranges(text_cases.assignments[5].rhs, {
    { name = "first", line = 5, start_col = 9, end_col = 14 },
    { name = "short", line = 5, start_col = 0, end_col = 5 },
  }, "compound assignment should retain RHS and LHS ranges")
  assert_ranges(text_cases.assignments[6].lhs, {
    { name = "left", line = 6, start_col = 6, end_col = 10 },
    { name = "right", line = 6, start_col = 12, end_col = 17 },
  }, "text analyzer should retain multiple LHS ranges")

  local c_style_buf =
    new_buffer({ "int value = source", "value -= source", "value *= source", "value /= source", "value %= source" })
  local c_style = flow.analyze_text({
    anchor = { row = 0, col = 4 },
    bufnr = c_style_buf,
    keywords = resolver.build_keywords({}),
    scope = { start_line = 1, end_line = 5 },
    symbol = "value",
  })
  assert_ranges(c_style.assignments[1].lhs, {
    { name = "value", line = 1, start_col = 4, end_col = 9 },
  }, "text analyzer should preserve simple C-style declarations")
  for i = 2, 5 do
    assert_true(c_style.assignments[i].rhs[2].name == "value", "compound operators should depend on their LHS")
  end

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
  tunnelvision.on({ flow_settings = { analyzers = { "text" } } })
  local text_state = core.get_buf_state(analyzer_buf)
  assert_true(text_state.path_set[3], "text-only analyzer should preserve flow behavior")
  local flow_status = tunnelvision.status()
  assert_true(
    flow_status.flow_analyzer == "text"
      and flow_status.flow_expanded
      and flow_status.flow_tracked_count == 2
      and flow_status.flow_added_lines == 1,
    "status should expose flow analyzer and expansion counts"
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
  local guarded_analysis = flow.analyze_text({
    anchor = { row = #guarded_lines - 1, col = 0 },
    bufnr = guarded_buf,
    keywords = resolver.build_keywords({}),
    scope = { start_line = 1, end_line = #guarded_lines },
    symbol = "v0",
  })
  local guarded_path = { [#guarded_lines] = true }
  local guarded_tracked = flow.expand(guarded_path, {}, "v0", guarded_analysis, "forward")
  assert_true(guarded_tracked.v32 and not guarded_tracked.v33, "default flow should preserve the 32-hop guard")
  assert_true(not guarded_path[1], "identifiers beyond the hard guard should remain hidden")
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
  local expected_path = { [1] = true, [2] = true, [3] = true }
  local expected_order = { 1, 2, 3 }
  local expected_ranges = {
    { line = 1, start_col = 6, end_col = 11 },
    { line = 2, start_col = 6, end_col = 10 },
    { line = 2, start_col = 13, end_col = 18 },
    { line = 3, start_col = 6, end_col = 11 },
    { line = 3, start_col = 14, end_col = 18 },
  }
  local scans = 0
  local collect_word_matches = resolver.collect_word_matches
  resolver.collect_word_matches = function(...)
    scans = scans + 1
    return collect_word_matches(...)
  end

  local function compute(sources, extra)
    return resolver.compute_path(
      flow_buf,
      "alpha",
      anchor,
      scope,
      vim.tbl_extend("force", {
        analyzers = { "text" },
        custom_sources = {
          custom_empty = function()
            return {}
          end,
          custom_flow = function()
            return { [1] = true }
          end,
        },
        direction = "forward",
        keywords = resolver.build_keywords({}),
        lsp_result = resolver.make_lsp_result("ok", { [1] = true }, true, {
          { line = 1, start_col = 6, end_col = 11 },
        }),
        mode = "flow",
        sources = sources,
      }, extra or {})
    )
  end

  local function assert_flow_result(sources, used_source, used, added_lines, msg)
    scans = 0
    local path, order, meta, ranges = compute(sources)
    assert_true(scans == 0, msg .. " should not scan word")
    assert_true(vim.deep_equal(path, expected_path), msg .. " path: " .. vim.inspect(path))
    assert_true(vim.deep_equal(order, expected_order), msg .. " order: " .. vim.inspect(order))
    assert_ranges(ranges, expected_ranges, msg .. " ranges")
    assert_true(
      vim.deep_equal(meta, {
        failed_sources = {},
        fallback_source = nil,
        used_lsp = used.lsp or false,
        used_custom = used.custom or false,
        used_word = false,
        used_fallback = false,
        fallback_reason = nil,
        used_source = used_source,
        flow_analyzers = { "text" },
        flow_analyzer = "text",
        flow_fallback = false,
        flow_expanded = true,
        flow_tracked_count = 3,
        flow_added_lines = added_lines,
      }),
      msg .. " metadata: " .. vim.inspect(meta)
    )
  end

  assert_flow_result({ { kind = "single", name = "lsp" }, { kind = "single", name = "word" } }, "lsp", {
    lsp = true,
  }, 2, "LSP flow winner")
  assert_flow_result({ { kind = "single", name = "custom_flow" }, { kind = "single", name = "word" } }, "custom_flow", {
    custom = true,
  }, 2, "custom flow winner")
  assert_flow_result({
    { kind = "combine", names = { "lsp", "custom_flow" } },
    { kind = "single", name = "word" },
  }, "combine(lsp,custom_flow)", { lsp = true, custom = true }, 2, "combined flow winner")

  local orig_get_parser = vim.treesitter.get_parser
  local orig_get_node_text = vim.treesitter.get_node_text
  local function node(node_type, row, start_col, end_col, text, children)
    return {
      type = function()
        return node_type
      end,
      range = function()
        return row, start_col, row, end_col
      end,
      iter_children = function()
        local index = 0
        return function()
          index = index + 1
          return (children or {})[index]
        end
      end,
      text = text,
    }
  end
  local ts_root = node("chunk", 0, 0, 18, nil, {
    node("identifier", 0, 6, 11, "alpha"),
    node("identifier", 1, 13, 18, "alpha"),
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
  assert_flow_result(
    { { kind = "single", name = "treesitter" }, { kind = "single", name = "word" } },
    "treesitter",
    {},
    1,
    "Tree-sitter flow winner"
  )
  vim.treesitter.get_parser = orig_get_parser
  vim.treesitter.get_node_text = orig_get_node_text

  scans = 0
  local failed_path, failed_order, failed_meta, failed_ranges = compute({
    { kind = "combine", names = { "word", "custom_empty" } },
  })
  assert_true(scans == 1, "failed strict combine should scan word once")
  assert_true(vim.deep_equal(failed_path, { [1] = true }), "failed strict combine should keep only the anchor")
  assert_true(vim.deep_equal(failed_order, { 1 }), "failed strict combine order should keep only the anchor")
  assert_ranges(failed_ranges, {}, "failed strict combine should not leak word ranges")
  assert_true(
    failed_meta.used_source == nil
      and failed_meta.fallback_source == "custom_empty"
      and failed_meta.failed_sources[1] == "combine(word,custom_empty)"
      and not failed_meta.used_word,
    "failed strict combine should not leak word metadata"
  )

  scans = 0
  local repeated_path, repeated_order, repeated_meta, repeated_ranges = compute({
    { kind = "combine", names = { "word", "custom_empty" } },
    { kind = "single", name = "word" },
  })
  assert_true(scans == 1, "repeated word references should share one activation scan")
  assert_true(vim.deep_equal(repeated_path, expected_path), "cached word fallback should preserve flow path")
  assert_true(vim.deep_equal(repeated_order, expected_order), "cached word fallback should preserve flow order")
  assert_ranges(repeated_ranges, expected_ranges, "cached word fallback should preserve flow ranges")
  assert_true(
    repeated_meta.used_source == "word"
      and repeated_meta.used_word
      and repeated_meta.used_fallback
      and repeated_meta.fallback_source == "custom_empty"
      and repeated_meta.flow_analyzer == "text"
      and repeated_meta.flow_tracked_count == 3,
    "cached word fallback should preserve source and flow metadata"
  )

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
  local reads = {}
  vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
    if bufnr == cache_buf then
      reads[#reads + 1] = { first, last }
    end
    return original_get_lines(bufnr, first, last, strict)
  end

  local path, order, meta, ranges = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
    analyzers = { "text" },
    direction = "forward",
    keywords = resolver.build_keywords({}),
    mode = "flow",
    sources = { { kind = "single", name = "word" } },
  })
  assert_true(vim.deep_equal(reads, { { 1, 5 } }), "word and text flow should share one scoped line read")
  assert_true(vim.deep_equal(path, { [2] = true, [4] = true, [5] = true }), "cached flow path")
  assert_true(vim.deep_equal(order, { 2, 4, 5 }), "cached flow order")
  assert_ranges(ranges, {
    { line = 2, start_col = 6, end_col = 11 },
    { line = 4, start_col = 6, end_col = 10 },
    { line = 4, start_col = 13, end_col = 18 },
    { line = 5, start_col = 6, end_col = 10 },
  }, "cached flow ranges")
  assert_true(
    vim.deep_equal(meta, {
      failed_sources = {},
      fallback_source = nil,
      used_lsp = false,
      used_custom = false,
      used_word = true,
      used_fallback = false,
      fallback_reason = nil,
      used_source = "word",
      flow_analyzers = { "text" },
      flow_analyzer = "text",
      flow_fallback = false,
      flow_expanded = true,
      flow_tracked_count = 2,
      flow_added_lines = 1,
    }),
    "cached flow metadata: " .. vim.inspect(meta)
  )

  reads = {}
  local custom_source = function()
    return { [2] = true, [3] = true, [5] = true }
  end
  path, order, meta, ranges = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
    custom_sources = { custom_cache = custom_source },
    direction = "forward",
    keywords = {},
    mode = "static",
    sources = { { kind = "single", name = "custom_cache" } },
  })
  assert_true(vim.deep_equal(reads, { { 1, 3 }, { 4, 5 } }), "custom lines should read contiguous touched ranges")
  assert_true(vim.deep_equal(path, { [2] = true, [3] = true, [5] = true }), "cached custom path")
  assert_true(vim.deep_equal(order, { 2, 3, 5 }), "cached custom order")
  assert_ranges(ranges, {
    { line = 2, start_col = 6, end_col = 11 },
  }, "cached custom ranges should preserve empty lines")
  assert_true(
    meta.used_source == "custom_cache" and meta.used_custom and not meta.used_word and not meta.used_lsp,
    "cached custom metadata"
  )

  reads = {}
  local _, _, _, _, pending = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
    custom_sources = { custom_cache = custom_source },
    direction = "forward",
    keywords = {},
    mode = "static",
    pause_for_lsp = true,
    sources = { { kind = "combine", names = { "custom_cache", "lsp" } } },
  })
  assert_true(pending ~= nil, "cache invalidation test should suspend for LSP")
  assert_true(vim.deep_equal(reads, { { 1, 3 }, { 4, 5 } }), "suspended custom source read ranges")
  assert_true(vim.deep_equal(pending.get_lines(2, 3), { "local alpha = 1", "" }), "cache should retain empty lines")
  assert_true(#reads == 2, "cached suspended lines should not be fetched again")
  vim.api.nvim_buf_set_lines(cache_buf, 2, 3, false, { "alpha" })
  assert_true(
    vim.deep_equal(pending.get_lines(2, 3), { "local alpha = 1", "alpha" }),
    "changedtick should invalidate cached contents"
  )
  assert_true(vim.deep_equal(reads[3], { 1, 3 }), "changedtick invalidation should refetch the requested range")

  path, order, meta, ranges = resolver.compute_path(cache_buf, "alpha", anchor, scope, {
    lsp_result = resolver.make_lsp_result("ok", { [3] = true }, true, {
      { line = 3, start_col = 0, end_col = 99 },
    }),
    resolution_context = pending,
  })
  assert_true(vim.deep_equal(path, { [2] = true, [3] = true, [5] = true }), "resumed cached path")
  assert_true(vim.deep_equal(order, { 2, 3, 5 }), "resumed cached order")
  assert_ranges(ranges, {
    { line = 2, start_col = 6, end_col = 11 },
    { line = 3, start_col = 0, end_col = 5 },
  }, "resumed changedtick ranges")
  assert_true(
    meta.used_source == "combine(custom_cache,lsp)" and meta.used_custom and meta.used_lsp,
    "resumed cached metadata"
  )
  assert_true(#reads == 3, "resumed final normalization should reuse changedtick-valid lines")
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
      cancellations[#cancellations + 1] = { client_id = cancel_client.id, handle = handle }
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
  local direct_reads = {}
  local direct_result
  local original_get_lines = vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
    if bufnr == lsp_buf then
      direct_reads[#direct_reads + 1] = { first, last }
    end
    return original_get_lines(bufnr, first, last, strict)
  end
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
  vim.api.nvim_buf_get_lines = original_get_lines
  assert_true(direct_result and direct_result.used, "five-argument LSP request callback should remain compatible")
  assert_ranges(direct_result.ranges, {
    { line = 3, start_col = 0, end_col = 5 },
  }, "direct LSP request ranges")
  assert_true(
    vim.deep_equal(direct_reads, { { 1, 2 }, { 2, 3 } }),
    "direct LSP normalization should read only anchor and result lines: " .. vim.inspect(direct_reads)
  )

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
  assert_true(
    bs.context == nil and bs.parser == nil and bs.tree == nil and bs.root == nil,
    "pending buffer state should not expose resolver context objects"
  )
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

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 2, 6 })
  vim.cmd("TunnelVision on")
  bs = core.get_buf_state(lsp_buf)
  local old_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
  assert_true(#old_marks > 0, "word render should create dim extmarks")
  bs.last_compute_meta = { flow_analyzer = "text", flow_expanded = true, flow_tracked_count = 2 }

  tunnelvision.setup({ notify = false, scope = "buffer", lsp_timeout_ms = 1000 })
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
  assert_true(vim.tbl_count(bs.request_handles) == 3, "all asynchronous requests should remain cancellable")
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
  local orig_ensure_highlights = ui.ensure_highlights
  local orig_set_hl = vim.api.nvim_set_hl
  local pending_setup_configs = {}
  local pending_set_hl_calls = 0
  local pending_groups = vim.deepcopy(bs.render_groups)
  local pending_config = bs.config
  ui.ensure_highlights = function(cfg)
    pending_setup_configs[#pending_setup_configs + 1] = cfg or false
    return orig_ensure_highlights(cfg)
  end
  vim.api.nvim_set_hl = function(...)
    pending_set_hl_calls = pending_set_hl_calls + 1
    return orig_set_hl(...)
  end
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  ui.ensure_highlights = orig_ensure_highlights
  vim.api.nvim_set_hl = orig_set_hl
  assert_true(
    vim.deep_equal(vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true }), old_marks),
    "ColorScheme should preserve retained extmarks while LSP is pending"
  )
  assert_true(
    #pending_setup_configs == 1 and pending_setup_configs[1] == false,
    "pending ColorScheme should setup only the global highlight"
  )
  assert_true(pending_set_hl_calls == 1, "pending ColorScheme should define only the global dim highlight")
  assert_true(bs.config == pending_config, "pending ColorScheme should preserve pending config")
  assert_true(vim.deep_equal(bs.render_groups, pending_groups), "pending ColorScheme should preserve render groups")

  fake_clients[1].offset_encoding = "utf-16"
  respond(batch[1], {
    { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } },
  })
  assert_true(bs.pending, "partial LSP results should wait for remaining clients")
  assert_true(vim.tbl_count(bs.request_handles) == 2, "completed requests should stop being cancellable")
  respond(batch[4], {
    { range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 7 } } },
  })
  respond(batch[2], {
    { range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 8 } } },
    { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } },
  })
  fake_clients[1].offset_encoding = "utf-8"
  assert_true(not bs.pending and next(bs.request_handles) == nil, "terminal responses should clear pending handles")
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
  local cancellation_cursor = #cancellations
  timeout()
  assert_true(
    #cancellations == cancellation_cursor + 1
      and cancellations[#cancellations].client_id == 2
      and cancellations[#cancellations].handle == batch[2].handle,
    "partial timeout should cancel only unresolved supported clients"
  )
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
  assert_true(not bs.pending and fallback_meta.used_source == "word", "total errors should use fallback chain")
  assert_true(
    fallback_meta.failed_sources[1] == "lsp"
      and fallback_meta.fallback_source == "lsp"
      and fallback_meta.fallback_reason == "request_failed"
      and fallback_meta.used_fallback,
    "total errors should preserve fallback metadata"
  )

  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  batch, timeout = take_batch()
  local total_timeout_handles = { [batch[1].handle] = true, [batch[2].handle] = true }
  cancellation_cursor = #cancellations
  sync_cancel_callbacks = true
  timeout()
  sync_cancel_callbacks = false
  assert_true(
    #cancellations == cancellation_cursor + 2
      and total_timeout_handles[cancellations[cancellation_cursor + 1].handle]
      and total_timeout_handles[cancellations[cancellation_cursor + 2].handle]
      and cancellations[cancellation_cursor + 1].handle ~= cancellations[cancellation_cursor + 2].handle,
    "total timeout should cancel all unresolved supported clients"
  )
  assert_true(not bs.pending, "total timeout should resolve pending state")
  assert_true(bs.last_compute_meta.used_source == "word", "reentrant timeout responses should not prevent fallback")

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
  assert_true(vim.tbl_count(bs.request_handles) == 2, "only asynchronous requests should remain cancellable")
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
  cancellation_cursor = #cancellations
  sync_cancel_callbacks = true
  core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
  sync_cancel_callbacks = false
  local current_batch = take_batch()
  local current_request_id = bs.request_id
  assert_true(current_request_id ~= stale_request_id, "supersession should replace the request ID")
  assert_true(
    #cancellations == cancellation_cursor + 1
      and cancellations[#cancellations].client_id == 2
      and cancellations[#cancellations].handle == stale_batch[2].handle,
    "supersession should cancel only incomplete cancellable clients"
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
  cancellation_cursor = #cancellations
  sync_cancel_callbacks = true
  vim.cmd("TunnelVision off")
  sync_cancel_callbacks = false
  assert_true(#cancellations == cancellation_cursor + 2, "deactivation should cancel all supported pending clients")
  assert_true(next(bs.request_handles) == nil, "deactivation should clear retained request handles")
  for _, request in pairs(batch) do
    respond(request, {})
  end
  assert_true(not bs.active and not bs.pending, "late callbacks after deactivation should remain stale")

  local deleted_buf = new_buffer({ "local alpha = 1", "print(alpha)" })
  core.activate(deleted_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 6 } })
  batch = take_batch()
  respond(batch[4], {})
  cancellation_cursor = #cancellations
  sync_cancel_callbacks = true
  vim.api.nvim_buf_delete(deleted_buf, { force = true })
  sync_cancel_callbacks = false
  assert_true(
    #cancellations == cancellation_cursor + 2,
    ("buffer deletion should cancel supported pending clients: expected 2, got %d"):format(
      #cancellations - cancellation_cursor
    )
  )
  assert_true(core.state.bufs[deleted_buf] == nil, "buffer deletion should clear request state")
  for _, request in pairs(batch) do
    respond(request, {})
  end
  assert_true(core.state.bufs[deleted_buf] == nil, "late callbacks after buffer deletion should remain stale")

  vim.defer_fn = orig_defer_fn
  restore_clients()
end

-- Fallback metadata and warnings remain stable when LSP is unavailable
do
  local messages = {}
  local orig_notify = core.notify
  core.notify = function(msg)
    messages[#messages + 1] = msg
  end

  tunnelvision.setup({ notify = true, source = "lsp_else_word", fallback_warn = "once", scope = "buffer" })
  local fallback_buf = new_buffer({
    "local alpha = 1",
    "print(alpha)",
  }, "plaintext")
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")

  local fallback_meta = core.get_buf_state(fallback_buf).last_compute_meta
  assert_true(fallback_meta.used_source == "word", "fallback metadata records selected word source")
  assert_true(fallback_meta.failed_sources[1] == "lsp", "fallback metadata records failed lsp source")
  assert_true(fallback_meta.fallback_source == "lsp", "fallback metadata records failure source")
  assert_true(fallback_meta.used_fallback, "fallback metadata marks fallback use")
  assert_true(messages[1] and messages[1]:find("falling back to word matching"), "default fallback warning")

  core.activate(fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 7 } })
  assert_true(#messages == 1, "fallback_warn once only warns once per buffer")

  vim.cmd("TunnelVision off")
  messages = {}
  tunnelvision.setup({ notify = true, source = "word", scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#messages == 0, "successful first source does not warn")

  vim.cmd("TunnelVision off")
  tunnelvision.setup({ notify = true, source = "lsp", scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")

  local strict_meta = core.get_buf_state(fallback_buf).last_compute_meta
  assert_true(strict_meta.used_source == nil, "strict lsp metadata has no selected source")
  assert_true(strict_meta.failed_sources[1] == "lsp", "strict lsp metadata records failed source")
  assert_true(messages[1] and messages[1]:find("strict LSP source"), "strict lsp warning")

  vim.cmd("TunnelVision off")
  core.notify = orig_notify
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

-- Structural walking uses exact columns and conservative statement boundaries.
do
  new_buffer({ "alpha(", "  value", ")" })
  local context = require("tunnelvision.context")
  local cfg = { highlights = { statement = {} } }
  local path_set = { [1] = true }
  local symbol_ranges = { { line = 1, start_col = 3, end_col = 8 } }
  local scope = { start_line = 1, end_line = 3 }
  local orig_get_parser = vim.treesitter.get_parser
  local seen_col

  local function id(value)
    return function()
      return value
    end
  end

  local function stub_parser(descendant)
    vim.treesitter.get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return { named_descendant_for_range = descendant }
              end,
            },
          }
        end,
      }
    end
  end

  local statement_node = {
    id = id(1),
    type = function()
      return "expression_statement"
    end,
    range = function()
      return 0, 0, 2, 0
    end,
    parent = function()
      return nil
    end,
  }
  stub_parser(function(_, _, col)
    seen_col = col
    return statement_node
  end)
  local statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(seen_col == 3, "structural lookup should use the exact source byte column")
  assert_true(vim.deep_equal(statements, { [1] = true, [2] = true }), "column-zero end rows should stay exclusive")
  assert_true(not fallback.statement, "safe statement resolution should not report fallback")

  local chunk_node = {
    id = id(2),
    type = function()
      return "chunk"
    end,
    parent = function()
      return nil
    end,
  }
  local call_node = {
    id = id(3),
    type = function()
      return "function_call"
    end,
    range = function()
      return 0, 0, 2, 0
    end,
    parent = function()
      return chunk_node
    end,
  }
  stub_parser(function()
    return call_node
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(vim.deep_equal(statements, { [1] = true, [2] = true }), "standalone Lua calls should be statements")
  assert_true(not fallback.statement, "standalone Lua calls should not report structural fallback")

  local assignment_node = {
    id = id(4),
    type = function()
      return "assignment_statement"
    end,
    range = function()
      return 0, 0, 2, 0
    end,
    parent = function()
      return nil
    end,
  }
  local expression_list = {
    id = id(5),
    type = function()
      return "expression_list"
    end,
    parent = function()
      return assignment_node
    end,
  }
  call_node.parent = function()
    return expression_list
  end
  stub_parser(function()
    return call_node
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(vim.deep_equal(statements, { [1] = true, [2] = true }), "nested Lua calls should defer to assignments")
  assert_true(not fallback.statement, "nested Lua calls inside assignments should resolve structurally")

  local parameters_node = {
    id = id(6),
    type = function()
      return "parameters"
    end,
    parent = function()
      return nil
    end,
  }
  for _, node_type in ipairs({ "typed_default_parameter", "parameter_declaration" }) do
    local parameter_node = {
      id = id(7),
      type = function()
        return node_type
      end,
      range = function()
        return 0, 0, 0, 8
      end,
      parent = function()
        return parameters_node
      end,
    }
    stub_parser(function()
      return parameter_node
    end)
    statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
    assert_true(vim.deep_equal(statements, { [1] = true }), node_type .. " should resolve as a parameter declaration")
    assert_true(not fallback.statement, node_type .. " should not report structural fallback")
  end

  local bare_parameter = {
    id = id(8),
    type = function()
      return "identifier"
    end,
    range = function()
      return 0, 0, 0, 5
    end,
    parent = function()
      return parameters_node
    end,
  }
  stub_parser(function()
    return bare_parameter
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(
    vim.deep_equal(statements, { [1] = true }),
    "bare parameters should resolve without broadening signatures"
  )
  assert_true(not fallback.statement, "bare parameters should not report structural fallback")

  local arguments_node = {
    id = id(9),
    type = function()
      return "arguments"
    end,
    parent = function()
      return nil
    end,
  }
  bare_parameter.parent = function()
    return arguments_node
  end
  stub_parser(function()
    return bare_parameter
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(vim.deep_equal(statements, path_set), "call arguments should not be classified as parameters")
  assert_true(fallback.statement, "unresolved call arguments should retain structural fallback")

  local broad_node = {
    id = id(10),
    type = function()
      return "try_statement"
    end,
    parent = function()
      return nil
    end,
  }
  stub_parser(function()
    return broad_node
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  assert_true(vim.deep_equal(statements, path_set), "unknown statement containers should fall back to matched lines")
  assert_true(fallback.statement, "conservative statement rejection should report fallback")

  vim.treesitter.get_parser = orig_get_parser
end

-- Structural evaluation reuses duplicate and shared ancestor work within one call.
do
  local context = require("tunnelvision.context")
  local buf = new_buffer({ "function", "if", "alpha", "alpha", "other", "missing" })

  local function evaluate(highlights, selected_ranges)
    local calls = { descendant = 0, parent = 0, range = 0, start = 0, type = 0 }
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
        calls.type = calls.type + 1
        return definition.type
      end
      current.parent = function()
        calls.parent = calls.parent + 1
        return definition.parent and node(definition.parent)
      end
      current.range = function()
        calls.range = calls.range + 1
        return definition.row, 0, definition.row == 2 and 4 or definition.row, 0
      end
      current.start = function()
        calls.start = calls.start + 1
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
    return statements, scope_heads, fallback, calls, path, ranges
  end

  local statements, scope_heads, fallback, calls, path, ranges = evaluate({ statement = {}, scope_head = {} })
  assert_true(vim.deep_equal(statements, { [3] = true, [4] = true, [6] = true }), "cached statement set")
  assert_true(vim.deep_equal(scope_heads, { [2] = true }), "cached and clipped scope-head set")
  assert_true(vim.deep_equal(fallback, { statement = true, scope_head = false }), "cached fallback metadata")
  assert_true(vim.deep_equal(path, { [3] = true, [4] = true, [6] = true }), "context should not alter navigation")
  assert_true(#ranges == 4, "context should not alter navigation ranges")
  assert_true(calls.descendant == 3, "duplicate positions should share one node lookup")
  assert_true(
    calls.parent == 7 and calls.type == 7 and calls.range == 1 and calls.start == 2,
    "stable node ids should reuse wrapper parent, type, range, and scope-head work: " .. vim.inspect(calls)
  )

  local shared_ranges = { { line = 3, start_col = 1 }, { line = 4, start_col = 2 } }
  statements, scope_heads, fallback, calls = evaluate({ statement = {} }, shared_ranges)
  assert_true(vim.deep_equal(statements, { [3] = true, [4] = true }), "statement-only exact set")
  assert_true(
    next(scope_heads) == nil and not fallback.statement and not fallback.scope_head,
    "statement-only fallback"
  )
  assert_true(calls.parent == 3 and calls.type == 3 and calls.range == 1 and calls.start == 0, "statement-only work")

  statements, scope_heads, fallback, calls = evaluate({ scope_head = {} }, shared_ranges)
  assert_true(next(statements) == nil and vim.deep_equal(scope_heads, { [2] = true }), "scope-head-only exact sets")
  assert_true(not fallback.statement and not fallback.scope_head, "scope-head-only fallback")
  assert_true(calls.parent == 6 and calls.type == 6 and calls.range == 0 and calls.start == 2, "scope-head-only work")

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
  local orig_notify = core.notify
  core.notify = function(msg)
    messages[#messages + 1] = msg
  end

  tunnelvision.setup({
    notify = true,
    source = "word",
    scope = "buffer",
    fallback_warn = "once",
    highlights = { statement = true, scope_head = true },
  })
  local structural_fallback_buf = new_buffer({ "alpha = 1", "print(alpha)" }, "plaintext")
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tunnelvision.on()
  local bs = core.get_buf_state(structural_fallback_buf)
  assert_true(vim.deep_equal(bs.statement_set, bs.path_set), "missing parser should fall back to every matched line")
  assert_true(next(bs.scope_head_set) == nil, "missing parser should skip scope heads")
  assert_true(messages[1] and messages[1]:find("using matched lines"), "statement fallback should warn")
  assert_true(messages[2] and messages[2]:find("skipping scope heads"), "scope-head fallback should warn")

  core.activate(structural_fallback_buf, {
    force = true,
    silent = false,
    symbol = "alpha",
    cursor = { 1, 1 },
  })
  assert_true(#messages == 2, "structural fallback warnings should only repeat when configured")
  vim.cmd("TunnelVision off")

  messages = {}
  tunnelvision.setup({
    notify = true,
    source = "word",
    scope = "buffer",
    fallback_warn = "always",
    highlights = { statement = true, scope_head = true },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tunnelvision.on()
  core.activate(structural_fallback_buf, {
    force = true,
    silent = false,
    symbol = "alpha",
    cursor = { 1, 1 },
  })
  assert_true(#messages == 4, "fallback_warn always should repeat both structural warnings")
  vim.cmd("TunnelVision off")

  messages = {}
  tunnelvision.setup({
    notify = true,
    source = "word",
    scope = "buffer",
    fallback_warn = "never",
    highlights = { statement = true, scope_head = true },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tunnelvision.on()
  assert_true(#messages == 0, "fallback_warn never should silence structural warnings")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    fallback_warn = "always",
    highlights = { statement = true, scope_head = true },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tunnelvision.on()
  assert_true(#messages == 0, "notify false should silence structural fallback warnings")
  vim.cmd("TunnelVision off")
  core.notify = orig_notify
end

-- === Dim API cleanup tests ===

-- Restore to baseline before dim form tests
tunnelvision.setup({ notify = false })

-- dim = nil uses Comment-derived default
tunnelvision.setup({ notify = false, dim = nil })
local nil_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
assert_true(nil_hl and comment_hl and nil_hl.fg == comment_hl.fg, "dim = nil should derive from Comment fg")

-- dim = "Comment" copies resolved attrs
tunnelvision.setup({ notify = false, dim = "Comment" })
local group_copy_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(group_copy_hl and group_copy_hl.fg == comment_hl.fg, "dim = 'Comment' should copy Comment fg")
assert_true(group_copy_hl and group_copy_hl.link == nil, "dim = 'Comment' should use copy semantics, not link")

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

-- deprecated dim_hl still works
vim.api.nvim_set_hl(0, "CustomDimGroup", { fg = 0x998877 })
tunnelvision.setup({ notify = false, dim_hl = "CustomDimGroup" })
assert_true(core.state.config.dim_hl == "CustomDimGroup", "deprecated dim_hl should set config.dim_hl")
tunnelvision.setup({ notify = false }) -- restore

-- dim plus dim_hl together works
vim.api.nvim_set_hl(0, "DimGroupBoth", { fg = 0x112233 })
tunnelvision.setup({ notify = false, dim = { fg = 0xAABBCC }, dim_hl = "DimGroupBoth" })
local both_hl = vim.api.nvim_get_hl(0, { name = "DimGroupBoth", link = false })
assert_true(both_hl and both_hl.fg == 0xAABBCC, "dim + dim_hl: dim should apply to dim_hl group")
tunnelvision.setup({ notify = false }) -- restore

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

-- one-shot dim = { fg = ... } works (also tested above, explicit here)
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = { fg = "#BB55DD", italic = true } })
local oneshot_table_fg = 0xBB55DD
local oneshot_table_hl =
  vim.api.nvim_get_hl(0, { name = core.get_buf_state(oneshot_hex_buf).config.dim_hl, link = false })
assert_true(oneshot_table_hl and oneshot_table_hl.fg == oneshot_table_fg, "one-shot dim = { fg = ... } should set fg")
vim.cmd("TunnelVision off")

-- deprecated one-shot dim_hl still works
vim.api.nvim_set_hl(0, "OneShotCompatDim", { fg = 0x336699 })
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim_hl = "OneShotCompatDim" })
assert_true(
  core.get_buf_state(oneshot_hex_buf).config.dim_hl == "OneShotCompatDim",
  "one-shot dim_hl should set active buffer dim group"
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

tunnelvision.setup({ notify = false, dim = "DefinitelyMissingTunnelVisionDimGroup" })
local invalid_group_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(
  invalid_group_hl and invalid_group_hl.fg == comment_hl.fg,
  "invalid dim group should fall back to Comment-derived fg"
)
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
local cs_hex_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(cs_hex_hl and cs_hex_hl.fg == 0x778899, "colorscheme refresh should preserve dim = '#778899'")

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
  local orig_deepcopy = vim.deepcopy
  local orig_get_hl = vim.api.nvim_get_hl
  local orig_set_hl = vim.api.nvim_set_hl
  local deepcopy_calls = 0
  local normal_bg_calls = 0
  local setup_configs = {}
  local set_hl_calls = {}
  local style_deepcopy_calls = 0
  local deepcopy_depth = 0
  local function reset_highlight_calls()
    deepcopy_calls = 0
    normal_bg_calls = 0
    setup_configs = {}
    set_hl_calls = {}
    style_deepcopy_calls = 0
  end
  ui.ensure_highlights = function(cfg)
    setup_configs[#setup_configs + 1] = cfg or false
    return orig_ensure_highlights(cfg)
  end
  vim.deepcopy = function(value, ...)
    -- Neovim 0.9 recurses through vim.deepcopy; count only calls made by the plugin.
    local top_level = deepcopy_depth == 0
    deepcopy_depth = deepcopy_depth + 1
    if top_level then
      deepcopy_calls = deepcopy_calls + 1
      if
        type(value) == "table"
        and (
          value.fg ~= nil
          or value.bg ~= nil
          or value.bold ~= nil
          or value.italic ~= nil
          or value.underline ~= nil
          or value.undercurl ~= nil
          or value.strikethrough ~= nil
          or value.bg_opacity ~= nil
        )
      then
        style_deepcopy_calls = style_deepcopy_calls + 1
      end
    end
    local copy = orig_deepcopy(value, ...)
    deepcopy_depth = deepcopy_depth - 1
    return copy
  end
  vim.api.nvim_get_hl = function(namespace, opts)
    if opts.name == "Normal" then
      normal_bg_calls = normal_bg_calls + 1
    end
    return orig_get_hl(namespace, opts)
  end
  vim.api.nvim_set_hl = function(_, group, attrs)
    set_hl_calls[#set_hl_calls + 1] = { group, attrs }
    return orig_set_hl(0, group, attrs)
  end

  local function positive_set_hl_calls()
    local count = 0
    for _, call in ipairs(set_hl_calls) do
      if call[1]:match("^TunnelVisionHighlight") then
        count = count + 1
      end
    end
    return count
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
  local bs = core.get_buf_state(render_buf)
  assert_true(
    #setup_configs == 1 and setup_configs[1] == bs.config,
    "ordinary default render should setup its highlights once"
  )
  assert_true(#set_hl_calls == 1, "ordinary default render should define one dim highlight")
  local default_snapshot = mark_snapshot(render_buf)
  assert_true(#default_snapshot == 1, "default renderer should add only the unrelated-line dim mark")
  assert_true(default_snapshot[1][5] == "TunnelVisionDim", "default renderer should use line dimming")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  reset_highlight_calls()
  ui.render(render_buf)
  local symbol_marks = marks(render_buf)
  assert_true(#symbol_marks == 4, "empty symbol style should create three complement dims and one line dim")
  assert_true(deepcopy_calls == 3, "repeated empty styles should resolve once after range normalization")
  assert_true(positive_set_hl_calls() == 0, "empty styles should not define positive groups")
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

  bs = core.get_buf_state(render_buf)
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
  assert_true(
    #setup_configs == 1 and setup_configs[1] == bs.config,
    "custom-rules render should setup its composed config once"
  )
  bs.scope_head_set = { [1] = true }
  bs.statement_set = { [1] = true }
  ui.clear_render_groups(bs)
  reset_highlight_calls()
  ui.render(render_buf)
  assert_true(
    #setup_configs == 1 and setup_configs[1] == bs.config,
    "composed custom-rules rerender should setup its config once"
  )
  local composed_marks = marks(render_buf)
  assert_true(#composed_marks == 6, "composed whole-line styles should split around two symbol ranges")
  local line_group = composed_marks[1][4].hl_group
  local symbol_group = composed_marks[2][4].hl_group
  assert_true(deepcopy_calls == 4 and style_deepcopy_calls == 2, "each composed effective style should resolve once")
  assert_true(positive_set_hl_calls() == 2, "each new composed effective style should define one group")
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
  ui.render(render_buf)
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), composed_snapshot),
    "composed rerender should preserve extmarks"
  )
  assert_true(deepcopy_calls == 4 and style_deepcopy_calls == 2, "rerender should retain bounded style resolution")
  assert_true(positive_set_hl_calls() == 0, "rerender should reuse groups for their valid buffer lifetime")
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
  assert_true(
    #setup_configs == 1 and setup_configs[1] == bs.config,
    "opacity render should run highlight setup once even with dim disabled"
  )
  assert_true(#set_hl_calls == 1, "opacity render should define one reusable positive group")
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
  assert_true(
    deepcopy_calls == 3 and style_deepcopy_calls == 1,
    "repeated raw styles should deepcopy and resolve only once per render"
  )
  assert_true(normal_bg_calls == 1, "opacity styles should share one Normal background lookup per render")
  assert_true(positive_set_hl_calls() == 0, "opacity rerender should reuse its existing render group")

  local opacity_config = bs.config
  local second_buf = new_buffer({ "local alpha = 1", "print(alpha)" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  reset_highlight_calls()
  tunnelvision.on({ highlights = { line = { underline = true } } })
  local second_bs = core.get_buf_state(second_buf)
  local second_config = second_bs.config
  assert_true(
    #setup_configs == 1
      and setup_configs[1] == second_config
      and not vim.deep_equal(second_config.highlights, core.state.config.highlights),
    "one-shot highlight-rules config should setup exactly once"
  )

  local resolver = require("tunnelvision.resolver")
  local orig_compute_path = resolver.compute_path
  local compute_calls = 0
  resolver.compute_path = function(...)
    compute_calls = compute_calls + 1
    return orig_compute_path(...)
  end
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x00FF00 })
  reset_highlight_calls()
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  resolver.compute_path = orig_compute_path
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(compute_calls == 0, "ColorScheme should rerender without recomputing sources")
  local rendered_configs = { [opacity_config] = 0, [second_config] = 0 }
  for i = 2, #setup_configs do
    rendered_configs[setup_configs[i]] = (rendered_configs[setup_configs[i]] or 0) + 1
  end
  assert_true(
    #setup_configs == 3
      and setup_configs[1] == false
      and rendered_configs[opacity_config] == 1
      and rendered_configs[second_config] == 1,
    "ColorScheme should setup the base once and each active buffer config once"
  )
  assert_true(
    bs.config == opacity_config and second_bs.config == second_config,
    "ColorScheme should preserve each active buffer config"
  )
  assert_true(#set_hl_calls == 4, "ColorScheme should clear and rebuild both buffers' groups")
  assert_true(normal_bg_calls == 1, "ColorScheme rerenders should perform one fresh Normal lookup for opacity")
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x808000,
    "ColorScheme should rebuild opacity-derived groups"
  )

  vim.api.nvim_set_current_buf(second_buf)
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  assert_true(#setup_configs == 0 and #set_hl_calls == 1, "second-buffer cleanup should only clear its group")
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
  assert_true(#setup_configs == 2, "fallback opacity ColorScheme should retain one setup per rerender")
  assert_true(#set_hl_calls == 2, "fallback opacity ColorScheme should clear and rebuild its group")
  assert_true(normal_bg_calls == 1, "missing Normal backgrounds should still be looked up only once per render")
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  assert_true(#marks(render_buf) == 0, "deactivation should clear every renderer mark")
  assert_true(
    next(vim.api.nvim_get_hl(0, { name = opacity_group, link = false })) == nil,
    "deactivation should clear buffer-specific highlight definitions"
  )
  assert_true(#setup_configs == 0, "deactivation should not setup highlights")
  assert_true(#set_hl_calls == 1, "deactivation should clear its buffer-specific group once")
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
  bs = core.get_buf_state(render_buf)
  assert_true(
    #setup_configs == 1 and setup_configs[1] == bs.config,
    "one-shot config rerender should setup highlights once"
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
  assert_true(#setup_configs == 0, "buffer deletion should not setup highlights")
  assert_true(#set_hl_calls == 1, "buffer deletion should clear its buffer-specific group once")

  ui.ensure_highlights = orig_ensure_highlights
  vim.deepcopy = orig_deepcopy
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
  local expected_meta = {
    failed_sources = {},
    fallback_source = nil,
    used_lsp = false,
    used_custom = false,
    used_word = false,
    used_fallback = false,
    fallback_reason = nil,
    used_source = "treesitter",
  }
  local function compute(scope)
    calls = { types = {}, ranges = {}, children = {} }
    return resolver.compute_path(prune_buf, "alpha", { row = 2, col = 6 }, scope, {
      direction = "forward",
      keywords = {},
      mode = "static",
      sources = source,
    })
  end

  local path, order, meta, ranges = compute({ start_line = 3, end_line = 5 })
  assert_true(vim.deep_equal(path, { [3] = true, [5] = true }), "pruned path: " .. vim.inspect(path))
  assert_true(vim.deep_equal(order, { 3, 5 }), "pruned order: " .. vim.inspect(order))
  assert_true(vim.deep_equal(meta, expected_meta), "pruned metadata: " .. vim.inspect(meta))
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
  for _, name in ipairs({ "before", "exclusive", "zero", "after" }) do
    assert_true(calls.ranges[name] == 1 and not calls.children[name], name .. " subtree should be pruned")
  end
  for _, name in ipairs({ "spanning", "intersecting" }) do
    assert_true(calls.children[name] == 1, name .. " subtree should be traversed")
  end
  for _, name in ipairs({ "span_start", "span_end", "intersect_id" }) do
    assert_true(calls.ranges[name] == 1 and calls.children[name] == 1, name .. " should be fully visited")
  end

  path, order, meta, ranges = compute({ start_line = 1, end_line = 8 })
  assert_true(
    vim.deep_equal(path, { [1] = true, [2] = true, [3] = true, [5] = true, [7] = true }),
    "buffer path: " .. vim.inspect(path)
  )
  assert_true(vim.deep_equal(order, { 1, 2, 3, 5, 7 }), "buffer order: " .. vim.inspect(order))
  assert_true(vim.deep_equal(meta, expected_meta), "buffer metadata: " .. vim.inspect(meta))
  assert_ranges(ranges, {
    { line = 1, start_col = 0, end_col = 5 },
    { line = 2, start_col = 0, end_col = 5 },
    { line = 3, start_col = 0, end_col = 5 },
    { line = 3, start_col = 6, end_col = 11 },
    { line = 5, start_col = 6, end_col = 11 },
    { line = 5, start_col = 13, end_col = 18 },
    { line = 7, start_col = 0, end_col = 5 },
  }, "buffer ranges")
  for _, name in ipairs({ "before", "exclusive", "zero", "spanning", "intersecting", "after" }) do
    assert_true(calls.ranges[name] == 1 and calls.children[name] == 1, name .. " should be traversed in buffer scope")
  end

  vim.treesitter.get_parser = function()
    error("parser unavailable")
  end
  local fail_path, fail_order, fail_meta, fail_ranges = resolver.compute_path(
    prune_buf,
    "alpha",
    { row = 2, col = 6 },
    {
      start_line = 3,
      end_line = 5,
    },
    {
      direction = "forward",
      keywords = {},
      mode = "static",
      sources = source,
    }
  )
  assert_true(vim.deep_equal(fail_path, { [3] = true }), "unavailable parser path")
  assert_true(vim.deep_equal(fail_order, { 3 }), "unavailable parser order")
  assert_ranges(fail_ranges, {}, "unavailable parser ranges")
  assert_true(
    vim.deep_equal(fail_meta, {
      failed_sources = { "treesitter" },
      fallback_source = "treesitter",
      used_lsp = false,
      used_custom = false,
      used_word = false,
      used_fallback = false,
      fallback_reason = "unavailable",
      used_source = nil,
    }),
    "unavailable parser metadata: " .. vim.inspect(fail_meta)
  )

  vim.treesitter.get_parser = orig_get_parser
  vim.treesitter.get_node_text = orig_get_node_text
end

print("tunnelvision smoke: OK")
