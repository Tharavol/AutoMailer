-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

local Testkit = require("tests.testkit")

-- A module missing from the TOC simply never loads in-game, and the rest of
-- the suite would not notice: it loads modules by explicit path, not by
-- reading AutoMailer.toc. This checks both directions instead.
Testkit.Test("AutoMailer.toc lists every root-level .lua file and nothing else", function()
  local listed = {}
  for _, file in ipairs(Testkit.ParseTocLuaFiles("AutoMailer.toc")) do
    listed[file] = true
  end

  local onDisk = {}
  for _, file in ipairs(Testkit.ListLuaFiles(".")) do
    onDisk[file] = true
    Testkit.AssertTrue(listed[file], file .. " exists on disk but is not listed in AutoMailer.toc")
  end

  for file in pairs(listed) do
    Testkit.AssertTrue(onDisk[file], "AutoMailer.toc lists " .. file .. ", which does not exist")
  end
end)

return true
