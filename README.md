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
  - Tree-sitter (better scope detection)
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

1. Put cursor on a symbol.
2. Run `:TunnelVisionOn`.
3. Jump with `:TunnelVisionNext` / `:TunnelVisionPrev`.
4. Run `:TunnelVisionOff`.

See [suggested keymaps](#suggested-keymaps)

## Modes

- `static` (default): tracks the symbol selected on activation.
- `dynamic`: retargets as cursor moves.
- `flow` (experimental): expands to assignment-related lines to follow value flow.

`flow_direction` (used only in `flow`):

- `forward` (default): follow forward influence.
- `both`: include backward influence.

## Symbol behavior (LSP vs lexical)

`symbol_source` controls how path lines are found:

- `lsp_strict_fallback` (default): use LSP highlights first, fallback to lexical.
- `hybrid`: union of lexical + LSP matches.
- `lexical`: lexical matching only.

`fallback_warn` controls strict fallback warnings:

- `once` (default): warn once per buffer lifetime.
- `always`: warn every fallback.
- `never`: never warn.

## Suggested keymaps

TunnelVision does not set keymaps automatically. The suggested convention is the `<leader>h` family (`h` for "highlight").

```lua
vim.keymap.set("n", "<leader>hh", "<cmd>TunnelVisionOn<CR>", { desc = "TunnelVision on" })
vim.keymap.set("n", "<leader>ho", "<cmd>TunnelVisionOff<CR>", { desc = "TunnelVision off" })
vim.keymap.set("n", "]h", "<cmd>TunnelVisionNext<CR>", { desc = "TunnelVision next" })
vim.keymap.set("n", "[h", "<cmd>TunnelVisionPrev<CR>", { desc = "TunnelVision prev" })
vim.keymap.set("n", "<leader>hd", "<cmd>TunnelVisionDynamic<CR>", { desc = "TunnelVision dynamic" })
vim.keymap.set("n", "<leader>hm", "<cmd>TunnelVisionMode toggle<CR>", { desc = "TunnelVision cycle mode" })
vim.keymap.set("n", "<Esc>", function()
  if require("tunnelvision.core").is_active(0) then
    vim.cmd.TunnelVisionOff()
    return ""
  end
  return "<Esc>"
end, { expr = true, silent = true, desc = "TunnelVision off on Esc" })
```

## Configuration

```lua
require("tunnelvision").setup({
  mode = "static", -- static | flow | dynamic
  flow_direction = "forward", -- forward | both
  symbol_source = "lsp_strict_fallback", -- lsp_strict_fallback | hybrid | lexical
  fallback_warn = "once", -- once | always | never
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  notify = true,
})
```

## Commands

- `:TunnelVisionOn`, `:TunnelVisionOff`, `:TunnelVisionToggle`
- `:TunnelVisionForward`, `:TunnelVisionDynamic`
- `:TunnelVisionNext`, `:TunnelVisionPrev`, `:TunnelVisionRefresh`
- `:TunnelVisionMode [static|flow|dynamic|toggle]`
- `:TunnelVisionFlowDirection [forward|both|toggle]`
- `:TunnelVisionSymbolSource [lsp_strict_fallback|hybrid|lexical|toggle]`

## More docs

- Full reference: `DOCS.md`
- Health checks: `:checkhealth tunnelvision`
- Contributing: `CONTRIBUTING.md`
- License: `LICENSE`
