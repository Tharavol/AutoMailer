-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

--[[
  Minimal test support for running AutoMailer's non-UI modules (Core, Profile,
  MailQueue) under plain Lua instead of in-game. Two jobs:

    1. Provide the handful of WoW-Lua globals those modules reference at load
       time or call unconditionally (tinsert/tremove/strjoin/strsplit are
       WoW-Lua aliases for table.* functions, not part of stock Lua).
    2. Load an addon file the way the game does: WoW calls each TOC-listed
       file as a function with (addonName, addonTable) as its varargs, which
       is what "local _, A = ..." at the top of every module destructures.

  Everything actually used by the WoW API (GetMoney, UnitLevel, C_Container,
  C_Item, ...) is deliberately NOT stubbed here. Tests inject those as plain
  Lua functions/tables assigned onto the addon table itself (A.GetMoney = ...,
  overriding A:GetContainerNumSlots, etc.) - fakes for the specific seam under
  test, not a mock game client. See test_mailqueue.lua for the pattern.
]]

-- WoW's Lua 5.1 runtime has a global unpack(); Lua 5.2+ (what runs these
-- tests) only kept it as table.unpack. Falling back keeps this file correct
-- under either.
local unpack = table.unpack or unpack

_G.tinsert = table.insert
_G.tremove = table.remove
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end end

function _G.strsplit(delimiter, text, pieces)
  local parts = {}
  local pattern = "([^" .. delimiter .. "]+)"
  for part in text:gmatch(pattern) do
    parts[#parts + 1] = part
    if pieces and #parts == pieces - 1 then
      local rest = text:match("^" .. ("[^" .. delimiter .. "]*" .. delimiter):rep(#parts) .. "(.*)$")
      if rest then parts[#parts + 1] = rest end
      break
    end
  end
  return unpack(parts)
end

function _G.strjoin(delimiter, ...)
  return table.concat({ ... }, delimiter)
end

function _G.tostringall(...)
  local args = { ... }
  for i = 1, select("#", ...) do
    args[i] = tostring(args[i])
  end
  return unpack(args, 1, select("#", ...))
end

local Testkit = {}

-- Loads a module file the way the TOC/game does: calls it with the given
-- addon table as its second vararg. Reuses the same table across LoadModule
-- calls so Core/Profile/MailQueue all attach methods to one shared A, mirroring
-- how they share A.db etc. in-game.
function Testkit.LoadModule(path, addonTable)
  local chunk, err = loadfile(path)
  if not chunk then
    error("failed to load " .. path .. ": " .. tostring(err))
  end
  chunk("AutoMailer", addonTable)
  return addonTable
end

function Testkit.NewAddonTable()
  return {}
end

--[[ TOC manifest checking - see tests/test_toc.lua ]]

-- The .lua entries a TOC file lists, in load order. Matches a whole trimmed
-- line that is exactly a filename (letters/digits/underscore/dot) ending in
-- .lua, so comments, the interface/title keywords and non-Lua files (the
-- XML template) are ignored.
function Testkit.ParseTocLuaFiles(path)
  local files = {}
  for line in io.lines(path) do
    local file = line:match("^%s*([%w_.]+%.lua)%s*$")
    if file then tinsert(files, file) end
  end
  return files
end

-- The *.lua files actually sitting in a directory, via `ls` rather than a
-- filesystem library the test environment may not have installed.
function Testkit.ListLuaFiles(dir)
  local files = {}
  local pipe = io.popen("ls " .. dir .. "/*.lua")
  if pipe then
    for line in pipe:lines() do
      tinsert(files, line:match("([^/\\]+)$"))
    end
    pipe:close()
  end
  return files
end

--[[ tiny assertion-based test runner ]]

local registered = {}

function Testkit.Test(name, fn)
  tinsert(registered, { name = name, fn = fn })
end

local function formatValue(value)
  if type(value) == "table" then
    local parts = {}
    for k, v in pairs(value) do
      tinsert(parts, tostring(k) .. "=" .. formatValue(v))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return tostring(value)
end

function Testkit.AssertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\n  expected: %s\n  actual:   %s",
        message or "values differ", formatValue(expected), formatValue(actual)), 2)
  end
end

function Testkit.AssertTrue(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function Testkit.AssertDeepEqual(actual, expected, message)
  local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
      if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end
  if not deepEqual(actual, expected) then
    error(string.format("%s\n  expected: %s\n  actual:   %s",
        message or "tables differ", formatValue(expected), formatValue(actual)), 2)
  end
end

function Testkit.RunAll()
  local passed, failed = 0, {}
  for _, test in ipairs(registered) do
    local ok, err = pcall(test.fn)
    if ok then
      passed = passed + 1
    else
      tinsert(failed, { name = test.name, err = err })
    end
  end

  print(string.format("%d passed, %d failed", passed, #failed))
  for _, failure in ipairs(failed) do
    print("\nFAIL: " .. failure.name)
    print("  " .. tostring(failure.err))
  end

  registered = {}
  return #failed == 0
end

return Testkit
