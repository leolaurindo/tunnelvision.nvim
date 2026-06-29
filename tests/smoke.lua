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
  vim.notify = function(msg, ...)
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

  tunnelvision.setup({ notify = false, source = "lsp_else_word", lsp_timeout_ms = 1000 })
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

  tunnelvision.setup({ notify = false, source = "lsp", lsp_timeout_ms = 1000 })
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

  vim.lsp.buf_request_all = orig_buf_request_all
  restore_clients()
end

local custom_fg = 0x778899
vim.api.nvim_set_hl(0, "TunnelVisionDim", { fg = custom_fg, italic = false })
tunnelvision.setup({ notify = false, source = "word" })
vim.cmd("colorscheme default")
local dim_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(dim_hl and dim_hl.fg ~= custom_fg, "TunnelVisionDim should follow colorscheme comment color")

local configured_fg = 0x445566
tunnelvision.setup({ notify = false, source = "word", dim = { fg = configured_fg, italic = false } })
local configured_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(configured_hl and configured_hl.fg == configured_fg, "custom dim highlight should apply")
vim.cmd("colorscheme default")
configured_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(
  configured_hl and configured_hl.fg == configured_fg,
  "custom dim highlight should survive colorscheme refresh"
)

vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local alpha = 1",
  "print(alpha)",
})
local one_shot_dim_buf = vim.api.nvim_get_current_buf()
local one_shot_fg = 0xAA33CC
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = { fg = one_shot_fg, italic = true } })
local one_shot_hl = vim.api.nvim_get_hl(0, { name = core.get_buf_state(one_shot_dim_buf).config.dim_hl, link = false })
assert_true(one_shot_hl and one_shot_hl.fg == one_shot_fg, "one-shot dim highlight should apply")

vim.cmd("TunnelVision off")
assert_true(not core.is_active(0), "deactivation failed")

print("tunnelvision smoke: OK")
