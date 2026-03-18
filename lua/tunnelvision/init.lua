local core = require("tunnelvision.core")
local ui = require("tunnelvision.ui")

local M = {}

core.set_renderer(ui.apply_dim)

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if core.is_active(bufnr) then
    core.deactivate(bufnr)
  else
    core.activate(bufnr)
  end
end

function M.forward()
  core.activate(vim.api.nvim_get_current_buf())
end

function M.dynamic()
  core.set_mode("dynamic")
  core.activate(vim.api.nvim_get_current_buf())
end

local function jump_or_notify(direction, count)
  if not core.jump_in_path(direction, count) then
    core.notify("TunnelVision: not active in this buffer", vim.log.levels.WARN)
  end
end

function M.next(count)
  jump_or_notify(1, count)
end

function M.prev(count)
  jump_or_notify(-1, count)
end

function M.refresh()
  core.refresh(vim.api.nvim_get_current_buf())
end

function M.get_mode()
  return core.get_mode()
end

function M.set_mode(mode)
  core.set_mode(mode)
end

function M.get_flow_direction()
  return core.get_flow_direction()
end

function M.set_flow_direction(direction)
  core.set_flow_direction(direction)
end

function M.get_symbol_source()
  return core.get_symbol_source()
end

function M.set_symbol_source(source)
  core.set_symbol_source(source)
end

function M.setup(opts)
  core.configure(opts)
  ui.setup(M)
end

return M
