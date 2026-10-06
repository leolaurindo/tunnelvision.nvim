-- Run with -c 'lua dofile("tests/native.lua")' so real input reaches the main loop.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)

if vim.fn.has("nvim-0.13") == 0 then
  print("tunnelvision native: skipped (requires Neovim 0.13)")
  vim.cmd("qa!")
  return
end

local tv = require("tunnelvision")
local ns = vim.api.nvim_create_namespace("nvim.multicursor")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha one", "beta two", "gamma three" })
vim.api.nvim_buf_set_extmark(0, ns, 1, 0, {})
vim.api.nvim_buf_set_extmark(0, ns, 2, 0, {})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
tv.setup({ notify = false, sources = { "word" }, scope = "buffer", mode = "dynamic_flow" })
vim.keymap.set("n", "<F12>", tv.on)
vim.cmd("normal! 1q=")

local phase = "activate"
local function fail(message)
  io.stderr:write("[tunnelvision native] " .. message .. "\n")
  vim.cmd("cquit 1")
end

vim.api.nvim_create_autocmd("CmdAtom", {
  callback = function()
    if phase == "activate" then
      local tracks = tv.status().tracks
      if #tracks ~= 3 then
        fail("a user mapping must activate the native batch once")
        return
      end
      phase = "move"
      vim.schedule(function()
        vim.api.nvim_input("w")
      end)
    elseif phase == "move" then
      phase = "check"
      vim.schedule(function()
        local followed = vim.wait(1000, function()
          local tracks = tv.status().tracks
          return #tracks == 3
            and tracks[1].symbol == "one"
            and tracks[2].symbol == "two"
            and tracks[3].symbol == "three"
        end)
        if not followed then
          fail("native follow-mode motions must retarget every cursor after cascade")
          return
        end
        for _, track in ipairs(tv.status().tracks) do
          if not track.moving or track.mode ~= "dynamic_flow" then
            fail("native motion must preserve every track's dynamic flow mode")
            return
          end
        end
        print("tunnelvision native: OK")
        vim.cmd("qa!")
      end)
    end
  end,
})
vim.defer_fn(function()
  fail("timed out waiting for real user-input events")
end, 5000)
vim.schedule(function()
  vim.api.nvim_input("<F12>")
end)
