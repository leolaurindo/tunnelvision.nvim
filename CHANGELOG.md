# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-07-02

### Added
- Added the new `sources` API for ordered source fallback. Source selection is
  now explicit, simple, and composable: use chains such as
  `sources = { "lsp", "treesitter", "word" }` instead of encoding behavior into
  one string.
- Added `combine(...)` for strict combined source steps in Lua config. A combined
  step behaves like "all": every source inside the step must produce usable
  matches, then their line sets are merged. If any member fails, the chain
  continues to the next fallback.
- Added `treesitter` as a lightweight syntax-aware source. It was added as a
  practical middle ground for cases where LSP is unavailable, slow, or heavier
  than needed: more precise than plain word matching, cheaper than semantic LSP,
  and intentionally not a full semantic analyzer.
- Added command fallback chains such as `:TunnelVision source lsp,word`,
  `:TunnelVision source treesitter,word`, and
  `:TunnelVision source lsp,treesitter,word`.
- Added `flow_settings` for flow-only options such as `direction` and
  `extra_keywords`, keeping the api simpler to understand.
- Expanded `dim` so dimming can be configured with `nil`, a highlight group name,
  a hex foreground color, or a highlight table.

### Changed
- The documented default config now uses `sources = { "lsp", "word" }`,
  preserving the previous LSP-first behavior while making fallback order visible.
- Source configuration now favors explicit fallback chains over special-case
  source names. This keeps common setups short while making richer setups easier
  to read.
- Tree-sitter can now sit between LSP and word matching as a fast syntax-aware
  fallback. LSP remains the default first source because it is semantic when
  `documentHighlight` is available.
- Flow configuration is grouped under `flow_settings`, keeping the top-level
  config focused on general behavior.
- Dimming configuration now favors the user-facing `dim` option instead of
  requiring users to manage highlight group names.

### Deprecated
- Deprecated `source` in favor of `sources`.
- Deprecated top-level `direction` and `extra_keywords` in favor of
  `flow_settings.direction` and `flow_settings.extra_keywords`.
- Deprecated public `dim_hl` configuration in favor of `dim`.

Deprecated APIs remain supported and do not emit runtime warnings in this
release.

## [0.2.1] - 2026-06-21

### Added
- Added `dim` color/style definitions for persistent config and one-shot activations.

## [0.2.0] - 2026-06-21

### Added
- Added one-shot activation overrides via `on(opts)` for alternate keymaps without changing global defaults.

## [0.1.1] - 2026-06-20

### Changed
- Simplified dynamic-mode debounce internals without changing user-facing behavior.
- Removed test-only renderer injection and reduced duplicate LSP warning code.
- Removed the redundant CI Lua syntax check; linting and smoke tests still run.

## [0.1.0] - 2026-04-16

### Added
- Initial public release of `tunnelvision.nvim`.
- Symbol-focused dimming that keeps attention on the active path in the current buffer.
- Support for `static`, `dynamic`, and experimental `flow` modes.
- Scope selection with `function` and `buffer`.
- Source selection with `lsp_else_word`, `lsp`, `lsp_and_word`, and `word`.
- Flow direction controls with `forward` and `both`.
- Runtime keyword extension with `add_keywords(words)` for flow mode.
- `:TunnelVision` command suite for activation, navigation, refresh, and configuration.
- Built-in health checks via `:checkhealth tunnelvision`.
- Runtime help documentation via `:help tunnelvision`.
- CI and smoke-test coverage for basic verification.
