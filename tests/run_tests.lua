-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

--[[
  Runs every tests/test_*.lua file with plain Lua (no WoW client needed) and
  exits non-zero if anything failed, so this can also run in CI.

  Usage (from the repository root):
    lua tests/run_tests.lua
]]

require("tests.test_locale")
require("tests.test_profile")
require("tests.test_mailqueue")
require("tests.test_send")

local Testkit = require("tests.testkit")
local ok = Testkit.RunAll()

os.exit(ok and 0 or 1)
