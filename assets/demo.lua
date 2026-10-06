-- Minimal recording environment: run from the repository root with -u assets/demo.lua.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")
local theme = vim.fn.stdpath("data") .. "/lazy/tokyonight.nvim"
if vim.fn.isdirectory(theme) == 1 then
  vim.opt.runtimepath:prepend(theme)
  vim.cmd.colorscheme("tokyonight-night")
else
  vim.cmd.colorscheme("habamax")
end
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.laststatus = 0
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.swapfile = false
vim.opt.cmdheight = 2
vim.opt.termguicolors = true
vim.opt.hlsearch = false

-- Named styles keep the explicitly chosen overrides readable in typed commands.
_G.tv = require("tunnelvision")
tv.setup()
_G.pink = { statement = true, symbol = { bg = "#743c63", fg = "#ffffff" } }
_G.green = { statement = true, symbol = { fg = "#9ece6a", underline = true } }
_G.heads = { statement = true, scope_head = { bold = true }, symbol = { bg_group = "Search" } }
local code = {
  "local function checkout(items, tax_rate)",
  "  local subtotal = 0",
  "  local discount = 5",
  "  local shipping = 8",
  "",
  "  for _, item in ipairs(items) do",
  "    subtotal = subtotal + item.price * item.quantity",
  "  end",
  "  local tax =",
  "    subtotal * tax_rate",
  "  local total = subtotal + tax - discount + shipping",
  "",
  "  if total > 100 then",
  "    shipping = 0",
  "    total = subtotal + tax - discount + shipping",
  "  end",
  "",
  "  print(string.format('Saved $%d', discount))",
  "  return total",
  "end",
  "",
  "local orders = { { price = 25, quantity = 4 } }",
  "local receipt = checkout(orders, 0.08)",
  "print(receipt)",
}
vim.api.nvim_buf_set_name(0, "checkout.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, code)
vim.bo.filetype = "lua"
vim.bo.modifiable = false
pcall(vim.treesitter.start, 0, "lua")
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function()
    pcall(vim.treesitter.start, 0, "lua")
  end,
})

-- Title mappings do not activate tracks or move the cursor.
local titles = {
  ["1"] = "01  DEFAULT FOCUS  |  statement context + symbol emphasis",
  ["2"] = "02  ADDITIVE TRACKS  |  plain add keeps the SAME default style",
  ["3"] = "02  ADDITIVE TRACKS  |  custom styles are OPTIONAL and explicitly chosen",
  ["4"] = "03  DYNAMIC + PIN  |  dynamic follows the cursor; on replaces tracks",
  ["5"] = "04  TOKEN STYLE, NO DIMMING  |  emphasize symbols only",
  ["6"] = "05  KEEP SCOPE HEADS HIGHLIGHTED  |  preserve surrounding structure",
  ["7"] = "06  FORWARD DATA FLOW  |  alpha -> beta -> gamma -> delta",
  ["8"] = "TunnelVision off  |  back to the full picture",
  ["9"] = "03  DYNAMIC + PIN  |  discount stays pinned while dynamic focus keeps moving",
}
for key, text in pairs(titles) do
  vim.keymap.set("n", key, function()
    vim.api.nvim_echo({ { text, "Title" } }, false, {})
  end)
end
vim.schedule(function()
  vim.cmd("normal! gg")
end)
