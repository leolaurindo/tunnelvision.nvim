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
local ui = require("tunnelvision.ui")

tunnelvision.setup({
  notify = false,
  source = "word",
})

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

vim.cmd("TunnelVision source lsp_else_word")
assert_true(core.get_source() == "lsp_else_word", "source lsp_else_word not applied")
vim.cmd("TunnelVision source lsp")
assert_true(core.get_source() == "lsp", "source lsp not applied")
vim.cmd("TunnelVision source lsp_and_word")
assert_true(core.get_source() == "lsp_and_word", "source lsp_and_word not applied")
vim.cmd("TunnelVision source word")
assert_true(core.get_source() == "word", "source word not applied")

local render_calls = 0
core.set_renderer(function()
  render_calls = render_calls + 1
end)

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
local dynamic_renders = render_calls

vim.api.nvim_win_set_cursor(0, { 2, 8 }) -- beta
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
vim.api.nvim_win_set_cursor(0, { 3, 8 }) -- gamma
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })

local waited = vim.wait(200, function()
  return core.get_buf_state(dynamic_buf).symbol == "gamma"
end, 10)
assert_true(waited, "dynamic debounce did not retarget to latest symbol")
assert_true(render_calls == dynamic_renders + 1, "dynamic debounce should collapse rapid retargets into one render")

local before_noop = render_calls
local no_op = core.activate(dynamic_buf, { silent = true, symbol = "gamma", cursor = { 3, 8 }, reuse_scope = true })
assert_true(no_op == false, "identical activate should no-op")
assert_true(render_calls == before_noop, "no-op activate should not render")

vim.cmd("TunnelVision off")
core.set_renderer(ui.apply_dim)

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

vim.cmd("TunnelVision off")
assert_true(not core.is_active(0), "deactivation failed")

print("tunnelvision smoke: OK")
