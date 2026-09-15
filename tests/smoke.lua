local helpers = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local tunnelvision = require("tunnelvision")
local core = require("tunnelvision.core")

local assert_true = helpers.assert_true
local new_buffer = helpers.new_buffer
local parser_or_skip = helpers.parser_or_skip

dofile(helpers.root .. "/tests/smoke/scope.lua")(helpers)

dofile(helpers.root .. "/tests/smoke/config.lua")(helpers)

dofile(helpers.root .. "/tests/smoke/sources.lua")(helpers)

dofile(helpers.root .. "/tests/smoke/flow.lua")(helpers)

-- Edit bursts coalesce into one refresh, which explicit actions cancel.
do
  local edit_buf = new_buffer({
    "local alpha = 1",
    "local beta = alpha + 1",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  core.configure({ notify = false, source = "word", mode = "static", scope = "function" })
  core.activate(edit_buf, { silent = true, symbol = "alpha", cursor = { 1, 8 } })

  local deferred = {}
  local orig_defer_fn = vim.defer_fn
  vim.defer_fn = function(callback, timeout)
    local timer = { callback = callback, timeout = timeout }
    function timer:stop()
      self.stopped = true
    end
    function timer:close()
      self.closed = true
    end
    deferred[#deferred + 1] = timer
    return timer
  end

  local refreshes = 0
  local orig_refresh = core.refresh
  core.refresh = function(bufnr)
    refreshes = refreshes + 1
    return orig_refresh(bufnr)
  end

  local function edit(line)
    vim.api.nvim_buf_set_lines(edit_buf, 0, 1, false, { line })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = edit_buf })
  end

  edit("local alpha = 2")
  edit("local beta = 3")
  edit("local gamma = 4")
  assert_true(
    deferred[1].stopped and deferred[1].closed and deferred[2].stopped and deferred[2].closed,
    "newer edits should replace the pending timer"
  )
  assert_true(not deferred[3].stopped and deferred[3].timeout == 75, "the latest edit should retain one 75 ms timer")

  deferred[3].callback()
  local edit_state = core.get_buf_state(edit_buf)
  assert_true(refreshes == 1, "edit burst should refresh once")
  assert_true(
    edit_state.path_set[1]
      and edit_state.path_set[2]
      and #edit_state.symbol_ranges == 1
      and edit_state.symbol_ranges[1].line == 2
      and edit_state.scope.changedtick == vim.api.nvim_buf_get_changedtick(edit_buf),
    "debounced refresh should use the latest tick and contents"
  )

  deferred = {}
  edit("local alpha = 5")
  local explicit_timer = deferred[1]
  local before_explicit = refreshes
  core.refresh(edit_buf)
  assert_true(explicit_timer.stopped and explicit_timer.closed, "explicit refresh should cancel the queued timer")
  assert_true(refreshes == before_explicit + 1, "explicit refresh should run immediately")

  deferred = {}
  edit("local alpha = 6")
  local inactive_timer = deferred[1]
  core.deactivate(edit_buf)
  assert_true(inactive_timer.stopped and inactive_timer.closed, "deactivation should cancel the queued timer")

  core.activate(edit_buf, { silent = true, symbol = "alpha", cursor = { 1, 8 } })
  deferred = {}
  edit("local alpha = 7")
  local deleted_timer = deferred[1]
  vim.api.nvim_buf_delete(edit_buf, { force = true })
  assert_true(
    deleted_timer.stopped and deleted_timer.closed and core.state.bufs[edit_buf] == nil,
    "buffer deletion should cancel the queued timer and clear state"
  )

  core.refresh = orig_refresh
  vim.defer_fn = orig_defer_fn
end

-- Structural contexts use exact source columns and remain separate from paths.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  local structural_buf = new_buffer({
    "local function classify(alpha)",
    "  local total =",
    "    alpha +",
    "    1",
    "  if alpha > 0 then",
    "    total = total + alpha",
    "  elseif alpha < 0 then",
    "    total = alpha",
    "  else",
    "    total = 0",
    "  end",
    "  return total",
    "end",
  })

  local parser = parser_or_skip(0, "lua", "real Lua structural contexts")
  if parser then
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    tunnelvision.on({ highlights = { statement = true, scope_head = true } })
    local bs = core.get_buf_state(structural_buf)

    assert_true(
      vim.deep_equal(
        bs.statement_set,
        { [2] = true, [3] = true, [4] = true, [6] = true, [8] = true, [10] = true, [12] = true }
      ),
      "statement context should include complete conservative statements from exact columns"
    )
    assert_true(
      vim.deep_equal(bs.scope_head_set, { [1] = true, [5] = true, [7] = true, [9] = true }),
      "scope-head context should include function and conditional clause ancestors"
    )
    for _, lnum in ipairs(bs.path_order) do
      assert_true(not bs.scope_head_set[lnum], "scope heads should not enter path navigation")
    end

    local parse_count = 0
    local orig_get_parser = vim.treesitter.get_parser
    vim.treesitter.get_parser = function()
      return {
        parse = function()
          parse_count = parse_count + 1
          return parser:parse()
        end,
      }
    end
    require("tunnelvision.context").evaluate(bs.config, bs.path_set, bs.symbol_ranges, structural_buf, bs.scope)
    vim.treesitter.get_parser = orig_get_parser
    assert_true(parse_count == 1, "structural contexts should parse once per evaluation")

    tunnelvision.on({ highlights = { scope_head = true }, force = true })
    bs = core.get_buf_state(structural_buf)
    assert_true(next(bs.statement_set) == nil, "statement context should remain disabled independently")
    assert_true(bs.scope_head_set[9], "scope-head context should remain enabled independently")
    vim.cmd("TunnelVision off")

    assert_true(
      tunnelvision.register_source("structural_custom", function()
        return { [10] = true }
      end),
      "structural custom source registers"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 25 })
    tunnelvision.on({
      sources = { "structural_custom" },
      highlights = { statement = true, scope_head = true },
    })
    bs = core.get_buf_state(structural_buf)
    assert_true(bs.statement_set[10], "range-less custom path should use its first nonblank statement node")
    assert_true(bs.scope_head_set[9], "range-less custom path should retain its enclosing else head")
    vim.cmd("TunnelVision off")
    assert_true(next(bs.statement_set) == nil, "deactivation should clear statement context")
    assert_true(next(bs.scope_head_set) == nil, "deactivation should clear scope-head context")
  end
