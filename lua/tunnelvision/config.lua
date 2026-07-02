-- tunnelvision.config
--
-- Config normalization helpers for TunnelVision.
--
-- Responsibilities:
-- - define defaults, validation tables, and config normalization
-- - legacy source compatibility helpers
-- - source-chain copy and LSP detection helpers
--
-- This module is intentionally stateless. All functions receive the values
-- they need and return results without owning runtime lifecycle or UI.

local resolver = require("tunnelvision.resolver")

local M = {}

local defaults = {
  mode = "static",
  direction = "forward",
  scope = "function",
  extra_keywords = {},
  flow_settings = {
    direction = "forward",
    extra_keywords = {},
  },
  source = "lsp_else_word",
  sources = { "lsp", "word" },
  fallback_warn = "once",
  dim = nil,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  lsp_timeout_ms = 150,
  notify = true,
}
M.defaults = defaults

-- Validation tables

local valid_modes = { static = true, flow = true, dynamic = true }
local valid_directions = { forward = true, both = true }
local valid_scopes = { ["function"] = true, buffer = true }
local valid_sources = { lsp_else_word = true, lsp = true, lsp_and_word = true, word = true }
local valid_source_names = { lsp = true, word = true, treesitter = true }
local valid_fallback_warn = { once = true, always = true, never = true }

M.valid_modes = valid_modes
M.valid_directions = valid_directions
M.valid_scopes = valid_scopes
M.valid_sources = valid_sources
M.valid_source_names = valid_source_names
M.valid_fallback_warn = valid_fallback_warn

M.activation_keys = {
  "mode",
  "direction",
  "scope",
  "extra_keywords",
  "flow_settings",
  "source",
  "sources",
  "fallback_warn",
  "lsp_timeout_ms",
  "dim",
  "dim_hl",
}

-- Source-helpers

