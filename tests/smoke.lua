-- Smoke entrypoint: loads the shared helpers and runs each domain in order.
local helpers = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local function domain(name)
  dofile(("%s/tests/smoke/%s.lua"):format(helpers.root, name))(helpers)
end

domain("scope")
domain("config")
domain("sources")
domain("flow")
domain("context")
domain("ui")

print("tunnelvision smoke: OK")
