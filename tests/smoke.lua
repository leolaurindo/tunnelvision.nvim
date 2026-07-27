local function fail(msg)
  error("[tunnelvision smoke] " .. msg)
end

local function assert_true(cond, msg)
  if not cond then
    fail(msg)
  end
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

local function assert_default_visual_config(msg)
  assert_true(config.format_sources(core.state.config.sources) == "lsp,word", msg .. " sources")
  assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), msg .. " highlights")
  assert_true(core.state.config.dim == nil, msg .. " dim")
end

tunnelvision.setup()
assert_default_visual_config("bare setup")
tunnelvision.setup({})
assert_default_visual_config("empty setup")
tunnelvision.setup({ source = "lsp_else_word" })
assert_default_visual_config("legacy default source setup")
tunnelvision.setup({ sources = { "lsp", "word" } })
assert_default_visual_config("modern default sources setup")

tunnelvision.setup({ notify = false })
assert_sources({ "lsp", "word" }, "default sources")
assert_true(config.format_sources(core.state.config.sources) == "lsp,word", "format_sources default")

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
vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "local beta = alpha + 1",
  "local gamma = beta + 1",
})
local fs_oneshot_buf = vim.api.nvim_get_current_buf()
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

vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local value = 1",
  "local copy = value",
  "value = copy + value",
  "print(value)",
})
local first_buf = vim.api.nvim_get_current_buf()
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

vim.cmd("TunnelVision mode static")
assert_true(core.get_mode() == "static", "mode static not applied")
vim.cmd("TunnelVision mode flow")
assert_true(core.get_mode() == "flow", "mode flow not applied")
vim.cmd("TunnelVision mode dynamic")
assert_true(core.get_mode() == "dynamic", "mode dynamic not applied")
vim.cmd("TunnelVision mode static")
assert_true(core.get_mode() == "static", "mode static restore failed")

vim.cmd("TunnelVision direction both")
assert_true(core.get_direction() == "both", "direction both not applied")
vim.cmd("TunnelVision direction forward")
assert_true(core.get_direction() == "forward", "direction forward not applied")

assert_true(core.get_scope() == "function", "default scope should be function")
vim.cmd("TunnelVision scope buffer")
assert_true(core.get_scope() == "buffer", "scope buffer not applied")
vim.cmd("TunnelVision scope function")
assert_true(core.get_scope() == "function", "scope function not applied")

vim.cmd("TunnelVision source lsp_else_word")
assert_true(core.get_source() == "lsp_else_word", "source lsp_else_word not applied")
vim.cmd("TunnelVision source lsp")
assert_true(core.get_source() == "lsp", "source lsp not applied")
vim.cmd("TunnelVision source lsp_and_word")
assert_true(core.get_source() == "lsp_and_word", "source lsp_and_word not applied")
vim.cmd("TunnelVision source word")
assert_true(core.get_source() == "word", "source word not applied")

-- Fallback-chain command syntax
vim.cmd("TunnelVision source lsp,word")
assert_sources({ "lsp", "word" }, "comma-separated fallback chain lsp,word")

-- Treesitter source validation
tunnelvision.setup({ notify = false, sources = { "treesitter" } })
assert_sources({ "treesitter" }, "treesitter source validates")
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for treesitter-only chain")

tunnelvision.setup({ notify = false, sources = { "treesitter", "word" } })
assert_sources({ "treesitter", "word" }, "treesitter,word sources validates")
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for treesitter,word chain")

tunnelvision.setup({ notify = false, sources = { "lsp", "treesitter", "word" } })
assert_sources({ "lsp", "treesitter", "word" }, "lsp,treesitter,word sources validates")

-- tv.combine("lsp", "treesitter") validates
tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "treesitter") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "treesitter" }, "combine(lsp,treesitter) validates")
assert_true(tunnelvision.get_source() == nil, "get_source returns nil for combine chain with treesitter")

-- :TunnelVision source treesitter works
tunnelvision.setup({ notify = false })
vim.cmd("TunnelVision source treesitter")
assert_sources({ "treesitter" }, "command source treesitter")
assert_true(tunnelvision.status().sources_label == "treesitter", "status source label shows treesitter")

