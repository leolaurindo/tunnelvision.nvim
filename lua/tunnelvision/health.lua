local M = {}

local function get_clients()
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({})
  end
  local ok, clients = pcall(vim.lsp.buf_get_clients, 0)
  return ok and clients or {}
end

local function has_doc_highlight(clients)
  for _, client in pairs(clients) do
    local caps = client.server_capabilities or client.resolved_capabilities
    if caps and (caps.documentHighlightProvider or caps.document_highlight) then
      return true
    end
  end
  return false
end

function M.check()
  vim.health.start("tunnelvision.nvim")

  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim version is >= 0.9")
  else
    vim.health.error("Neovim >= 0.9 is required")
  end

  if pcall(require, "vim.treesitter") then
    vim.health.ok("Tree-sitter runtime available")
  else
    vim.health.warn("Tree-sitter runtime not available; scope detection may be less accurate")
  end

  local clients = get_clients()
  if vim.tbl_isempty(clients) then
    vim.health.warn("No active LSP clients detected; strict source will fallback to lexical matching")
  elseif has_doc_highlight(clients) then
    vim.health.ok("At least one active LSP client supports documentHighlight")
  else
    vim.health.warn("Active LSP clients found, but none advertise documentHighlight")
  end

  local ok_core, core = pcall(require, "tunnelvision.core")
  if not ok_core then
    vim.health.error("Failed to load tunnelvision.core")
    return
  end

  local ok_hl, hl = pcall(vim.api.nvim_get_hl, 0, { name = core.state.config.dim_hl, link = false })
  if ok_hl and type(hl) == "table" and next(hl) ~= nil then
    vim.health.ok(("Highlight group '%s' is defined"):format(core.state.config.dim_hl))
  else
    vim.health.warn(("Highlight group '%s' is not currently defined; run setup() to initialize it"):format(core.state.config.dim_hl))
  end
end

return M
