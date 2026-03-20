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
  symbol_source = "lexical",
})

for _, cmd in ipairs({
  "TunnelVisionOn",
  "TunnelVisionOff",
  "TunnelVisionToggle",
  "TunnelVisionForward",
  "TunnelVisionDynamic",
  "TunnelVisionNext",
  "TunnelVisionPrev",
  "TunnelVisionRefresh",
  "TunnelVisionMode",
  "TunnelVisionFlowDirection",
  "TunnelVisionSymbolSource",
}) do
  assert_true(vim.fn.exists(":" .. cmd) == 2, "missing command: " .. cmd)
end

vim.cmd("enew")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local value = 1",
  "local copy = value",
  "value = copy + value",
  "print(value)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- value

vim.cmd("TunnelVisionOn")
assert_true(core.is_active(0), "activation failed")

local before = vim.api.nvim_win_get_cursor(0)[1]
vim.cmd("TunnelVisionNext")
local after_next = vim.api.nvim_win_get_cursor(0)[1]
assert_true(after_next ~= before, "next path jump did not move cursor")

vim.cmd("TunnelVisionPrev")
local after_prev = vim.api.nvim_win_get_cursor(0)[1]
assert_true(after_prev == before, "prev path jump did not return cursor")

vim.cmd("TunnelVisionMode static")
assert_true(core.get_mode() == "static", "mode static not applied")
vim.cmd("TunnelVisionMode toggle")
assert_true(core.get_mode() == "flow", "mode toggle static->flow failed")
vim.cmd("TunnelVisionMode toggle")
assert_true(core.get_mode() == "dynamic", "mode toggle flow->dynamic failed")
vim.cmd("TunnelVisionMode toggle")
assert_true(core.get_mode() == "static", "mode toggle dynamic->static failed")

vim.cmd("TunnelVisionSymbolSource lsp_strict_fallback")
vim.cmd("TunnelVisionSymbolSource toggle")
assert_true(core.get_symbol_source() == "hybrid", "symbol source toggle strict->hybrid failed")
vim.cmd("TunnelVisionSymbolSource toggle")
assert_true(core.get_symbol_source() == "lexical", "symbol source toggle hybrid->lexical failed")

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

vim.cmd("TunnelVisionDynamic")
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

vim.cmd("TunnelVisionOff")
core.set_renderer(ui.apply_dim)

local custom_fg = 0x778899
vim.api.nvim_set_hl(0, "TunnelVisionDim", { fg = custom_fg, italic = false })
tunnelvision.setup({ notify = false, symbol_source = "lexical" })
vim.cmd("colorscheme default")
local dim_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(dim_hl and dim_hl.fg ~= custom_fg, "TunnelVisionDim should follow colorscheme comment color")

vim.cmd("TunnelVisionOff")
assert_true(not core.is_active(0), "deactivation failed")

print("tunnelvision smoke: OK")
