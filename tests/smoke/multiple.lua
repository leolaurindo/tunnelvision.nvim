return function(helpers)
  local assert_true = helpers.assert_true
  local new_buffer = helpers.new_buffer
  local tv = require("tunnelvision")
  local core = require("tunnelvision.core")

  -- Track styles compose per byte; dim policy belongs to the buffer.
  tv.setup({ notify = false, sources = { "word" }, scope = "buffer", dim = "#445566" })
  local visual = new_buffer({ "alpha", "beta", "alpha beta", "outside" })
  local function groups(row, col)
    local positive, dimmed = nil, false
    for _, mark in ipairs(helpers.marks(visual)) do
      local details = mark[4]
      if mark[2] == row - 1 then
        if details.hl_group and mark[3] <= col and col < details.end_col then
          if details.hl_group:match("^TunnelVisionHighlight") then
            positive = vim.api.nvim_get_hl(0, { name = details.hl_group, link = false })
          else
            dimmed = true
          end
        elseif details.line_hl_group then
          dimmed = true
        end
      end
    end
    return positive, dimmed
  end
  tv.on({
    symbol = "alpha",
    cursor = { 1, 0 },
    dim = "none",
    highlights = { line = { fg = 0xAA0000, bold = true }, symbol = { fg = 0x00AA00 } },
  })
  assert_true(not select(2, groups(4, 0)), "sole opted-out track should not dim")
  tv.set_buffer_dim("#778899")
  assert_true(not select(2, groups(4, 0)), "style override alone must not enable dimming")
  tv.force_buffer_dim(true)
  assert_true(select(2, groups(4, 0)), "forcing dim should override all track opt-outs")
  local override_group = ("TunnelVisionDimBuffer%d"):format(visual)
  assert_true(
    vim.api.nvim_get_hl(0, { name = override_group, link = false }).fg == 0x778899,
    "forced dim should use buffer color"
  )
  vim.api.nvim_set_hl(0, override_group, {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert_true(
    vim.api.nvim_get_hl(0, { name = override_group, link = false }).fg == 0x778899,
    "colorscheme refresh should restore the buffer color"
  )
  tv.force_buffer_dim(false)
  assert_true(not select(2, groups(4, 0)), "disabling force should restore opted-out behavior")
  tv.on({ symbol = "beta", cursor = { 2, 0 }, highlights = { line = { fg = 0x0000BB, italic = true } } })
  local older, newer = groups(1, 0), groups(2, 0)
  local overlap = groups(3, 0)
  assert_true(older.fg == 0x00AA00 and older.bold and newer.fg == 0x0000BB, "track context styles should compose")
  assert_true(
    overlap.fg == 0x0000BB and overlap.bold and overlap.italic,
    "newer track should win only conflicting attributes"
  )
  assert_true(select(2, groups(4, 0)), "one requesting track should enable shared dim")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  tv.remove()
  assert_true(not select(2, groups(4, 0)), "removing the requester should stop dimming")
  tv.force_buffer_dim(true)
  tv.off()
  assert_true(core.get_buf_state(visual).dim_override ~= nil, "off should preserve the buffer style")
  assert_true(
    core.get_buf_state(visual).force_dim and #helpers.marks(visual) == 0,
    "off should retain force but clear marks"
  )
  tv.setup({ notify = false, sources = { "word" }, scope = "buffer", dim = "none" })
  tv.on({ symbol = "alpha", cursor = { 1, 0 }, dim = "none" })
  tv.force_buffer_dim(true)
  assert_true(select(2, groups(4, 0)), "buffer override should work with global none")
  tv.set_buffer_dim(nil)
  assert_true(not core.get_buf_state(visual).force_dim, "clearing the override should clear forced dimming")
  assert_true(not select(2, groups(4, 0)), "reset should restore the global none style")
  tv.off()

  tv.setup({ notify = false, source = "word", scope = "buffer", dim = "none" })
  local buf = new_buffer({ "local alpha = 1", "local beta = alpha", "print(beta, alpha)", "local gamma = beta" })
  assert_true(tv.on_many({ { 1, 7 }, { 2, 7 } }), "batch activation should add both symbols")
  local bs = core.get_buf_state(buf)
  assert_true(#bs.tracks == 2 and bs.path_set[4], "tracks should contribute to one path")
  assert_true(not tv.on_many({ { 1, 7 } }), "repeat activation should not add another track")
  assert_true(#bs.tracks == 2, "duplicate activation should be a no-op")
  assert_true(#core.occurrences(buf) >= 4, "batch activation should preserve occurrence coordinates")
  vim.api.nvim_win_set_cursor(0, { 3, 6 }) -- beta
  tv.remove()
  assert_true(#bs.tracks == 1 and bs.tracks[1].symbol == "alpha", "remove at an occurrence should remove its track")
  tv.on({ symbol = "beta", cursor = { 2, 7 } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- no tracked occurrence
  tv.remove()
  assert_true(#bs.tracks == 1 and bs.tracks[1].symbol == "alpha", "remove away from tracks should pop latest")
  tv.on({ mode = "dynamic_flow", symbol = "beta", cursor = { 2, 7 } })
  assert_true(
    #bs.tracks == 2 and core.get_moving_track(buf).config.mode == "dynamic_flow",
    "moving flow and pin should coexist"
  )
  tv.pin({ mode = "dynamic_flow", symbol = "gamma", cursor = { 4, 7 } })
  assert_true(#bs.tracks == 3 and bs.tracks[3].config.mode == "flow", "pin of dynamic flow should retain flow analysis")
  core.activate(buf, { track = core.get_moving_track(buf), symbol = "gamma", cursor = { 4, 7 }, silent = true })
  assert_true(#bs.tracks == 3 and bs.tracks[1].symbol == "alpha", "moving flow should not consume pins")
  tv.set_mode("static")
  assert_true(
    core.get_moving_track(buf).config.mode == "dynamic_flow",
    "global defaults should not change active tracks"
  )
  tv.refresh()
  assert_true(#bs.tracks == 3, "refresh must not duplicate tracks")
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "print(beta, beta)" })
  tv.refresh()
  assert_true(#bs.tracks == 3 and bs.tracks[1].symbol == "alpha", "editing should refresh without changing pins")
  for index = 2, #bs.symbol_ranges do
    local before, after = bs.symbol_ranges[index - 1], bs.symbol_ranges[index]
    assert_true(
      before.line < after.line or before.line == after.line and before.start_col <= after.start_col,
      "overlapping flow and pin ranges should stay sorted"
    )
  end
  tv.off()
  assert_true(not tv.is_active() and #bs.tracks == 0, "off should clear the whole buffer")

  local movement = new_buffer({ "local alpha = 1", "local beta = alpha", "local gamma = beta", "" })
  tv.pin({ symbol = "alpha", cursor = { 1, 7 } })
  tv.on({ mode = "dynamic_flow", source = "word", scope = "buffer", cursor = { 2, 7 }, symbol = "beta" })
  local movement_state = core.get_buf_state(movement)
  local moving = core.get_moving_track(movement)
  assert_true(moving.last_compute_meta.flow_expanded, "dynamic flow should expand its path")
  local delayed = {}
  local old_defer = vim.defer_fn
  vim.defer_fn = function(callback)
    delayed[#delayed + 1] = callback
    return { stop = function() end, close = function() end }
  end
  vim.api.nvim_win_set_cursor(0, { 3, 7 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = movement })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = movement })
  delayed[#delayed]()
  assert_true(moving.symbol == "beta", "moving to blank space should cancel a queued retarget")
  assert_true(
    not core.activate(movement, { cursor = { 4, 0 }, silent = true }),
    "empty-space activation should be a no-op"
  )
  assert_true(#movement_state.tracks == 2, "empty-space activation must preserve existing tracks")
  assert_true(not tv.retarget(), "retarget on empty space should leave tracks untouched")
  assert_true(#movement_state.tracks == 2, "failed retarget must not clear pins")
  vim.api.nvim_win_set_cursor(0, { 3, 7 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = movement })
  local stale = delayed[#delayed]
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  tv.remove() -- no occurrence: remove the latest (moving) track
  tv.on({ mode = "dynamic_flow", symbol = "gamma", cursor = { 3, 7 } })
  stale()
  assert_true(core.get_moving_track(movement).symbol == "gamma", "old timer must not retarget a replacement track")
  assert_true(movement_state.tracks[1].symbol == "alpha", "timer invalidation must not disturb other tracks")
  vim.defer_fn = old_defer
  tv.off()

  new_buffer({ "alpha beta alpha", "beta alpha", "" })
  tv.on({ symbol = "alpha", cursor = { 1, 0 }, sources = { "word" }, scope = "buffer" })
  tv.on({ symbol = "beta", cursor = { 1, 6 }, sources = { "word" }, scope = "buffer" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  tv.next()
  assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 6 }), "next should navigate the union of all tracks")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  tv.next_track()
  assert_true(
    vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 11 }),
    "track navigation should stay on the track under the cursor"
  )
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  tv.next_track()
  assert_true(
    vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 0 }),
    "track navigation should choose the matching track when starting on its occurrence"
  )
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  tv.prev_track()
  assert_true(
    vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 0 }),
    "track navigation away from occurrences should use the latest track"
  )
  tv.off()

  local flows = new_buffer({ "local raw = 1", "local scaled = raw + 1", "local other = 2", "local total = other * 2" })
  tv.on({ symbol = "raw", cursor = { 1, 7 }, mode = "flow", sources = { "word" }, scope = "buffer" })
  tv.on({ symbol = "other", cursor = { 3, 7 }, mode = "flow", sources = { "word" }, scope = "buffer" })
  local flow_state = core.get_buf_state(flows)
  assert_true(
    #flow_state.tracks == 2
      and flow_state.tracks[1].config.mode == "flow"
      and flow_state.tracks[2].config.mode == "flow",
    "multiple independent static flow tracks should coexist"
  )
  tv.off()

  tv.register_source("anchor_only", function(ctx)
    return { [ctx.anchor.row + 1] = true }
  end)
  local shadow = new_buffer({ "local alpha = 1", "local alpha = 2" })
  tv.on_many({ { 1, 7 }, { 2, 7 } }, { sources = { "anchor_only" }, scope = "buffer" })
  local shadow_state = core.get_buf_state(shadow)
  assert_true(#shadow_state.tracks == 2, "same spelling with disjoint occurrences should remain separate tracks")
  tv.remove()
  tv.off()

  local resolver = require("tunnelvision.resolver")
  local get_status = resolver.get_lsp_status
  local request = resolver.request_lsp_highlight
  local callbacks = {}
  resolver.get_lsp_status = function()
    return true
  end
  resolver.request_lsp_highlight = function(_, anchor, _, _, on_done)
    callbacks[anchor.row + 1] = on_done
    return {}
  end
  tv.setup({
    notify = false,
    source = "lsp",
    scope = "buffer",
    dim = "none",
    highlights = { line = { fg = 0xAABBCC } },
  })
  local async_buf = new_buffer({ "local alpha = 1", "local beta = 2" })
  tv.on_many({ { 1, 7 }, { 2, 7 } })
  local async_state = core.get_buf_state(async_buf)
  assert_true(async_state.pending and #async_state.tracks == 2, "batch should own independent LSP requests")
  callbacks[1](resolver.make_lsp_result("ok", { [1] = true }, true, {
    { line = 1, start_col = 6, end_col = 11 },
  }))
  assert_true(async_state.pending and async_state.path_set[1], "completed track should render while another is pending")
  assert_true(#helpers.marks(async_buf) > 0, "async batch completion should render without another user action")
  local late = callbacks[2]
  tv.remove() -- no resolved range under the cursor: pop the pending track
  late(resolver.make_lsp_result("ok", { [2] = true }, true, { { line = 2, start_col = 6, end_col = 10 } }))
  assert_true(not async_state.path_set[2] and #async_state.tracks == 1, "removed track must ignore late results")
  tv.on({ symbol = "beta", cursor = { 2, 7 } })
  assert_true(async_state.pending and #async_state.tracks == 2, "second request should not clear completed geometry")
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  assert_true(#helpers.marks(async_buf) > 0, "completed track should have a visible highlight")
  tv.remove()
  assert_true(async_state.pending and #async_state.tracks == 1, "removing the resolved track must keep the pending one")
  assert_true(#helpers.marks(async_buf) == 0, "removed highlights must disappear even if another track is pending")
  callbacks[2](resolver.make_lsp_result("ok", { [2] = true }, true, {
    { line = 2, start_col = 6, end_col = 10 },
  }))
  assert_true(not async_state.pending and async_state.path_set[2], "remaining request should render normally")
  tv.off()
  tv.on_many({ { 1, 7 }, { 2, 7 } })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tv.remove()
  assert_true(
    #async_state.tracks == 1 and async_state.tracks[1].symbol == "beta",
    "remove at a pending anchor should not pop an unrelated latest track"
  )
  callbacks[1](resolver.make_lsp_result("ok", { [1] = true }, true, {
    { line = 1, start_col = 6, end_col = 11 },
  }))
  assert_true(not async_state.path_set[1], "removed pending track should reject late callbacks")
  tv.off()
  resolver.get_lsp_status, resolver.request_lsp_highlight = get_status, request

  tv.setup({ notify = false, source = "word", scope = "buffer", dim = "none" })
  local edited = new_buffer({ "alpha", "other" })
  tv.on({ symbol = "alpha", cursor = { 1, 0 } })
  local edited_state = core.get_buf_state(edited)
  vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "other", "alpha" })
  core.activate(edited, { symbol = "alpha", cursor = { 2, 0 } })
  assert_true(
    #edited_state.tracks == 1 and edited_state.symbol_ranges[1].line == 2,
    "on after edit must refresh rather than duplicate the old track"
  )
  assert_true(
    edited_state.tracks[1].scope.changedtick == vim.api.nvim_buf_get_changedtick(edited),
    "on after edit should use current scope geometry"
  )
  tv.off()

  local invalid = new_buffer({ "local alpha = 1", "local beta = alpha" })
  tv.on({ symbol = "alpha", cursor = { 1, 7 } })
  local invalid_state = core.get_buf_state(invalid)
  assert_true(not tv.on({ symbol = {}, cursor = { 2, 7 } }), "invalid on symbol should fail")
  assert_true(not tv.pin({ symbol = "beta", cursor = {} }), "invalid pin cursor should fail")
  assert_true(not tv.retarget({ symbol = "beta", cursor = {} }), "invalid retarget must not clear tracks")
  assert_true(not tv.retarget({ symbol = {} }), "invalid retarget symbol should fail")
  assert_true(not tv.on_many({ { 2, 7 }, { -1, 7 } }), "invalid batch should reject all positions")
  assert_true(
    #invalid_state.tracks == 1 and invalid_state.tracks[1].symbol == "alpha",
    "invalid target operations must not change state"
  )
  tv.pin({ mode = "flow", symbol = "beta", cursor = { 2, 7 } })
  assert_true(
    invalid_state.tracks[2].config.mode == "flow" and invalid_state.tracks[2].last_compute_meta.flow_expanded,
    "explicit flow pin must retain flow expansion"
  )
  tv.off()

  local mixed = new_buffer({ "alpha", "beta", "other" })
  tv.on_many({ { 1, 0 }, { 2, 0 } })
  local mixed_state = core.get_buf_state(mixed)
  vim.api.nvim_buf_set_lines(mixed, 0, -1, false, { "other", "alpha", "beta" })
  local original_compute = resolver.compute_path
  local original_status, original_request = resolver.get_lsp_status, resolver.request_lsp_highlight
  local pending_callback
  resolver.get_lsp_status = function()
    return true
  end
  resolver.request_lsp_highlight = function(_, _, _, _, done)
    pending_callback = done
    return {}
  end
  resolver.compute_path = function(_, symbol, _, _, opts)
    if symbol == "alpha" then
      return { [2] = true }, { 2 }, {}, {}, false
    end
    if opts.lsp_result then
      return { [3] = true }, { 3 }, {}, {}, false
    end
    return nil, nil, nil, nil, { bufnr = mixed }
  end
  tv.refresh()
  assert_true(
    mixed_state.pending and mixed_state.refreshing and mixed_state.path_set[1] and mixed_state.path_set[2],
    "mixed refresh must retain the complete old view while one track is pending"
  )
  assert_true(not mixed_state.path_set[3], "partial new results must not leak into old view")
  pending_callback(resolver.make_lsp_result("ok", { [3] = true }, true))
  assert_true(
    not mixed_state.pending
      and not mixed_state.refreshing
      and not mixed_state.path_set[1]
      and mixed_state.path_set[2]
      and mixed_state.path_set[3],
    "mixed refresh must publish only the new generation"
  )
  resolver.compute_path = original_compute
  resolver.get_lsp_status, resolver.request_lsp_highlight = original_status, original_request
  tv.off()
  tv.setup({ notify = false })
end
