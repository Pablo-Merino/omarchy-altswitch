-- Windows-style ALT+TAB for Hyprland: cycle windows on the current workspace
-- by default, most recently used first. Hold ALT, tap TAB to move down the list, release
-- ALT to jump to the highlighted window. ALT+SHIFT+TAB moves back up, ESCAPE
-- cancels.
--
-- Load it from ~/.config/hypr/bindings.lua:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.makiwinster72.altswitch/altswitch.lua")
--
-- This half owns all the state and all the keys. The list is drawn by the
-- companion shell plugin, which renders what it is told and nothing else.
--
-- Two details that make it behave like Windows rather than like `cyclenext`:
--   * The list is snapshotted when the switch starts and then frozen, so the
--     order cannot shuffle underneath you while you are tabbing through it.
--   * Selection is virtual. Focus moves once, on commit. Focusing on every tap
--     would drag you across workspaces on the way past.

local altswitch = { windows = {}, candidates = {}, index = 1, active = false, workspace_name = "", effective_scope = "current" }

-- Set `_G.altswitch_scope = "all"` before loading this file to include windows
-- from every normal workspace. The fork defaults to the focused workspace.
local altswitch_scope = tostring(rawget(_G, "altswitch_scope") or "current")
if altswitch_scope ~= "current" and altswitch_scope ~= "all" then
  altswitch_scope = "current"
end

-- Single-quote a string for the shell. Omarchy's config helpers provide this,
-- but this file also has to work without them.
local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function altswitch_send(method, argument)
  local command = "omarchy-shell -q altswitch " .. method
  if argument then
    command = command .. " " .. shell_quote(argument)
  end
  hl.exec_cmd(command)
end

-- Minimal JSON string escaping. Window titles are arbitrary text and routinely
-- contain quotes and backslashes.
local function altswitch_json_string(value)
  local escaped = tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("[%c]", function(control) return string.format("\\u%04x", control:byte()) end)
  return '"' .. escaped .. '"'
end

