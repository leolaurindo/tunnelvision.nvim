local core = require("tunnelvision.core")
local ui = require("tunnelvision.ui")

local M = {}

function M.add(opts)
  return core.activate(vim.api.nvim_get_current_buf(), opts)
end

function M.pin(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return false
  end
  return core.activate(vim.api.nvim_get_current_buf(), vim.tbl_extend("force", opts or {}, { pin = true }))
end

function M.remove()
  return core.remove(vim.api.nvim_get_current_buf())
end

function M.retarget(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  if not core.validate_options(opts, true) then
    return false
  end
  if not core.valid_target(bufnr, opts) then
    return false
  end
  local symbol = opts.symbol or core.symbol_at(bufnr, opts.cursor or vim.api.nvim_win_get_cursor(0))
  if not symbol or symbol == "" then
    return false
  end
  core.deactivate(bufnr)
  return core.activate(bufnr, vim.tbl_extend("force", opts, { symbol = symbol }))
end

function M.on(opts)
  if core.state.config.primary_action == "add" then
    return M.add(opts)
  end
  return M.retarget(opts)
end

function M.on_many(positions, opts)
  return core.activate_many(vim.api.nvim_get_current_buf(), positions, opts)
end

function M.set_buffer_dim(dim, bufnr)
  return core.set_buffer_dim(dim, bufnr)
end

function M.force_buffer_dim(enabled, bufnr)
  return core.force_buffer_dim(enabled, bufnr)
end

function M.set_quickfix(bufnr)
  return core.set_quickfix(bufnr)
end

function M.off()
  core.deactivate(vim.api.nvim_get_current_buf())
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if core.is_active(bufnr) then
    core.deactivate(bufnr)
  else
    core.activate(bufnr)
  end
end

local function jump_or_notify(direction, count, track_only)
  local jump = track_only and core.jump_in_track or core.jump_in_path
  if not jump(direction, count) then
    local message = track_only and "no matching track occurrences in this buffer" or "not active in this buffer"
    core.notify("TunnelVision: " .. message, vim.log.levels.WARN)
  end
end

function M.next(count)
  jump_or_notify(1, count)
end

function M.prev(count)
  jump_or_notify(-1, count)
end

function M.next_track(count)
  jump_or_notify(1, count, true)
end

function M.prev_track(count)
  jump_or_notify(-1, count, true)
end

function M.refresh()
  core.refresh(vim.api.nvim_get_current_buf())
end

function M.is_active(bufnr)
  return core.is_active(bufnr)
end

function M.status(bufnr)
  return core.get_status(bufnr)
end

function M.get_mode()
  return core.get_mode()
end

function M.set_mode(mode)
  core.set_mode(mode)
end

function M.get_direction()
  return core.get_direction()
end

function M.set_direction(direction)
  core.set_direction(direction)
end

function M.get_scope()
  return core.get_scope()
end

function M.set_scope(scope)
  core.set_scope(scope)
end

function M.add_keywords(words)
  return core.add_keywords(words)
end

function M.combine(...)
  return core.combine(...)
end

function M.register_source(name, handler)
  return core.register_source(name, handler)
end

function M.get_sources()
  return core.get_sources()
end

function M.set_sources(sources)
  core.set_sources(sources)
end

function M.get_source()
  return core.get_source()
end

function M.set_source(source)
  core.set_source(source)
end

function M.setup(opts)
  if not core.configure(opts) then
    return false
  end
  ui.setup(M)
  for bufnr, bs in pairs(core.state.bufs) do
    if bs.active then
      ui.render(bufnr)
    end
  end
end

return M
