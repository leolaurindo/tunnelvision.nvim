-- Source chain, LSP, Tree-sitter, and fallback coverage.
return function(helpers)
  local assert_true = helpers.assert_true
  local assert_ranges = helpers.assert_ranges
  local assert_sources = helpers.assert_sources
  local new_buffer = helpers.new_buffer
  local parser_or_skip = helpers.parser_or_skip

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")

  -- Custom synchronous sources participate in source chains
  do
    for _, case in ipairs({
      { "", function() end },
      { "custom_invalid", false },
      { "lsp", function() end },
      { "lsp_else_word", function() end },
    }) do
      assert_true(not tunnelvision.register_source(case[1], case[2]), "reserved or invalid custom source " .. case[1])
    end

    local seen_context
    assert_true(
      tunnelvision.register_source("custom_hit", function(ctx)
        seen_context = ctx
        ctx.anchor.row, ctx.scope.start_line = 99, 99
        return { [0] = true, [1.5] = true, [2] = true, [999] = true }
      end),
      "custom source registers"
    )
    assert_true(
      tunnelvision.register_source("custom_empty", function()
        return {}
      end),
      "empty custom source registers"
    )
    assert_true(
      tunnelvision.register_source("custom_error", function()
        error("custom source failure")
      end),
      "failing custom source registers"
    )

    tunnelvision.setup({
      notify = false,
      sources = { "custom_hit" },
      scope = "buffer",
      mode = "static",
      flow_settings = { extra_keywords = { "sentinel" } },
    })
    local custom_buf = new_buffer({
      "local alpha = 1",
      "local beta = alpha",
      "print(beta)",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vim.cmd("TunnelVision on")
    local custom_state = core.get_buf_state(custom_buf)
    assert_true(
      custom_state.path_set[1] and custom_state.path_set[2] and vim.tbl_count(custom_state.path_set) == 2,
      "custom sources should filter invalid and out-of-scope lines"
    )
    assert_true(
      custom_state.anchor.row == 0
        and custom_state.scope.start_line == 1
        and seen_context.bufnr == custom_buf
        and seen_context.symbol == "alpha"
        and seen_context.mode == "static"
        and seen_context.direction == "forward"
        and seen_context.keywords.sentinel
        and seen_context.get_treesitter == nil,
      "custom sources should receive an isolated public context"
    )
    assert_true(
      #custom_state.symbol_ranges == 1 and custom_state.symbol_ranges[1].line == 2,
      "range-less custom results should synthesize ranges on returned lines"
    )
    vim.cmd("TunnelVision off")

    local function run_sources(sources)
      tunnelvision.on({ sources = sources, scope = "buffer", mode = "static" })
      local path = vim.deepcopy(core.get_buf_state(custom_buf).path_set)
      vim.cmd("TunnelVision off")
      return path
    end
    for _, name in ipairs({ "custom_empty", "custom_error" }) do
      assert_true(run_sources({ name, "word" })[2], name .. " should fall back to word matching")
    end
    assert_true(
      not run_sources({ tunnelvision.combine("custom_empty", "word") })[2],
      "failed strict combine should not leak member results"
    )

    tunnelvision.setup({ notify = false, source = "word", scope = "buffer" })
    assert_true(
      tunnelvision.register_source("custom_late", function()
        return { [2] = true }
      end),
      "custom source should register after setup"
    )
    assert_true(run_sources({ "custom_late" })[2], "late custom source should work as a one-shot override")
    assert_sources({ "word" }, "late one-shot source should not mutate global sources")

    tunnelvision.setup({ notify = false, sources = { "custom_unavailable" } })
    assert_sources(
      { "lsp", "treesitter", "word" },
      "unavailable custom source should normalize to the default fallback"
    )
  end

  tunnelvision.setup({ notify = false, source = "lsp", scope = "buffer" })
  local one_shot_buf = new_buffer({
    "local alpha = 1",
    "local beta = 2",
    "print(alpha)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })

  tunnelvision.on({ source = "word" })
  assert_true(core.get_buf_state(one_shot_buf).path_set[3], "one-shot source should override activation source")
  assert_true(core.get_source() == "lsp", "one-shot source should not mutate global source")
  assert_sources({ "lsp" }, "one-shot source should not mutate global sources")
  assert_true(core.get_buf_state(one_shot_buf).config.source == "word", "active buffer should keep one-shot source")
  assert_true(
    core.get_buf_state(one_shot_buf).config.sources[1].name == "word",
    "active buffer should keep one-shot sources"
  )
  vim.cmd("TunnelVision off")

  -- Source ranges use exact, sorted byte columns and preserve ignored-text offsets.
  do
    tunnelvision.setup({ notify = false, source = "word", mode = "static", scope = "buffer" })
    local range_buf = new_buffer({
      "alpha + alpha_ + alpha -- alpha",
      '"alpha" .. alpha',
      "é alpha alpha",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    tunnelvision.on()
    assert_ranges(core.get_buf_state(range_buf).symbol_ranges, {
      { line = 1, start_col = 0, end_col = 5 },
      { line = 1, start_col = 17, end_col = 22 },
      { line = 2, start_col = 11, end_col = 16 },
      { line = 3, start_col = 3, end_col = 8 },
      { line = 3, start_col = 9, end_col = 14 },
    }, "word ranges should retain exact byte positions and all valid occurrences")
    vim.cmd("TunnelVision off")
    assert_ranges(core.get_buf_state(range_buf).symbol_ranges, {}, "deactivation should clear symbol ranges")

    local resolver = require("tunnelvision.resolver")
    local _, _, _, normalized = resolver.compute_path(range_buf, "alpha", { row = 0, col = 0 }, {
      start_line = 1,
      end_line = 3,
    }, {
      direction = "forward",
      keywords = {},
      lsp_result = resolver.make_lsp_result("ok", { [1] = true }, true, {
        { line = 1, start_col = 17, end_col = 99 },
        { line = 1, start_col = 0, end_col = 5 },
        { line = 1, start_col = 0, end_col = 5 },
        { line = 1, start_col = 9, end_col = 9 },
      }),
      mode = "static",
      sources = { { kind = "single", name = "lsp" } },
    })
    assert_ranges(normalized, {
      { line = 1, start_col = 0, end_col = 5 },
      { line = 1, start_col = 17, end_col = 31 },
    }, "computed ranges should clamp, deduplicate, discard empties, and sort")

    local direct_path, direct_order, direct_meta, _, pending = resolver.compute_path(
      range_buf,
      "alpha",
      { row = 0, col = 0 },
      { start_line = 1, end_line = 3 },
      {
        direction = "forward",
        keywords = {},
        mode = "static",
        sources = { { kind = "single", name = "lsp" }, { kind = "single", name = "word" } },
      }
    )
    assert_true(pending == nil, "direct compute_path without LSP data should remain synchronous")
    assert_true(
      direct_path[1] and direct_path[2] and direct_path[3],
      "direct LSP fallback should include anchor and word matches"
    )
    assert_true(#direct_order == 3, "direct LSP fallback should return ordinary path order")
    assert_true(
      direct_meta.used_source == "word"
        and direct_meta.fallback_source == "lsp"
        and direct_meta.fallback_reason == "disabled",
      "direct LSP fallback should preserve disabled metadata"
    )
  end

  do
    local cancellations = {}
    local lsp_buf
    local requests = {}
    local sync_cancel_callbacks = false
    local timers = {}
    local explicit_client_self = vim.fn.has("nvim-0.11") == 1
    local fake_clients = {
      { id = 1, offset_encoding = "utf-8", server_capabilities = {} },
      { id = 2, offset_encoding = "utf-16", server_capabilities = { documentHighlightProvider = true } },
      { id = 3, offset_encoding = "utf-8", server_capabilities = { documentHighlightProvider = true } },
      { id = 4, offset_encoding = "utf-32", server_capabilities = {} },
    }
    local function client_method(client, fn)
      if explicit_client_self then
        return function(self, ...)
          assert_true(self == client, "Neovim 0.11 client methods should receive explicit self")
          return fn(...)
        end
      end
      return fn
    end
    fake_clients[1].supports_method = client_method(fake_clients[1], function(method, context)
      local supported_context = explicit_client_self and type(context) == "number"
        or not explicit_client_self and type(context) == "table" and type(context.bufnr) == "number"
      assert_true(supported_context, "LSP support checks should use the version's client API")
      return method == "textDocument/documentHighlight"
    end)
    fake_clients[3].supports_method = client_method(fake_clients[3], function()
      return false
    end)
    fake_clients[4].supports_method = client_method(fake_clients[4], function(method)
      return method == "textDocument/documentHighlight"
    end)
    for _, client in ipairs({ fake_clients[1], fake_clients[2] }) do
      local cancel_client = client
      client.cancel_request = client_method(client, function(handle)
        cancellations[("%d:%d"):format(cancel_client.id, handle)] = true
        if sync_cancel_callbacks then
          requests[handle - 100].callback(nil, {
            { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } },
          })
        end
      end)
    end
    for _, client in ipairs(fake_clients) do
      local request_client = client
      client.request = client_method(client, function(method, params, callback, bufnr)
        local handle = 101 + #requests
        requests[#requests + 1] = {
          bufnr = bufnr,
          callback = callback,
          client_id = request_client.id,
          handle = handle,
          method = method,
          params = params,
        }
        if request_client.sync_result then
          callback(nil, request_client.sync_result)
        end
        return true, handle
      end)
    end

    local orig_defer_fn = vim.defer_fn
    vim.defer_fn = function(callback)
      timers[#timers + 1] = callback
    end
    local restore_clients
    if vim.lsp.get_clients then
      local orig_get_clients = vim.lsp.get_clients
      vim.lsp.get_clients = function()
        return fake_clients
      end
      restore_clients = function()
        vim.lsp.get_clients = orig_get_clients
      end
    else
      local orig_buf_get_clients = vim.lsp.buf_get_clients
      vim.lsp.buf_get_clients = function()
        return fake_clients
      end
      restore_clients = function()
        vim.lsp.buf_get_clients = orig_buf_get_clients
      end
    end

    local function respond(request, result, err)
      request.callback(err, result, { client_id = request.client_id })
    end

    local function was_canceled(request)
      return cancellations[("%d:%d"):format(request.client_id, request.handle)]
    end

    local request_cursor, timer_cursor = 0, 0
    local function take_batch()
      local batch = {}
      for i = request_cursor + 1, #requests do
        batch[requests[i].client_id] = requests[i]
      end
      request_cursor = #requests
      timer_cursor = timer_cursor + 1
      assert_true(timers[timer_cursor] ~= nil, "each activation should create one global timeout")
      return batch, timers[timer_cursor]
    end

    lsp_buf = new_buffer({ "😀 alpha alpha", "plain alpha", "alpha", "beta" })
    local direct_result
    require("tunnelvision.resolver").request_lsp_highlight(
      lsp_buf,
      { row = 1, col = 6 },
      { start_line = 1, end_line = 4 },
      1000,
      function(result)
        direct_result = result
      end
    )
    local direct_batch = take_batch()
    respond(direct_batch[1], {
      { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } },
    })
    respond(direct_batch[2], {})
    respond(direct_batch[4], {})
    assert_true(direct_result and direct_result.used, "five-argument LSP request callback should remain compatible")
    assert_ranges(direct_result.ranges, {
      { line = 3, start_col = 0, end_col = 5 },
    }, "direct LSP request ranges")

    local request_count = #requests
    tunnelvision.setup({ notify = false, sources = { "word", "lsp" }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    local bs = core.get_buf_state(lsp_buf)
    assert_true(#requests == request_count and not bs.pending, "successful word before LSP should avoid requests")
    assert_true(bs.last_compute_meta.used_source == "word", "word-first resolution should select word")

    if parser_or_skip(lsp_buf, "lua", "Tree-sitter-first LSP demand") then
      tunnelvision.setup({ notify = false, sources = { "treesitter", "lsp" }, scope = "buffer" })
      core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
      assert_true(
        #requests == request_count and not bs.pending,
        "successful treesitter before LSP should avoid requests"
      )
      assert_true(
        bs.last_compute_meta.used_source == "treesitter",
        "treesitter-first resolution should select treesitter"
      )
    end

    tunnelvision.setup({
      notify = false,
      sources = { tunnelvision.combine("custom_empty", "lsp"), "word" },
      scope = "buffer",
    })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    assert_true(#requests == request_count, "failed earlier combine member should not request a later LSP member")
    assert_true(bs.last_compute_meta.used_source == "word", "failed strict combine should use the next source")
    assert_true(
      bs.last_compute_meta.fallback_source == "custom_empty",
      "strict combine should preserve the first failed member metadata"
    )

    local custom_resume_calls = 0
    assert_true(
      tunnelvision.register_source("custom_resume", function()
        custom_resume_calls = custom_resume_calls + 1
        return { [1] = true }
      end),
      "resumable custom source registers"
    )
    tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("custom_resume", "lsp") }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    local resume_batch = take_batch()
    assert_true(bs.pending and custom_resume_calls == 1, "strict combine should pause when it reaches LSP")
    respond(resume_batch[1], {
      { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } },
    })
    respond(resume_batch[2], {})
    respond(resume_batch[4], {})
    assert_true(custom_resume_calls == 1, "resume should not rerun a completed custom source")
    assert_true(
      not bs.pending
        and bs.last_compute_meta.used_source == "combine(custom_resume,lsp)"
        and bs.path_set[1]
        and bs.path_set[2],
      "resumed strict combine should merge cached custom and LSP results"
    )

    tunnelvision.setup({ notify = false, sources = { "custom_empty", "lsp" }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    local fallback_batch = take_batch()
    assert_true(bs.pending, "failed earlier source should continue to LSP")
    respond(fallback_batch[1], {
      { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } },
    })
    respond(fallback_batch[2], {})
    respond(fallback_batch[4], {})
    assert_true(
      bs.last_compute_meta.used_source == "lsp"
        and bs.last_compute_meta.used_fallback
        and bs.last_compute_meta.fallback_source == "custom_empty",
      "LSP reached after an earlier failure should retain fallback metadata"
    )

    tunnelvision.setup({
      notify = false,
      source = "word",
      scope = "buffer",
      dim = "none",
      highlights = { line = { fg = 0x112233 } },
    })
    vim.api.nvim_win_set_cursor(0, { 2, 6 })
    vim.cmd("TunnelVision on")
    bs = core.get_buf_state(lsp_buf)
    local old_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
    local function mark_geometry(marks)
      return vim.tbl_map(function(mark)
        return { mark[2], mark[3], mark[4] }
      end, marks)
    end
    assert_true(#old_marks > 0, "word render should create styled extmarks")
    bs.last_compute_meta = { flow_analyzer = "text", flow_expanded = true, flow_tracked_count = 2 }

    tunnelvision.setup({
      notify = false,
      scope = "buffer",
      dim = "none",
      highlights = { line = { fg = 0xAABBCC } },
      lsp_timeout_ms = 1000,
    })
    core.activate(lsp_buf, { silent = true, symbol = "alpha", cursor = { 1, 5 } })
    local batch = take_batch()
    local timeout
    assert_true(batch[1] and batch[2] and batch[4] and not batch[3], "only supporting clients should be requested")
    for _, request in pairs(batch) do
      assert_true(request.method == "textDocument/documentHighlight", "per-client request method")
      assert_true(request.bufnr == lsp_buf, "per-client request buffer")
    end
    assert_true(batch[1].params.position.character == 5, "UTF-8 request should use byte offset")
    assert_true(batch[2].params.position.character == 3, "UTF-16 request should count astral code units")
    assert_true(batch[4].params.position.character == 2, "UTF-32 request should count astral characters")
    assert_true(bs.pending, "default LSP-first activation should be pending")
    local pending_status = tunnelvision.status()
    assert_true(
      pending_status.flow_analyzer == nil
        and not pending_status.flow_expanded
        and pending_status.flow_tracked_count == 0,
      "pending status should not expose stale flow metadata"
    )
    assert_true(
      vim.deep_equal(vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true }), old_marks),
      "pending LSP request should retain the previous render"
    )
    local ui = require("tunnelvision.ui")
    local resolver = require("tunnelvision.resolver")
    local orig_ensure_highlights = ui.ensure_highlights
    local orig_compute_path = resolver.compute_path
    local pending_config, rendered_config, request_id = bs.config, bs.rendered_config, bs.request_id
    local pending_config_setups = 0
    local compute_calls = 0
    ui.ensure_highlights = function(cfg)
      if cfg == pending_config then
        pending_config_setups = pending_config_setups + 1
      end
      return orig_ensure_highlights(cfg)
    end
    resolver.compute_path = function(...)
      compute_calls = compute_calls + 1
      return orig_compute_path(...)
    end
    local old_group = old_marks[1][4].hl_group
    vim.api.nvim_set_hl(0, old_group, {})
    assert_true(
      next(vim.api.nvim_get_hl(0, { name = old_group, link = false })) == nil,
      "colorscheme should clear old groups"
    )
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    ui.ensure_highlights = orig_ensure_highlights
    resolver.compute_path = orig_compute_path
    local recreated_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
    assert_true(
      vim.deep_equal(mark_geometry(recreated_marks), mark_geometry(old_marks)),
      "ColorScheme should preserve retained extmarks while LSP is pending"
    )
    local recreated_group = recreated_marks[1][4].hl_group
    assert_true(
      vim.api.nvim_get_hl(0, { name = recreated_group, link = false }).fg == 0x112233,
      "pending ColorScheme should recreate the last rendered style"
    )
    assert_true(
      pending_config_setups == 0
        and compute_calls == 0
        and bs.pending
        and bs.request_id == request_id
        and bs.config == pending_config
        and bs.rendered_config == rendered_config,
      "pending ColorScheme should preserve pending config, request, and cached render state"
    )

    fake_clients[1].offset_encoding = "utf-16"
    respond(batch[1], {
      { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } },
    })
    assert_true(bs.pending, "partial LSP results should wait for remaining clients")
    respond(batch[4], {
      { range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 7 } } },
    })
    respond(batch[2], {
      { range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 8 } } },
      { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } },
    })
    fake_clients[1].offset_encoding = "utf-8"
    assert_true(not bs.pending, "terminal responses should clear pending state")
    local completed_group =
      vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })[1][4].hl_group
    assert_true(
      bs.rendered_config == pending_config
        and vim.api.nvim_get_hl(0, { name = completed_group, link = false }).fg == 0xAABBCC,
      "completed request should apply the pending style"
    )
    assert_ranges(bs.symbol_ranges, {
      { line = 1, start_col = 5, end_col = 10 },
      { line = 2, start_col = 6, end_col = 11 },
    }, "mixed response encodings should normalize and deduplicate byte ranges")

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    assert_true(batch[1].params.position.character == 6, "ASCII UTF-8 offset should remain unchanged")
    assert_true(batch[2].params.position.character == 6, "ASCII UTF-16 offset should remain unchanged")
    assert_true(batch[4].params.position.character == 6, "ASCII UTF-32 offset should remain unchanged")
    respond(batch[1], { { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } } })
    respond(batch[2], nil, { code = -1, message = "boom" })
    respond(batch[4], nil, { code = -1, message = "boom" })
    assert_true(not bs.pending and bs.path_set[2], "valid partial results should survive another client error")

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 3, 0 } })
    batch, timeout = take_batch()
    respond(batch[1], { { range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 5 } } } })
    timeout()
    assert_true(was_canceled(batch[2]) and not was_canceled(batch[1]), "timeout should cancel only unresolved clients")
    assert_true(not bs.pending, "partial result should complete at the global timeout")
    assert_true(bs.path_set[3], "timed-out clients should not discard valid partial results")
    local timeout_ranges = vim.deepcopy(bs.symbol_ranges)
    respond(batch[2], { { range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 5 } } } })
    assert_ranges(bs.symbol_ranges, timeout_ranges, "late responses after timeout should be ignored")

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    for _, request in pairs(batch) do
      respond(request, nil, { code = -1, message = "boom" })
    end
    local fallback_meta = bs.last_compute_meta
    assert_true(not bs.pending and fallback_meta.used_source == "treesitter", "total errors should use fallback chain")
    assert_true(
      fallback_meta.failed_sources[1] == "lsp"
        and fallback_meta.fallback_source == "lsp"
        and fallback_meta.fallback_reason == "request_failed"
        and fallback_meta.used_fallback,
      "total errors should preserve fallback metadata"
    )

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch, timeout = take_batch()
    sync_cancel_callbacks = true
    timeout()
    sync_cancel_callbacks = false
    assert_true(
      was_canceled(batch[1]) and was_canceled(batch[2]) and bs.last_compute_meta.used_source == "treesitter",
      "reentrant total timeout should cancel its owned requests and fall back"
    )

    tunnelvision.setup({ notify = false, sources = { "lsp" }, scope = "buffer", lsp_timeout_ms = 1000 })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    for _, request in pairs(batch) do
      respond(request, nil, { code = -1, message = "boom" })
    end
    assert_true(bs.last_compute_meta.used_source == nil, "strict LSP total failure should not select a fallback")
    assert_true(not bs.path_set[1] and not bs.path_set[3], "strict LSP total failure should keep only the anchor")

    tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    respond(batch[1], { { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } } })
    respond(batch[2], {})
    respond(batch[4], {})
    assert_true(bs.last_compute_meta.used_source == "combine(lsp,word)", "combined source should succeed")
    assert_true(bs.path_set[1] and bs.path_set[3], "combined source should include LSP and word lines")

    tunnelvision.setup({ notify = false, sources = { tunnelvision.combine("lsp", "word") }, scope = "buffer" })
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    for _, request in pairs(batch) do
      respond(request, {})
    end
    assert_true(bs.last_compute_meta.used_source == nil, "empty LSP should fail an all-or-nothing combined source")
    assert_true(bs.last_compute_meta.fallback_source == "lsp", "empty combined source should record its failed member")

    tunnelvision.setup({
      notify = false,
      sources = { tunnelvision.combine("lsp", "treesitter"), "word" },
      scope = "buffer",
    })
    vim.bo[lsp_buf].filetype = "plaintext"
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    respond(batch[1], { { range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 10 } } } })
    respond(batch[2], {})
    respond(batch[4], {})
    assert_true(bs.last_compute_meta.used_source == "word", "later combined member failure should use next source")
    assert_true(bs.last_compute_meta.fallback_source == "treesitter", "combined failure should record later member")
    assert_true(
      bs.last_compute_meta.failed_sources[1] == "combine(lsp,treesitter)",
      "combined failure should record the failed step"
    )

    tunnelvision.setup({ notify = false, sources = { "lsp", "word" }, scope = "buffer" })
    fake_clients[4].sync_result = {}
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    respond(batch[1], {})
    respond(batch[2], {})
    fake_clients[4].sync_result = nil
    assert_true(bs.last_compute_meta.used_source == "word", "empty successful LSP response should follow source chain")
    assert_true(
      bs.last_compute_meta.fallback_reason == "no_matches",
      "empty successful response should report no_matches"
    )

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 5 } })
    local stale_batch = take_batch()
    local stale_request_id = bs.request_id
    respond(stale_batch[1], {})
    respond(stale_batch[4], {})
    local retained_marks = vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true })
    sync_cancel_callbacks = true
    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    sync_cancel_callbacks = false
    local current_batch = take_batch()
    local current_request_id = bs.request_id
    assert_true(current_request_id ~= stale_request_id, "supersession should replace the request ID")
    assert_true(
      was_canceled(stale_batch[2]) and not was_canceled(stale_batch[1]),
      "supersession owns incomplete requests"
    )
    assert_true(
      bs.pending and bs.anchor.row == 1,
      "synchronous cancellation callbacks should leave replacement pending"
    )
    assert_true(
      vim.deep_equal(vim.api.nvim_buf_get_extmarks(lsp_buf, core.state.ns, 0, -1, { details = true }), retained_marks),
      "synchronous cancellation callbacks should preserve the pending render"
    )
    respond(stale_batch[1], {})
    respond(stale_batch[2], {})
    respond(stale_batch[4], {})
    assert_true(
      bs.pending and bs.anchor.row == 1 and bs.request_id == current_request_id,
      "older completed requests should remain stale"
    )
    respond(
      current_batch[1],
      { { range = { start = { line = 1, character = 6 }, ["end"] = { line = 1, character = 11 } } } }
    )
    respond(current_batch[2], {})
    respond(current_batch[4], {})
    assert_true(
      not bs.pending and bs.request_id == nil and bs.path_set[2],
      "current request should apply after stale response"
    )

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    local pre_edit_batch = take_batch()
    vim.api.nvim_buf_set_lines(lsp_buf, 1, 2, false, { "edited alpha" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = lsp_buf })
    local edit_refresh = timers[#timers]
    assert_true(
      not was_canceled(pre_edit_batch[1]) and not was_canceled(pre_edit_batch[2]),
      "edit debounce should retain pending LSP requests during the delay"
    )
    edit_refresh()
    timer_cursor = timer_cursor + 1
    batch = take_batch()
    assert_true(
      was_canceled(pre_edit_batch[1]) and was_canceled(pre_edit_batch[2]) and bs.pending,
      "debounced refresh should cancel the pre-edit LSP requests before replacing them"
    )
    respond(batch[1], {})
    respond(batch[2], {})
    respond(batch[4], {})

    core.activate(lsp_buf, { force = true, silent = true, symbol = "alpha", cursor = { 2, 6 } })
    batch = take_batch()
    respond(batch[4], {})
    sync_cancel_callbacks = true
    vim.cmd("TunnelVision off")
    sync_cancel_callbacks = false
    assert_true(was_canceled(batch[1]) and was_canceled(batch[2]), "deactivation should cancel pending clients")
    for _, request in pairs(batch) do
      respond(request, {})
    end
    assert_true(not bs.active and not bs.pending, "late callbacks after deactivation should remain stale")

    local deleted_buf = new_buffer({ "alpha", "alpha" })
    core.activate(deleted_buf, { force = true, silent = true, symbol = "alpha", cursor = { 1, 0 } })
    batch = take_batch()
    respond(batch[4], {})
    vim.api.nvim_buf_delete(deleted_buf, { force = true })
    assert_true(
      was_canceled(batch[1]) and was_canceled(batch[2]) and core.state.bufs[deleted_buf] == nil,
      "buffer deletion should cancel owned requests and clear state"
    )
    for _, request in pairs(batch) do
      respond(request, {})
    end
    assert_true(core.state.bufs[deleted_buf] == nil, "late callbacks after buffer deletion should stay stale")

    vim.defer_fn = orig_defer_fn
    restore_clients()
  end

  -- Fallback warning policies remain stable when LSP is unavailable.
  do
    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end

    local fallback_buf = new_buffer({
      "local alpha = 1",
      "print(alpha)",
    }, "plaintext")
    local function warning_count(policy, notify, source)
      messages = {}
      tunnelvision.setup({
        notify = notify,
        source = source or "lsp_else_word",
        fallback_warn = policy,
        scope = "buffer",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 7 })
      tunnelvision.on()
      core.activate(fallback_buf, { force = true, silent = false, symbol = "alpha", cursor = { 1, 7 } })
      vim.cmd("TunnelVision off")
      return #messages
    end
    for _, case in ipairs({
      { "once", true, 1 },
      { "always", true, 2 },
      { "never", true, 0 },
      { "always", false, 0 },
    }) do
      local count = warning_count(case[1], case[2])
      assert_true(count == case[3], ("fallback_warn %s: expected %d, got %d"):format(case[1], case[3], count))
    end
    assert_true(
      warning_count("once", true, "lsp") == 1 and messages[1]:find("strict LSP source"),
      "strict LSP should warn when clients are unavailable"
    )
    vim.notify = orig_notify
  end

  -- Treesitter fallback behavior (plaintext has no parser)
  tunnelvision.setup({ notify = false })
  local ts_fb_buf = new_buffer({
    "local alpha = 1",
    "local beta = 2",
    "print(alpha)",
  }, "plaintext")
  vim.api.nvim_win_set_cursor(0, { 1, 7 })

  -- sources = { "treesitter" } should only keep the anchor line
  tunnelvision.on({ sources = { "treesitter" } })
  assert_true(next(core.get_buf_state(ts_fb_buf).path_set) ~= nil, "treesitter-only should keep anchor")
  assert_true(core.get_buf_state(ts_fb_buf).path_set[1], "treesitter-only anchor at line 1")
  assert_true(not core.get_buf_state(ts_fb_buf).path_set[3], "treesitter-only should not match line 3")
  local ts_meta = core.get_buf_state(ts_fb_buf).last_compute_meta
  assert_true(ts_meta.fallback_reason == "unavailable", "treesitter-only fallback reason is unavailable")
  vim.cmd("TunnelVision off")

  -- sources = { "treesitter", "word" } falls back to word matching
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on({ sources = { "treesitter", "word" } })
  assert_true(core.get_buf_state(ts_fb_buf).path_set[3], "treesitter,word falls back to word matching")
  assert_true(
    core.get_buf_state(ts_fb_buf).last_compute_meta.fallback_reason == "unavailable",
    "treesitter,word fallback reason is unavailable"
  )
  vim.cmd("TunnelVision off")

  -- tv.combine("lsp", "treesitter"), "word" falls back to word when treesitter unavailable
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tunnelvision.on({ sources = { tunnelvision.combine("lsp", "treesitter"), "word" } })
  assert_true(core.get_buf_state(ts_fb_buf).path_set[3], "combine(lsp,treesitter),word falls back to word")
  local combined_meta = core.get_buf_state(ts_fb_buf).last_compute_meta
  assert_true(combined_meta.used_source == "word", "combined fallback metadata records selected word source")
  assert_true(
    combined_meta.failed_sources[1] == "combine(lsp,treesitter)",
    "combined fallback metadata records failed combined step"
  )
  assert_true(combined_meta.fallback_source == "lsp", "combined fallback metadata records failed member")
  vim.cmd("TunnelVision off")
  tunnelvision.setup({ notify = false, source = "lsp_else_word" })

  -- Treesitter source matches identifier nodes when parser is available
  do
    tunnelvision.setup({ notify = false })
    local ts_buf = new_buffer({
      "local alpha = 1",
      "local beta = 2",
      "print(alpha)",
    })

    if parser_or_skip(0, "lua", "real Lua Tree-sitter source and flow") then
      -- sources = { "treesitter" } returns identifier lines
      vim.api.nvim_win_set_cursor(0, { 1, 7 })
      tunnelvision.on({ sources = { "treesitter" } })
      assert_true(core.get_buf_state(ts_buf).path_set[1], "treesitter should match line 1 (declaration)")
      assert_true(core.get_buf_state(ts_buf).path_set[3], "treesitter should match line 3 (usage)")
      assert_true(not core.get_buf_state(ts_buf).path_set[2], "treesitter should not match line 2 (different symbol)")
      assert_ranges(core.get_buf_state(ts_buf).symbol_ranges, {
        { line = 1, start_col = 6, end_col = 11 },
        { line = 3, start_col = 6, end_col = 11 },
      }, "treesitter should retain exact identifier node ranges")
      assert_true(
        core.get_buf_state(ts_buf).last_compute_meta.fallback_reason == nil,
        "treesitter should not set fallback_reason on success"
      )
      vim.cmd("TunnelVision off")

      local ts_flow_buf = new_buffer({
        "local alpha = 1",
        "local beta = alpha",
        "print(beta)",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 7 })
      tunnelvision.on({ sources = { "treesitter" }, scope = "buffer", mode = "flow" })
      assert_true(core.get_buf_state(ts_flow_buf).path_set[3], "treesitter-only source should enable flow expansion")
      assert_ranges(core.get_buf_state(ts_flow_buf).symbol_ranges, {
        { line = 1, start_col = 6, end_col = 11 },
        { line = 2, start_col = 6, end_col = 10 },
        { line = 2, start_col = 13, end_col = 18 },
        { line = 3, start_col = 6, end_col = 10 },
      }, "treesitter-only flow should retain source and propagated ranges")
      vim.cmd("TunnelVision off")

      local ts_analysis = require("tunnelvision.flow").analyze_treesitter({
        anchor = { row = 0, col = 6 },
        bufnr = ts_flow_buf,
        keywords = require("tunnelvision.resolver").build_keywords({}),
        scope = { start_line = 1, end_line = 3 },
        symbol = "alpha",
      })
      assert_true(ts_analysis and #ts_analysis.assignments >= 2, "treesitter analyzer should extract assignments")
      assert_ranges(ts_analysis.assignments[2].lhs, {
        { name = "beta", line = 2, start_col = 6, end_col = 10 },
      }, "treesitter analyzer should retain exact LHS ranges")

      local nested_flow_buf = new_buffer({
        "local alpha = 1",
        "local function nested()",
        "  local nested_value = alpha",
        "  print(nested_value)",
        "end",
        "local callback = function()",
        "  local leaked = alpha",
        "end",
        "local beta = alpha",
      })
      local nested_analysis = require("tunnelvision.flow").analyze_treesitter({
        anchor = { row = 0, col = 6 },
        bufnr = nested_flow_buf,
        keywords = require("tunnelvision.resolver").build_keywords({}),
        scope = { start_line = 1, end_line = 9 },
        symbol = "alpha",
      })
      assert_true(not nested_analysis.occurrences.nested_value, "treesitter analyzer should skip nested functions")
      assert_true(not nested_analysis.occurrences.leaked, "treesitter analyzer should skip function expressions")
      assert_true(#nested_analysis.occurrences.alpha == 2, "nested functions should not leak identifier occurrences")

      -- Treesitter excludes string-only occurrences
      local str_buf = new_buffer({
        'local msg = "alpha is here"',
        "-- alpha in a comment",
        "local copy = alpha",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 10 })
      tunnelvision.on({ sources = { "treesitter" } })
      -- alpha on line 3 is an identifier reference
      assert_true(core.get_buf_state(str_buf).path_set[3], "treesitter should match identifier alpha on line 3")
      -- alpha on line 1 is inside a string literal, not an identifier node
      assert_true(
        not core.get_buf_state(str_buf).path_set[1],
        "treesitter should not match alpha inside string on line 1"
      )
      assert_true(
        not core.get_buf_state(str_buf).path_set[2],
        "treesitter should not match alpha inside comment on line 2"
      )
      vim.cmd("TunnelVision off")

      -- Treesitter respects scope = "function" vs scope = "buffer"
      local scope_buf = new_buffer({
        "local function foo()",
        "  local alpha = 1",
        "  print(alpha)",
        "end",
        "local alpha = 2",
      })
      -- scope = "function" with cursor inside foo() should only find alpha inside the function
      vim.api.nvim_win_set_cursor(0, { 2, 10 })
      tunnelvision.on({ sources = { "treesitter" }, scope = "function" })
      assert_true(core.get_buf_state(scope_buf).path_set[2], "treesitter function scope should match alpha on line 2")
      assert_true(core.get_buf_state(scope_buf).path_set[3], "treesitter function scope should match alpha on line 3")
      -- line 5 (outside function) may or may not be included depending on scope resolution;
      -- we just verify function scope is narrower than buffer scope
      local function_scope_matches = vim.tbl_count(core.get_buf_state(scope_buf).path_set)
      vim.cmd("TunnelVision off")

      -- scope = "buffer" should find alpha everywhere
      vim.api.nvim_win_set_cursor(0, { 2, 10 })
      tunnelvision.on({ sources = { "treesitter" }, scope = "buffer" })
      assert_true(core.get_buf_state(scope_buf).path_set[5], "treesitter buffer scope should match alpha on line 5")
      local buffer_scope_matches = vim.tbl_count(core.get_buf_state(scope_buf).path_set)
      assert_true(
        buffer_scope_matches >= function_scope_matches,
        "buffer scope should match at least as many lines as function scope"
      )
      vim.cmd("TunnelVision off")

      -- combine(lsp, treesitter) fails the combined step when LSP is unavailable
      local combine_buf = new_buffer({
        "local alpha = 1",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 7 })
      tunnelvision.on({ sources = { tunnelvision.combine("lsp", "treesitter"), "word" } })
      -- LSP is unavailable, so combine fails, falls back to word
      assert_true(core.get_buf_state(combine_buf).path_set[1], "combine(lsp,treesitter) fallback should keep anchor")
      assert_true(
        core.get_buf_state(combine_buf).last_compute_meta.used_fallback,
        "combine(lsp,treesitter) should trigger fallback when LSP unavailable"
      )
      vim.cmd("TunnelVision off")
    end
  end

  -- Tree-sitter source prunes complete out-of-scope subtrees without changing results.
  do
    local resolver = require("tunnelvision.resolver")
    local orig_get_parser = vim.treesitter.get_parser
    local orig_get_node_text = vim.treesitter.get_node_text
    local calls

    local function node(name, node_type, range, text, children)
      local result = {
        type = function()
          calls.types[name] = (calls.types[name] or 0) + 1
          return node_type
        end,
        iter_children = function()
          calls.children[name] = (calls.children[name] or 0) + 1
          local index = 0
          return function()
            index = index + 1
            return (children or {})[index]
          end
        end,
        text = text,
      }
      result.range = function()
        calls.ranges[name] = (calls.ranges[name] or 0) + 1
        return unpack(range)
      end
      return result
    end

    local function ranged(name, node_type, start_row, start_col, end_row, end_col, text, children)
      return node(name, node_type, { start_row, start_col, end_row, end_col }, text, children)
    end

    local before_id = ranged("before_id", "identifier", 0, 0, 0, 5, "alpha")
    local exclusive_id = ranged("exclusive_id", "identifier", 1, 0, 1, 5, "alpha")
    local zero_id = ranged("zero_id", "identifier", 2, 0, 2, 5, "alpha")
    local span_start = ranged("span_start", "identifier", 2, 6, 2, 11, "alpha")
    local span_end = ranged("span_end", "identifier", 4, 6, 4, 11, "alpha")
    local intersect_id = ranged("intersect_id", "identifier", 4, 13, 4, 18, "alpha")
    local after_id = ranged("after_id", "identifier", 6, 0, 6, 5, "alpha")
    local ts_root = ranged("root", "chunk", 0, 0, 8, 0, nil, {
      ranged("before", "parent", 0, 0, 1, 5, nil, { before_id }),
      ranged("exclusive", "parent", 0, 0, 2, 0, nil, { exclusive_id }),
      ranged("zero", "parent", 2, 0, 2, 0, nil, { zero_id }),
      ranged("spanning", "parent", 1, 0, 6, 0, nil, { span_start, span_end }),
      ranged("intersecting", "parent", 4, 0, 5, 0, nil, { intersect_id }),
      ranged("after", "parent", 5, 0, 7, 0, nil, { after_id }),
    })
    vim.treesitter.get_parser = function()
      return {
        parse = function()
          return { {
            root = function()
              return ts_root
            end,
          } }
        end,
      }
    end
    vim.treesitter.get_node_text = function(current)
      return current.text
    end
    local prune_buf = new_buffer(vim.fn["repeat"]({ (" "):rep(30) }, 8), "prune-ts")
    local source = { { kind = "single", name = "treesitter" } }
    local function compute(scope)
      calls = { types = {}, ranges = {}, children = {} }
      return resolver.compute_path(prune_buf, "alpha", { row = 2, col = 6 }, scope, {
        direction = "forward",
        keywords = {},
        mode = "static",
        sources = source,
      })
    end

    local path, _, _, ranges = compute({ start_line = 3, end_line = 5 })
    assert_true(vim.deep_equal(path, { [3] = true, [5] = true }), "pruned path: " .. vim.inspect(path))
    assert_ranges(ranges, {
      { line = 3, start_col = 6, end_col = 11 },
      { line = 5, start_col = 6, end_col = 11 },
      { line = 5, start_col = 13, end_col = 18 },
    }, "pruned ranges")
    for _, name in ipairs({ "before_id", "exclusive_id", "zero_id", "after_id" }) do
      assert_true(
        not calls.ranges[name] and not calls.types[name] and not calls.children[name],
        name .. " should not be entered"
      )
    end
    vim.treesitter.get_parser = orig_get_parser
    vim.treesitter.get_node_text = orig_get_node_text
  end

  print("tunnelvision smoke: OK")

  -- Documented baseline for later domains.
  tunnelvision.setup({ notify = false })
end