-- :TunnelVision source treesitter,word works
vim.cmd("TunnelVision source treesitter,word")
assert_sources({ "treesitter", "word" }, "command source treesitter,word")

vim.cmd("TunnelVision source lsp,treesitter,word")
assert_sources({ "lsp", "treesitter", "word" }, "command source lsp,treesitter,word")

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
  assert_true(
    tunnelvision.register_source("custom_empty", function()
      return {}
    end),
    "empty custom source registers"
  )
  assert_true(
    tunnelvision.register_source("custom_without_symbol", function()
      return { [3] = true }
    end),
    "custom source without symbol registers"
  )
  assert_true(
    tunnelvision.register_source("custom_error", function()
      error("custom source failure")
    end),
    "erroring custom source registers"
  )

  tunnelvision.setup({
    notify = false,
    sources = { "custom_hit" },
    scope = "buffer",
    mode = "flow",
    flow_settings = { direction = "both", extra_keywords = { "sentinel" } },
  })
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "local beta = alpha",
    "print(beta)",
  })
  local custom_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  local custom_state = core.get_buf_state(custom_buf)
  assert_true(custom_state.path_set[2], "custom source adds valid returned line")
  assert_true(not custom_state.path_set[3], "custom source does not add unrelated word line")
  assert_true(vim.tbl_count(custom_state.path_set) == 2, "custom source ignores invalid lines")
  assert_ranges(custom_state.symbol_ranges, {
    { line = 2, start_col = 13, end_col = 18 },
  }, "custom source should derive symbol ranges only on selected matching lines")
  assert_true(custom_state.anchor.row == 0 and custom_state.scope.start_line == 1, "custom context is isolated")
  assert_true(handler_context.bufnr == custom_buf and handler_context.symbol == "alpha", "custom context identity")
  assert_true(handler_context.mode == "flow" and handler_context.direction == "both", "custom context mode")
  assert_true(handler_context.keywords.sentinel, "custom context keywords")
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { "custom_without_symbol" }, scope = "buffer", mode = "static" })
  assert_true(core.get_buf_state(custom_buf).path_set[3], "custom source may select a line without the symbol")
  assert_ranges(
    core.get_buf_state(custom_buf).symbol_ranges,
    {},
    "custom-selected lines without the active symbol should have no range"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { "custom_hit", "word" }, scope = "buffer" })
  assert_true(core.get_buf_state(custom_buf).path_set[2], "successful custom source wins before word fallback")
  assert_true(
    not core.get_buf_state(custom_buf).path_set[3],
    "unused word fallback does not flow-expand successful custom source"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { "custom_empty", "word" }, scope = "buffer" })
  assert_true(core.get_buf_state(custom_buf).path_set[3], "empty custom source falls back to word")
  assert_true(core.get_buf_state(custom_buf).last_compute_meta.used_source == "word", "custom fallback metadata")
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { "custom_error", "word" }, scope = "buffer" })
  assert_true(core.get_buf_state(custom_buf).path_set[3], "erroring custom source falls back without crashing")
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { tunnelvision.combine("custom_hit", "word") }, scope = "buffer" })
  assert_true(core.get_buf_state(custom_buf).path_set[2], "combined custom source includes custom lines")
  assert_true(core.get_buf_state(custom_buf).path_set[3], "combined custom source includes word lines")
  vim.cmd("TunnelVision off")

  tunnelvision.on({ sources = { tunnelvision.combine("custom_empty", "word") }, scope = "buffer" })
  assert_true(
    not core.get_buf_state(custom_buf).path_set[3],
    "failed custom combine does not flow-expand member word lines"
  )
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
  assert_true(not failed_combine_state.path_set[3], "failed custom combine does not leak partial word lines")
  assert_ranges(failed_combine_state.symbol_ranges, {
    { line = 2, start_col = 13, end_col = 18 },
  }, "failed combine should not leak partial member ranges")
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
vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "local beta = 2",
  "print(alpha)",
})
local one_shot_buf = vim.api.nvim_get_current_buf()
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
vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "local sentinel = alpha + 1",
  "local result = sentinel + 1",
})
local flow_keywords_buf = vim.api.nvim_get_current_buf()

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
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "alpha + alpha_ + alpha -- alpha",
    '"alpha" .. alpha',
    "é alpha alpha",
  })
  local range_buf = vim.api.nvim_get_current_buf()
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
end

