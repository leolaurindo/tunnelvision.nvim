-- Shared assertions, stubs, and buffer helpers for the smoke suite.
-- Loaded with dofile() by the smoke entrypoint, which owns the runtime path.
local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local core = require("tunnelvision.core")
local config = require("tunnelvision.config")

local helpers = { root = root }

function helpers.fail(msg)
  error("[tunnelvision smoke] " .. msg)
end

function helpers.assert_true(cond, msg)
  if not cond then
    helpers.fail(msg)
  end
end

function helpers.parser_or_skip(bufnr, language, coverage)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language)
  if ok and parser then
    return parser
  end
  if ({ cpp = true, go = true, rust = true })[language] then
    print(("tunnelvision smoke: SKIP %s: optional %s parser unavailable (%s)"):format(coverage, language, parser))
    return
  end
  helpers.fail(("required %s parser unavailable for %s: %s"):format(language, coverage, parser))
end

function helpers.assert_ranges(actual, expected, msg)
  helpers.assert_true(vim.deep_equal(actual, expected), msg .. ": " .. vim.inspect(actual))
end

function helpers.assert_sources(expected, msg)
  local got = require("tunnelvision").get_sources()
  helpers.assert_true(vim.deep_equal(got, expected), msg .. ": " .. vim.inspect(got))
end

function helpers.assert_combine(step, expected, msg)
  local combine = { kind = "combine", names = expected }
  helpers.assert_true(vim.deep_equal(step, combine), msg .. ": " .. vim.inspect(step))
end

function helpers.new_buffer(lines, filetype)
  vim.cmd("enew")
  vim.bo.filetype = filetype or "lua"
  if lines then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end
  return vim.api.nvim_get_current_buf()
end

function helpers.assert_default_visual_config(msg)
  helpers.assert_true(config.format_sources(core.state.config.sources) == "lsp,treesitter,word", msg .. " sources")
  helpers.assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), msg .. " highlights")
  helpers.assert_true(core.state.config.dim == nil, msg .. " dim")
end

function helpers.marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr or 0, core.state.ns, 0, -1, { details = true })
end

return helpers
