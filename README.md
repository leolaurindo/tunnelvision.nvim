# tunnelvision.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

Focus on one thing at a time.

TunnelVision dims unrelated lines and keeps attention on the targeted symbol.

![demo](assets/demo.gif)

## Installation

Requires Neovim `>= 0.9`. Tree-sitter is optional but recommended for scope and
syntax-aware matching; LSP matching requires `documentHighlight` support.

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
<summary><code>vim.pack</code> (Neovim 0.12+)</summary>

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

## Basics

Put the cursor on a symbol and run `:TunnelVision on` to focus it. Use
`:TunnelVision add` to keep that track while focusing another symbol, navigate
with `:TunnelVision next` and `:TunnelVision prev`, then finish with
`:TunnelVision off`.

See [suggested keymaps](#suggested-keymaps)

## Modes, Sources, and Highlights

### Modes

| Mode | Behavior |
| --- | --- |
| `static` (default) | Pins the selected symbol. |
| `dynamic` | Retargets one moving track as the cursor moves. |
| `flow` | Pins a symbol and expands its path through assignments. |
| `dynamic_flow` | Retargets the moving track and recomputes its flow path. |

### Sources

`sources` is an ordered fallback chain: each source is tried until one returns
usable lines. The default is `{ "lsp", "treesitter", "word" }`.

| Source | Behavior |
| --- | --- |
| `lsp` | Semantic and async; most precise when the server supports `documentHighlight`. |
| `treesitter` | Syntax-aware and lightweight; not semantic. |
| `word` | Broad, language-agnostic whole-word matching. |

LSP falls through after `lsp_timeout_ms` when slow or unavailable. For an
LSP-free setup, `{ "treesitter", "word" }` pairs well with `scope = function`.

Use `combine(...)` for a strict "all" step. Every member must return matches;
their lines are merged on success, or the chain continues on failure:

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

In commands, commas mean fallback order; strict combinations are Lua-only:

```vim
:TunnelVision source lsp,word
:TunnelVision source treesitter,word
:TunnelVision source lsp,treesitter,word
```

### Highlights

`highlights` controls which contexts stay focused and optionally gives them a
positive style:

| Context | Range |
| --- | --- |
| `scope_head` | First line of enclosing function, conditional, loop, and clause heads found by Tree-sitter. |
| `statement` | Nearest recognized declaration or statement around each path occurrence, clipped to the active scope and limited to 50 lines. |
| `line` | Complete source and flow path lines. |
| `symbol` | Exact symbol. With only this enabled, the rest of matched lines stays dimmed. |

A missing key or `false` disables a context. `true` or `{}` preserves its
original syntax colors; a style table applies `fg`, `bg`, `bold`, `italic`,
`underline`, `undercurl`, `strikethrough`, or `bg_opacity`. Numeric opacity is
clamped to `0..1` and pre-blended against `Normal`, not alpha-blended; without
usable backgrounds, the configured `bg` is used unchanged.

Within each track, overlaps compose from `scope_head` to `statement` to `line`
to `symbol`: more specific contexts override only the attributes they define.
Across tracks, newer tracks override only conflicting attributes. All tracks'
focused ranges form one union; its complement is dimmed at most once.

```lua
require("tunnelvision").setup({
  highlights = {
    scope_head = { bold = true },
    statement = true,
    line = { bg = "#292e42", bg_opacity = 0.2 },
    symbol = { fg = "#f7768e", bold = true, underline = true },
  },
  dim = { fg = "#565f89", italic = true },
})
```

Omitted or empty `highlights` defaults to `{ line = true }`. A non-empty table
replaces that default; it is not merged. Useful variations include:

```lua
{ highlights = { symbol = true } } -- token-only focus, original colors
{ dim = "none", highlights = { symbol = { bold = true } } } -- this track does not request dimming
```

Symbol ranges come from the winning source: LSP ranges, exact Tree-sitter
identifier nodes, or whole-word matches outside masked strings/comments. Custom
source lines derive ranges where the active symbol occurs; flow adds ranges for
tracked identifiers.

`statement` and `scope_head` use Tree-sitter independently of `sources`. If
structure is unavailable, statements fall back to path lines and scope heads are
skipped. Lookup starts at exact symbol columns, or the first nonblank column for
custom lines without ranges. Structural lines are visual only: `next` and `prev`
still navigate the source/flow path; warnings follow `fallback_warn` and `notify`.

## Configuration

`setup()` defines defaults for new tracks; existing tracks keep their options.
`on(opts)` replaces the buffer's tracks; `add(opts)` keeps them; `pin(opts)` adds
a fixed track even with a dynamic mode. All three accept one-shot overrides for
`mode`, `scope`, `sources`, `flow_settings`, and `highlights`. Setting
`dim = "none"` opts that track out of dimming; omitted `dim` requests dimming.
One-shot dim colors, `dim_hl`, and `max_dim_lines` are not accepted.

| Option | Default | Notes |
| --- | --- | --- |
| `mode` | `static` | `static`, `dynamic`, `flow`, or `dynamic_flow`. |
| `scope` | `function` | Nearest function-like Tree-sitter scope, falling back to the full buffer; also accepts `buffer`. |
| `sources` | `{ "lsp", "treesitter", "word" }` | Ordered source fallback chain. |
| `flow_settings.direction` | `forward` | `forward`, `backward`, or `both`. |
| `flow_settings.extra_keywords` | `{}` | Extra identifiers ignored during flow analysis. |
| `flow_settings.analyzers` | `{ "treesitter", "text" }` | Ordered analyzer fallback; use one item for strict behavior. |
| `flow_settings.max_depth` | `nil` | Positive hop limit; `nil` uses the internal 32-hop guard. |
| `fallback_warn` | `once` | Legacy LSP fallback and structural warnings: `once` per buffer, `always`, or `never`. Strict LSP still warns once. |
| `lsp_timeout_ms` | `150` | Async LSP `documentHighlight` timeout. |
| `highlights` | `{ line = true }` | Enabled visual contexts and their positive styles. [See configs](#highlights) |
| `dim` | `nil` | `nil` derives from `Comment`; accepts `"none"`, a highlight group, hex foreground, or style table. |
| `max_dim_lines` | `6000` | Skip dimming in larger buffers. |
| `notify` | `true` | Enable plugin notifications. |

Flow analyzers are separate from sources: sources select the initial path, then
the first usable analyzer expands assignments. `forward` follows dependencies to
dependents, `backward` finds inputs feeding the symbol, and `both` combines them.
Tree-sitter analysis falls back silently to text by default. `status()` reports
the analyzer, fallback state, tracked identifiers, and flow-added lines.

One-shot options do not change setup defaults:

```lua
require("tunnelvision").on({
  mode = "dynamic",
  scope = "buffer",
  sources = { "word" },
  highlights = { line = { bg = "#292e42", bg_opacity = 0.2 } },
})
```

For `on(opts)`, `add(opts)`, and `pin(opts)`, omitted `highlights` inherits
setup; an empty table selects line focus; a non-empty table replaces the setup
rules for that activation.

The dim style is shared per buffer: a buffer override takes precedence over
`setup({ dim = ... })`. The complement of all focused ranges dims only while at
least one active track requests dimming, or the buffer is forced to dim. No
active tracks means no dimming. A style override alone does not enable dimming;
`"none"` as the effective style disables it even when forced.

```lua
local tv = require("tunnelvision")
tv.set_buffer_dim("#565f89")  -- current buffer; nil resets override and force
tv.force_buffer_dim(true)   -- false turns force off
```

Both functions accept an optional second `bufnr` argument and return whether
the setting was accepted. Buffer settings survive `off()` and are cleared when
the buffer is deleted. `setup()` changes the global dim style for active buffers
without changing their saved track options. From Ex:

```vim
:TunnelVision dim #565f89
:TunnelVision dim Comment
:TunnelVision dim none
:TunnelVision dim reset
```

These set a hex foreground, use a highlight group, disable dimming, and restore
the setup style (clearing force-dim), respectively. `:TunnelVision dim` shows
the current override.

Run `:help tunnelvision-config` for the full option reference.

## Commands

```text
:TunnelVision on|add|pin|remove|retarget|off|toggle|next|prev|next-track|prev-track|refresh|quickfix|status
:TunnelVision mode [static|dynamic|flow|dynamic_flow]
:TunnelVision scope [function|buffer]
:TunnelVision source [lsp|treesitter|word|lsp,word|treesitter,word|lsp,treesitter,word|lsp_else_word|lsp_and_word]
:TunnelVision direction [forward|backward|both]
```

`on` replaces all tracks with one new target, preserving the pre-existing API.
`add` adds a track without removing other pins. `pin` adds a fixed track even
while dynamic tracking continues and accepts the same one-shot highlight rules.
`retarget` remains an alias for `on` for compatibility. `remove` removes the
track under the cursor or, if none is there, the latest track; `off` clears the
current buffer. Multiple static tracks, including flow tracks, can coexist;
at most one moving track can coexist with pins. `next`/`prev` visit the union
of occurrences (and unmatched custom/flow path lines). `next-track` and
`prev-track` navigate only the track under the cursor (latest-added if tracks
overlap); away from a tracked occurrence or path line, they use the latest track.
Commands with optional arguments change defaults only for future tracks;
`refresh` recomputes active tracks with their original options.
`status` describes the active buffer. `next`/`prev` record jumps in the
jumplist (`<C-o>` returns), and `:TunnelVision quickfix` creates a new quickfix
list with positions from all tracked symbols; `:colder` restores the previous
list. Run `:help tunnelvision` for the complete command and Lua API reference.

### Suggested keymaps
```lua
local tv = require("tunnelvision")

vim.keymap.set("n", "<leader>v", "<cmd>TunnelVision on<CR>", { desc = "Focus only this symbol" })
vim.keymap.set("n", "<leader>va", "<cmd>TunnelVision add<CR>", { desc = "Add a tracked symbol" })
vim.keymap.set("n", "]v", "<cmd>TunnelVision next<CR>", { desc = "Next across all tracks" })
vim.keymap.set("n", "[v", "<cmd>TunnelVision prev<CR>", { desc = "Previous across all tracks" })
vim.keymap.set("n", "]V", "<cmd>TunnelVision next-track<CR>", { desc = "Next in selected track" })
vim.keymap.set("n", "[V", "<cmd>TunnelVision prev-track<CR>", { desc = "Previous in selected track" })
vim.keymap.set("n", "<leader>vq", "<cmd>TunnelVision quickfix<CR>", { desc = "Tracked occurrences to quickfix" })
vim.keymap.set("n", "<leader>vu", "<cmd>TunnelVision remove<CR>", { desc = "TunnelVision remove" })
vim.keymap.set("n", "<Esc>", function()
  if tv.is_active() then
    tv.off()
    return ""
  end
  return "<Esc>"
end, { expr = true, silent = true, desc = "TunnelVision off on Esc" })

vim.keymap.set("n", "<leader>V", function()
  tv.on({ scope = "buffer", sources = { "word" } })
end, { desc = "TunnelVision word in buffer" })
```

Use `toggle` instead of `on` in the first mapping if preferred. For scripted
additive batch activation, `on_many({ { row, col }, ... }, opts)` accepts
(1,0)-indexed positions in the current buffer. With a dynamic default, all but
the last position are pinned and the last becomes the moving track. Native
multicursor activation and cursor creation are deferred until Neovim 0.13 APIs
can be verified; pass positions explicitly for now.

## Custom Sources

Register a synchronous Lua function before using its name in `sources`. This
example defines an `assertions` source; it is not built in:

```lua
local tv = require("tunnelvision")

tv.register_source("assertions", function(ctx)
  local matches = {}
  local lines = vim.api.nvim_buf_get_lines(
    ctx.bufnr,
    ctx.scope.start_line - 1,
    ctx.scope.end_line,
    false
  )

  for offset, text in ipairs(lines) do
    local symbol = "%f[%w_]" .. vim.pesc(ctx.symbol) .. "%f[^%w_]"
    if text:find("assert", 1, true) and text:find(symbol) then
      matches[ctx.scope.start_line + offset - 1] = true
    end
  end

  return matches
end)

tv.setup({ sources = { "lsp", "assertions", "word" } })
```

The handler receives `bufnr`, `symbol`, `anchor`, `scope`, `mode`, `direction`,
and `keywords`. Return a line set such as `{ [3] = true, [8] = true }`. `nil`,
`false`, an empty table, or an error continues the chain; invalid and out-of-scope
lines are ignored.

Custom sources work in `combine(...)`. They are synchronous and Lua-only, so
`:TunnelVision source` does not accept them. Built-in and legacy names cannot be
replaced.

## Compatibility and Project

Legacy options remain supported without runtime deprecation warnings, but new
configuration should use the composable forms:

| Old | New |
| --- | --- |
| `source = "word"` | `sources = { "word" }` |
| `source = "lsp"` | `sources = { "lsp" }` |
| `source = "lsp_else_word"` | `sources = { "lsp", "word" }` |
| `source = "lsp_and_word"` | `sources = { tv.combine("lsp", "word") }` |
| `direction = "both"` | `flow_settings = { direction = "both" }` |
| `extra_keywords = { ... }` | `flow_settings = { extra_keywords = { ... } }` |
| `dim_hl = "..."` | `dim = ...` |

`on()` keeps its original replace-one-target behavior. Use `add()` to retain
other tracks, `pin()` for a fixed track, or `on_many()` for additive batches.
The existing `:TunnelVision retarget` alias still acts like `on`.
Existing setup defaults still produce line focus with Comment-derived dimming.
One-shot `on({ dim = color })` must move to `set_buffer_dim(color)` or
`setup({ dim = color })`; only `on({ dim = "none" })` remains valid. Move one-shot
`dim_hl` and `max_dim_lines` settings to `setup()`. This is a breaking API change.

Run `:checkhealth tunnelvision` to check Neovim, Tree-sitter, LSP highlighting,
and the dim highlight. Contributions are welcome; include the rationale and
update the documentation and `CHANGELOG.md`.

# Other approaches:

- [folke/twilight.nvim](https://github.com/folke/twilight.nvim)
- [RRethy/vim-illuminate](https://github.com/RRethy/vim-illuminate)
- [junegunn/limelight.vim](https://github.com/junegunn/limelight.vim)
