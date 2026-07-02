# tunnelvision.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

Focus on one thing at a time.

TunnelVision dims unrelated lines and keeps attention on the targeted symbol.

![TunnelVision screenshot](assets/screenshot.png)

## Requirements

- Neovim `>= 0.9`
- Optional:
  - Tree-sitter for better scope detection (recommended, specially for LSP-free
    setups)
  - LSP with `documentHighlight`

## Installation

<details open>
<summary><code>lazy.nvim</code></summary>

```lua
{
  "leolaurindo/tunnelvision.nvim",
  opts = {},
}
```

</details>

<details>
<summary><code>vim.pack</code></summary>

```lua
vim.pack.add({ "https://github.com/leolaurindo/tunnelvision.nvim" })
require("tunnelvision").setup()
```

</details>

<details>
<summary><code>mini.deps</code></summary>

```lua
MiniDeps.add({ source = "leolaurindo/tunnelvision.nvim" })
require("tunnelvision").setup()
```

</details>

<details>
<summary><code>packer.nvim</code></summary>

```lua
use({
  "leolaurindo/tunnelvision.nvim",
  config = function()
    require("tunnelvision").setup()
  end,
})
```

</details>

## Quick start

1. Call `require("tunnelvision").setup()` so the `:TunnelVision` command is
   registered.
2. Put the cursor on a symbol.
3. Run `:TunnelVision on`.
4. Jump with `:TunnelVision next` and `:TunnelVision prev`.
5. Run `:TunnelVision off`.

## Commands

```text
:TunnelVision on|retarget|off|toggle|next|prev|refresh|status
:TunnelVision mode [static|dynamic|flow]
:TunnelVision scope [function|buffer]
:TunnelVision source [lsp|treesitter|word|lsp,word|treesitter,word|lsp,treesitter,word]
:TunnelVision direction [forward|both]
```

Run `:help tunnelvision` for full command and option reference.

## Modes

- `static` (default): track the symbol selected on activation.
- `dynamic`: retarget as the cursor moves.
- `flow`: experimental mode that expands to assignment-related lines to follow
  value flow.

`scope = "function"` uses Tree-sitter when available, otherwise TunnelVision
falls back to the full buffer.

`sources = { "lsp", "word" }` is the default and works well as a general setting.
If LSP is slow or unavailable, TunnelVision falls back to `word` after
`lsp_timeout_ms`.

Since `0.3.0`, `treesitter` can also be used as a lightweight source fallback:
`sources = { "lsp", "treesitter", "word" }`.

For LSP-free setups, `sources = { "treesitter", "word" }` pairs well with
`scope = "function"`, because Tree-sitter keeps matching syntax-aware when a
parser is available, and word matching remains as a broad fallback.

## Configuration

### Defaults

Use `setup()` to define the persistent defaults used by `:TunnelVision on`,
`on()`, and runtime commands such as `:TunnelVision scope buffer`.

```lua
require("tunnelvision").setup({
  mode = "static",
  scope = "function",
  sources = { "lsp", "word" },
  flow_settings = {
    direction = "forward",
    extra_keywords = {},
  },
  dim = nil,
})
```

By default, TunnelVision derives its dim style from your colorscheme's `Comment`
highlight. Set `dim` when you want to choose the color or style used for dimmed
lines yourself:

```lua
require("tunnelvision").setup({
  dim = { fg = "#565f89", italic = true },
})
```

### One-shot activations

Use one-shot overrides when you want a specific keymap or command to activate with
different behavior without changing those defaults:

```lua
require("tunnelvision").on({ scope = "buffer", sources = { "word" } })
```

This makes it easy to keep a stable default, such as LSP-first matching in the
current function, while adding focused alternatives like plain word matching across
the full buffer.

### Source chains

TunnelVision uses `sources` to describe how matching lines are found. The list is
ordered: each source is tried in sequence and the first source with usable lines
wins.

```lua
require("tunnelvision").setup({
  sources = { "lsp", "treesitter", "word" },
})
```

Available source engines:

| Source | Notes |
| --- | --- |
| `lsp` | Semantic and async. Best precision when the attached server supports `documentHighlight`. |
| `treesitter` | Syntax-aware and lightweight. Matches identifier-like nodes and avoids string/comment-only matches where parser support allows it. Not semantic. |
| `word` | Textual and broad. Language-agnostic fallback. |