end

-- Grammar-neutral structural contracts cover columns and conservative boundaries.
do
  local context = require("tunnelvision.context")
  local buf = new_buffer({ "alpha(", "  value", ")" })
  local next_id, seen_col = 0
  local function node(node_type, parent, range)
    next_id = next_id + 1
    local id = next_id
    return {
      id = function()
        return id
      end,
      type = function()
        return node_type
      end,
      parent = function()
        return parent
      end,
      range = function()
        return unpack(range or { 0, 0, 0, 8 })
      end,
    }
  end
  local chunk = node("chunk")
  local assignment = node("assignment_statement", nil, { 0, 0, 2, 0 })
  local cases = {
    { "exclusive statement", node("expression_statement", nil, { 0, 0, 2, 0 }), { [1] = true, [2] = true }, false },
    { "standalone call", node("function_call", chunk, { 0, 0, 2, 0 }), { [1] = true, [2] = true }, false },
    {
      "nested call",
      node("function_call", node("expression_list", assignment), { 0, 0, 0, 8 }),
      { [1] = true, [2] = true },
      false,
    },
    { "parameter", node("parameter_declaration", node("parameters")), { [1] = true }, false },
    { "bare parameter", node("identifier", node("parameters")), { [1] = true }, false },
    { "argument", node("identifier", node("arguments")), { [1] = true }, true },
    { "broad container", node("try_statement"), { [1] = true }, true },
  }
  for _, case in ipairs(cases) do
    local tree_root = {
      named_descendant_for_range = function(_, _, col)
        seen_col = col
        return case[2]
      end,
    }
    local statements, _, fallback = context.evaluate(
      { highlights = { statement = {} } },
      { [1] = true },
      { { line = 1, start_col = 3, end_col = 8 } },
      buf,
      { start_line = 1, end_line = 3 },
      {
        get_treesitter = function()
          return { root = tree_root }
        end,
      }
    )
    assert_true(seen_col == 3, case[1] .. " should use the exact source column")
    assert_true(vim.deep_equal(statements, case[3]), case[1] .. " structural boundary")
    assert_true(fallback.statement == case[4], case[1] .. " fallback")
  end
end

