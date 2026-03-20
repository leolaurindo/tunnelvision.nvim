# tunnelvision.nvim docs

## Setup

```lua
require("tunnelvision").setup({
  mode = "static",
})
```

## Commands

- `:TunnelVisionOn` - activate or remap symbol tracking in current buffer.
- `:TunnelVisionOff` - deactivate in current buffer.
- `:TunnelVisionToggle` - toggle on/off at cursor symbol.
- `:TunnelVisionForward` - retarget to cursor symbol without toggling off.
- `:TunnelVisionDynamic` - set dynamic mode and activate.
- `:TunnelVisionNext` - jump to next path line.
- `:TunnelVisionPrev` - jump to previous path line.
- `:TunnelVisionRefresh` - recompute path and redraw dim.
- `:TunnelVisionMode [static|flow|dynamic|toggle]` - query or set mode.
- `:TunnelVisionFlowDirection [forward|both|toggle]` - query or set flow direction.
- `:TunnelVisionSymbolSource [lsp_strict_fallback|hybrid|lexical|toggle]` - query or set symbol source.

## Configuration

```lua
require("tunnelvision").setup({
  mode = "static",                -- static | flow | dynamic
  flow_direction = "forward",     -- forward | both
  symbol_source = "lsp_strict_fallback", -- lsp_strict_fallback | hybrid | lexical
  fallback_warn = "once",         -- once | always | never
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  notify = true,
})
```

Notes:
- `fallback_warn = "once"` warns once per buffer lifetime.
- `symbol_source = "lsp_strict_fallback"` uses LSP highlights first, then lexical fallback.

## Suggested keymaps

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

## Lua API

From `require("tunnelvision")`:

- `setup(opts?)`
- `toggle()`
- `forward()`
- `dynamic()`
- `next(count?)`
- `prev(count?)`
- `refresh()`
- `get_mode()` / `set_mode(mode)`
- `get_flow_direction()` / `set_flow_direction(direction)`
- `get_symbol_source()` / `set_symbol_source(source)`

## Health

Run:

```vim
:checkhealth tunnelvision
```

Checks:
- Neovim version
- Tree-sitter availability
- LSP `documentHighlight` availability
- `TunnelVisionDim` highlight availability

## Troubleshooting

- Fallback warnings in strict source: set `fallback_warn = "never"` or use `symbol_source = "lexical"`.
- Dynamic mode too noisy: use `symbol_source = "lexical"`.
- Activation says no symbol under cursor: move cursor to a word identifier.
- Dim color follows your colorscheme `Comment` highlight.