-- Flow adds propagated identifiers while static mode retains only source ranges.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "local beta = alpha",
    "local gamma = beta",
  })
  local flow_range_buf = vim.api.nvim_get_current_buf()
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
end

vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "local beta = alpha + 1",
  "local gamma = beta + 1",
})
local dynamic_buf = vim.api.nvim_get_current_buf()
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

if vim.lsp.buf_request_all then
  local fake_clients = {
    { id = 1, offset_encoding = "utf-8", server_capabilities = { documentHighlightProvider = true } },
    { id = 2, offset_encoding = "utf-16", server_capabilities = { documentHighlightProvider = true } },
  }
  local callbacks = {}
  local restore_clients
  local orig_buf_request_all = vim.lsp.buf_request_all
  local orig_get_client_by_id = vim.lsp.get_client_by_id

  vim.lsp.get_client_by_id = function(id)
    return fake_clients[id]
  end

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

  vim.lsp.buf_request_all = function(_, _, _, cb)
    callbacks[#callbacks + 1] = cb
  end

  tunnelvision.setup({ notify = false, source = "word" })
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "local beta = alpha + 1",
    "print(beta)",
  })
  local lsp_buf = vim.api.nvim_get_current_buf()

  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  local old_marks = #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {})
  assert_true(old_marks > 0, "word render should create dim extmarks")

  tunnelvision.setup({ notify = false, sources = { "lsp", "word" }, lsp_timeout_ms = 1000 })
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  assert_true(core.get_buf_state(lsp_buf).pending, "async LSP activation should be pending")
  assert_true(
    #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == old_marks,
    "pending render should keep previous dim extmarks"
  )

  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#callbacks == 2, "expected two async LSP requests")

  callbacks[1]({
    [1] = {
      result = {
        { range = { start = { line = 0 }, ["end"] = { line = 0 } } },
      },
    },
  })
  assert_true(core.get_buf_state(lsp_buf).pending, "stale LSP response should be ignored")
  assert_true(core.get_buf_state(lsp_buf).symbol == "alpha", "stale response should not retarget symbol")

  local notify_calls = 0
  local orig_notify = core.notify
  core.notify = function()
    notify_calls = notify_calls + 1
  end
  callbacks[2]({
    [1] = {
      result = {
        { range = { start = { line = 0 }, ["end"] = { line = 1 } } },
      },
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "current LSP response should resolve pending state")
  assert_true(core.get_buf_state(lsp_buf).path_set[2], "resolved LSP response should update path")
  assert_true(core.get_buf_state(lsp_buf).last_compute_meta.used_source == "lsp", "first lsp source selected")
  assert_true(not core.get_buf_state(lsp_buf).last_compute_meta.used_fallback, "first lsp source is not fallback")
  assert_true(notify_calls == 0, "successful first lsp source does not warn")
  core.notify = orig_notify

  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  callbacks[3]({
    [1] = {
      err = { code = -1, message = "boom" },
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "error response should resolve pending state")
  assert_true(core.get_buf_state(lsp_buf).path_set[2], "error response should fallback to word matching")

  tunnelvision.setup({ notify = false, sources = { "lsp" }, lsp_timeout_ms = 1000 })
  vim.cmd("TunnelVision off")
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#callbacks == 4, "expected strict lsp async request")
  callbacks[4]({
    [1] = {
      err = { code = -1, message = "boom" },
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "strict lsp error should resolve pending state")
  assert_true(not core.get_buf_state(lsp_buf).path_set[3], "strict lsp source should not fallback to word")

  tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") }, lsp_timeout_ms = 1000 })
  vim.cmd("TunnelVision off")
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#callbacks == 5, "expected combined source async request")
  callbacks[5]({
    [1] = {
      result = {
        { range = { start = { line = 0 }, ["end"] = { line = 0 } } },
      },
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "combined source should resolve pending state")
  assert_true(core.get_buf_state(lsp_buf).path_set[1], "combined source should include lsp lines")
  assert_true(core.get_buf_state(lsp_buf).path_set[3], "combined source should include word lines")

  vim.cmd("TunnelVision off")
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#callbacks == 6, "expected combined source empty lsp request")
  callbacks[6]({
    [1] = {
      result = {},
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "empty combined source should resolve pending state")
  assert_true(core.get_buf_state(lsp_buf).path_set[2], "empty combined source should keep anchor line")
  assert_true(not core.get_buf_state(lsp_buf).path_set[3], "empty combined source should not fallback to word")
  assert_true(
    core.get_buf_state(lsp_buf).last_compute_meta.fallback_reason == "no_matches",
    "empty lsp result records no_matches"
  )
  assert_true(
    core.get_buf_state(lsp_buf).last_compute_meta.fallback_source == "lsp",
    "empty lsp result records failed member"
  )

  tunnelvision.setup({
    notify = false,
    sources = { tunnelvision.combine("lsp", "treesitter"), "word" },
    lsp_timeout_ms = 1000,
  })
  vim.cmd("TunnelVision off")
  vim.bo.filetype = "plaintext"
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd("TunnelVision on")
  assert_true(#callbacks == 7, "expected combined source request for later-member failure")
  callbacks[7]({
    [1] = {
      result = {
        { range = { start = { line = 1 }, ["end"] = { line = 1 } } },
      },
    },
  })
  local combined_later_meta = core.get_buf_state(lsp_buf).last_compute_meta
  assert_true(combined_later_meta.used_source == "word", "later combined failure falls back to word")
  assert_true(combined_later_meta.fallback_source == "treesitter", "later combined failure records member")
  assert_true(combined_later_meta.failed_sources[1] == "combine(lsp,treesitter)", "later combined failure records step")

  tunnelvision.setup({ notify = false, source = "lsp", scope = "buffer", lsp_timeout_ms = 1000 })
  vim.cmd("TunnelVision off")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "é alpha alpha" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.cmd("TunnelVision on")
  callbacks[8]({
    [1] = {
      result = {
        { range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 8 } } },
      },
    },
    [2] = {
      result = {
        { range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 7 } } },
        { range = { start = { line = 0, character = 8 }, ["end"] = { line = 0, character = 13 } } },
      },
    },
  })
  assert_ranges(core.get_buf_state(lsp_buf).symbol_ranges, {
    { line = 1, start_col = 3, end_col = 8 },
    { line = 1, start_col = 9, end_col = 14 },
  }, "LSP ranges should convert each client's encoding to deduplicated byte columns")

  vim.lsp.buf_request_all = orig_buf_request_all
  vim.lsp.get_client_by_id = orig_get_client_by_id
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
  vim.cmd("enew")
  vim.bo.filetype = "plaintext"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "print(alpha)",
  })
  local fallback_buf = vim.api.nvim_get_current_buf()
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
vim.cmd("enew")
vim.bo.filetype = "plaintext"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "local beta = 2",
  "print(alpha)",
})
local ts_fb_buf = vim.api.nvim_get_current_buf()
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
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "local beta = 2",
    "print(alpha)",
  })

  local ok_parser, parser = pcall(vim.treesitter.get_parser, 0, "lua")
  if ok_parser and parser then
    local ts_buf = vim.api.nvim_get_current_buf()

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

    -- Treesitter excludes string-only occurrences
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      'local msg = "alpha is here"',
      "-- alpha in a comment",
      "local copy = alpha",
    })
    local str_buf = vim.api.nvim_get_current_buf()
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
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "local function foo()",
      "  local alpha = 1",
      "  print(alpha)",
      "end",
      "local alpha = 2",
    })
    local scope_buf = vim.api.nvim_get_current_buf()
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
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "local alpha = 1",
    })
    local combine_buf = vim.api.nvim_get_current_buf()
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
tunnelvision.setup({ notify = false, source = "lsp_else_word" })

