# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - Unreleased

Version 0.4 adds a `highlights` table for configuring visible contexts and their
styles. The default remains unchanged line focus with Comment-derived dimming.

### Added
- Added unified `highlights` rules for four increasingly specific contexts:
  `scope_head`, `statement`, `line`, and exact `symbol` ranges. Rules can preserve
  original colors with `true` or `{}`, or apply `fg`, `bg`, `bold`, `italic`,
  `underline`, `undercurl`, `strikethrough`, and `bg_opacity` styles.
- Added attribute-level composition in `scope_head -> statement -> line -> symbol`
  order. More-specific contexts override only the attributes they provide.
- Added token-only focus with exact source-owned ranges. On matched path lines,
  TunnelVision can now dim only the text around matched symbols while leaving
  their original syntax colors intact.
- Added deterministic background pseudo-opacity by blending a configured
  background with the colorscheme's `Normal` background.
- Added `dim = "none"` for using positive context styles without dimming unrelated
  text.
- Added `register_source(name, handler)` for custom synchronous Lua sources in
  fallback chains and strict combined source steps.

### Changed
- Statement and scope-head highlighting now uses Tree-sitter independently of
  symbol source selection. LSP, Tree-sitter, word, and custom source paths can all
  gain structural context. Unsafe statements fall back to matched lines, missing
  scope heads are skipped, and structural warnings follow `fallback_warn`.
- Sources and word-enabled, eligible flow paths now retain exact symbol ranges for
  visual styling. Structural context remains visual only; navigation continues
  through source/flow path lines.
- One-shot `highlights` follows the same replacement semantics as setup: omitted
  rules inherit setup, an empty table selects default line focus, and a non-empty
  table replaces the setup rules for that activation.
- Existing setup forms require no migration. Bare setup, legacy `source` values
  such as `lsp_else_word`, and modern `sources` chains keep line focus with
  Comment-derived dimming unless users opt into richer visual rules.
- Refactored internal source resolution without changing public behavior.
- Clarified internal fallback metadata for source-chain resolution without
  changing public behavior.

### Fixed
- Function scope detection now skips Tree-sitter nodes that describe calls,
  signatures, types, declarators, parameters, and other non-body constructs
  instead of treating them as enclosing functions. This fixes narrow scopes in
  Lua calls, C/C++ declarators, Java method invocations, and similar grammar
  nodes while retaining broad parser compatibility.
- Added function-scope support for Rust `closure_expression` nodes.
- Statement context now recognizes standalone Lua function calls and common
  parameter declaration forms without emitting unnecessary line-fallback
  warnings. Calls nested in assignments still resolve to the enclosing
  assignment or declaration.

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
