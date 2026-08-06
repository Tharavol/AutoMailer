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

-- The type-repair pass restated each meta default by hand and had drifted from
-- DefaultMeta: a wrong-typed useGlobalProfile repaired to false while a fresh
-- install got true, so a corrupted value quietly moved the character onto the
-- per-character profile instead of the global one it had been using.
Testkit.Test("InitializeSavedVariables repairs a wrong-typed meta pref to its stated default", function()
  local A = NewA()
  _G.AutoMailer = { useGlobalProfile = "yes", loginMessage = 0 }
  _G.AutoMailerGlobal = {}

  A:InitializeSavedVariables()

  local defaults = A:DefaultMeta()
  Testkit.AssertEqual(AutoMailer.useGlobalProfile, defaults.useGlobalProfile,
      "repair and fresh-install defaults have to agree")
  Testkit.AssertEqual(AutoMailer.loginMessage, defaults.loginMessage)

  _G.AutoMailer, _G.AutoMailerGlobal = nil, nil
end)

Testkit.Test("InitializeSavedVariables leaves a valid meta pref alone", function()
  local A = NewA()
  _G.AutoMailer = { useGlobalProfile = false, debugLogging = true }
  _G.AutoMailerGlobal = {}

  A:InitializeSavedVariables()

  Testkit.AssertEqual(AutoMailer.useGlobalProfile, false,
      "repairing must not override a deliberate setting")
  Testkit.AssertEqual(AutoMailer.debugLogging, true)

  _G.AutoMailer, _G.AutoMailerGlobal = nil, nil
end)

Testkit.Test("RefreshActiveProfile points A.meta at AutoMailer regardless of which profile is active", function()
  local A = NewA()
  _G.AutoMailer = { useGlobalProfile = true }
  _G.AutoMailerGlobal = {}

  A:InitializeSavedVariables()

  Testkit.AssertTrue(A.meta == AutoMailer, "A.meta must always be the per-character table")
  Testkit.AssertTrue(A.db == AutoMailerGlobal, "A.db follows useGlobalProfile as before")

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
  Testkit.AssertTrue(A:GetAutoMailEntry("Ore", 1) ~= nil,
      "a loose rule should match an item named exactly like it")
  Testkit.AssertTrue(A:GetAutoMailEntry("Linen Cloth", 2589) == nil,
      "a loose 'Ore' rule should not match unrelated items")
end)

-- Matching used to run in both directions, so a rule matched any item whose
-- name was a substring of the rule text: "Heavy Silken Thread" also mailed
-- Silken Thread, and with no length floor, an item named "Thread" too.
Testkit.Test("GetAutoMailEntry: a name rule does not match items whose names it contains", function()
  local A = NewA()
  A.db = { items = { { itemName = "Heavy Silken Thread", recipient = "" } } }

  Testkit.AssertTrue(A:GetAutoMailEntry("Heavy Silken Thread", 4291) ~= nil,
      "the rule must still match the item it names")
  for _, name in ipairs({ "Silken Thread", "Thread", "Silken", "Heavy", "Silk", "n" }) do
    Testkit.AssertTrue(A:GetAutoMailEntry(name, 1) == nil,
        "'" .. name .. "' is not what the rule asked for and must not match")
  end
end)

-- Precedence used to be storage order, so which rule won depended on the
-- order they happened to be added - and the options panel shows the two kinds
-- in two separate tables, with no ordering shown and no way to reorder them.
Testkit.Test("GetAutoMailEntry: an item rule beats a name rule that also matches", function()
  local A = NewA()
  A.db = { items = {
    { itemName = "Cloth", recipient = "NameRuleAlt" },
    { itemID = 2589, itemName = "Linen Cloth", recipient = "ItemRuleAlt" },
  } }

  local entry = A:GetAutoMailEntry("Linen Cloth", 2589)
  Testkit.AssertEqual(entry.recipient, "ItemRuleAlt",
      "the exact item rule must win even though the name rule is stored first")

  -- The name rule must still do its job for everything else.
  Testkit.AssertEqual(A:GetAutoMailEntry("Woolen Cloth", 2592).recipient, "NameRuleAlt")
end)

Testkit.Test("GetAutoMailEntry: precedence does not depend on the order rules were added", function()
  local itemRule = { itemID = 2589, itemName = "Linen Cloth", recipient = "ItemRuleAlt" }
  local nameRule = { itemName = "Cloth", recipient = "NameRuleAlt" }

  for _, order in ipairs({ { nameRule, itemRule }, { itemRule, nameRule } }) do
    local A = NewA()
    A.db = { items = order }
    Testkit.AssertEqual(A:GetAutoMailEntry("Linen Cloth", 2589).recipient, "ItemRuleAlt",
        "both storage orders must resolve to the same rule")
  end
end)

