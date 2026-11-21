-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- See ATTRIBUTION.md for the full contributor list.
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of version 3 of the GNU General Public License as published
-- by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
-- without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
-- PARTICULAR PURPOSE. See the LICENSE file, or
-- <https://www.gnu.org/licenses/gpl-3.0.html>, for the full license text.
--
-- SPDX-License-Identifier: GPL-3.0-only

--[[
  Every user-facing string goes through A.L. The key is the English text, and
  a missing key returns itself, so untranslated strings fall back to English.
  Interpolated strings use string.format so translators can reorder them.
  Debug output (A:Log) is deliberately untranslated, for bug reports.

  Adding a translation: call A:RegisterLocale from a file listed in the TOC
  after this one; only the running client's locale is applied.

    A:RegisterLocale("deDE", { ["No recipient configured."] = "..." })
]]

local _, A = ...

local L = setmetatable({}, {
  __index = function(_, key) return key end,
})

A.L = L

-- Returns whether the translations were applied.
function A:RegisterLocale(locale, translations)
  if type(translations) ~= "table" then return false end
  if locale ~= GetLocale() then return false end

  for key, value in pairs(translations) do
    -- Blank values fall back to English rather than showing empty labels.
    if type(key) == "string" and type(value) == "string" and value ~= "" then
      rawset(L, key, value)
    end
  end

  return true
end
