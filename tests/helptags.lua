local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h")
local doc = vim.env.TUNNELVISION_HELPTAGS_DIR or root .. "/doc"

vim.cmd("helptags " .. vim.fn.fnameescape(doc))
print("tunnelvision helptags: OK")