-- Structural evaluation reuses duplicate and shared ancestor work within one call.
do
  local context = require("tunnelvision.context")
  local buf = new_buffer({ "function", "if", "alpha", "alpha", "other", "missing" })

  local function evaluate(highlights, selected_ranges)
    local parent_seen = {}
    local calls = { descendant = 0, statement_range = 0, statement_start = 0 }
    local definitions = {
      root = { id = 0, type = "chunk", row = 0 },
      ["function"] = { id = 1, type = "function_definition", row = 0, parent = "root" },
      ["if"] = { id = 2, type = "if_statement", row = 1, parent = "function" },
      statement = { id = 3, type = "assignment_statement", row = 2, parent = "if" },
      first = { id = 4, type = "identifier", row = 2, parent = "statement" },
      second = { id = 5, type = "identifier", row = 3, parent = "statement" },
      missing = { id = 6, type = "identifier", row = 5, parent = "if" },
    }
    local function node(name)
      local definition = definitions[name]
      local current = {}
      current.id = function()
        return definition.id
      end
      current.type = function()
        return definition.type
      end
      current.parent = function()
        assert_true(not parent_seen[name], "shared ancestor should not be entered twice: " .. name)
        parent_seen[name] = true
        return definition.parent and node(definition.parent)
      end
      current.range = function()
        if name == "statement" then
          calls.statement_range = calls.statement_range + 1
        end
        return definition.row, 0, definition.row == 2 and 4 or definition.row, 0
      end
      current.start = function()
        if name == "statement" then
          calls.statement_start = calls.statement_start + 1
        end
        return definition.row, 0
      end
      return current
    end

    local tree_root = node("root")
    local nodes = { ["2:1"] = "first", ["3:2"] = "second", ["5:0"] = "missing" }
    tree_root.named_descendant_for_range = function(_, row, col)
      calls.descendant = calls.descendant + 1
      return node(nodes[row .. ":" .. col])
    end

    local path = selected_ranges and { [3] = true, [4] = true } or { [3] = true, [4] = true, [6] = true }
    local ranges = selected_ranges
      or {
        { line = 3, start_col = 1 },
        { line = 3, start_col = 1 },
        { line = 4, start_col = 2 },
        { line = 6, start_col = 0 },
      }
    local statements, scope_heads, fallback = context.evaluate(
      { highlights = highlights },
      path,
      ranges,
      buf,
      { start_line = 2, end_line = 6 },
      {
        get_treesitter = function()
          return { root = tree_root }
        end,
      }
    )
    return statements, scope_heads, fallback, path, ranges, calls
  end

  local statements, scope_heads, fallback, path, ranges, calls = evaluate({ statement = {}, scope_head = {} })
  assert_true(vim.deep_equal(statements, { [3] = true, [4] = true, [6] = true }), "cached statement set")
  assert_true(vim.deep_equal(scope_heads, { [2] = true }), "cached and clipped scope-head set")
  assert_true(fallback.statement and not fallback.scope_head, "cached structural fallback")
  assert_true(vim.deep_equal(path, { [3] = true, [4] = true, [6] = true }), "context should not alter navigation")
  assert_true(#ranges == 4, "context should not alter navigation ranges")
  assert_true(calls.descendant == 3, "duplicate positions should share one descendant lookup")
  assert_true(
    calls.statement_range <= 1 and calls.statement_start <= 1,
    "shared statement geometry should not be repeated"
  )
  local parse_calls = 0
  statements, scope_heads, fallback = context.evaluate(
    { highlights = {} },
    { [1] = true },
    {},
    buf,
    { start_line = 1, end_line = 6 },
    {
      get_treesitter = function()
        parse_calls = parse_calls + 1
      end,
    }
  )
  assert_true(parse_calls == 0, "disabled structural contexts should do no parse work")
  assert_true(next(statements) == nil and next(scope_heads) == nil, "disabled structural contexts should stay empty")
  assert_true(not fallback.statement and not fallback.scope_head, "disabled structural fallback metadata")
end

-- Missing structural parsers fall back safely and obey warning policy.
do
  local messages = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    messages[#messages + 1] = msg
  end

  local structural_fallback_buf = new_buffer({ "alpha = 1", "print(alpha)" }, "plaintext")
  local function warning_count(policy, notify)
    messages = {}
    tunnelvision.setup({
      notify = notify,
      source = "word",
      scope = "buffer",
      fallback_warn = policy,
      highlights = { statement = true, scope_head = true },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    tunnelvision.on()
    local bs = core.get_buf_state(structural_fallback_buf)
    assert_true(vim.deep_equal(bs.statement_set, bs.path_set), "missing parser should preserve matched geometry")
    assert_true(next(bs.scope_head_set) == nil, "missing parser should skip scope heads")
    core.activate(structural_fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 1 } })
    vim.cmd("TunnelVision off")
    return #messages
  end
  for _, case in ipairs({
    { "once", true, 2 },
    { "always", true, 4 },
    { "never", true, 0 },
    { "always", false, 0 },
  }) do
    assert_true(warning_count(case[1], case[2]) == case[3], "structural fallback_warn " .. case[1])
  end

  vim.notify = orig_notify
end

-- === Dim API cleanup tests ===

-- Restore to baseline before dim form tests
tunnelvision.setup({ notify = false })

-- dim = nil uses Comment-derived default
tunnelvision.setup({ notify = false, dim = nil })
local nil_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
assert_true(nil_hl and comment_hl and nil_hl.fg == comment_hl.fg, "dim = nil should derive from Comment fg")

-- dim = "#445566" sets foreground color
tunnelvision.setup({ notify = false, dim = "#445566" })
local hex_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(hex_hl and hex_hl.fg == 0x445566, "dim = '#445566' should set fg")

-- dim = { fg = "#667788", italic = false } works
tunnelvision.setup({ notify = false, dim = { fg = "#667788", italic = false } })
local table_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(table_hl and table_hl.fg == 0x667788, "dim = { fg = ... } table form should set fg")
assert_true(
  table_hl and (table_hl.italic == nil or table_hl.italic == false),
  "dim = { italic = false } should not be italic"
)

vim.api.nvim_set_hl(0, "CompatDim", { fg = 0x998877 })
tunnelvision.setup({ notify = false, dim = "CompatDim" })
local copied_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(copied_hl.fg == 0x998877 and copied_hl.link == nil, "dim groups should be copied, not linked")

tunnelvision.setup({ notify = false, dim_hl = "CompatDim" })
assert_true(core.state.config.dim_hl == "CompatDim", "deprecated setup dim_hl should remain public")
tunnelvision.setup({ notify = false, dim = "#AABBCC", dim_hl = "CompatDim" })
assert_true(
  vim.api.nvim_get_hl(0, { name = "CompatDim", link = false }).fg == 0xAABBCC,
  "dim should apply to the deprecated dim_hl target"
)

tunnelvision.setup({ notify = false, dim = "DefinitelyMissingTunnelVisionDimGroup" })
assert_true(
  vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false }).fg == comment_hl.fg,
  "missing dim groups should use the Comment fallback"
)

