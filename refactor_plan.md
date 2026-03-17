# Refactor Plan: `init.lua` -> `init.lua` + `core.lua` + `ui.lua`

## Goal
Split `lua/tunnelvision/init.lua` into three modules with clear responsibilities while preserving current behavior and user-facing API.

## Target Structure
- `lua/tunnelvision/init.lua`
  - Public API only (`setup`, `toggle`, `forward`, `dynamic`, `next`, `prev`, `refresh`, mode getters/setters).
  - Thin orchestration layer that delegates to `core` and `ui`.
- `lua/tunnelvision/core.lua`
  - State/config ownership (`defaults`, runtime `state`, config normalization/validation).
  - Runtime behavior (activate/deactivate, refresh, jump navigation, scope/path computation).
  - Pure helpers currently in `init.lua` stay here to avoid over-fragmentation.
- `lua/tunnelvision/ui.lua`
  - Neovim integration concerns: highlights, dim rendering, commands, keymaps, autocmd registration.
  - Calls into `core` for state checks and actions.

## Function Move Guide
- Move to `core.lua`:
  - state/config: `defaults`, `state`, `get_buf_state`, `clear_buf_state`, mode/flow getters/setters, config normalize/validate.
  - analysis/runtime: `get_scope_range`, `compute_path`, `activate`, `deactivate`, `jump_in_path`, refresh helpers.
- Move to `ui.lua`:
  - `ensure_highlights`, `apply_dim`, `ensure_commands`, `ensure_mappings`, `ensure_autocmds`.
- Keep in `init.lua`:
  - module wiring and exported public functions only.

## Dependency Rules
- `init` depends on `core` + `ui`.
- `ui` depends on `core` (for actions/state checks).
- `core` depends on no plugin-local modules.
- Avoid circular requires; pass callbacks/refs from `init` if needed.

## Migration Steps (Low Risk)
1. Create `core.lua`; move state/config/runtime logic first with no behavior changes.
2. Create `ui.lua`; move render/wiring functions and point them to `core` APIs.
3. Reduce `init.lua` to public API wrappers + `setup` that initializes `ui` and `core`.
4. Verify all commands/mappings/autocmds and mode transitions still behave identically.

## Verification Checklist
- Commands: `:TunnelVisionToggle`, `:TunnelVisionForward`, `:TunnelVisionDynamic`, `:TunnelVisionRefresh`.
- Navigation: `n` / `N` path jumps when active.
- Mappings: `<Esc>` exits tunnel mode; `<leader>H` re-targets.
- Modes: `:TunnelVisionMode` and `:TunnelVisionFlowDirection` update behavior and refresh correctly.
- Rendering: dimming/highlights and colorscheme re-apply still work.
