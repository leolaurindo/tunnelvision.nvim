-- Configuration, command, compatibility, and status coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local assert_sources = helpers.assert_sources
  local assert_combine = helpers.assert_combine
  local new_buffer = helpers.new_buffer

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")
  local config = require("tunnelvision.config")

  -- Highlight rules normalize without deep-merging the default line context.
  tunnelvision.setup({ notify = false, highlights = {} })
  assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), "empty highlights should use line default")

  tunnelvision.setup({ notify = false, highlights = { symbol = true } })
  assert_true(vim.deep_equal(core.state.config.highlights, { symbol = {} }), "symbol rule should replace line default")

  tunnelvision.setup({ notify = false, highlights = { line = false } })
  assert_true(vim.deep_equal(core.state.config.highlights, {}), "false context should remain disabled")

  tunnelvision.setup({
    notify = false,
    highlights = { statement = {}, line = { bold = true } },
  })
  assert_true(
    vim.deep_equal(core.state.config.highlights, { statement = {}, line = { bold = true } }),
    "enabled highlight rules should preserve empty and styled contexts"
  )

  tunnelvision.setup({
    notify = false,
    highlights = {
      scope_head = {
        fg = "#112233",
        bg = 0x445566,
        bg_opacity = 2,
        bold = true,
        italic = false,
        underline = true,
        undercurl = false,
        strikethrough = true,
      },
    },
  })
  assert_true(
    vim.deep_equal(core.state.config.highlights, {
      scope_head = {
        fg = "#112233",
        bg = 0x445566,
        bg_opacity = 1,
        bold = true,
        italic = false,
        underline = true,
        undercurl = false,
        strikethrough = true,
      },
    }),
    "all supported highlight style fields should normalize"
  )

  tunnelvision.setup({
    notify = false,
    highlights = {
      unknown = true,
      line = false,
      symbol = "bold",
      statement = { fg = false, bold = "yes", bg_opacity = "0.5", unknown = true },
    },
  })
  assert_true(
    vim.deep_equal(core.state.config.highlights, { statement = {} }),
    "invalid highlight rules should be ignored"
  )

  tunnelvision.setup({ notify = false, highlights = 42 })
  assert_true(vim.deep_equal(core.state.config.highlights, { line = {} }), "invalid highlights should use line default")
  tunnelvision.setup({ notify = false }) -- restore

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
  assert_true(
    vim.deep_equal(merged_flow.flow_settings.analyzers, { "text" }),
    "one-shot flow settings preserve analyzers"
  )
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

  local before = vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd("TunnelVision next")
  local after_next = vim.api.nvim_win_get_cursor(0)[1]
  assert_true(after_next ~= before, "next path jump did not move cursor")

  vim.cmd("TunnelVision prev")
  local after_prev = vim.api.nvim_win_get_cursor(0)[1]
  assert_true(after_prev == before, "prev path jump did not return cursor")

  assert_true(core.get_scope() == "function", "default scope should be function")
  for _, case in ipairs({
    { "mode", "static", core.get_mode },
    { "mode", "flow", core.get_mode },
    { "mode", "dynamic", core.get_mode },
    { "mode", "static", core.get_mode },
    { "direction", "backward", core.get_direction },
    { "direction", "both", core.get_direction },
    { "direction", "forward", core.get_direction },
    { "scope", "buffer", core.get_scope },
    { "scope", "function", core.get_scope },
    { "source", "lsp_else_word", core.get_source },
    { "source", "lsp", core.get_source },
    { "source", "lsp_and_word", core.get_source },
    { "source", "word", core.get_source },
  }) do
    vim.cmd(("TunnelVision %s %s"):format(case[1], case[2]))
    assert_true(case[3]() == case[2], ("%s %s not applied"):format(case[1], case[2]))
  end
  assert_true(
    vim.tbl_contains(vim.fn.getcompletion("TunnelVision direction b", "cmdline"), "backward"),
    "direction completion should include backward"
  )

  -- Fallback-chain command syntax
  vim.cmd("TunnelVision source lsp,word")
  assert_sources({ "lsp", "word" }, "comma-separated fallback chain lsp,word")

  tunnelvision.setup({ notify = false })
  local sources_copy = tunnelvision.get_sources()
  sources_copy[1] = "word"
  assert_sources({ "lsp", "treesitter", "word" }, "get_sources should return an isolated copy")
  for _, value in ipairs({ "treesitter", "lsp,treesitter,word" }) do
    vim.cmd("TunnelVision source " .. value)
    assert_sources(vim.split(value, ",", { plain = true }), "Tree-sitter command source " .. value)
  end
  vim.cmd("TunnelVision source lsp,word")
  assert_sources({ "lsp", "word" }, "restored to lsp,word")

  -- Status display uses source= label
  do
    local notify_msg
    local orig_notify = core.notify
    core.notify = function(msg)
      notify_msg = msg
    end
    vim.cmd("TunnelVision status")
    assert_true(notify_msg and notify_msg:find("source="), "status should use source= label")
    assert_true(notify_msg and notify_msg:find("source=lsp,word"), "status should show formatted source label")
    core.notify = orig_notify
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
    assert_sources({ "lsp", "word" }, "sources unchanged after invalid chain")
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

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
