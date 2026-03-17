local M = {}

local defaults = {
  scope = "auto",
  mode = "static",
  flow_direction = "forward",
  include_lsp_highlights = true,
  lsp_timeout_ms = 150,
  dim_hl = "TunnelVisionDim",
  max_dim_lines = 6000,
  use_bracket_h = true,
  use_nN = false,
  use_leader_h = true,
  use_esc = true,
  notify = true,
}

local state = {
  ns = vim.api.nvim_create_namespace("tunnelvision"),
  bufs = {},
  config = vim.deepcopy(defaults),
  mappings_set = false,
  commands_set = false,
  augroup = nil,
}

local keywords = {}
for keyword in ([[
and break case catch class const continue default defer do else elseif end enum except export
false finally fn for func function if implements import in interface is lambda let local match mod
namespace new nil not null of or package private protected public return self static struct super
switch then this throw true try type typeof union until use var void while with yield
]]):gmatch("%S+") do
  keywords[keyword] = true
end

local assign_ops = { "+=", "-=", "*=", "/=", "%=", "=" }

local function notify(msg, level)
  if state.config.notify then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
end

local function get_buf_state(bufnr)
  local s = state.bufs[bufnr]
  if not s then
    s = {
      active = false,
      symbol = nil,
      anchor = nil,
      scope = nil,
      path_set = {},
      path_order = {},
    }
    state.bufs[bufnr] = s
  end
  return s
end

local function clear_buf_state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
  state.bufs[bufnr] = nil
end

local function ensure_highlights()
  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok and comment and comment.fg then
    vim.api.nvim_set_hl(0, state.config.dim_hl, { fg = comment.fg, italic = true })
  else
    vim.api.nvim_set_hl(0, state.config.dim_hl, { link = "Comment", default = true })
  end
end

local function line_has_word(line, word)
  if not line or line == "" or not word or word == "" then
    return false
  end
  local escaped = vim.pesc(word)
  return line:find("%f[%w_]" .. escaped .. "%f[^%w_]") ~= nil
end

local function get_line_target_col(line, symbol)
  local symbol_col = line and symbol and symbol ~= "" and line:find("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]")
  if symbol_col then
    return symbol_col - 1
  end
  local first_nonblank = line and line:find("%S")
  return first_nonblank and first_nonblank - 1 or 0
end

local function strip_strings_and_comments(line)
  local s = line
  s = s:gsub('".-"', '""')
  s = s:gsub("'.-'", "''")
  s = s:gsub("//.*$", "")
  s = s:gsub("#.*$", "")
  s = s:gsub("%-%-.*$", "")
  return s
end

local function collect_identifiers(text)
  local out = {}
  for id in text:gmatch("[%a_][%w_]*") do
    if not keywords[id] then
      out[id] = true
    end
  end
  return out
end

local function set_intersects(a, b)
  for name in pairs(a) do
    if b[name] then
      return true
    end
  end
  return false
end

local function add_set(dst, src)
  local changed = false
  for name in pairs(src) do
    if not dst[name] then
      dst[name] = true
      changed = true
    end
  end
  return changed
end

local function find_assign(line)
  for _, op in ipairs(assign_ops) do
    local start_col = line:find(op, 1, true)
    if start_col then
      if op == "=" then
        local prev = start_col > 1 and line:sub(start_col - 1, start_col - 1) or ""
        local nxt = line:sub(start_col + 1, start_col + 1)
        if prev ~= "=" and prev ~= ">" and prev ~= "<" and prev ~= "!" and nxt ~= "=" then
          return start_col, op
        end
      else
        return start_col, op
      end
    end
  end
  return nil, nil
end

local function parse_assignment(line)
  local assign_col, op = find_assign(line)
  if not assign_col then
    return nil, nil
  end

  local lhs_text = line:sub(1, assign_col - 1)
  local rhs_text = line:sub(assign_col + #op)
  if lhs_text:find(",", 1, true) then
    return nil, nil
  end

  local lhs_name = lhs_text:match("^%s*local%s+([%a_][%w_]*)")
    or lhs_text:match("([%a_][%w_]*)%s*$")

  if not lhs_name or keywords[lhs_name] then
    return nil, nil
  end

  local lhs = { [lhs_name] = true }
  local rhs = collect_identifiers(rhs_text)
  if op ~= "=" then
    rhs[lhs_name] = true
  end
  return lhs, rhs
end

local function is_function_like(node_type)
  return node_type:find("function", 1, true)
    or node_type:find("method", 1, true)
    or node_type:find("lambda", 1, true)
    or node_type:find("arrow", 1, true)
    or node_type == "func_literal"
end

local function get_scope_range(bufnr, anchor, scope_mode)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if scope_mode == "file" then
    return 1, total, "file"
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok_parser and parser then
    local ok_tree, parsed = pcall(parser.parse, parser)
    if ok_tree and parsed and parsed[1] then
      local root = parsed[1]:root()
      local node = root:named_descendant_for_range(anchor.row, anchor.col, anchor.row, anchor.col)
      while node do
        local t = node:type()
        if is_function_like(t) then
          local start_row, _, end_row, _ = node:range()
          return start_row + 1, end_row + 1, "function"
        end
        node = node:parent()
      end
    end
  end

  return 1, total, "file"
end

local function get_lsp_highlight_lines(bufnr, anchor, scope)
  local out = {}
  if not state.config.include_lsp_highlights then
    return out
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = anchor.row, character = anchor.col },
  }

  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentHighlight", params, state.config.lsp_timeout_ms)
  if not responses then
    return out
  end

  for _, resp in pairs(responses) do
    if resp and resp.result then
      for _, item in ipairs(resp.result) do
        local r = item.range
        if r and r.start and r["end"] then
          local from = r.start.line + 1
          local to = r["end"].line + 1
          for lnum = from, to do
            if lnum >= scope.start_line and lnum <= scope.end_line then
              out[lnum] = true
            end
          end
        end
      end
    end
  end

  return out
