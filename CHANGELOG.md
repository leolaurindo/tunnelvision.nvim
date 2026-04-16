# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