-- one-shot dim = "#AA33CC" works
local oneshot_hex_buf = new_buffer({
  "local alpha = 1",
  "print(alpha)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = "#AA33CC" })
local oneshot_hex_hl =
  vim.api.nvim_get_hl(0, { name = core.get_buf_state(oneshot_hex_buf).config.dim_hl, link = false })
assert_true(oneshot_hex_hl and oneshot_hex_hl.fg == 0xAA33CC, "one-shot dim = '#AA33CC' should set fg")
vim.cmd("TunnelVision off")

vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim_hl = "CompatDim" })
assert_true(
  core.get_buf_state(oneshot_hex_buf).config.dim_hl == "CompatDim",
  "deprecated one-shot dim_hl should select its public group"
)
vim.cmd("TunnelVision off")

-- one-shot dim without one-shot dim_hl uses buffer-specific dim group
tunnelvision.setup({ notify = false, dim = { fg = 0x445566 } })
local buf_a = new_buffer({
  "local alpha = 1",
  "print(alpha)",
})
vim.api.nvim_win_set_cursor(0, { 1, 7 })
tunnelvision.on({ source = "word", dim = "#BB44DD" })
local buf_a_dim_hl = core.get_buf_state(buf_a).config.dim_hl
assert_true(
  buf_a_dim_hl:match("TunnelVisionDim%d+$"),
  "one-shot dim without one-shot dim_hl should use buffer-specific group"
)
-- Global dim should still use global group
local global_dim_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(global_dim_hl and global_dim_hl.fg == 0x445566, "global dim should be unchanged by buffer-specific group")
-- Buffer-specific group should have the one-shot color
local buf_a_hl = vim.api.nvim_get_hl(0, { name = buf_a_dim_hl, link = false })
assert_true(buf_a_hl and buf_a_hl.fg == 0xBB44DD, "buffer-specific dim group should have one-shot color")
vim.cmd("TunnelVision off")

