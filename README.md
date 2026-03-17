# tunnelvision.nvim


Focus on one symbol at a time.

`tunnelvision.nvim` dims everything except the code path related to the symbol under your cursor, so you can follow logic without visual noise.

![screenshot](aseets/screenshot.png)

## Features

- Dims non-relevant lines and keeps related lines visible.
- Tracks inside function scope when possible (falls back to file scope).
- Includes optional LSP `documentHighlight` matches.
- Supports 3 modes: `static`,`dynamic` and `flow` (experimental).
- Builtin path jumps with `]h` / `[h`.
- Handy defaults: `<leader>hh` on/remap, `<leader>hs|hd|hf` mode toggles, `<Esc>` to exit.

## Requirements

- Neovim `>= 0.9`
- Optional but recommended:
  - Tree-sitter (better function/method scope detection)
  - LSP (extra highlight accuracy)

## Dependencies

- No external plugin dependencies.
- Uses built-in Neovim APIs only.
- Optional integrations:
  - Tree-sitter (scope detection quality)
  - LSP `documentHighlight` (extra relevant lines)

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
local add = MiniDeps.add
add({ source = "leolaurindo/tunnelvision.nvim" })

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

### vim-plug

```vim
Plug 'leolaurindo/tunnelvision.nvim'
```

```lua
require("tunnelvision").setup()
```

## Quick start

- `:TunnelVisionOn` - turn on (or remap to current symbol if already on).
- `:TunnelVisionOff` - turn off.
- `:TunnelVisionToggle` - toggle tunnel mode at cursor symbol.
- `:TunnelVisionForward` - retarget to current symbol without turning it off.
- `:TunnelVisionDynamic` - switch to dynamic mode and start tracking.
- `:TunnelVisionNext` / `:TunnelVisionPrev` - jump path lines.
- `:TunnelVisionRefresh` - recompute path.
- `:TunnelVisionMode [static|flow|dynamic|toggle]`
- `:TunnelVisionFlowDirection [forward|both|toggle]`

Default keymaps:

- `]h` / `[h` jump to next/previous path line.
- `<leader>hh` turns on TunnelVision (or remaps to symbol under cursor if already on).
- `<leader>hs` toggles `static` mode.
- `<leader>hd` toggles `dynamic` mode.
- `<leader>hf` toggles `flow` mode.
- `<leader>ho` turns TunnelVision off.
- `<Esc>` exits TunnelVision if active (`use_esc = true`).
- `n` / `N` can be enabled as optional path navigation (`use_nN = true`).
- `:TunnelVisionToggle` is available if you prefer a single toggle keymap.

## Modes

- `static` (default): symbol usages/references only (plus optional LSP highlights).
- `flow` (experimental): adds lightweight assignment-based propagation.
- `dynamic`: static tracking, but automatically retargets as cursor symbol changes.

For `flow` mode:

- `flow_direction = "forward"` follows influence forward.
- `flow_direction = "both"` also pulls backward provenance (broader, noisier).

## Configuration

```lua
require("tunnelvision").setup({
  scope = "auto", -- auto | function | file
  mode = "static", -- static | flow | dynamic
  flow_direction = "forward", -- forward | both
  include_lsp_highlights = true,
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  use_bracket_h = true,
  use_nN = false,
  use_leader_h = true,
  use_esc = true,
  notify = true,
})
```

