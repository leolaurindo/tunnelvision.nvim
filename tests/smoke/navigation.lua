-- Quickfix export and jumplist behavior for next/prev.
return function(helpers)
  local assert_true = helpers.assert_true
  local new_buffer = helpers.new_buffer

  local tunnelvision = require("tunnelvision")

  -- next/prev are jumps: <C-o> returns, and the temporary jump mark is restored.
  do
    new_buffer({ "alpha", "other", "alpha", "other", "alpha" }, "plaintext")
    tunnelvision.setup({ notify = false, sources = { "word" }, scope = "buffer", dim = "none" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tunnelvision.on({ symbol = "alpha", cursor = { 1, 0 } })
    vim.cmd("normal! mz")
    local user_mark = vim.fn.getpos("'z")

    tunnelvision.next(2)
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 5, "counted next should advance twice")
    vim.cmd("normal! \15") -- <C-o>
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 1, "<C-o> should return after a counted jump")
    assert_true(vim.deep_equal(vim.fn.getpos("'z"), user_mark), "jumps must not disturb user marks")
    tunnelvision.off()
  end

  -- set_quickfix exports the union of all tracked symbols.
  do
    local bufnr = new_buffer({ "alpha", "alpha beta", "beta", "alpha" }, "plaintext")
    tunnelvision.setup({ notify = false, sources = { "word" }, scope = "buffer", dim = "none" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tunnelvision.on({ symbol = "alpha", cursor = { 1, 0 } })
    tunnelvision.add({ symbol = "beta", cursor = { 2, 6 } })

    vim.fn.setqflist({}, " ", { title = "previous results", items = { { bufnr = bufnr, lnum = 3, text = "beta" } } })
    local previous_list = vim.fn.getqflist({ id = 0, title = 1, items = 1 })
    local count = tunnelvision.set_quickfix(bufnr)
    local list = vim.fn.getqflist()
    assert_true(vim.fn.getqflist({ id = 0 }).id ~= previous_list.id, "export should create a new quickfix list")
    vim.cmd("colder")
    local restored = vim.fn.getqflist({ id = 0, title = 1, items = 1 })
    assert_true(vim.deep_equal(restored, previous_list), "previous quickfix results should remain accessible")
    vim.cmd("cnewer")
    local positions = vim.tbl_map(function(item)
      return { item.lnum, item.col }
    end, list)
    assert_true(
      count == 5 and vim.deep_equal(positions, { { 1, 1 }, { 2, 1 }, { 2, 7 }, { 3, 1 }, { 4, 1 } }),
      "export should include positions from both tracked symbols"
    )
    for index, item in ipairs(list) do
      assert_true(item.valid == 1 and item.bufnr == bufnr, "entries should target the active buffer")
      if index > 1 then
        local previous = list[index - 1]
        assert_true(
          previous.lnum < item.lnum or previous.lnum == item.lnum and previous.col < item.col,
          "entries should be strictly sorted and unique"
        )
      end
    end

    vim.cmd("TunnelVision quickfix")
    assert_true(#vim.fn.getqflist() == count, "the command should export the same targets")
    tunnelvision.off()
    assert_true(tunnelvision.set_quickfix(bufnr) == 0, "no active tracks should export nothing")
  end

  tunnelvision.setup({ notify = false })
end