local function altswitch_candidates(scope)
  local candidates = {}
  for _, window in ipairs(altswitch.windows) do
    local workspace = window.workspace
    if scope == "all" or not workspace
      or workspace.name == altswitch.workspace_name then
      candidates[#candidates + 1] = window
    end
  end
  return candidates
end

local function display_index(selected)
  if not selected then return 0 end
  local address = tostring(selected.address)
  for index, window in ipairs(altswitch.windows) do
    if tostring(window.address) == address then return index - 1 end
  end
  return 0
end

local function altswitch_payload()
  local rows = {}
  for _, window in ipairs(altswitch.windows) do
    local workspace_name = window.workspace and window.workspace.name or ""
    local in_scope = altswitch.effective_scope == "all" or workspace_name == altswitch.workspace_name
    rows[#rows + 1] = string.format(
      '{"title":%s,"appClass":%s,"workspace":%s,"inScope":%s}',
      altswitch_json_string(window.title),
      altswitch_json_string(window.class),
      altswitch_json_string(workspace_name),
      tostring(in_scope)
    )
  end

  return string.format(
    '{"windows":[%s],"index":%d,"scope":%s}',
    table.concat(rows, ","),
    display_index(altswitch.candidates[altswitch.index]),
    altswitch_json_string(altswitch.effective_scope)
  )
end

local function altswitch_teardown()
  altswitch.active = false
  altswitch.windows = {}
  altswitch.candidates = {}
  altswitch.workspace_name = ""
  altswitch.effective_scope = altswitch_scope
  altswitch_send("hide")
end

local function altswitch_commit()
  if not altswitch.active then
    return -- nothing in flight; the Alt release fires on every switch-less tap
  end

  local target = altswitch.candidates[altswitch.index]
  local address = target and target.address

  altswitch_teardown()

  if address then
    local focus = string.format('hl.dsp.focus({ window = "address:%s" })', address)
    hl.exec_cmd("hyprctl dispatch " .. shell_quote(focus))
  end
end

local function altswitch_snapshot()
  local windows = {}
  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    if window.mapped and workspace and not workspace.special then
      windows[#windows + 1] = window
    end
  end

  table.sort(windows, function(a, b) return a.focus_history_id < b.focus_history_id end)
  return windows
end

-- Scope changes rebuild the selectable subset while all normal windows remain
-- visible. The highlighted window is preserved when it is still selectable.
_G.__altswitch_set_scope = function(scope)
  local wanted = tostring(scope or "")
  if wanted ~= "current" and wanted ~= "all" then return altswitch_scope end
  if wanted == altswitch_scope then return altswitch_scope end

  local selected = altswitch.candidates[altswitch.index]
  local selected_address = selected and tostring(selected.address)
  altswitch_scope = wanted

  if altswitch.active then
    altswitch.effective_scope = wanted
    altswitch.candidates = altswitch_candidates(wanted)
    if wanted == "current" and #altswitch.candidates < 2 then
      altswitch.effective_scope = "all"
      altswitch.candidates = altswitch_candidates("all")
    end
    if #altswitch.candidates < 2 then
      altswitch_teardown()
      return altswitch_scope
    end

    altswitch.index = 1
    if selected_address then
      for index, window in ipairs(altswitch.candidates) do
        if tostring(window.address) == selected_address then
          altswitch.index = index
          break
        end
      end
    end
    altswitch_send("show", altswitch_payload())
  end

  return altswitch_scope
end

local function altswitch_step(delta)
  if altswitch.active then
    altswitch.index = (altswitch.index - 1 + delta) % #altswitch.candidates + 1
    altswitch_send("select", tostring(display_index(altswitch.candidates[altswitch.index])))
    return
  end

  local active_workspace = hl.get_active_workspace()
  altswitch.workspace_name = active_workspace and active_workspace.name or ""
  altswitch.windows = altswitch_snapshot()
  local current_candidates = altswitch_candidates("current")
  altswitch.effective_scope = altswitch_scope
  if altswitch_scope == "current" and #current_candidates < 2 then
    -- A workspace with fewer than two windows cannot switch locally; fall back
    -- to the global list without changing the user's persisted preference.
    altswitch.effective_scope = "all"
  end
  altswitch.candidates = altswitch_candidates(altswitch.effective_scope)
  if #altswitch.candidates < 2 then return end

  -- Entry 1 is the focused window, so one tap lands on entry 2. Reverse wraps
  -- to the oldest selectable window. Out-of-scope rows remain visible but dim.
  altswitch.index = delta % #altswitch.candidates + 1
  altswitch.active = true
  altswitch_send("show", altswitch_payload())
end

-- Self-heal hook for the panel. If the ALT release is ever missed, the panel
-- gives up on its own after a few seconds and calls this, so the two halves
-- cannot disagree about whether a switch is still in progress.
_G.__altswitch_cancel = altswitch_teardown

-- Omarchy binds ALT+TAB four times by default (cyclenext and bring_to_top, in
-- both directions), so both chords are cleared before rebinding.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.bind("ALT + TAB", function() altswitch_step(1) end, { description = "Switch window" })
hl.bind("ALT + SHIFT + TAB", function() altswitch_step(-1) end, { description = "Switch window (reverse)" })
hl.bind("ALT + ESCAPE", altswitch_teardown, { non_consuming = true, description = "Cancel window switch" })

-- Committing on ALT release cannot be a keybind. A release bind on a modifier
-- only fires when that modifier is tapped on its own; pressing TAB in between
-- cancels it, which is exactly what every switch does. So the raw key stream is
-- read instead, where the release always shows up.
--
-- 64 is Alt_L and 108 is Alt_R. This runs for every keystroke on the system, so
-- it stays down to two integer compares and a boolean unless a switch is up.
local ALT_KEYCODES = { [64] = true, [108] = true }

hl.on("input.keyboard.key", function(keycode, _, state)
  if state == 0 and altswitch.active and ALT_KEYCODES[keycode] then
    altswitch_commit()
  end
end)