-- invalid dim falls back to Comment-derived behavior
tunnelvision.setup({ notify = false, dim = 42 })
local invalid_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
assert_true(invalid_hl and invalid_hl.fg == comment_hl.fg, "invalid dim = 42 should fall back to Comment-derived fg")

tunnelvision.setup({ notify = false }) -- restore

-- colorscheme refresh preserves configured dim behavior
tunnelvision.setup({ notify = false, dim = "Comment" })
vim.cmd("colorscheme default")
local cs_copy_hl = vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false })
local cs_comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
assert_true(
  cs_copy_hl and cs_comment_hl and cs_copy_hl.fg == cs_comment_hl.fg,
  "colorscheme refresh should re-copy from Comment group for dim = 'Comment'"
)

tunnelvision.setup({ notify = false, dim = "#778899" })
vim.cmd("colorscheme default")
assert_true(
  vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false }).fg == 0x778899,
  "colorscheme refresh should preserve hex dim colors"
)

tunnelvision.setup({ notify = false }) -- restore
vim.cmd("TunnelVision off")
assert_true(not core.is_active(0), "deactivation failed")

-- One-shot highlight rules inherit or replace the setup rules.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  local highlight_buf = new_buffer({
    "local alpha = 1",
    "print(alpha)",
    "local beta = 2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })

  tunnelvision.on()
  local bs = core.get_buf_state(highlight_buf)
  assert_true(vim.deep_equal(bs.config.highlights, { symbol = {} }), "missing one-shot highlights should inherit")

  assert_true(
    core.activate(highlight_buf, {
      source = "word",
      scope = "buffer",
      highlights = { statement = true },
      symbol = "alpha",
      cursor = { 1, 7 },
    }),
    "changed one-shot highlights should invalidate config equality"
  )
  bs = core.get_buf_state(highlight_buf)
  assert_true(
    vim.deep_equal(bs.config.highlights, { statement = {} }),
    "non-empty one-shot highlights should replace setup rules"
  )

  core.activate(highlight_buf, {
    source = "word",
    scope = "buffer",
    highlights = {},
    symbol = "alpha",
    cursor = { 1, 7 },
    force = true,
  })
  assert_true(
    vim.deep_equal(core.get_buf_state(highlight_buf).config.highlights, { line = {} }),
    "empty one-shot highlights should use line default"
  )

  core.activate(highlight_buf, {
    source = "word",
    highlights = { unknown = true, symbol = 42, line = { bold = "yes" } },
    symbol = "alpha",
    cursor = { 1, 7 },
    force = true,
  })
  assert_true(
    vim.deep_equal(core.get_buf_state(highlight_buf).config.highlights, { line = {} }),
    "invalid one-shot highlight rules should normalize safely"
  )
  vim.cmd("TunnelVision off")
end

-- The renderer dims only the visible union's complement and composes styles.
do
  local ui = require("tunnelvision.ui")
  local orig_ensure_highlights = ui.ensure_highlights
  local orig_get_hl = vim.api.nvim_get_hl
  local orig_set_hl = vim.api.nvim_set_hl
  local normal_bg_calls = 0
  local function reset_highlight_calls()
    normal_bg_calls = 0
  end
  vim.api.nvim_get_hl = function(namespace, opts)
    if opts.name == "Normal" then
      normal_bg_calls = normal_bg_calls + 1
    end
    return orig_get_hl(namespace, opts)
  end
  local function capture_setups(action)
    local setups = {}
    ui.ensure_highlights = function(cfg)
      setups[cfg or false] = (setups[cfg or false] or 0) + 1
      return orig_ensure_highlights(cfg)
    end
    action()
    ui.ensure_highlights = orig_ensure_highlights
    return setups
  end
  local function marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, core.state.ns, 0, -1, { details = true })
  end

  local function mark_priority(details)
    -- Neovim 0.9 omits priority from line-highlight extmark details.
    return details.priority or (details.line_hl_group and 1000)
  end

  local function mark_snapshot(bufnr)
    local out = {}
    for _, mark in ipairs(marks(bufnr)) do
      local details = mark[4]
      out[#out + 1] = {
        mark[2],
        mark[3],
        details.end_col,
        details.hl_group,
        details.line_hl_group,
        mark_priority(details),
      }
    end
    return out
  end

  local render_buf = new_buffer({ "xx alpha yy alpha zz", "local beta = 1" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })

  tunnelvision.setup()
  reset_highlight_calls()
  tunnelvision.on({ scope = "buffer", silent = true })
  local default_snapshot = mark_snapshot(render_buf)
  assert_true(#default_snapshot == 1, "default renderer should add only the unrelated-line dim mark")
  assert_true(default_snapshot[1][5] == "TunnelVisionDim", "default renderer should use line dimming")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { symbol = true } })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  reset_highlight_calls()
  local bs = core.get_buf_state(render_buf)
  local setups = capture_setups(function()
    ui.render(render_buf)
  end)
  assert_true(
    setups[bs.config] == 1 and vim.tbl_count(setups) == 1,
    "each render should setup only its effective highlights once"
  )
  local symbol_marks = marks(render_buf)
  assert_true(#symbol_marks == 4, "empty symbol style should create three complement dims and one line dim")
  assert_true(
    symbol_marks[1][3] == 0 and symbol_marks[1][4].end_col == 3 and symbol_marks[1][4].hl_group == "TunnelVisionDim",
    "symbol renderer should dim bytes before the first range"
  )
  assert_true(
    symbol_marks[2][3] == 8 and symbol_marks[2][4].end_col == 12,
    "symbol renderer should dim bytes between ranges"
  )
  assert_true(
    symbol_marks[3][3] == 17 and symbol_marks[3][4].end_col == 20,
    "symbol renderer should dim bytes after the last range"
  )
  assert_true(symbol_marks[4][4].line_hl_group == "TunnelVisionDim", "unrelated lines should retain whole-line dimming")
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), {
      { 0, 0, 3, "TunnelVisionDim", nil, 1000 },
      { 0, 8, 12, "TunnelVisionDim", nil, 1000 },
      { 0, 17, 20, "TunnelVisionDim", nil, 1000 },
      { 1, 0, nil, nil, "TunnelVisionDim", 1000 },
    }),
    "empty styles should preserve exact visible geometry: " .. vim.inspect(mark_snapshot(render_buf))
  )

  bs.symbol_ranges = {
    { line = 1, start_col = 3, end_col = 8 },
    { line = 1, start_col = 4, end_col = 6 },
    { line = 1, start_col = 12, end_col = 17 },
  }
  require("tunnelvision.ui").render(render_buf)
  symbol_marks = marks(render_buf)
  assert_true(#symbol_marks == 4, "overlapping symbol ranges should render as one visible interval")
  assert_true(
    symbol_marks[2][3] == 8 and symbol_marks[2][4].end_col == 12,
    "nested symbol ranges should not move complement dimming inside a visible range"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    highlights = {
      scope_head = { fg = 0x111111, bold = true },
      statement = { fg = 0x222222, italic = true },
      line = { fg = 0x333333, bold = false, underline = true },
      symbol = { fg = 0x444444, italic = false, strikethrough = true },
    },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  bs = core.get_buf_state(render_buf)
  bs.scope_head_set = { [1] = true }
  bs.statement_set = { [1] = true }
  ui.clear_render_groups(bs)
  reset_highlight_calls()
  ui.render(render_buf)
  local composed_marks = marks(render_buf)
  assert_true(#composed_marks == 6, "composed whole-line styles should split around two symbol ranges")
  local line_group = composed_marks[1][4].hl_group
  local symbol_group = composed_marks[2][4].hl_group
  local line_hl = vim.api.nvim_get_hl(0, { name = line_group, link = false })
  local symbol_hl = vim.api.nvim_get_hl(0, { name = symbol_group, link = false })
  assert_true(
    line_hl.fg == 0x333333 and line_hl.italic and line_hl.underline,
    "whole-line attributes should compose in order"
  )
  assert_true(not line_hl.bold, "line boolean should override a broader plugin boolean")
  assert_true(
    symbol_hl.fg == 0x444444 and not symbol_hl.italic and symbol_hl.underline and symbol_hl.strikethrough,
    "symbol attributes should override conflicts and inherit other attributes"
  )
  assert_true(composed_marks[4][4].hl_group == symbol_group, "equal effective symbol styles should reuse a group")
  assert_true(mark_priority(composed_marks[1][4]) == 1100, "positive styles should use positive priority")
  assert_true(
    line_group:match("^TunnelVisionHighlight" .. render_buf .. "_"),
    "positive groups should be buffer-specific"
  )
  assert_true(mark_priority(composed_marks[6][4]) == 1000, "dim priority should remain below positive styles")
  local composed_snapshot = mark_snapshot(render_buf)
  assert_true(
    vim.deep_equal(composed_snapshot, {
      { 0, 0, 3, line_group, nil, 1100 },
      { 0, 3, 8, symbol_group, nil, 1100 },
      { 0, 8, 12, line_group, nil, 1100 },
      { 0, 12, 17, symbol_group, nil, 1100 },
      { 0, 17, 20, line_group, nil, 1100 },
      { 1, 0, nil, nil, "TunnelVisionDim", 1000 },
    }),
    "composed styles should preserve exact extmark geometry and order"
  )
  reset_highlight_calls()
  local redefined = false
  vim.api.nvim_set_hl = function(namespace, group, attrs)
    redefined = redefined or group == line_group or group == symbol_group
    return orig_set_hl(namespace, group, attrs)
  end
  ui.render(render_buf)
  vim.api.nvim_set_hl = orig_set_hl
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), composed_snapshot),
    "composed rerender should preserve extmarks"
  )
  assert_true(not redefined, "rerender should not redefine equal existing highlight groups")
  vim.cmd("TunnelVision off")

  local collision_buf = new_buffer({ "first", "other" })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    highlights = {
      scope_head = { fg = "#112233;bg=number:4478310" },
      line = { fg = "#112233", bg = 0x445566 },
    },
  })
  tunnelvision.on()
  local collision_bs = core.get_buf_state(collision_buf)
  collision_bs.symbol_ranges = {}
  collision_bs.statement_set = {}

  local function assert_collision_order(valid_line, invalid_line)
    collision_bs.path_set = { [valid_line] = true }
    collision_bs.scope_head_set = { [invalid_line] = true }
    ui.clear_render_groups(collision_bs)
    ui.render(collision_buf)
    local collision_marks = marks(collision_buf)
    assert_true(#collision_marks == 1, "invalid colliding style should not suppress or reuse the valid group")
    local group = collision_marks[1][4].hl_group
    assert_true(
      vim.deep_equal(mark_snapshot(collision_buf), { { valid_line - 1, 0, 5, group, nil, 1100 } }),
      "colliding styles should preserve the valid extmark in either resolution order: "
        .. vim.inspect(mark_snapshot(collision_buf))
    )
    local attrs = vim.api.nvim_get_hl(0, { name = group, link = false })
    assert_true(
      attrs.fg == 0x112233 and attrs.bg == 0x445566,
      "invalid colliding style should not alter valid attributes"
    )
  end

  assert_collision_order(2, 1)
  assert_collision_order(1, 2)
  vim.cmd("TunnelVision off")
  vim.api.nvim_buf_delete(collision_buf, { force = true })
  vim.api.nvim_set_current_buf(render_buf)

  vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = 0xFF0000, bg_opacity = 0.5, bold = true } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  reset_highlight_calls()
  tunnelvision.on()
  bs = core.get_buf_state(render_buf)
  local opacity_marks = marks(render_buf)
  assert_true(#opacity_marks == 2, "dim none should retain positive symbol marks")
  local opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x800080,
    "background opacity should blend deterministically against Normal"
  )
  local opacity_snapshot = mark_snapshot(render_buf)
  reset_highlight_calls()
  ui.render(render_buf)
  assert_true(
    vim.deep_equal(mark_snapshot(render_buf), opacity_snapshot),
    "repeated opacity style should preserve extmarks"
  )
  assert_true(normal_bg_calls == 1, "opacity styles should share one Normal background lookup per render")

  local opacity_config = bs.config
  local second_buf = new_buffer({ "local alpha = 1", "print(alpha)" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  reset_highlight_calls()
  tunnelvision.on({ highlights = { line = { underline = true } } })
  local second_bs = core.get_buf_state(second_buf)
  local second_config = second_bs.config
  assert_true(not vim.deep_equal(second_config.highlights, core.state.config.highlights), "one-shot rules stay local")

  local resolver = require("tunnelvision.resolver")
  local orig_compute_path = resolver.compute_path
  local compute_calls = 0
  resolver.compute_path = function(...)
    compute_calls = compute_calls + 1
    return orig_compute_path(...)
  end
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x00FF00 })
  reset_highlight_calls()
  local expected_setups = { [false] = 1 }
  for _, state in pairs(core.state.bufs) do
    if state.active and not state.pending then
      expected_setups[state.config] = (expected_setups[state.config] or 0) + 1
    end
  end
  setups = capture_setups(function()
    vim.api.nvim_exec_autocmds("ColorScheme", {})
  end)
  resolver.compute_path = orig_compute_path
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(compute_calls == 0, "ColorScheme should rerender without recomputing sources")
  assert_true(
    bs.config == opacity_config and second_bs.config == second_config,
    "ColorScheme should preserve each active buffer config"
  )
  assert_true(
    vim.deep_equal(setups, expected_setups),
    "ColorScheme should setup global and active configs without extras"
  )
  assert_true(normal_bg_calls == 1, "ColorScheme rerenders should perform one fresh Normal lookup for opacity")
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0x808000,
    "ColorScheme should rebuild opacity-derived groups"
  )

  vim.api.nvim_set_current_buf(second_buf)
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  vim.api.nvim_set_current_buf(render_buf)
  vim.api.nvim_buf_delete(second_buf, { force = true })

  vim.api.nvim_set_hl(0, "Normal", {})
  reset_highlight_calls()
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  opacity_marks = marks(render_buf)
  opacity_group = opacity_marks[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = opacity_group, link = false }).bg == 0xFF0000,
    "missing Normal background should safely retain the configured background"
  )
  assert_true(normal_bg_calls == 1, "missing Normal backgrounds should still be looked up only once per render")
  reset_highlight_calls()
  vim.cmd("TunnelVision off")
  assert_true(#marks(render_buf) == 0, "deactivation should clear every renderer mark")
  assert_true(
    next(vim.api.nvim_get_hl(0, { name = opacity_group, link = false })) == nil,
    "deactivation should clear buffer-specific highlight definitions"
  )
  vim.cmd("colorscheme default")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = "DefinitelyNotAColor", bg_opacity = 0.5 } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  assert_true(pcall(tunnelvision.on), "invalid positive colors should not abort activation")
  assert_true(#marks(render_buf) == 0, "invalid positive colors should preserve visibility without style marks")
  vim.cmd("TunnelVision off")

  vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { symbol = { bg = "red", bg_opacity = 0.5 } },
  })
  tunnelvision.on()
  local named_group = marks(render_buf)[1][4].hl_group
  assert_true(
    vim.api.nvim_get_hl(0, { name = named_group, link = false }).bg == 0x800080,
    "named background colors should support pseudo-opacity"
  )
  vim.cmd("TunnelVision off")
  vim.cmd("colorscheme default")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    max_dim_lines = 2,
    highlights = { line = { bold = true } },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  tunnelvision.on()
  reset_highlight_calls()
  assert_true(
    core.activate(render_buf, { max_dim_lines = 1, symbol = "alpha", cursor = { 1, 4 } }),
    "one-shot max_dim_lines should invalidate same-target rendering"
  )
  assert_true(core.get_buf_state(render_buf).config.max_dim_lines == 1, "one-shot max_dim_lines should normalize")
  local large_marks = marks(render_buf)
  assert_true(#large_marks == 1, "large-buffer dim skipping should retain positive path styles")
  assert_true(large_marks[1][4].hl_group ~= nil, "large-buffer positive style should use a range highlight")
  vim.cmd("TunnelVision off")

  tunnelvision.setup({
    notify = false,
    source = "word",
    scope = "buffer",
    dim = "none",
    highlights = { line = { bold = true } },
  })
  tunnelvision.on()
  local deleted_buf = render_buf
  new_buffer({ "local alpha = 1", "print(alpha)", "local beta = 2" })
  reset_highlight_calls()
  vim.api.nvim_buf_delete(deleted_buf, { force = true })
  assert_true(core.state.bufs[deleted_buf] == nil, "buffer deletion should clear renderer state")
  ui.ensure_highlights = orig_ensure_highlights
  vim.api.nvim_get_hl = orig_get_hl
  vim.api.nvim_set_hl = orig_set_hl
end

-- dim = "none" clears existing marks and skips dim rendering.
do
  tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on()
  assert_true(#vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) > 0, "default dim should create extmarks")

  tunnelvision.on({ dim = "none" })
  assert_true(
    #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
    "one-shot dim none should clear and skip dim extmarks"
  )
  vim.cmd("TunnelVision off")

  tunnelvision.setup({ notify = false, source = "word", scope = "buffer", dim = "none" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on()
  assert_true(
    #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
    "setup dim none should create no dim extmarks"
  )
  vim.cmd("TunnelVision off")
end
