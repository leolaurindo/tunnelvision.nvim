This is a good plugin to learn Lua with because it is compact and event-driven.

Read only these two files first:
- `README.md`
- `lua/tunnelvision/init.lua`

**How to read the plugin (in a useful order)**
- Start with `README.md` so you know intended behavior, modes, and public commands.
- Open `lua/tunnelvision/init.lua:684` (`M.setup`) to see startup wiring.
- Read command registration in `lua/tunnelvision/init.lua:563` (`ensure_commands`) to map user commands -> Lua functions.
- Read keymaps in `lua/tunnelvision/init.lua:601` (`ensure_mappings`) and autocmd behavior in `lua/tunnelvision/init.lua:637` (`ensure_autocmds`).
- Read runtime control flow: `M.toggle` (`lua/tunnelvision/init.lua:463`), `activate` (`lua/tunnelvision/init.lua:372`), `deactivate` (`lua/tunnelvision/init.lua:405`), `M.refresh` (`lua/tunnelvision/init.lua:484`).
- Read core path calculation last: `compute_path` (`lua/tunnelvision/init.lua:282`), then dim rendering in `apply_dim` (`lua/tunnelvision/init.lua:344`).

**Lua mental model (for this codebase)**
- Lua modules usually return a table; here `M` is that table (public API).
- `state` is the plugin singleton state (config + per-buffer runtime info).
- `defaults` is the baseline config that `setup()` merges with user options.
- Most functions are small helpers; user-facing commands call a small set of entry points.
- The main pipeline is: cursor word -> scope selection -> path line computation -> dim everything not in path.

**Lua quick-reference while reading**
- `local x = {}` creates a table (used as object/map/list).
- `tbl.key` and `tbl["key"]` are field lookup styles.
- `ipairs(t)` iterates array-like tables in numeric order.
- `pairs(t)` iterates key/value pairs in map-like tables.
- `pcall(fn, ...)` calls safely and prevents hard crashes.
- Arrays are 1-indexed in Lua.
- `vim.v.count1` means "user count, default 1" for motions/commands.

**How this plugin works in plain words**
- `strict` mode tracks symbol usages/references.
- `flow` mode adds lightweight assignment-based propagation heuristics.
- `dynamic` mode behaves like strict, but re-targets as cursor symbol changes.
- Scope is auto-detected (function/method if possible, file fallback).
- Optional LSP document highlights are merged into computed path lines.
- Rendering uses extmarks/highlights to dim non-path lines.

**What to review carefully before publishing**
- Correctness of `compute_path` for `strict` vs `flow` behavior.
- Noise/coverage tradeoff for `flow_direction = forward` vs `both`.
- Performance impact of `apply_dim` on large files (`max_dim_lines`).
- UX interactions for `n/N`, `<Esc>`, and `<leader>H` mappings.
- Edge handling when there is no symbol, no Treesitter, or no LSP response.

**TunnelVision commands (for manual testing)**
- `:TunnelVisionToggle`
- `:TunnelVisionForward`
- `:TunnelVisionDynamic`
- `:TunnelVisionNext`
- `:TunnelVisionPrev`
- `:TunnelVisionRefresh`
- `:TunnelVisionMode`
- `:TunnelVisionMode strict`
- `:TunnelVisionMode flow`
- `:TunnelVisionMode dynamic`
- `:TunnelVisionMode toggle`
- `:TunnelVisionFlowDirection`
- `:TunnelVisionFlowDirection forward`
- `:TunnelVisionFlowDirection both`
- `:TunnelVisionFlowDirection toggle`
