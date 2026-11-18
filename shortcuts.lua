-- My Voxtype: Hyprland shortcuts for the Voxtype dictation backend.
--
-- Omarchy's default/hypr/dictation-backend.lua loads
-- ~/.config/<backend>/shortcuts.lua for the active dictation backend, so
-- ~/.config/voxtype/shortcuts.lua is a link to this file. Omarchy owns the
-- dictation toggle keys; this adds:
--
-- * Escape cancels a recording or transcription. The key is not consumed,
--   so apps still get Escape; outside a recording it does nothing.
--   Off when ~/.config/voxtype/escape-off exists.
-- * An optional hold-to-talk key: press starts, release stops. The chord is
--   the first line of ~/.config/voxtype/hold-key (e.g. "SUPER + F10");
--   no file or an empty line means no hold key.
--
-- The panel writes those files and runs `hyprctl reload`.
if package.loaded["voxtype.shortcuts"] then return end
package.loaded["voxtype.shortcuts"] = true

local home = os.getenv("HOME") or ""
local config = (os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")) .. "/voxtype"
local runtime = os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000"
local state_path = runtime .. "/voxtype/state"

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function first_line(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local line = f:read("*l") or ""
  f:close()
  return line
end

if not exists(config .. "/escape-off") then
  hl.bind("Escape", function()
    local state = first_line(state_path)
    if state:match("^recording") or state:match("^transcribing") then
      hl.exec_cmd("voxtype record cancel")
    end
  end, { description = "Voxtype: cancel recording", non_consuming = true, ignore_mods = true })
end

-- Only letters, digits, underscores, spaces and "+" are accepted, so a bad
-- file can't inject anything into the bind.
local hold = first_line(config .. "/hold-key"):gsub("^%s+", ""):gsub("%s+$", "")
if hold ~= "" and hold:match("^[%w_ +]+$") then
  local ok, err = pcall(function()
    hl.bind(hold, function() hl.exec_cmd("omarchy-dictation start") end,
      { description = "Voxtype: hold to talk (press)" })
    hl.bind(hold, function() hl.exec_cmd("omarchy-dictation stop") end,
      { description = "Voxtype: hold to talk (release)", release = true })
  end)
  if not ok then print("My Voxtype: could not bind hold key " .. hold .. ": " .. tostring(err)) end
end
