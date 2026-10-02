-- Rendering, highlight, dim, and lifecycle coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local new_buffer = helpers.new_buffer
  local marks = helpers.marks

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")

  tunnelvision.setup({ notify = false })

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

  -- Per-buffer styles are independent of activation and setup styles.
  local oneshot_hex_buf = new_buffer({ "local alpha = 1", "print(alpha)" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  assert_true(not tunnelvision.on({ source = "word", dim = "#AA33CC" }), "one-shot dim colors should be rejected")
  assert_true(not tunnelvision.is_active(), "rejected activation should not create a track")
  assert_true(tunnelvision.set_buffer_dim("#AA33CC"), "buffer dim style should be accepted")
  tunnelvision.on({ source = "word" })
  local buffer_group = ("TunnelVisionDimBuffer%d"):format(oneshot_hex_buf)
  assert_true(
    vim.api.nvim_get_hl(0, { name = buffer_group, link = false }).fg == 0xAA33CC,
    "buffer dim override should use its own group"
  )
  tunnelvision.off()
  assert_true(core.get_buf_state(oneshot_hex_buf).dim_override ~= nil, "off should retain the buffer override")
  tunnelvision.set_buffer_dim(nil)
  tunnelvision.setup({ notify = false, dim = { fg = 0x445566 } })
  assert_true(
    vim.api.nvim_get_hl(0, { name = "TunnelVisionDim", link = false }).fg == 0x445566,
    "buffer overrides should not affect the global style"
  )

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
      vim.deep_equal(
        core.get_buf_state(highlight_buf).config.highlights,
        { statement = {}, symbol = { bg_group = "Search" } }
      ),
      "empty one-shot highlights should use plugin defaults"
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
      "invalid one-shot style fields should normalize safely"
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

    local original_search = orig_get_hl(0, { name = "Search", link = true })
    orig_set_hl(0, "Search", { bg = 0x55AA77 })
    tunnelvision.setup()
    reset_highlight_calls()
    tunnelvision.on({ scope = "buffer", silent = true })
    local default_marks = marks(render_buf)
    assert_true(#default_marks == 3, "default renderer should emphasize two symbols and dim the unrelated line")
    local default_group = default_marks[1][4].hl_group
    local default_hl = orig_get_hl(0, { name = default_group, link = false })
    assert_true(
      default_hl.bg == 0x55AA77 and not default_hl.bold,
      "default symbol should use Search background without bold"
    )
    assert_true(default_marks[3][4].line_hl_group == "TunnelVisionDim", "unrelated line should stay dim")
    orig_set_hl(0, "Search", { bg = 0xAA7755 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local updated_group = marks(render_buf)[1][4].hl_group
    assert_true(
      orig_get_hl(0, { name = updated_group, link = false }).bg == 0xAA7755,
      "active symbol should adopt the updated Search background"
    )
    orig_set_hl(0, "Search", {})
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local plain_group = marks(render_buf)[1][4].hl_group
    local plain_hl = orig_get_hl(0, { name = plain_group, link = false })
    assert_true(plain_hl.bg == nil and not plain_hl.bold, "missing Search background should not add a style")
    orig_set_hl(0, "Search", original_search)
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
      setups[core.state.config] == 1 and vim.tbl_count(setups) == 1,
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
    assert_true(
      symbol_marks[4][4].line_hl_group == "TunnelVisionDim",
      "unrelated lines should retain whole-line dimming"
    )
    assert_true(
      vim.deep_equal(mark_snapshot(render_buf), {
        { 0, 0, 3, "TunnelVisionDim", nil, 1000 },
        { 0, 8, 12, "TunnelVisionDim", nil, 1000 },
        { 0, 17, 20, "TunnelVisionDim", nil, 1000 },
        { 1, 0, nil, nil, "TunnelVisionDim", 1000 },
      }),
      "empty styles should preserve exact visible geometry: " .. vim.inspect(mark_snapshot(render_buf))
    )

    bs.tracks[1].symbol_ranges = {
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
    bs.tracks[1].scope_head_set = { [1] = true }
    bs.tracks[1].statement_set = { [1] = true }
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
    collision_bs.tracks[1].symbol_ranges = {}
    collision_bs.tracks[1].statement_set = {}

    local function assert_collision_order(valid_line, invalid_line)
      collision_bs.tracks[1].path_set = { [valid_line] = true }
      collision_bs.tracks[1].scope_head_set = { [invalid_line] = true }
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
      if state.active and not state.dim_override and core.state.config.dim ~= "none" then
        expected_setups[core.state.config] = (expected_setups[core.state.config] or 0) + 1
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

    vim.api.nvim_set_hl(0, "Normal", { bg = 0x0000FF })
    vim.api.nvim_set_hl(0, "Search", { bg = 0xFF0000 })
    tunnelvision.setup({
      notify = false,
      source = "word",
      scope = "buffer",
      dim = "none",
      highlights = { symbol = { bg_group = "Search", bold = true } },
    })
    tunnelvision.on()
    local group_bg = marks(render_buf)[1][4].hl_group
    local search_hl = vim.api.nvim_get_hl(0, { name = group_bg, link = false })
    assert_true(
      search_hl.bg == 0xFF0000 and search_hl.bold,
      "theme group background should be used without added opacity"
    )

    vim.api.nvim_set_hl(0, "Normal", { bg = 0xFFFFFF })
    vim.api.nvim_set_hl(0, "Search", { bg = 0x00FF00 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    group_bg = marks(render_buf)[1][4].hl_group
    search_hl = vim.api.nvim_get_hl(0, { name = group_bg, link = false })
    assert_true(search_hl.bg == 0x00FF00, "active style should refresh to the new theme group background")
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
      not core.activate(render_buf, { max_dim_lines = 1, symbol = "alpha", cursor = { 1, 4 } }),
      "one-shot max_dim_lines should be rejected"
    )
    tunnelvision.setup({ notify = false, max_dim_lines = 1, dim = nil })
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
    tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { line = true } })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on()
    assert_true(#vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) > 0, "default dim should create extmarks")

    tunnelvision.on({ dim = "none" })
    assert_true(
      #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
      "one-shot dim none should clear and skip dim extmarks"
    )
    vim.cmd("TunnelVision off")

    tunnelvision.setup({
      notify = false,
      source = "word",
      scope = "buffer",
      dim = "none",
      highlights = { line = true },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    tunnelvision.on()
    assert_true(
      #vim.api.nvim_buf_get_extmarks(0, core.state.ns, 0, -1, {}) == 0,
      "setup dim none should create no dim extmarks"
    )
    vim.cmd("TunnelVision off")
  end

  -- Buffer dim commands change style without changing tracks; reset also clears force.
  do
    tunnelvision.setup({ notify = false, source = "word", scope = "buffer", highlights = { line = true } })
    local dim_buf = new_buffer({ "alpha", "outside" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("TunnelVision dim #123456")
    local bs = core.get_buf_state(dim_buf)
    assert_true(vim.deep_equal(bs.dim_override, { fg = "#123456" }), "dim command should set a buffer color")
    tunnelvision.on()
    assert_true(
      vim.api.nvim_get_hl(0, { name = ("TunnelVisionDimBuffer%d"):format(dim_buf), link = false }).fg == 0x123456,
      "dim command should apply to an active buffer"
    )
    vim.cmd("TunnelVision dim none")
    assert_true(#marks(dim_buf) == 0, "dim none should disable the shared layer")
    vim.cmd("TunnelVision dim Comment")
    assert_true(bs.dim_override == "Comment" and #marks(dim_buf) > 0, "dim command should accept group names")
    tunnelvision.force_buffer_dim(true)
    vim.cmd("TunnelVision dim reset")
    assert_true(bs.dim_override == nil and not bs.force_dim, "dim reset should clear override and force together")
    assert_true(marks(dim_buf)[1][4].line_hl_group == "TunnelVisionDim", "reset should use global dim")
    vim.cmd("TunnelVision dim #123")
    assert_true(bs.dim_override == nil, "invalid hex command should leave dim unchanged")
    assert_true(
      vim.tbl_contains(vim.fn.getcompletion("TunnelVision dim r", "cmdline"), "reset"),
      "dim completion should offer reset"
    )
    tunnelvision.off()
  end

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
