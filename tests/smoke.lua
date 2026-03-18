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

local custom_fg = 0x778899
vim.api.nvim_set_hl(0, "TunnelVisionDim", { fg = custom_fg, italic = false })
tunnelvision.setup({ notify = false, symbol_source = "lexical" })
vim.cmd("colorscheme default")
local dim_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(dim_hl and dim_hl.fg == custom_fg, "custom TunnelVisionDim highlight should be preserved")

vim.cmd("TunnelVisionOff")
assert_true(not core.is_active(0), "deactivation failed")

print("tunnelvision smoke: OK")
