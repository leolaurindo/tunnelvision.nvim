# tunnelvision.nvim


Remove visual noise and focus on one symbol at time.

![screenshot](assets/screenshot.png)

## Modes

Think of modes as "how TunnelVision follows your current symbol/word":

- `static` (default): targets the symbol under cursor when activating tunnelvision and show lines related to that symbol.
- `dynamic`: same idea as static, but it automatically retargets as your cursor moves to a different symbol.
- `flow` (experimental): starts from the symbol under cursor and expands to nearby assignment flow, so you can follow how values move.

For `flow` only:

- `flow_direction = "forward"`: follow influence forward (usually cleaner).
- `flow_direction = "both"`: include both forward and backward links (broader and noisier).

More about behavior on [Symbol source](#symbol-source) section.

## Requirements

- Neovim `>= 0.9`
- Optional but recommended:
  - [Tree-sitter](https://github.com/tree-sitter/tree-sitter) (better function/method scope detection)
  - LSP (extra highlight accuracy)

## Dependencies

- No external plugin dependencies.
- Uses built-in Neovim APIs only.
- Optional integrations:
  - Tree-sitter (scope detection quality)
  - LSP `documentHighlight` (extra relevant lines)

## Installation

- `lazy.nvim`
  <details open>
  <summary>Show config</summary>

  ```lua
  {
    "leolaurindo/tunnelvision.nvim",
    opts = {},
  }
  ```

  </details>

- `mini.deps`
  <details>
  <summary>Show config</summary>

  ```lua
  local add = MiniDeps.add
  add({ source = "leolaurindo/tunnelvision.nvim" })

  require("tunnelvision").setup()
  ```

  </details>

- `packer.nvim`
  <details>
  <summary>Show config</summary>

  ```lua
  use({
    "leolaurindo/tunnelvision.nvim",
    config = function()
      require("tunnelvision").setup()
    end,
  })
  ```

  </details>

- `vim-plug`
  <details>
  <summary>Show config</summary>

  ```vim
  Plug 'leolaurindo/tunnelvision.nvim'
  ```

  ```lua
  require("tunnelvision").setup()
  ```

  </details>

## Quick start

- `:TunnelVisionOn` - turn on (or remap to current symbol if already on).
- `:TunnelVisionOff` - turn off.
- `:TunnelVisionToggle` - toggle tunnel mode at cursor symbol.
- `:TunnelVisionForward` - retarget to current symbol without turning it off.
- `:TunnelVisionDynamic` - switch to dynamic mode and start tracking.
- `:TunnelVisionNext` / `:TunnelVisionPrev` - jump to next symbol.
- `:TunnelVisionRefresh` - recompute path.
- `:TunnelVisionMode [static|flow|dynamic|toggle]`
- `:TunnelVisionFlowDirection [forward|both|toggle]`
- `:TunnelVisionSymbolSource [lsp_strict_fallback|hybrid|lexical]`

Default keymaps:

- `<leader>hh` turns on TunnelVision on default mode set in configs (or remaps to symbol under cursor if already on).
- `]h` / `[h` jump to next/previous path line.
- `<leader>hs` toggles `static` mode.
- `<leader>hd` toggles `dynamic` mode.
- `<leader>hf` toggles `flow` mode.
- `<leader>ho` turns TunnelVision off.
- `<Esc>` exits TunnelVision if active (`use_esc = true`).
- `n` / `N` can be enabled as optional path navigation (`use_nN = true`).
- `:TunnelVisionToggle` is available if you prefer a single toggle keymap.

## Symbol source

Behavior is controlled by `symbol_source`:

- `lsp_strict_fallback` (default): uses LSP `documentHighlight` to identify the symbol under cursor (semantic match); if unavailable, falls back to lexical word matching in the current scope.
- `hybrid`: combines lexical word matching with LSP highlights.
- `lexical`: uses lexical word matching only (no LSP dependency).

Configure it in `setup()` or at runtime with `:TunnelVisionSymbolSource`.

Fallback warnings in strict mode are controlled by `fallback_warn`:

- `once` (default): warn once per buffer/session when lsp strict mode falls back.
- `always`: warn on every fallback activation.
- `never`: disable strict fallback warnings.

Set `notify = false` to disable all TunnelVision notifications.

## Configuration

```lua
require("tunnelvision").setup({
  scope = "auto", -- auto | function | file
  mode = "static", -- static | flow | dynamic
  flow_direction = "forward", -- forward | both
  symbol_source = "lsp_strict_fallback", -- lsp_strict_fallback | hybrid | lexical
  fallback_warn = "once", -- once | always | never
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
