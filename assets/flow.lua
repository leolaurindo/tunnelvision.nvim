-- Each assignment carries the value forward to the next variable.

local alpha = 1
local beta = alpha + 1
local gamma = beta * 2
local delta = gamma + 1
print(delta)

-- Two dependent branches join again.
local left = beta + gamma
local right = delta + 1
local combined = left + right
print(combined)

-- Unrelated work stays out of the focused path.
local greeting = "hello"
local retries = 3
print(greeting, retries)

-- Nested functions keep their own flow scope.
local callback = function()
  local nested = alpha + 100
  print(nested)
end