end

local function sorted_lines(path_set)
  local out = {}
  for lnum in pairs(path_set) do
    out[#out + 1] = lnum
  end
  table.sort(out)
  return out
end

local function is_valid_mode(mode)
  return mode == "static" or mode == "flow" or mode == "dynamic"
end

local function is_valid_flow_direction(direction)
  return direction == "forward" or direction == "both"
end

local function normalize_config(cfg)
  if cfg.transformations ~= nil then
    cfg.mode = cfg.transformations and "flow" or "static"
  end
  if cfg.propagate_backwards ~= nil then
    cfg.flow_direction = cfg.propagate_backwards and "both" or "forward"
  end

  if cfg.use_leader_H ~= nil and cfg.use_leader_h == nil then
    cfg.use_leader_h = cfg.use_leader_H
  end

  cfg.transformations = nil
  cfg.propagate_backwards = nil
  cfg.use_leader_H = nil

  if not is_valid_mode(cfg.mode) then
    cfg.mode = "static"
  end
  if not is_valid_flow_direction(cfg.flow_direction) then
    cfg.flow_direction = "forward"
  end
end

local function compute_path(bufnr, symbol, anchor, scope)
  local path_set = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, scope.start_line - 1, scope.end_line, false)
  local use_flow = state.config.mode == "flow"
  local tracked = { [symbol] = true }
  local line_info = {}

  for idx, raw in ipairs(lines) do
    local lnum = scope.start_line + idx - 1
    local cleaned = strip_strings_and_comments(raw)

    if line_has_word(cleaned, symbol) then
      path_set[lnum] = true
    end

    if use_flow then
      local ids = collect_identifiers(cleaned)
      local lhs, rhs = parse_assignment(cleaned)
      line_info[#line_info + 1] = {
        lnum = lnum,
        ids = ids,
        lhs = lhs,
        rhs = rhs,
      }
    end
  end

  local lsp_lines = get_lsp_highlight_lines(bufnr, anchor, scope)
  add_set(path_set, lsp_lines)

  if not use_flow then
    path_set[anchor.row + 1] = true
    return path_set, sorted_lines(path_set)
  end

  local changed = true
  local guard = 0
  while changed and guard < 32 do
    changed = false
    guard = guard + 1

    for _, info in ipairs(line_info) do
      local lhs_hit = info.lhs and set_intersects(info.lhs, tracked) or false
      local rhs_hit = info.rhs and set_intersects(info.rhs, tracked) or false
      local ids_hit = set_intersects(info.ids, tracked)

      if lhs_hit or rhs_hit or ids_hit then
        path_set[info.lnum] = true
      end
      if rhs_hit and info.lhs then
        changed = add_set(tracked, info.lhs) or changed
      end
      if state.config.flow_direction == "both" and lhs_hit and info.rhs then
        changed = add_set(tracked, info.rhs) or changed
      end
    end
  end

  path_set[anchor.row + 1] = true
  return path_set, sorted_lines(path_set)
end

local function apply_dim(bufnr)
  local bs = state.bufs[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)

  if not bs or not bs.active then
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total > state.config.max_dim_lines then
    notify(("TunnelVision: file too large to dim (%d lines > %d)"):format(total, state.config.max_dim_lines), vim.log.levels.WARN)
    return
  end

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for idx, line in ipairs(all_lines) do
    if not bs.path_set[idx] then
      vim.api.nvim_buf_set_extmark(bufnr, state.ns, idx - 1, 0, {
        end_row = idx - 1,
        end_col = #line,
        hl_group = state.config.dim_hl,
        hl_eol = true,
        priority = 1000,
      })
    end
  end
end

