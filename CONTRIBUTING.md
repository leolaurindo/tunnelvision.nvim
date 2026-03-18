# Contributing

Thanks for contributing to `tunnelvision.nvim`.

## Development setup

1. Clone the repo.
2. Open Neovim with this repo in `runtimepath` (or use your plugin manager dev mode).
3. Run smoke checks:

```bash
nvim --headless -u NONE -c "luafile tests/smoke.lua" -c "qa!"
```

## Style

- Format Lua with `stylua` (`stylua .`).
- Lint with `luacheck` (`luacheck lua tests`).
- Keep public API docs in LuaCATS comments (`---@param`, `---@return`).

## Pull requests

- Keep changes focused and include rationale.
- Update `README.md` and `DOCS.md` when behavior or API changes.
- Add/update smoke checks for behavior that can regress.
