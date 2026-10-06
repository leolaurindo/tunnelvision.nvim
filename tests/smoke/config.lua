-- Configuration, command, compatibility, and status coverage.
return function(helpers)
  local assert_equal = helpers.assert_equal
  local assert_true = helpers.assert_true
  local assert_sources = helpers.assert_sources
  local assert_combine = helpers.assert_combine
  local new_buffer = helpers.new_buffer

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")
  local config = require("tunnelvision.config")

  -- Explicit highlight rules replace defaults; invalid values normalize safely.
  local default_rules = { statement = {}, symbol = { bg_group = "Search" } }
  for _, case in ipairs({
    { {}, default_rules, "empty defaults" },
    { { symbol = true }, { symbol = {} }, "symbol replacement" },
    { { line = false }, {}, "disabled context" },
    { { statement = {}, line = { bold = true } }, { statement = {}, line = { bold = true } }, "mixed styles" },
    {
      { line = false, symbol = "bold", statement = { fg = false, bold = "yes", bg_opacity = "0.5" } },
      { statement = {} },
      "invalid style fields",
    },
    { 42, default_rules, "invalid highlights" },
  }) do
    tunnelvision.setup({ notify = false, highlights = case[1] })
    assert_equal(core.state.config.highlights, case[2], "highlight normalization: " .. case[3])
  end
  tunnelvision.setup({
    notify = false,
    highlights = {
      scope_head = {
        fg = "#112233",
        bg = 0x445566,
        bg_group = "Search",
        bg_opacity = 2,
        bold = true,
        italic = false,
        underline = true,
        undercurl = false,
        strikethrough = true,
      },
    },
  })
  assert_equal(core.state.config.highlights, {
    scope_head = {
      fg = "#112233",
      bg = 0x445566,
      bg_group = "Search",
      bg_opacity = 1,
      bold = true,
      italic = false,
      underline = true,
      undercurl = false,
      strikethrough = true,
    },
  }, "all supported highlight fields should normalize and clamp opacity")

  tunnelvision.setup({
    notify = false,
    flow_settings = {
      direction = "backward",
      analyzers = { "text" },
      extra_keywords = { "keep" },
      max_depth = 3,
    },
  })
  local merged_flow = config.normalize_activation(core.state.config, { flow_settings = { max_depth = 1 } }, 0, {})
  assert_true(merged_flow.flow_settings.direction == "backward", "one-shot flow settings preserve direction")
  assert_equal(merged_flow.flow_settings.analyzers, { "text" }, "one-shot flow settings preserve analyzers")
  assert_true(merged_flow.flow_settings.extra_keywords[1] == "keep", "one-shot flow settings preserve keywords")
  assert_true(merged_flow.flow_settings.max_depth == 1, "one-shot flow settings override selected fields")
  tunnelvision.setup({ notify = false })

  -- Deprecated top-level flow fields fill only missing flow_settings fields
  tunnelvision.setup({
    notify = false,
    direction = "both",
    extra_keywords = { "deprecated" },
    flow_settings = { extra_keywords = { "nested" } },
  })
  assert_true(
    core.state.config.flow_settings.direction == "both",
    "deprecated direction fills missing flow_settings.direction"
  )
  assert_true(
    core.state.config.flow_settings.extra_keywords[1] == "nested",
    "flow_settings.extra_keywords wins over deprecated extra_keywords"
  )
  tunnelvision.setup({ notify = false })

  tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") } })
  assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "combine sources")

  tunnelvision.setup({ notify = false, source = "word" })
  assert_sources({ "word" }, "legacy source should normalize to sources")

  assert_true(vim.fn.exists(":TunnelVision") == 2, "missing command: TunnelVision")
  assert_true(vim.fn.exists(":Tunnelvision") == 2, "missing command alias: Tunnelvision")

  local first_buf = new_buffer({
    "local value = 1",
    "local copy = value",
    "value = copy + value",
    "print(value)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- value

  vim.cmd("Tunnelvision on")
  assert_true(tunnelvision.is_active(0), "activation failed")

  vim.api.nvim_win_set_cursor(0, { 2, 7 }) -- copy
  vim.cmd("TunnelVision retarget")
  assert_true(core.get_buf_state(first_buf).symbol == "copy", "retarget alias should re-run on current symbol")
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- value
  vim.cmd("TunnelVision add")
  assert_true(#core.get_buf_state(first_buf).tracks == 2, "add should retain the existing track")
  vim.api.nvim_win_set_cursor(0, { 2, 7 }) -- copy
  vim.cmd("TunnelVision on")
  assert_true(
    #core.get_buf_state(first_buf).tracks == 1 and core.get_buf_state(first_buf).tracks[1].symbol == "copy",
    "on should replace all tracks"
  )

  tunnelvision.setup({ notify = false, sources = { "word" }, primary_action = "add" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on()
  assert_true(#tunnelvision.status().tracks == 2, "add primary action should preserve tracks")
  for _, case in ipairs({
    { "mode flow", "mode", "flow" },
    { "direction backward", "direction", "backward" },
    { "scope buffer", "scope", "buffer" },
    { "source treesitter,word", "sources_label", "treesitter,word" },
  }) do
    tunnelvision.retarget({ symbol = "copy", cursor = { 2, 7 } })
    local original = vim.deepcopy(core.get_buf_state(first_buf).tracks[1])
    vim.cmd("TunnelVision " .. case[1])
    assert_true(
      #tunnelvision.status().tracks == 2
        and vim.deep_equal(core.get_buf_state(first_buf).tracks[1], original)
        and tunnelvision.status()[case[2]] == case[3],
      "one-shot commands should preserve existing tracks and apply " .. case[1]
    )
  end
  assert_true(core.get_mode() == "static" and core.get_scope() == "function", "commands preserve defaults")
  tunnelvision.retarget()
  assert_true(#tunnelvision.status().tracks == 1, "explicit Lua retarget must replace under add primary action")
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  tunnelvision.add()
  vim.cmd("TunnelVision retarget")
  assert_true(#tunnelvision.status().tracks == 1, "explicit command retarget must replace under add primary action")
  tunnelvision.setup({ notify = false, source = "word" })

  local before = vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd("TunnelVision next")
  local after_next = vim.api.nvim_win_get_cursor(0)[1]
  assert_true(after_next ~= before, "next path jump did not move cursor")

  vim.cmd("TunnelVision prev")
  local after_prev = vim.api.nvim_win_get_cursor(0)[1]
  assert_true(after_prev == before, "prev path jump did not return cursor")

  assert_true(core.get_scope() == "function", "default scope should be function")
  for _, mode in ipairs({ "flow", "dynamic", "static" }) do
    vim.cmd("TunnelVision mode " .. mode)
    assert_true(tunnelvision.status().mode == mode, "mode command should activate " .. mode)
    assert_true(core.get_mode() == "static", "mode command should not change setup defaults")
  end
  vim.cmd("TunnelVision mode dynamic_flow")
  vim.cmd("TunnelVision direction backward")
  assert_true(tunnelvision.status().mode == "dynamic_flow", "direction should preserve dynamic flow")
  vim.cmd("TunnelVision mode static")
  for _, direction in ipairs({ "backward", "both", "forward" }) do
    vim.cmd("TunnelVision direction " .. direction)
    assert_true(tunnelvision.status().mode == "flow", "direction command should activate flow")
    assert_true(tunnelvision.status().direction == direction, "direction command should apply " .. direction)
    assert_true(core.get_direction() == "forward", "direction command should not change setup defaults")
  end
  for _, scope in ipairs({ "buffer", "function" }) do
    vim.cmd("TunnelVision scope " .. scope)
    assert_true(tunnelvision.status().scope == scope, "scope command should apply " .. scope)
    assert_true(core.get_scope() == "function", "scope command should not change setup defaults")
  end
  for _, source in ipairs({ "lsp_else_word", "lsp", "lsp_and_word", "word" }) do
    vim.cmd("TunnelVision source " .. source)
    assert_true(tunnelvision.status().source == source, "source command should apply " .. source)
    assert_sources({ "word" }, "source command should not change setup defaults")
  end
  assert_true(
    vim.tbl_contains(vim.fn.getcompletion("TunnelVision direction b", "cmdline"), "backward"),
    "direction completion should include backward"
  )

  -- Fallback-chain command syntax
  vim.cmd("TunnelVision source lsp,word")
  assert_true(tunnelvision.status().sources_label == "lsp,word", "comma-separated command source should activate")
  assert_sources({ "word" }, "comma-separated command source should not change setup defaults")

  tunnelvision.setup({ notify = false })
  local sources_copy = tunnelvision.get_sources()
  sources_copy[1] = "word"
  assert_sources({ "lsp", "treesitter", "word" }, "get_sources should return an isolated copy")
  for _, value in ipairs({ "treesitter", "lsp,treesitter,word" }) do
    vim.cmd("TunnelVision source " .. value)
    assert_true(tunnelvision.status().sources_label == value, "Tree-sitter command source " .. value)
    assert_sources({ "lsp", "treesitter", "word" }, "source command should preserve setup defaults")
  end
  vim.cmd("TunnelVision source lsp,word")
  assert_true(tunnelvision.status().sources_label == "lsp,word", "restored active source to lsp,word")
  vim.cmd("TunnelVision mode invalid")
  assert_true(tunnelvision.status().sources_label == "lsp,word", "invalid command should preserve active tracks")
  vim.cmd("TunnelVision on")
  assert_true(
    tunnelvision.status().sources_label == "lsp,treesitter,word",
    "activation after a one-shot command should use setup defaults"
  )
  vim.cmd("TunnelVision source lsp,word")

  -- Status display uses source= label
  do
    local notify_msg
    local orig_notify = core.notify
    core.notify = function(msg)
      notify_msg = msg
    end
    vim.cmd("TunnelVision status")
    assert_true(
      notify_msg and notify_msg:find("source=" .. tunnelvision.status().sources_label, 1, true),
      "status should show active source label"
    )
    core.notify = orig_notify
  end

  -- Queries report active settings, then setup defaults after off, without activating.
  do
    local original_notify = core.notify
    local message
    core.notify = function(value)
      message = value
    end
    tunnelvision.on({ mode = "flow", scope = "buffer", sources = { "word" } })
    for _, case in ipairs({
      { "mode", "flow", "static" },
      { "scope", "buffer", "function" },
      { "source", "word", "lsp,treesitter,word" },
      { "direction", "forward", "forward" },
    }) do
      vim.cmd("TunnelVision " .. case[1])
      assert_true(message == "TunnelVision " .. case[1] .. ": " .. case[2], "queries should report active settings")
    end
    tunnelvision.off()
    for _, case in ipairs({
      { "mode", "static" },
      { "scope", "function" },
      { "source", "lsp,treesitter,word" },
      { "direction", "forward" },
    }) do
      vim.cmd("TunnelVision " .. case[1])
      assert_true(
        message == "TunnelVision " .. case[1] .. ": " .. case[2] and not tunnelvision.is_active(),
        "inactive queries should report defaults without activating"
      )
    end
    core.notify = original_notify
    vim.cmd("TunnelVision source lsp,word")
  end

  -- Invalid comma values fail without corrupting config
  do
    local notify_msg
    local orig_notify = core.notify
    core.notify = function(msg)
      notify_msg = msg
    end
    vim.cmd("TunnelVision source lsp,foo")
    assert_true(notify_msg and notify_msg:find("invalid source"), "invalid chain source should error")
    assert_true(tunnelvision.status().sources_label == "lsp,word", "active source unchanged after invalid chain")
    assert_sources({ "lsp", "treesitter", "word" }, "setup sources unchanged after invalid chain")
    core.notify = orig_notify
  end

  tunnelvision.set_sources({ "lsp", "word" })
  assert_sources({ "lsp", "word" }, "set_sources should update sources")
  assert_true(core.get_source() == "lsp_else_word", "set_sources should update legacy source view")
  tunnelvision.set_sources({ "word" })
  assert_sources({ "word" }, "set_sources word")

  -- sources wins over source when both are provided
  tunnelvision.setup({ notify = false, source = "word", sources = { tunnelvision.combine("lsp", "word") } })
  assert_combine(tunnelvision.get_sources()[1], { "lsp", "word" }, "sources wins over deprecated source")
  assert_true(
    tunnelvision.get_source() == "lsp_and_word",
    "get_source returns legacy for representable chain after sources win"
  )

  tunnelvision.setup({ notify = false, source = "lsp_else_word" })

  do
    local messages = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
    tunnelvision.setup({
      notify = true,
      source = "word",
      direction = "both",
      extra_keywords = { "old" },
      sources = { "treesitter", "word" },
      flow_settings = { direction = "backward", extra_keywords = { "new" } },
    })
    assert_true(
      #messages == 1 and messages[1][1]:find("direction, extra_keywords, source", 1, true),
      "deprecated setup inputs should aggregate into one warning"
    )
    assert_sources({ "treesitter", "word" }, "modern source chain wins")
    assert_true(
      tunnelvision.get_direction() == "backward" and core.state.config.flow_settings.extra_keywords[1] == "new",
      "modern flow fields win conflicts"
    )
    tunnelvision.setup({ notify = true, source = "word" })
    assert_true(#messages == 1, "setup deprecations should warn once per session")
    tunnelvision.get_source()
    tunnelvision.set_source("word")
    vim.cmd("Tunnelvision on")
    assert_true(#messages == 2, "deprecated API and command use should warn once per session")
    tunnelvision.setup({ notify = false, sources = { "word" } })
    tunnelvision.on({ symbol = "value", cursor = { 1, 7 } })
    local tracks = vim.deepcopy(core.get_buf_state(first_buf).tracks)
    local cfg = vim.deepcopy(core.state.config)
    for _, operation in ipairs({
      function()
        return tunnelvision.setup({ sources = { "lsp" }, typo = true })
      end,
      function()
        return tunnelvision.on({ symbol = "copy", cursor = { 2, 7 }, typo = true })
      end,
      function()
        return tunnelvision.add({ flow_settings = { typo = true } })
      end,
      function()
        return tunnelvision.setup({ highlights = { typo = true } })
      end,
      function()
        return tunnelvision.on({ highlights = { symbol = { typo = true } } })
      end,
      function()
        return tunnelvision.setup({ direction = "both", flow_settings = false })
      end,
      function()
        return tunnelvision.on_many({ { 2, 7 } }, { typo = true })
      end,
      function()
        return tunnelvision.pin({ dim = "#112233" })
      end,
    }) do
      local count = #messages
      assert_true(operation() == false, "invalid options must be rejected")
      assert_true(
        #messages == count + 1 and messages[#messages][2] == vim.log.levels.ERROR,
        "invalid options must report visible errors even with notify=false"
      )
      assert_true(
        vim.deep_equal(core.state.config, cfg) and vim.deep_equal(core.get_buf_state(first_buf).tracks, tracks),
        "invalid options must not change config or clear tracks"
      )
    end
    vim.notify = original_notify
  end

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
