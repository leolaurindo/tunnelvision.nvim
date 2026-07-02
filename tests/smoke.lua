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

local function assert_sources(expected, msg)
  local got = tunnelvision.get_sources()
  assert_true(#got == #expected, msg .. " length")
  for i, value in ipairs(expected) do
    assert_true(got[i] == value, msg .. " item " .. i)
  end
end

local function assert_combine(step, expected, msg)
  assert_true(type(step) == "table" and step.kind == "combine", msg .. " kind")
  assert_true(#step.names == #expected, msg .. " length")
  for i, value in ipairs(expected) do
    assert_true(step.names[i] == value, msg .. " item " .. i)
  end
end

tunnelvision.setup({ notify = false })
assert_sources({ "lsp", "word" }, "default sources")
assert_true(config.format_sources(core.state.config.sources) == "lsp,word", "format_sources default")

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
core.state.keywords = require("tunnelvision.resolver").build_keywords({})

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

tunnelvision.setup({
  notify = false,
  source = "word",
})
assert_sources({ "word" }, "legacy source should normalize to sources")

tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") } })
assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "combine sources")

tunnelvision.setup({
  notify = false,
  source = "word",
})
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
  local fake_clients = { { server_capabilities = { documentHighlightProvider = true } } }
  local callbacks = {}
  local restore_clients
  local orig_buf_request_all = vim.lsp.buf_request_all

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

  callbacks[2]({
    [1] = {
      result = {
        { range = { start = { line = 0 }, ["end"] = { line = 1 } } },
      },
    },
  })
  assert_true(not core.get_buf_state(lsp_buf).pending, "current LSP response should resolve pending state")
  assert_true(core.get_buf_state(lsp_buf).path_set[2], "resolved LSP response should update path")

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

  vim.lsp.buf_request_all = orig_buf_request_all
  restore_clients()
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

print("tunnelvision smoke: OK")
