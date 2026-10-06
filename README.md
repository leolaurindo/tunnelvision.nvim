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

Put the cursor on a symbol and run `:TunnelVision on` to focus it (replacing
any tracks in this buffer). Move to another symbol and run `:TunnelVision add`
to keep the first track and add a second. Navigate with `:TunnelVision next` and
`:TunnelVision prev`, then finish with `:TunnelVision off`. For a one-shot mode,
use `:TunnelVision mode flow` or `:TunnelVision mode dynamic`; later activations
still use your setup defaults.

See [suggested keymaps](#suggested-keymaps)

## Modes, Sources, and Highlights

### Modes

| Mode | Behavior |
| --- | --- |
| `static` (default) | Pins the selected symbol. |
| `dynamic` | Retargets a moving track per cursor as cursors move. |
| `flow` | Pins a symbol and expands its path through assignments. |
| `dynamic_flow` | Retargets each moving track and recomputes its flow path. |

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
`underline`, `undercurl`, `strikethrough`, `bg_opacity`, `fg_group`, or
`bg_group`. `fg_group` and `bg_group` take the foreground or background,
respectively, from a colorscheme highlight group; explicit `fg` or `bg` takes
precedence. If a group lacks that color, other styles still apply. A group
background is used directly unless `bg_opacity` is explicitly set; no opacity is
inferred from the source group. Numeric opacity is clamped to `0..1` and
pre-blended against `Normal`, not alpha-blended; without a usable `Normal`
background, the source background is used unchanged.

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

Omitted or empty `highlights` defaults to
`{ statement = true, symbol = { bg_group = "Search" } }`.
Statement focus falls back to path lines without a usable Tree-sitter structure;
`Search` supplies a theme-derived symbol background when it has one, used directly
without added opacity. A non-empty table replaces the default; it is not merged.
Useful variations include:

```lua
{ highlights = { symbol = true } } -- token-only focus, original colors
{ highlights = { symbol = { bg_group = "Search", bold = true } } } -- theme-derived symbol background
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
still navigate the source/flow path. Structural fallbacks are quiet.

## Configuration

`setup()` defines defaults for new tracks; existing tracks keep their options.
`on(opts)` uses `primary_action` (replace by default); `retarget(opts)` always
replaces the buffer's tracks; `add(opts)` keeps them; `pin(opts)` adds fixed
tracks even with a dynamic mode. Activation uses all native cursors on Neovim
0.13, or the primary cursor on older versions. All accept one-shot overrides for
`mode`, `scope`, `sources`, `flow_settings`, and `highlights`. Setting
`dim = "none"` opts that track out of dimming; omitted `dim` requests dimming.
One-shot dim colors, `dim_hl`, and `max_dim_lines` are not accepted.

| Option | Default | Notes |
| --- | --- | --- |
| `primary_action` | `retarget` | `on()` replaces tracks with `retarget`, or retains them with `add`. |
| `mode` | `static` | `static`, `dynamic`, `flow`, or `dynamic_flow`. |
| `scope` | `function` | Nearest function-like Tree-sitter scope, falling back to the full buffer; also accepts `buffer`. |
| `sources` | `{ "lsp", "treesitter", "word" }` | Ordered source fallback chain. |
| `flow_settings.direction` | `forward` | `forward`, `backward`, or `both`. |
| `flow_settings.extra_keywords` | `{}` | Extra identifiers ignored during flow analysis. |
| `flow_settings.analyzers` | `{ "treesitter", "text" }` | Ordered analyzer fallback; use one item for strict behavior. |
| `flow_settings.max_depth` | `nil` | Positive hop limit; `nil` uses the internal 32-hop guard. |
| `fallback_warn` | `once` | Legacy LSP-to-word fallback warning: `once` per buffer, `always`, or `never`. LSP timeouts and strict LSP warn once per buffer when notifications are enabled. |
| `lsp_timeout_ms` | `150` | Async LSP `documentHighlight` timeout. |
| `highlights` | `{ statement = true, symbol = { bg_group = "Search" } }` | Enabled visual contexts and their positive styles. [See configs](#highlights) |
| `dim` | `nil` | `nil` derives from `Comment`; accepts `"none"`, a highlight group, hex foreground, or style table. |
| `max_dim_lines` | `6000` | Skip dimming in larger buffers. |
| `notify` | `true` | Enable plugin notifications; invalid-option errors remain visible. |

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
setup; an empty table selects the plugin default; a non-empty table replaces the setup
rules for that activation. Use `{ line = true }` for line focus.

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

`on` uses `primary_action = "retarget"` by default; set it to `"add"` to retain
existing tracks. Explicit `retarget` always replaces tracks; `add` always keeps
them; `pin` adds fixed tracks even in dynamic modes. Track mode is independent
of this action. Native multicursor activation creates a track per cursor.
`remove` removes the track under the primary cursor or, if none is there, the
latest track; `off` clears the current buffer. Static and moving tracks can
coexist. `next`/`prev` visit the union of occurrences (and unmatched custom/flow
path lines). `next-track`/`prev-track` navigate the track under the cursor
(latest-added if tracks overlap), or the latest track when outside tracked paths.

`mode`, `direction`, `scope`, and `source` with an argument use the configured
`on()` action without changing setup defaults. `direction` starts flow analysis,
preserving `dynamic_flow` when active. Without an argument, they report the
active configuration (or setup defaults when inactive). `refresh` recomputes
active tracks with their original options and cursor associations.
`status` describes the active buffer. `next`/`prev` record jumps in the
jumplist (`<C-o>` returns), and `:TunnelVision quickfix` creates a new quickfix
list with positions from all tracked symbols; `:colder` restores the previous
list. Run `:help tunnelvision` for the complete command and Lua API reference.

### Suggested keymaps
```lua
local tv = require("tunnelvision")

-- on replaces the current buffer's tracks; add keeps them and tracks another symbol.
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

Use `toggle` instead of `on` in the first mapping if preferred. Native `*`, `n`,
and `N` mappings are unchanged.

### Multicursor activation

On Neovim 0.13, `on()`, `retarget()`, `add()`, and `pin()` use the primary cursor
plus secondary cursors from the `nvim.multicursor` extmark namespace. A secondary
cursor overlapping the primary is counted once. Replacing clears tracks once
before activating the batch; adding keeps existing tracks. In `dynamic` and
`dynamic_flow`, every cursor owns a moving track; secondary tracks follow stable
extmark IDs, not buffer order. `pin()` makes every track fixed instead.
TunnelVision does not create native cursors.

For scripted additive batches on any supported version,
`on_many({ { row, col }, ... }, opts)` accepts (1,0)-indexed positions and keeps
the selected mode for every track. Moving tracks associate with matching native
cursors when available, otherwise with cursor enumeration slots (primary first).
A moving track with no corresponding cursor stays at its last target. Supplying
`cursor` explicitly to `on()`, `add()`, or `pin()` targets only that position.

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

Legacy options remain supported. Deprecated setup inputs produce one aggregated
warning per Neovim session; deprecated API/command use warns at most once per
session. `notify = false` suppresses these warnings. Modern fields win conflicts.
Unknown options fail with a visible error before configuration or tracks change.
New configuration should use the composable forms:

| Old | New |
| --- | --- |
| `source = "word"` | `sources = { "word" }` |
| `source = "lsp"` | `sources = { "lsp" }` |
| `source = "lsp_else_word"` | `sources = { "lsp", "word" }` |
| `source = "lsp_and_word"` | `sources = { tv.combine("lsp", "word") }` |
| `direction = "both"` | `flow_settings = { direction = "both" }` |
| `extra_keywords = { ... }` | `flow_settings = { extra_keywords = { ... } }` |
| `dim_hl = "..."` | `dim = ...` |

`on()` retains replace behavior by default; opt into accumulation with
`primary_action = "add"`. Use `add()` to retain
other tracks, `pin()` for a fixed track, or `on_many()` for additive batches.
Explicit `retarget()` and `:TunnelVision retarget` always replace tracks, even
with `primary_action = "add"`. `get_source()`/`set_source()` and the old
`:Tunnelvision` spelling remain working deprecated wrappers; use
`get_sources()`/`set_sources()` and `:TunnelVision`. `get_direction()`,
`set_direction()`, and `add_keywords()` remain supported.
The current default uses statement focus and theme-derived symbol emphasis with Comment-derived dimming.
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
