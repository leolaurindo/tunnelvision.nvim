# tunnelvision.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

Focus one symbol path at a time.

![TunnelVision screenshot](assets/screenshot.png)

## What it does

TunnelVision dims unrelated lines and keeps attention on the symbol under cursor.

- `static` (default): track the symbol selected on activation.
- `dynamic`: retarget as cursor moves.
- `flow`: expand to assignment-related lines to follow value flow.

`flow_direction` only affects `flow` mode:

- `forward` (default): follow forward influence.
- `both`: include backward influence too.

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

## Commands

- `:TunnelVisionOn` activate or remap tracking in current buffer.
- `:TunnelVisionOff` deactivate in current buffer.
- `:TunnelVisionToggle` toggle active state at cursor symbol.
- `:TunnelVisionForward` retarget to cursor symbol without toggling off.
- `:TunnelVisionDynamic` set dynamic mode and activate.
- `:TunnelVisionNext` jump to next path line.
- `:TunnelVisionPrev` jump to previous path line.
- `:TunnelVisionRefresh` recompute path and redraw.
- `:TunnelVisionMode [static|flow|dynamic|toggle]` query/set mode.
- `:TunnelVisionFlowDirection [forward|both|toggle]` query/set flow direction.
- `:TunnelVisionSymbolSource [lsp_strict_fallback|hybrid|lexical|toggle]` query/set symbol source.

## Keymaps

TunnelVision does not set keymaps automatically.

Suggested defaults:

```lua
vim.keymap.set("n", "<leader>hh", "<cmd>TunnelVisionOn<CR>", { desc = "TunnelVision on" })
vim.keymap.set("n", "<leader>ho", "<cmd>TunnelVisionOff<CR>", { desc = "TunnelVision off" })
vim.keymap.set("n", "]h", "<cmd>TunnelVisionNext<CR>", { desc = "TunnelVision next" })
vim.keymap.set("n", "[h", "<cmd>TunnelVisionPrev<CR>", { desc = "TunnelVision prev" })
vim.keymap.set("n", "<leader>hd", "<cmd>TunnelVisionDynamic<CR>", { desc = "TunnelVision dynamic" })
vim.keymap.set("n", "<leader>hm", "<cmd>TunnelVisionMode toggle<CR>", { desc = "TunnelVision cycle mode" })
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

## Notes

- `fallback_warn = "once"` warns once per buffer lifetime.
- User-defined `TunnelVisionDim` is preserved.
- On `ColorScheme`, TunnelVision reapplies highlights and redraws active buffers.

## Troubleshooting

- Strict fallback warnings: set `fallback_warn = "never"` or use `symbol_source = "lexical"`.
- Dynamic mode feels noisy: use `symbol_source = "lexical"`.
- No symbol warning: place cursor on an identifier.
- Custom dim color: define `TunnelVisionDim` before `setup()`.

## More docs

- Full reference: `DOCS.md`
- Health checks: `:checkhealth tunnelvision`
- Contributing: `CONTRIBUTING.md`
- License: `LICENSE`
