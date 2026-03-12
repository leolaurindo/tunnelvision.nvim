# tunnelvision.nvim

Low-light everything except the data path for the symbol under cursor.

## Features

- Toggle tunnel view from symbol under cursor
- Auto scope selection (function/method when possible, file fallback)
- Local transformation chain approximation (assignments and dependent usages)
- Optional LSP document highlights blended into the path
- Path navigation with `n`/`N` when tunnel mode is active

## Commands

- `:TunnelVisionToggle`
- `:TunnelVisionNext`
- `:TunnelVisionPrev`
- `:TunnelVisionRefresh`
- `:TunnelVisionMode [strict|flow|toggle]`
- `:TunnelVisionFlowDirection [forward|both|toggle]`

## Modes

- `strict` (default): only highlights real references/usages of the symbol under cursor (plus LSP highlights, when available).
- `flow` (experimental): adds heuristic transformation tracking (assignment-based data flow in the current scope).

### How Flow Heuristics Work

- Works inside the chosen scope (`function`/`method` when found, otherwise file).
- Parses each line and extracts identifiers and simple assignments (`=`, `+=`, `-=`, `*=`, `/=`, `%=`).
- Starts from the symbol under cursor, then expands a tracked set when a tracked identifier appears on the right-hand side of an assignment.
- In `flow_direction = "both"`, it also expands backward from assignment targets to their inputs (broader provenance).
- Uses lightweight parsing (not full AST/SSA dataflow), so complex control flow, aliasing, mutation, and dynamic patterns can produce misses or extra lines.

### Flow Direction

- `forward` (default): follows how the symbol influences later values.
- `both`: follows forward influence and backward provenance; this is broader and can include sibling/provenance lines.

### Recommended Usage

- Use `strict` when you want predictable, low-noise symbol tracking.
- Switch to `flow` when exploring value propagation and you accept heuristic, experimental results.
- Start with `flow_direction = "forward"`; use `both` only when you intentionally want wider context.

## Setup (lazy.nvim)

```lua
{
  "tunnelvision.nvim",
  dir = vim.fn.expand("~/projects/tunnelvision"),
  config = function()
    require("tunnelvision").setup({
      scope = "auto",
      mode = "strict",
      use_nN = true,
    })
  end,
}
```

## Default options

```lua
{
  scope = "auto", -- auto | function | file
  mode = "strict", -- strict | flow
  flow_direction = "forward", -- forward | both (used in flow mode)
  include_lsp_highlights = true,
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  use_nN = true,
  notify = true,
}
```
