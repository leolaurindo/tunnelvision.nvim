-- Quickfix export and jumplist behavior for next/prev.
return function(helpers)
  local assert_true = helpers.assert_true
  local new_buffer = helpers.new_buffer

  local tunnelvision = require("tunnelvision")
  local core = require("tunnelvision.core")

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

  -- set_quickfix exports one buffer's deduplicated navigation targets.
  do
    local bufnr = new_buffer({ "alpha", "alpha beta", "other", "alpha" }, "plaintext")
    tunnelvision.setup({ notify = false, sources = { "word" }, scope = "buffer", dim = "none" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tunnelvision.on({ symbol = "alpha", cursor = { 1, 0 } })

    -- This track's only line is already covered, so it must add no entry.
    tunnelvision.register_source("nav_fixed_line", function()
      return { [4] = true }
    end)
    tunnelvision.add({ symbol = "beta", cursor = { 2, 6 }, sources = { "nav_fixed_line" }, scope = "buffer" })

    local expected = core.occurrences(bufnr)
    local count = tunnelvision.set_quickfix(bufnr)
    local list = vim.fn.getqflist()
    assert_true(count == 3 and count == #expected and #list == count, "export should dedupe to three targets")
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
