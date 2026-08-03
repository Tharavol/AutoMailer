-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

local Testkit = require("tests.testkit")

-- GetLocale is the only client API Locale.lua touches, so it's the only thing
-- these tests have to control.
local function NewLocaleAddon(locale)
  local A = Testkit.NewAddonTable()
  _G.GetLocale = function() return locale end
  Testkit.LoadModule("Locale.lua", A)
  return A
end

Testkit.Test("L returns the key itself when there is no translation", function()
  local A = NewLocaleAddon("enUS")
  Testkit.AssertEqual(A.L["No recipient configured."], "No recipient configured.")
end)

-- The whole point of keying on the English text: a string that nobody has
-- translated yet still displays, rather than returning nil and blowing up
-- inside a concatenation mid send run.
Testkit.Test("L falls back to English for a key a registered locale omits", function()
  local A = NewLocaleAddon("deDE")
  A:RegisterLocale("deDE", { ["Send cancelled."] = "Senden abgebrochen." })

  Testkit.AssertEqual(A.L["Send cancelled."], "Senden abgebrochen.")
  Testkit.AssertEqual(A.L["No recipient configured."], "No recipient configured.",
      "an untranslated key must still return readable English")
end)

Testkit.Test("RegisterLocale applies only the running client's locale", function()
  local A = NewLocaleAddon("enUS")

  Testkit.AssertEqual(A:RegisterLocale("deDE", { ["Send cancelled."] = "Senden abgebrochen." }), false)
  Testkit.AssertEqual(A.L["Send cancelled."], "Send cancelled.",
      "a non-matching locale table must not leak into an English client")

  Testkit.AssertEqual(A:RegisterLocale("enUS", { ["Send cancelled."] = "Cancelled."  }), true)
  Testkit.AssertEqual(A.L["Send cancelled."], "Cancelled.")
end)

-- A locale file with a stubbed-out entry should fall back per string rather
-- than displaying an empty label.
Testkit.Test("RegisterLocale ignores blank and non-string translations", function()
  local A = NewLocaleAddon("frFR")
  A:RegisterLocale("frFR", {
    ["Send cancelled."] = "",
    ["Proceed?"] = 42,
    ["Gold"] = "Or",
  })

  Testkit.AssertEqual(A.L["Send cancelled."], "Send cancelled.")
  Testkit.AssertEqual(A.L["Proceed?"], "Proceed?")
  Testkit.AssertEqual(A.L["Gold"], "Or")
end)

Testkit.Test("RegisterLocale tolerates a missing translation table", function()
  local A = NewLocaleAddon("enUS")
  Testkit.AssertEqual(A:RegisterLocale("enUS", nil), false)
end)

-- Guards the load-order contract the TOC comment states: modules capture A.L
-- at file scope, so Locale.lua has to publish it as a side effect of loading.
Testkit.Test("Locale.lua publishes A.L at load time", function()
  local A = NewLocaleAddon("enUS")
  Testkit.AssertTrue(type(A.L) == "table", "A.L must exist before any other module loads")
end)

return true