-- An itemID rule still must not match a different item just because an
-- earlier name rule would have; the first pass only looks at IDs.
Testkit.Test("GetAutoMailEntry: the item-rule pass does not match on name", function()
  local A = NewA()
  A.db = { items = { { itemID = 2589, itemName = "Linen Cloth", recipient = "ItemRuleAlt" } } }

  Testkit.AssertTrue(A:GetAutoMailEntry("Linen Cloth", 9999) == nil,
      "a different item sharing the rule's name must not match an itemID rule")
end)

-- An uncached item has no name at all; the itemID pass has to still work.
Testkit.Test("GetAutoMailEntry: an item rule matches with no item name available", function()
  local A = NewA()
  A.db = { items = {
    { itemName = "Cloth", recipient = "NameRuleAlt" },
    { itemID = 2589, itemName = "Linen Cloth", recipient = "ItemRuleAlt" },
  } }

  Testkit.AssertEqual(A:GetAutoMailEntry(nil, 2589).recipient, "ItemRuleAlt")
  Testkit.AssertTrue(A:GetAutoMailEntry(nil, 9999) == nil,
      "with no name there is nothing for a name rule to match against")
end)

--[[
  Answers "is this profile configured enough to run?" for a setup with no
  default Recipient. The send guard used to look only at the two recipient
  boxes, so a profile where every rule named its own recipient was refused
  before the queue was ever built.
]]
Testkit.Test("HasRuleRecipient finds a rule carrying its own recipient", function()
  local A = NewA()
  A.db = { items = {
    { itemID = 2589, itemName = "Linen Cloth", recipient = "" },
    { itemName = "Ore", recipient = "Bankalt" },
  } }

  Testkit.AssertEqual(A:HasRuleRecipient(), true)
end)

Testkit.Test("HasRuleRecipient is false when no rule names a recipient", function()
  local A = NewA()
  A.db = { items = {
    { itemID = 2589, itemName = "Linen Cloth", recipient = "" },
    { itemName = "Ore", recipient = "" },
  } }

  Testkit.AssertEqual(A:HasRuleRecipient(), false,
      "rules that all fall back to the default can't run without one")
end)

Testkit.Test("HasRuleRecipient is false for an empty rule list", function()
  local A = NewA()
  A.db = { items = {} }

  Testkit.AssertEqual(A:HasRuleRecipient(), false)
end)

