local source = arg[1] or "altswitch.lua"
local bindings = {}
local commands = {}
local input_handler

hl = {
  bind = function(chord, callback)
    bindings[chord] = callback
  end,
  unbind = function() end,
  on = function(event, callback)
    if event == "input.keyboard.key" then input_handler = callback end
  end,
  get_windows = function()
    return {
      { address = "current", title = "Current", class = "one", mapped = true,
        focus_history_id = 0, workspace = { name = "1", special = false } },
      { address = "previous", title = "Previous", class = "two", mapped = true,
        focus_history_id = 1, workspace = { name = "1", special = false } },
      { address = "oldest", title = "Oldest", class = "three", mapped = true,
        focus_history_id = 2, workspace = { name = "2", special = false } },
    }
  end,
  exec_cmd = function(command)
    commands[#commands + 1] = command
  end,
}

dofile(source)

local function assert_contains(value, expected)
  assert(value and value:find(expected, 1, true),
    string.format("expected %q to contain %q", tostring(value), expected))
end

assert(type(bindings["ALT + DOWN"]) == "function", "ALT+DOWN binding is missing")
assert(type(bindings["ALT + UP"]) == "function", "ALT+UP binding is missing")
assert(type(input_handler) == "function", "ALT release handler is missing")

bindings["ALT + DOWN"]()
assert_contains(commands[#commands], "altswitch show")
assert_contains(commands[#commands], '"index":1')

bindings["ALT + DOWN"]()
assert_contains(commands[#commands], "altswitch select '2'")

bindings["ALT + UP"]()
assert_contains(commands[#commands], "altswitch select '1'")

input_handler(64, nil, 0)
assert_contains(commands[#commands - 1], "altswitch hide")
assert_contains(commands[#commands], "address:previous")

bindings["ALT + UP"]()
assert_contains(commands[#commands], "altswitch show")
assert_contains(commands[#commands], '"index":2')

input_handler(64, nil, 0)
assert_contains(commands[#commands], "address:oldest")

print("ok - ALT+UP and ALT+DOWN navigate and commit the expected windows")