LSP is the most semantic source, but it depends on server support and response
time. If `documentHighlight` is slow or unavailable, TunnelVision falls back to
the next source in the chain after `lsp_timeout_ms`. For a lightweight setup,
`sources = { "treesitter", "word" }` with `scope = "function"` often works well:
Tree-sitter keeps matches syntax-aware, word matching gives a broad fallback, and
function scope keeps both cheap and focused.

`tv.combine(...)` creates one strict combined source step. Think of it as an
"all" step: every source inside the combined step must produce usable matches,
then their line sets are merged. If any member fails or returns no matches, the
whole combined step fails and the chain continues to the next fallback.

```lua
local tv = require("tunnelvision")

tv.setup({
  sources = {
    tv.combine("lsp", "treesitter"),
    "treesitter",
    "word",
  },
})
```

For command usage, comma syntax means fallback order:

```vim
:TunnelVision source lsp,word
:TunnelVision source treesitter,word
:TunnelVision source lsp,treesitter,word
```

Strict `combine(...)` steps are Lua-only.

### Migration

The old API remains supported without runtime deprecation warnings, but new
configuration should prefer the composable forms below.

| Old | New |
| --- | --- |
| `source = "word"` | `sources = { "word" }` |
| `source = "lsp"` | `sources = { "lsp" }` |
| `source = "lsp_else_word"` | `sources = { "lsp", "word" }` |
| `source = "lsp_and_word"` | `sources = { tv.combine("lsp", "word") }` |
| `direction = "both"` | `flow_settings = { direction = "both" }` |
| `extra_keywords = { ... }` | `flow_settings = { extra_keywords = { ... } }` |
| `dim_hl = "..."` | `dim = ...` |

### Options

These options can be set as persistent defaults in `setup()`. Core behavior and
appearance options such as `mode`, `scope`, `sources`, `flow_settings`, and `dim`
can also be passed to `on(opts)` for one-shot activations.

| Option | Default | Notes |
| --- | --- | --- |
| `mode` | `static` | `dynamic` retargets as you move; `flow` is experimental. |
| `scope` | `function` | Uses the nearest function-like scope when Tree-sitter is available. |
| `sources` | `{ "lsp", "word" }` | Ordered fallback chain for source engines. |
| `flow_settings.direction` | `forward` | Flow mode only. Use `both` to include backward influence. |
| `flow_settings.extra_keywords` | `{}` | Extra identifiers to ignore in flow analysis. |
| `fallback_warn` | `once` | Controls warnings when LSP falls back to another source. |
| `lsp_timeout_ms` | `150` | Timeout for async LSP `documentHighlight` requests. |
| `dim` | `nil` | Optional dim style: `nil` (`Comment` derived), highlight group name, hex foreground, or highlight table. |
| `max_dim_lines` | `6000` | Skip dimming in very large buffers. |
| `notify` | `true` | Enable plugin notifications. |

Run `:help tunnelvision-config` for the full option reference.

## Suggested keymaps

```lua
local tv = require("tunnelvision")

vim.keymap.set("n", "<leader>v", "<cmd>TunnelVision on<CR>", { desc = "TunnelVision on" })
-- or vim.keymap.set("n", "<leader>v", "<cmd>TunnelVision toggle<CR>", { desc = "TunnelVision toggle" })
vim.keymap.set("n", "]v", "<cmd>TunnelVision next<CR>", { desc = "TunnelVision next" })
vim.keymap.set("n", "[v", "<cmd>TunnelVision prev<CR>", { desc = "TunnelVision prev" })
vim.keymap.set("n", "<Esc>", function()
  if tv.is_active() then
    tv.off()
    return ""
  end
  return "<Esc>"
end, { expr = true, silent = true, desc = "TunnelVision off on Esc" })

-- as an example: a different activation as one-shot
vim.keymap.set("n", "<leader>V", function()
  tv.on({ scope = "buffer", sources = { "word" } })
end, { desc = "TunnelVision word in buffer" })
```

## Health

- `:checkhealth tunnelvision`

## Contributing

Feel free to contribute.

Just make sure to:

- include your rationale
- update the documentation
- update `CHANGELOG.md`

## Other approaches

- [folke/twilight.nvim](https://github.com/folke/twilight.nvim)
- [RRethy/vim-illuminate](https://github.com/RRethy/vim-illuminate)
- [junegunn/limelight.vim](https://github.com/junegunn/limelight.vim)