local function activate(bufnr, opts)
  opts = opts or {}
  local symbol = vim.fn.expand("<cword>")
  if not symbol or symbol == "" then
    if not opts.silent then
      notify("TunnelVision: no symbol under cursor", vim.log.levels.WARN)
    end
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local anchor = {
    row = cursor[1] - 1,
    col = cursor[2],
  }

  local start_line, end_line, scope_kind = get_scope_range(bufnr, anchor, state.config.scope)
  local scope = {
    start_line = start_line,
    end_line = end_line,
    kind = scope_kind,
  }

  local path_set, path_order = compute_path(bufnr, symbol, anchor, scope)
  local bs = get_buf_state(bufnr)
  bs.active = true
  bs.symbol = symbol
  bs.anchor = anchor
  bs.scope = scope
  bs.path_set = path_set
  bs.path_order = path_order

  apply_dim(bufnr)
end

local function deactivate(bufnr)
  local bs = get_buf_state(bufnr)
  bs.active = false
  bs.symbol = nil
  bs.anchor = nil
  bs.scope = nil
  bs.path_set = {}
  bs.path_order = {}
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
end

local function jump_in_path(direction, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = get_buf_state(bufnr)
  if not bs.active or #bs.path_order == 0 then
    return false
  end

  local steps = math.max(1, count or 1)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]

  for _ = 1, steps do
    local target = nil
    if direction > 0 then
      for _, lnum in ipairs(bs.path_order) do
        if lnum > line then
          target = lnum
          break
        end
      end
      target = target or bs.path_order[1]
    else
      for i = #bs.path_order, 1, -1 do
        local lnum = bs.path_order[i]
        if lnum < line then
          target = lnum
          break
        end
      end
      target = target or bs.path_order[#bs.path_order]
    end
    line = target
  end

  local target_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local col = get_line_target_col(target_line, bs.symbol)
  vim.api.nvim_win_set_cursor(0, { line, col })
  return true
end

function M.is_active(bufnr)
  local b = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local bs = state.bufs[b]
  return bs and bs.active or false
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.is_active(bufnr) then
    deactivate(bufnr)
  else
    activate(bufnr)
  end
end

function M.on()
  activate(vim.api.nvim_get_current_buf())
end

function M.off()
  deactivate(vim.api.nvim_get_current_buf())
end

function M.forward()
  M.on()
end

function M.dynamic()
  M.set_mode("dynamic")
  activate(vim.api.nvim_get_current_buf())
end

local function jump_or_notify(direction, count)
  if jump_in_path(direction, count) then
    return
  end
  notify("TunnelVision: not active in this buffer", vim.log.levels.WARN)
end

function M.next(count)
  jump_or_notify(1, count)
end

function M.prev(count)
  jump_or_notify(-1, count)
end

local function refresh_buffer(bufnr, bs)
  local path_set, path_order = compute_path(bufnr, bs.symbol, bs.anchor, bs.scope)
  bs.path_set = path_set
  bs.path_order = path_order
  apply_dim(bufnr)
  return #path_order
end

function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = state.bufs[bufnr]
  if not bs or not bs.active then
    return
  end

  refresh_buffer(bufnr, bs)
end

local function refresh_active_buffers()
  for bufnr, bs in pairs(state.bufs) do
    if bs.active and vim.api.nvim_buf_is_valid(bufnr) then
      refresh_buffer(bufnr, bs)
    end
  end
end

function M.get_mode()
  return state.config.mode
end

function M.set_mode(mode)
  local next_mode = mode
  if next_mode == "toggle" then
    next_mode = state.config.mode == "static" and "flow" or "static"
  end

  if not is_valid_mode(next_mode) then
    notify("TunnelVision: mode must be static, flow, dynamic, or toggle", vim.log.levels.ERROR)
    return
  end

  state.config.mode = next_mode
  refresh_active_buffers()
end

function M.get_flow_direction()
  return state.config.flow_direction
end

function M.set_flow_direction(direction)
  local next_direction = direction
  if next_direction == "toggle" then
    next_direction = state.config.flow_direction == "forward" and "both" or "forward"
  end

  if not is_valid_flow_direction(next_direction) then
    notify("TunnelVision: flow direction must be forward, both, or toggle", vim.log.levels.ERROR)
    return
  end

  state.config.flow_direction = next_direction
  if state.config.mode == "flow" then
    refresh_active_buffers()
  end
end

local function ensure_commands()
  if state.commands_set then
    return
  end
  state.commands_set = true

  for _, cmd in ipairs({
    { "TunnelVisionOn", M.on, "Turn on tunnel vision for symbol under cursor" },
    { "TunnelVisionOff", M.off, "Turn off tunnel vision in current buffer" },
    { "TunnelVisionToggle", M.toggle, "Toggle tunnel vision for symbol under cursor" },
    { "TunnelVisionForward", M.forward, "Track symbol under cursor without toggling" },
    { "TunnelVisionDynamic", M.dynamic, "Set dynamic mode and track symbol under cursor" },
    { "TunnelVisionNext", function() M.next(vim.v.count1) end, "Jump to next tunnel vision line" },
    { "TunnelVisionPrev", function() M.prev(vim.v.count1) end, "Jump to previous tunnel vision line" },
    { "TunnelVisionRefresh", M.refresh, "Recompute tunnel vision path" },
  }) do
    vim.api.nvim_create_user_command(cmd[1], cmd[2], { desc = cmd[3] })
  end

  local function create_query_command(name, get_value, set_value, choices, label, desc)
    vim.api.nvim_create_user_command(name, function(opts)
      local arg = vim.trim(opts.args or "")
      if arg == "" then
        notify(("TunnelVision %s: %s"):format(label, get_value()))
        return
      end
      set_value(arg)
    end, {
      nargs = "?",
      complete = function()
        return choices
      end,
      desc = desc,
    })
  end

  create_query_command("TunnelVisionMode", M.get_mode, M.set_mode, { "static", "flow", "dynamic", "toggle" }, "mode", "Set tunnel vision mode (static|flow|dynamic|toggle)")
  create_query_command("TunnelVisionFlowDirection", M.get_flow_direction, M.set_flow_direction, { "forward", "both", "toggle" }, "flow direction", "Set flow direction (forward|both|toggle)")
end

local function ensure_mappings()
  if state.mappings_set then
    return
  end
  state.mappings_set = true

  if state.config.use_nN then
    local function set_path_mapping(key, direction, desc)
      vim.keymap.set("n", key, function()
        if M.is_active(0) then
          jump_in_path(direction, vim.v.count1)
          return ""
        end
        return key
      end, { expr = true, silent = true, desc = desc })
    end

    set_path_mapping("n", 1, "Next search (TunnelVision aware)")
    set_path_mapping("N", -1, "Prev search (TunnelVision aware)")
  end

  if state.config.use_bracket_h then
    vim.keymap.set("n", "]h", function()
      if M.is_active(0) then
        jump_in_path(1, vim.v.count1)
      end
    end, { silent = true, desc = "TunnelVision next" })

    vim.keymap.set("n", "[h", function()
      if M.is_active(0) then
        jump_in_path(-1, vim.v.count1)
      end
    end, { silent = true, desc = "TunnelVision prev" })
  end

  if state.config.use_esc then
    vim.keymap.set("n", "<Esc>", function()
      if M.is_active(0) then
        deactivate(vim.api.nvim_get_current_buf())
        return ""
      end
      return "<Esc>"
    end, { expr = true, silent = true, desc = "Exit TunnelVision on Esc" })
  end

  if state.config.use_leader_h then
    local function toggle_mode_mapping(mode)
      local bufnr = vim.api.nvim_get_current_buf()
      if M.is_active(bufnr) then
        if state.config.mode == mode then
          deactivate(bufnr)
        else
          M.set_mode(mode)
        end
      else
        M.set_mode(mode)
        activate(bufnr)
      end
    end

    vim.keymap.set("n", "<leader>hh", M.on, { silent = true, desc = "TunnelVision on/remap" })
    vim.keymap.set("n", "<leader>hs", function()
      toggle_mode_mapping("static")
    end, { silent = true, desc = "TunnelVision toggle static" })
    vim.keymap.set("n", "<leader>hd", function()
      toggle_mode_mapping("dynamic")
    end, { silent = true, desc = "TunnelVision toggle dynamic" })
    vim.keymap.set("n", "<leader>hf", function()
      toggle_mode_mapping("flow")
    end, { silent = true, desc = "TunnelVision toggle flow" })
    vim.keymap.set("n", "<leader>ho", M.off, { silent = true, desc = "TunnelVision off" })
  end
end

local function ensure_autocmds()
  if state.augroup then
    return
  end

  state.augroup = vim.api.nvim_create_augroup("TunnelVision", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.augroup,
    callback = function(args)
      clear_buf_state(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.augroup,
    callback = function()
      ensure_highlights()
      for bufnr, bs in pairs(state.bufs) do
        if bs.active and vim.api.nvim_buf_is_valid(bufnr) then
          apply_dim(bufnr)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    callback = function(args)
      if state.config.mode ~= "dynamic" then
        return
      end
      local bs = state.bufs[args.buf]
      if not bs or not bs.active then
        return
      end

      local symbol = vim.fn.expand("<cword>")
      if not symbol or symbol == "" or symbol == bs.symbol then
        return
      end

      activate(args.buf, { silent = true })
    end,
  })
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  normalize_config(state.config)
  ensure_highlights()
  ensure_commands()
  ensure_mappings()
  ensure_autocmds()
end

return M
