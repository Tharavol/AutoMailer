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
  The translation seam. Every user-facing string in the addon goes through
  A.L; nothing else in the codebase should hold a displayed string literal.

  The key IS the English text, so there is no enUS table to keep in sync and
  an untranslated client shows exactly what a reader of the source sees. A
  missing key returns itself rather than nil, which means a typo'd or
  not-yet-translated string degrades to English instead of erroring inside a
  concatenation at the worst possible moment (mid send run).

  Strings that interpolate use string.format rather than concatenation, so a
  translator can reorder the substitutions - word order is exactly what
  differs between languages, and a concatenated sentence can't express that.

  Debug output (A:Log) is deliberately NOT routed through here. It exists to
  be pasted into a bug report, so it should read the same whatever client
  produced it.

  Adding a translation: call A:RegisterLocale from a new file listed in the
  TOC after this one, e.g.

    A:RegisterLocale("deDE", { ["No recipient configured."] = "..." })

  Only the table matching the running client's locale is applied, so every
  locale file can be shipped unconditionally.
]]

local _, A = ...

local L = setmetatable({}, {
  __index = function(_, key) return key end,
})

A.L = L

-- Returns whether the translations were applied, which is what makes this
-- testable without a client: the locale comparison is the whole behavior.
function A:RegisterLocale(locale, translations)
  if type(translations) ~= "table" then return false end
  if locale ~= (GetLocale and GetLocale()) then return false end

  for key, value in pairs(translations) do
    -- Skip blanks so a half-finished translation file falls back to English
    -- per string rather than displaying empty labels.
    if type(key) == "string" and type(value) == "string" and value ~= "" then
      rawset(L, key, value)
    end
  end

  return true
end