Testkit.Test("SplitAutoMailEntries separates itemID rules from name rules", function()
  local A = NewA()
  local linen = { itemID = 2589, itemName = "Linen Cloth", recipient = "" }
  local ore = { itemName = "Ore", recipient = "Bankalt" }
  local frostwood = { itemID = 123, itemName = "Frostwood", recipient = "" }
  A.db = { items = { linen, ore, frostwood } }

  local exact, loose = A:SplitAutoMailEntries()

  Testkit.AssertEqual(#exact, 2, "both itemID rules belong in the Items table")
  Testkit.AssertEqual(#loose, 1, "the name rule belongs in the Name Matches table")
  -- The options table edits rules in place through these lists, so they have
  -- to hold the entries themselves rather than copies of them.
  Testkit.AssertTrue(exact[1] == linen and exact[2] == frostwood,
      "split must return the stored entry tables, in order")
  Testkit.AssertTrue(loose[1] == ore, "split must return the stored entry tables, in order")
end)

Testkit.Test("SplitAutoMailEntries handles all-exact and all-loose lists", function()
  local A = NewA()

  A.db = { items = { { itemID = 2589, itemName = "Linen Cloth", recipient = "" } } }
  local exact, loose = A:SplitAutoMailEntries()
  Testkit.AssertEqual(#exact, 1)
  Testkit.AssertEqual(#loose, 0)

  A.db = { items = { { itemName = "Ore", recipient = "" } } }
  exact, loose = A:SplitAutoMailEntries()
  Testkit.AssertEqual(#exact, 0)
  Testkit.AssertEqual(#loose, 1)
end)

Testkit.Test("FindAutoMailEntryByName matches name rules case-insensitively", function()
  local A = NewA()
  local ore = { itemName = "Ore", recipient = "" }
  A.db = { items = { ore, { itemID = 2589, itemName = "Linen Cloth", recipient = "" } } }

  Testkit.AssertTrue(A:FindAutoMailEntryByName("ore") == ore,
      "a name rule should be found regardless of case")
  Testkit.AssertTrue(A:FindAutoMailEntryByName("Ore", ore) == nil,
      "the entry being edited must not count as its own duplicate")
  Testkit.AssertTrue(A:FindAutoMailEntryByName("Linen Cloth") == nil,
      "an itemID rule is not a name rule, so it must not block one")
  Testkit.AssertTrue(A:FindAutoMailEntryByName("   ") == nil, "a blank name matches nothing")
end)

-- Promotion of a typed name to an itemID rule happens only when the user
-- edits a rule (OptionsPanel's CommitName). Loading or migrating must never
-- do it, or an upgrade would silently narrow what a pre-4.9 setup mails.
Testkit.Test("migration and sanitizing leave rules as loose name rules", function()
  local A = NewA()
  local profile = { items = "Linen Cloth = Bankalt" }
  A:SanitizeProfile(profile)

  Testkit.AssertEqual(profile.items[1].itemID, nil,
      "a migrated rule must stay loose even though its name is a real item")

  A.db = profile
  local exact, loose = A:SplitAutoMailEntries()
  Testkit.AssertEqual(#exact, 0)
  Testkit.AssertEqual(#loose, 1, "migrated rules land in the Name Matches table")
end)

--[[ ApplyRuleName - the promote/demote policy the options panel drives ]]

-- Stands in for C_Item.GetItemInfoInstant: resolves only the names given to
-- it, exactly as the real one resolves only what the client has cached.
local function Resolver(knownNames)
  return function(text)
    local known = knownNames[text]
    if not known then return nil end
    return known.itemID, known.canonicalName
  end
end

Testkit.Test("ApplyRuleName promotes a recognized name to an exact item rule", function()
  local A = NewA()
  local entry = { itemName = "linen cloth", recipient = "Bankalt" }
  A.db = { items = { entry } }

  local status, _, movedTable = A:ApplyRuleName(entry, "Linen Cloth",
      Resolver({ ["Linen Cloth"] = { itemID = 2589, canonicalName = "Linen Cloth" } }))

  Testkit.AssertEqual(status, "applied")
  Testkit.AssertEqual(entry.itemID, 2589)
  Testkit.AssertEqual(entry.itemName, "Linen Cloth", "the canonical name should win over what was typed")
  Testkit.AssertEqual(entry.recipient, "Bankalt", "the recipient must survive a rule changing kind")
  Testkit.AssertTrue(movedTable, "gaining an itemID moves the rule to the Items table")
end)

Testkit.Test("ApplyRuleName leaves an unrecognized name as a name rule", function()
  local A = NewA()
  local entry = { itemID = 2589, itemName = "Linen Cloth", recipient = "" }
  A.db = { items = { entry } }

  local status, _, movedTable = A:ApplyRuleName(entry, "  Ore  ", Resolver({}))

  Testkit.AssertEqual(status, "applied")
  Testkit.AssertEqual(entry.itemID, nil, "an unrecognized name demotes the rule to a name rule")
  Testkit.AssertEqual(entry.itemName, "Ore", "the typed text is trimmed before being stored")
  Testkit.AssertTrue(movedTable, "losing an itemID moves the rule to the Name Matches table")
end)

Testkit.Test("ApplyRuleName reports an unchanged name without touching the rule", function()
  local A = NewA()
  local entry = { itemName = "Ore", recipient = "" }
  A.db = { items = { entry } }

  local status = A:ApplyRuleName(entry, "  Ore  ", Resolver({
    ["Ore"] = { itemID = 999, canonicalName = "Ore" },
  }))

  Testkit.AssertEqual(status, "unchanged")
  Testkit.AssertEqual(entry.itemID, nil, "an unchanged name must not be re-resolved and promoted")
end)

Testkit.Test("ApplyRuleName rejects a name that duplicates another rule", function()
  local A = NewA()
  local existing = { itemID = 2589, itemName = "Linen Cloth", recipient = "" }
  local editing = { itemName = "Ore", recipient = "" }
  A.db = { items = { existing, editing } }
  local resolver = Resolver({ ["Linen Cloth"] = { itemID = 2589, canonicalName = "Linen Cloth" } })

  local status, duplicate = A:ApplyRuleName(editing, "Linen Cloth", resolver)
  Testkit.AssertEqual(status, "duplicate")
  Testkit.AssertTrue(duplicate == existing, "the conflicting rule should come back for the message")
  Testkit.AssertEqual(editing.itemName, "Ore", "a rejected edit must leave the rule alone")

  local otherName = { itemName = "Cloth", recipient = "" }
  tinsert(A.db.items, otherName)
  Testkit.AssertEqual(A:ApplyRuleName(editing, "Cloth", resolver), "duplicate",
      "name rules collide with each other too")
end)

Testkit.Test("ApplyRuleName treats a blank name as a name rule, not a lookup", function()
  local A = NewA()
  local entry = { itemID = 2589, itemName = "Linen Cloth", recipient = "" }
  A.db = { items = { entry } }

  local status = A:ApplyRuleName(entry, "   ", function()
    error("a blank name must never reach the resolver")
  end)

  Testkit.AssertEqual(status, "applied")
  Testkit.AssertEqual(entry.itemID, nil)
  Testkit.AssertEqual(entry.itemName, "")
end)

Testkit.Test("GetAutoMailEntries returns the live table by reference", function()
  local A = NewA()
  A.db = { items = { { itemName = "Ore", recipient = "" } } }

  local entries = A:GetAutoMailEntries()
  tinsert(entries, { itemName = "Cloth", recipient = "" })

  Testkit.AssertEqual(#A.db.items, 2, "edits to the returned list must be visible on A.db.items")
end)

return true