local function source_step(step)
  if type(step) == "string" and valid_source_names[step] then
    return { kind = "single", name = step }
  end

  if type(step) == "table" and step.kind == "single" and valid_source_names[step.name] then
    return { kind = "single", name = step.name }
  end

  if type(step) == "table" and step.kind == "combine" and type(step.names) == "table" and #step.names > 0 then
    local names = {}
    for _, name in ipairs(step.names) do
      if not valid_source_names[name] then
        return nil
      end
      names[#names + 1] = name
    end
    return { kind = "combine", names = names }
  end
end

-- Legacy source mapping (deprecated, intentionally supports old source values
-- without runtime warnings).
function M.sources_from_legacy_source(source)
  if source == "word" or source == "lsp" then
    return { source }
  end
  if source == "lsp_and_word" then
    return { M.combine("lsp", "word") }
  end
  return { "lsp", "word" }
end

function M.normalize_sources(sources)
  local out = {}
  if type(sources) ~= "table" then
    return M.normalize_sources(defaults.sources)
  end

  for _, step in ipairs(sources) do
    local normalized = source_step(step)
    if not normalized then
      return M.normalize_sources(defaults.sources)
    end
    out[#out + 1] = normalized
  end

  return #out > 0 and out or M.normalize_sources(defaults.sources)
end

function M.get_sources_copy(sources)
  local out = {}
  for _, step in ipairs(sources or {}) do
    if step.kind == "single" then
      out[#out + 1] = step.name
    elseif step.kind == "combine" then
      out[#out + 1] = M.combine(unpack(step.names))
    end
  end
  return out
end

-- Inverse of sources_from_legacy_source: maps normalized sources back to a
-- legacy value, or returns nil for custom chains that cannot be represented.
function M.legacy_source_from_sources(sources)
  if #sources == 1 and sources[1].kind == "single" and valid_sources[sources[1].name] then
    return sources[1].name
  end
  if
    #sources == 2
    and sources[1].kind == "single"
    and sources[1].name == "lsp"
    and sources[2].kind == "single"
    and sources[2].name == "word"
  then
    return "lsp_else_word"
  end
  if
    #sources == 1
    and sources[1].kind == "combine"
    and #sources[1].names == 2
    and sources[1].names[1] == "lsp"
    and sources[1].names[2] == "word"
  then
    return "lsp_and_word"
  end
end

function M.sources_use_lsp(sources)
  for _, step in ipairs(sources or {}) do
    if step.name == "lsp" then
      return true
    end
    for _, name in ipairs(step.names or {}) do
      if name == "lsp" then
        return true
      end
    end
  end
  return false
end

function M.format_sources(sources)
  local parts = {}
  for _, step in ipairs(sources or {}) do
    if step.kind == "single" then
      parts[#parts + 1] = step.name
    elseif step.kind == "combine" then
      parts[#parts + 1] = "combine(" .. table.concat(step.names, ",") .. ")"
    end
  end
  return table.concat(parts, ",")
end

-- Public helpers

function M.combine(...)
  return { kind = "combine", names = { ... } }
end

function M.normalize(cfg)
  if not valid_modes[cfg.mode] then
    cfg.mode = defaults.mode
  end
  if not valid_directions[cfg.direction] then
    cfg.direction = defaults.direction
  end
  if not valid_scopes[cfg.scope] then
    cfg.scope = defaults.scope
  end
  if cfg.sources ~= nil then
    cfg.sources = M.normalize_sources(cfg.sources)
  else
    cfg.sources =
      M.normalize_sources(valid_sources[cfg.source] and M.sources_from_legacy_source(cfg.source) or defaults.sources)
  end
  cfg.source = M.legacy_source_from_sources(cfg.sources) or defaults.source
  if not valid_fallback_warn[cfg.fallback_warn] then
    cfg.fallback_warn = defaults.fallback_warn
  end
  -- Normalize dim: nil (derive from Comment), string group name (copy attrs),
  -- hex string (convert to { fg = ... }), highlight table (use as-is).
  if cfg.dim ~= nil then
    if type(cfg.dim) == "string" then
      if cfg.dim:match("^#%x%x%x%x%x%x$") then
        cfg.dim = { fg = cfg.dim }
      end
      -- else: keep as string (group name like "Comment")
    elseif type(cfg.dim) ~= "table" then
      cfg.dim = nil
    end
  end
  -- Compatibility: deprecated dim_hl support. If both dim and dim_hl are
  -- provided, dim is applied to the configured dim_hl group.
  cfg.extra_keywords = resolver.sanitize_keywords(cfg.extra_keywords)

  -- Compatibility: deprecated top-level flow options map into missing
  -- flow_settings fields. New nested fields win. No runtime warnings.
  if type(cfg.flow_settings) ~= "table" then
    cfg.flow_settings = {}
  end
  if cfg.flow_settings.direction == nil and cfg.direction ~= nil then
    cfg.flow_settings.direction = cfg.direction
  end
  if cfg.flow_settings.extra_keywords == nil and cfg.extra_keywords ~= nil then
    cfg.flow_settings.extra_keywords = cfg.extra_keywords
  end
  if not valid_directions[cfg.flow_settings.direction] then
    cfg.flow_settings.direction = defaults.flow_settings.direction
  end
  cfg.flow_settings.extra_keywords = resolver.sanitize_keywords(cfg.flow_settings.extra_keywords)

  cfg.max_dim_lines = math.max(1, tonumber(cfg.max_dim_lines) or defaults.max_dim_lines)
  cfg.lsp_timeout_ms = math.max(1, tonumber(cfg.lsp_timeout_ms) or defaults.lsp_timeout_ms)
end

function M.normalize_activation(base_config, opts, bufnr)
  local cfg = vim.deepcopy(base_config)
  for _, key in ipairs(M.activation_keys) do
    if opts[key] ~= nil then
      cfg[key] = opts[key]
    end
  end

  -- Compatibility: deprecated one-shot flow options fill missing
  -- flow_settings fields. New nested fields win. No runtime warnings.
  if opts.direction ~= nil and (opts.flow_settings == nil or opts.flow_settings.direction == nil) then
    if type(cfg.flow_settings) ~= "table" then
      cfg.flow_settings = {}
    end
    cfg.flow_settings.direction = cfg.direction
  end
  if opts.extra_keywords ~= nil and (opts.flow_settings == nil or opts.flow_settings.extra_keywords == nil) then
    if type(cfg.flow_settings) ~= "table" then
      cfg.flow_settings = {}
    end
    cfg.flow_settings.extra_keywords = cfg.extra_keywords
  end

  if opts.source ~= nil and opts.sources == nil then
    cfg.sources = nil
  end
  if opts.dim ~= nil and opts.dim_hl == nil and opts.config == nil then
    cfg.dim_hl = ("TunnelVisionDim%d"):format(bufnr)
  end
  M.normalize(cfg)
  return cfg
end

return M
