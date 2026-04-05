# tunnelvision.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

Focus one symbol path at a time.

![TunnelVision screenshot](assets/screenshot.png)

## What it does

TunnelVision dims unrelated lines and keeps attention on the symbol under cursor.

## Requirements

- Neovim `>= 0.9`
- Optional (recommended):
  - Tree-sitter for better scope detection
  - LSP with `documentHighlight`

## Installation

### lazy.nvim

```lua
{
  "leolaurindo/tunnelvision.nvim",
  opts = {},
}
```

### mini.deps

```lua
MiniDeps.add({ source = "leolaurindo/tunnelvision.nvim" })
require("tunnelvision").setup()
```

### packer.nvim

```lua
use({
  "leolaurindo/tunnelvision.nvim",
  config = function()
    require("tunnelvision").setup()
  end,
})
```

## Quick start

1. Put the cursor on a symbol.
2. Run `:TunnelVision on`.
3. Jump with `:TunnelVision next` and `:TunnelVision prev`.
4. Run `:TunnelVision off`.

Run `:help tunnelvision` for the full reference.

## Commands

```text
:TunnelVision
|- on
|- retarget (alias of on)
|- off
|- toggle
|- next
|- prev
|- refresh
|- status
|- mode [static|flow|dynamic]
|- direction [forward|both]
`- source [lsp_else_word|lsp|lsp_and_word|word]
```

- `:TunnelVision on`
- `:TunnelVision retarget` (alias of `on`)
- `:TunnelVision off`
- `:TunnelVision toggle`
- `:TunnelVision next`
- `:TunnelVision prev`
- `:TunnelVision refresh`
- `:TunnelVision status`
- `:TunnelVision mode [static|flow|dynamic]`
- `:TunnelVision direction [forward|both]`
- `:TunnelVision source [lsp_else_word|lsp|lsp_and_word|word]`

With no value, `mode`, `direction`, and `source` show the current setting.

## Modes

- `static` (default): track the symbol selected on activation.
- `dynamic`: retarget as the cursor moves.
- `flow`: expand to assignment-related lines to follow value flow.

## Flow settings

`direction` matters only in `flow` mode (outside flow mode, TunnelVision warns and keeps the value unchanged in behavior):

- `forward` (default): follow forward influence.
- `both`: include backward influence too.

## Source

`source` controls how TunnelVision finds related lines:

- `lsp_else_word` (default): use LSP highlights first, fallback to word matching on failure.
- `lsp`: use LSP highlights only; no word fallback.
- `lsp_and_word`: union of word matching and LSP matches.
- `word`: word matching only.

`fallback_warn` controls `lsp_else_word` warnings:

- `once` (default): warn once per buffer lifetime.
- `always`: warn every fallback.
- `never`: never warn.

## Configuration

```lua
require("tunnelvision").setup({
  mode = "static", -- static | flow | dynamic
  direction = "forward", -- forward | both
  source = "lsp_else_word", -- lsp_else_word | lsp | lsp_and_word | word
  fallback_warn = "once", -- once | always | never
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  notify = true,
})
```

## Suggested keymaps

```lua
local tv = require("tunnelvision")

vim.keymap.set("n", "<leader>hh", "<cmd>TunnelVision on<CR>", { desc = "TunnelVision on" })
vim.keymap.set("n", "<leader>ho", "<cmd>TunnelVision off<CR>", { desc = "TunnelVision off" })
vim.keymap.set("n", "]h", "<cmd>TunnelVision next<CR>", { desc = "TunnelVision next" })
vim.keymap.set("n", "[h", "<cmd>TunnelVision prev<CR>", { desc = "TunnelVision prev" })
vim.keymap.set("n", "<leader>hf", function()
  tv.set_mode("flow")
  tv.on()
end, { desc = "TunnelVision flow" })
vim.keymap.set("n", "<leader>hd", function()
  tv.set_mode("dynamic")
  tv.on()
end, { desc = "TunnelVision dynamic" })
vim.keymap.set("n", "<Esc>", function()
  if tv.is_active() then
    tv.off()
    return ""
  end
  return "<Esc>"
end, { expr = true, silent = true, desc = "TunnelVision off on Esc" })
```

## Health

- `:checkhealth tunnelvision`

## Contributing

- `CONTRIBUTING.md`