-- Structural contexts use exact source columns and remain separate from paths.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
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

  local ok_parser, parser = pcall(vim.treesitter.get_parser, 0, "lua")
  if ok_parser and parser then
    local structural_buf = vim.api.nvim_get_current_buf()
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

-- Structural walking is conservative and falls back on parser/node failures.
do
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha(", "  value", ")" })
  local context = require("tunnelvision.context")
  local cfg = { highlights = { statement = {} } }
  local path_set = { [1] = true }
  local symbol_ranges = { { line = 1, start_col = 3, end_col = 8 } }
  local scope = { start_line = 1, end_line = 3 }
  local orig_get_parser = vim.treesitter.get_parser
  local seen_col

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

  local broad_node = {
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

  stub_parser(function()
    error("broken node traversal")
  end)
  statements, _, fallback = context.evaluate(cfg, path_set, symbol_ranges, 0, scope)
  vim.treesitter.get_parser = orig_get_parser
  assert_true(vim.deep_equal(statements, path_set), "node traversal errors should fall back to matched lines")
  assert_true(fallback.statement, "node traversal errors should report structural fallback")
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
  vim.cmd("enew")
  vim.bo.filetype = "plaintext"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha = 1", "print(alpha)" })
  local structural_fallback_buf = vim.api.nvim_get_current_buf()
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
vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "print(alpha)",
})
local oneshot_hex_buf = vim.api.nvim_get_current_buf()
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
vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "print(alpha)",
})
local buf_a = vim.api.nvim_get_current_buf()
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
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local alpha = 1",
    "print(alpha)",
    "local beta = 2",
  })
  local highlight_buf = vim.api.nvim_get_current_buf()
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
  local function marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, core.state.ns, 0, -1, { details = true })
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
        details.priority,
      }
    end
    return out
  end

  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "xx alpha yy alpha zz", "local beta = 1" })
  local render_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 4 })

  tunnelvision.setup()
  tunnelvision.on({ scope = "buffer", silent = true })
  local default_snapshot = mark_snapshot(render_buf)
  assert_true(#default_snapshot == 1, "default renderer should add only the unrelated-line dim mark")
  assert_true(default_snapshot[1][5] == "TunnelVisionDim", "default renderer should use line dimming")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  tunnelvision.on()
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

  local bs = core.get_buf_state(render_buf)
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
  tunnelvision.on()
  bs = core.get_buf_state(render_buf)
  bs.scope_head_set = { [1] = true }
  bs.statement_set = { [1] = true }
  require("tunnelvision.ui").render(render_buf)
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
  assert_true(composed_marks[1][4].priority == 1100, "positive styles should use positive priority")
  assert_true(
    line_group:match("^TunnelVisionHighlight" .. render_buf .. "_"),
    "positive groups should be buffer-specific"
  )
  assert_true(composed_marks[6][4].priority == 1000, "dim priority should remain below positive styles")
  vim.cmd("TunnelVision off")

  vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = 0xFF0000, bg_opacity = 0.5, bold = true } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  tunnelvision.on()
  local opacity_marks = marks(render_buf)
  assert_true(#opacity_marks == 2, "dim none should retain positive symbol marks")
  local opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x800080,
    "background opacity should blend deterministically against Normal"
  )

  local resolver = require("tunnelvision.resolver")
  local orig_compute_path = resolver.compute_path
  local compute_calls = 0
  resolver.compute_path = function(...)
    compute_calls = compute_calls + 1
    return orig_compute_path(...)
  end
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x00FF00 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  resolver.compute_path = orig_compute_path
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(compute_calls == 0, "ColorScheme should rerender without recomputing sources")
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x808000,
    "ColorScheme should rebuild opacity-derived groups"
  )

  vim.api.nvim_set_hl(0, "Normal", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0xFF0000,
    "missing Normal background should safely retain the configured background"
  )
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
  assert_true(
    core.activate(render_buf, { max_dim_lines = 1, symbol = "alpha", cursor = { 1, 4 } }),
    "one-shot max_dim_lines should invalidate same-target rendering"
  )
  assert_true(core.get_buf_state(render_buf).config.max_dim_lines == 1, "one-shot max_dim_lines should normalize")
  local large_marks = marks(render_buf)
  assert_true(#large_marks == 1, "large-buffer dim skipping should retain positive path styles")
  assert_true(large_marks[1][4].hl_group ~= nil, "large-buffer positive style should use a range highlight")
  vim.cmd("TunnelVision off")

  local deleted_buf = render_buf
  vim.cmd("enew")
  vim.api.nvim_buf_delete(deleted_buf, { force = true })
  assert_true(core.state.bufs[deleted_buf] == nil, "buffer deletion should clear renderer state")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local alpha = 1", "print(alpha)", "local beta = 2" })
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

print("tunnelvision smoke: OK")
