-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

local Testkit = require("tests.testkit")

local function NewA()
  local A = Testkit.NewAddonTable()
  Testkit.LoadModule("Core.lua", A)
  Testkit.LoadModule("Profile.lua", A)
  return A
end

Testkit.Test("MigrateItemsString parses 'Item = Recipient' lines", function()
  local A = NewA()
  local list = A:MigrateItemsString("Linen Cloth = Bankalt\nWool Cloth|Otheralt\nJust A Name\n\n  ")

  Testkit.AssertEqual(#list, 3, "expected 3 parsed entries")
  Testkit.AssertDeepEqual(list[1], { itemName = "Linen Cloth", recipient = "Bankalt" })
  Testkit.AssertDeepEqual(list[2], { itemName = "Wool Cloth", recipient = "Otheralt" })
  Testkit.AssertDeepEqual(list[3], { itemName = "Just A Name", recipient = "" })
end)

Testkit.Test("MigrateItemsString trims whitespace around name and recipient", function()
  local A = NewA()
  local list = A:MigrateItemsString("  Linen Cloth   =   Bankalt  ")
  Testkit.AssertDeepEqual(list[1], { itemName = "Linen Cloth", recipient = "Bankalt" })
end)

Testkit.Test("SanitizeItemEntries drops rows with no itemID and a blank name", function()
  local A = NewA()
  local cleaned = A:SanitizeItemEntries({
    { itemID = 123, itemName = "Frostwood", recipient = "" },
    { itemName = "", recipient = "Bankalt" }, -- no itemID, blank name: identifies nothing
    { itemName = "Ore", recipient = "Bankalt" },
    "not even a table",
  })

  Testkit.AssertEqual(#cleaned, 2, "malformed/unidentifiable rows should be dropped")
  Testkit.AssertEqual(cleaned[1].itemID, 123)
  Testkit.AssertEqual(cleaned[2].itemName, "Ore")
end)

Testkit.Test("SanitizeProfile migrates a legacy string item list to the table format", function()
  local A = NewA()
  local profile = { items = "Linen Cloth = Bankalt" }
  A:SanitizeProfile(profile)

  Testkit.AssertEqual(type(profile.items), "table")
  Testkit.AssertDeepEqual(profile.items[1], { itemName = "Linen Cloth", recipient = "Bankalt" })
end)

Testkit.Test("SanitizeProfile fills in missing/invalid fields with defaults", function()
  local A = NewA()
  local profile = { goldThreshold = "not a number", SendBOE = "yes" }
  A:SanitizeProfile(profile)

  Testkit.AssertEqual(profile.goldThreshold, 50000)
  Testkit.AssertEqual(profile.SendBOE, false)
  Testkit.AssertEqual(profile.confirmGoldSends, false)
  Testkit.AssertDeepEqual(profile.items, {})
end)

Testkit.Test("InitializeSavedVariables gives per-character and global profiles independent item lists", function()
  local A = NewA()
  _G.AutoMailer = {}
  _G.AutoMailerGlobal = {}

  A:InitializeSavedVariables()
  tinsert(AutoMailer.items, { itemName = "Only In Per-Character", recipient = "" })

  Testkit.AssertEqual(#AutoMailerGlobal.items, 0,
      "mutating one profile's item list must not affect the other's")

  _G.AutoMailer, _G.AutoMailerGlobal = nil, nil
end)

Testkit.Test("GetAutoMailEntry: an itemID rule matches only that exact item", function()
  local A = NewA()
  A.db = { items = { { itemID = 2589, itemName = "Linen Cloth", recipient = "" } } }

  Testkit.AssertTrue(A:ItemInAutomailList("Linen Cloth Bandage", 2592) == false or
      A:GetAutoMailEntry("Linen Cloth Bandage", 2592) == nil,
      "an itemID rule for Linen Cloth must not match a different item")
  Testkit.AssertTrue(A:GetAutoMailEntry("Linen Cloth", 2589) ~= nil,
      "an itemID rule must match its own item by ID")
end)

Testkit.Test("GetAutoMailEntry: a name-only rule matches loosely, by substring", function()
  local A = NewA()
  A.db = { items = { { itemName = "Ore", recipient = "" } } }

  Testkit.AssertTrue(A:GetAutoMailEntry("Copper Ore", 2770) ~= nil,
      "a loose 'Ore' rule should match any item whose name contains it")
  Testkit.AssertTrue(A:GetAutoMailEntry("Linen Cloth", 2589) == nil,
      "a loose 'Ore' rule should not match unrelated items")
end)

Testkit.Test("GetAutoMailEntries returns the live table by reference", function()
  local A = NewA()
  A.db = { items = { { itemName = "Ore", recipient = "" } } }

  local entries = A:GetAutoMailEntries()
  tinsert(entries, { itemName = "Cloth", recipient = "" })

  Testkit.AssertEqual(#A.db.items, 2, "edits to the returned list must be visible on A.db.items")
end)

return true
