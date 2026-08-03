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
  Saved variables, profile switching, and the per-item mail rules.

  Everything here is deliberately free of WoW UI dependencies so it can be
  exercised directly by tests/ - see tests/test_profile.lua.
]]

local _, A = ...

-- Fields in DefaultProfile are the "mailing profile": what gets duplicated
-- between the per-character AutoMailer table and the global AutoMailerGlobal
-- table, and swapped out wholesale by the "use global profile" option.
function A:DefaultProfile()
  return {
    items = {},
    recipient = "",
    boeRecipient = "",
    boeRarityLimit = 4,
    SendBOE = false,
    LimitBoeLevel = false,
    limitBoeRarity = false,
    SendReagents = false,
    sendExcessGold = false,
    goldThreshold = 50000,
    confirmGoldSends = false,
  }
end

-- Fields in DefaultMeta are addon-level preferences that always stay on the
-- per-character AutoMailer table, even when a global profile is active.
function A:DefaultMeta()
  return {
    loginMessage = true,
    debugLogging = false,
    useGlobalProfile = true,
    autoSendOnShiftOpen = false,
  }
end

-- Pre-4.9 profiles stored the mail rules as one newline-delimited string of
-- "Item Name = Recipient" lines. Parse that legacy format into the structured
-- list the options table now edits. Migrated rules carry no itemID, which is
-- deliberate: itemID-less rules keep the old loose name matching (see
-- A:GetAutoMailEntry), so an upgrade can't silently change what gets mailed.
function A:MigrateItemsString(itemsString)
  local list = {}
  for line in string.gmatch(itemsString .. "\n", "(.-)\n") do
    local trimmed = A:Trim(line)
    if trimmed ~= "" then
      local itemName, recipient = trimmed:match("^(.-)%s*[%|=]%s*(.+)$")
      if not itemName then
        itemName, recipient = trimmed, ""
      end
      tinsert(list, { itemName = A:Trim(itemName), recipient = A:Trim(recipient) })
    end
  end
  return list
end

-- Rebuilds the rule list from whatever is in saved variables, discarding
-- malformed rows and rows that identify no item at all (a rule with a blank
-- name and no itemID would otherwise sit in the list matching nothing).
function A:SanitizeItemEntries(list)
  local cleaned = {}
  for _, entry in ipairs(list) do
    if type(entry) == "table" then
      local itemID = type(entry.itemID) == "number" and entry.itemID or nil
      local itemName = type(entry.itemName) == "string" and A:Trim(entry.itemName) or ""
      local recipient = type(entry.recipient) == "string" and A:Trim(entry.recipient) or ""
      if itemID or itemName ~= "" then
        tinsert(cleaned, { itemID = itemID, itemName = itemName, recipient = recipient })
      end
    end
  end
  return cleaned
end

function A:SanitizeProfile(t)
  if type(t.items) == "string" then
    t.items = A:MigrateItemsString(t.items)
  elseif type(t.items) ~= "table" then
    t.items = {}
  else
    t.items = A:SanitizeItemEntries(t.items)
  end
  if type(t.recipient) ~= "string" then t.recipient = "" end
  if type(t.boeRecipient) ~= "string" then t.boeRecipient = "" end
  if type(t.boeRarityLimit) ~= "number" then t.boeRarityLimit = 4 end
  if type(t.SendBOE) ~= "boolean" then t.SendBOE = false end
  if type(t.LimitBoeLevel) ~= "boolean" then t.LimitBoeLevel = false end
  if type(t.limitBoeRarity) ~= "boolean" then t.limitBoeRarity = false end
  if type(t.SendReagents) ~= "boolean" then t.SendReagents = false end
  if type(t.sendExcessGold) ~= "boolean" then t.sendExcessGold = false end
  if type(t.goldThreshold) ~= "number" then t.goldThreshold = 50000 end
  if type(t.confirmGoldSends) ~= "boolean" then t.confirmGoldSends = false end
end

-- Points at whichever profile table (per-character AutoMailer or global
-- AutoMailerGlobal) is currently active. All mailing-profile reads/writes
-- should go through A.db; meta prefs (logging, login message, the toggle
-- itself) always read/write AutoMailer directly.
function A:RefreshActiveProfile()
  A.db = AutoMailer.useGlobalProfile and AutoMailerGlobal or AutoMailer
end

function A:InitializeSavedVariables()
  if type(AutoMailer) ~= "table" then
    AutoMailer = {}
  end
  if type(AutoMailerGlobal) ~= "table" then
    AutoMailerGlobal = {}
  end

  local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
      if target[key] == nil then target[key] = value end
    end
  end

  ApplyDefaults(AutoMailer, A:DefaultMeta())
  -- DefaultProfile is called once per table on purpose: it contains a table
  -- field (items), and handing both profiles the same defaults table would
  -- leave them sharing one rule list.
  ApplyDefaults(AutoMailer, A:DefaultProfile())
  ApplyDefaults(AutoMailerGlobal, A:DefaultProfile())

  if type(AutoMailer.loginMessage) ~= "boolean" then AutoMailer.loginMessage = true end
  if type(AutoMailer.debugLogging) ~= "boolean" then AutoMailer.debugLogging = false end
  if type(AutoMailer.useGlobalProfile) ~= "boolean" then AutoMailer.useGlobalProfile = false end
  if type(AutoMailer.autoSendOnShiftOpen) ~= "boolean" then AutoMailer.autoSendOnShiftOpen = false end

  A:SanitizeProfile(AutoMailer)
  A:SanitizeProfile(AutoMailerGlobal)

  A:RefreshActiveProfile()
end

-- The live rule list. Returned by reference so the options table can edit
-- rules in place; treat the result as read-only everywhere else.
function A:GetAutoMailEntries()
  if type(A.db.items) ~= "table" then
    A.db.items = {}
  end
  return A.db.items
end

-- The options table shows the two kinds of rule as two separate lists, so it
-- needs them split apart. Both returned arrays hold the same entry tables as
-- A.db.items, not copies: the options table edits rules in place, and an entry
-- moves between the lists by gaining or losing its itemID.
function A:SplitAutoMailEntries()
  local exact, loose = {}, {}
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    tinsert(entry.itemID and exact or loose, entry)
  end
  return exact, loose
end

-- Whether some other rule already matches on this name, so the options table
-- can reject a duplicate name rule. Comparison is case-insensitive because
-- A:GetAutoMailEntry matches that way too.
function A:FindAutoMailEntryByName(itemName, ignoreEntry)
  local wanted = itemName and A:Trim(itemName):lower() or ""
  if wanted == "" then return nil end
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    if entry ~= ignoreEntry and not entry.itemID
        and type(entry.itemName) == "string" and entry.itemName:lower() == wanted then
      return entry
    end
  end
  return nil
end

function A:FindAutoMailEntryByItemID(itemID, ignoreEntry)
  if not itemID then return nil end
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    if entry ~= ignoreEntry and entry.itemID == itemID then return entry end
  end
  return nil
end

--[[
  Applies typed text to a rule, and with it the one policy decision in the
  addon that changes what a rule matches: a name the client recognizes as an
  item makes the rule exact (and moves it to the Items table), anything else
  makes it a name rule.

  Lives here rather than in the options panel so it can be tested without a
  frame. `resolveItemID` is the seam: the panel passes a function wrapping
  C_Item.GetItemInfoInstant, tests pass a table lookup. It is called with the
  trimmed text and may return an itemID and that item's canonical name.

  Returns a status - "unchanged", "applied", or "duplicate" - plus, for
  "duplicate", the rule already holding that item or name, and for "applied",
  whether the rule changed kind and so moved between the two tables.

  Deliberately not called on load or on migration: promoting stored rules
  would silently narrow what a pre-4.9 setup mails.
]]
function A:ApplyRuleName(entry, text, resolveItemID)
  text = A:Trim(text)
  if text == (entry.itemName or "") then return "unchanged" end

  local itemID, canonicalName
  if text ~= "" and resolveItemID then
    itemID, canonicalName = resolveItemID(text)
  end

  local duplicate = itemID and A:FindAutoMailEntryByItemID(itemID, entry)
      or (not itemID) and A:FindAutoMailEntryByName(text, entry)
  if duplicate then
    return "duplicate", duplicate
  end

  local wasExact = entry.itemID ~= nil
  entry.itemID = itemID
  entry.itemName = (itemID and canonicalName ~= nil and canonicalName) or text
  return "applied", nil, wasExact ~= (itemID ~= nil)
end

-- Two kinds of rule live in the same list, distinguished by whether the rule
-- carries an itemID:
--   * itemID set (added by shift-clicking or dragging an item, or by typing a
--     name the client resolves to a real item) - matches that exact item and
--     nothing else, so a rule for Linen Cloth doesn't also sweep up Linen
--     Cloth Bandages.
--   * itemID nil (a name rule, or one migrated from the pre-4.9 text list) -
--     matches any item whose name contains the rule's text, so "Ore" still
--     catches every ore and existing setups behave as they did before.
--
-- Matching is deliberately one-directional: the rule's text has to appear in
-- the item's name, not the other way round. It used to test both directions,
-- which meant a rule matched any item whose name was a substring of the rule -
-- a rule for "Heavy Silken Thread" also mailed Silken Thread, and with no
-- minimum length, an item named "Thread" too. Breadth is what the containment
-- test above is for; the reverse only ever mailed things nobody asked for.
--
-- Item rules are checked in a separate first pass, so an exact rule always
-- beats a name rule that happens to also match. This used to be one pass in
-- storage order, which made precedence depend on the order rules were added:
-- a name rule for "Cloth" added before an exact rule for Linen Cloth won, and
-- deleting and re-adding either one silently flipped where Linen Cloth went.
-- Nothing in the options panel showed that ordering or let you change it -
-- the two kinds live in two separate tables - so the order was invisible as
-- well as arbitrary. Specific beats general is the rule the two-table UI
-- already implies.
function A:GetAutoMailEntry(itemName, itemID)
  local entries = A:GetAutoMailEntries()

  if itemID then
    for _, entry in ipairs(entries) do
      if entry.itemID == itemID then
        return entry
      end
    end
  end

  local itemLower = itemName and itemName:lower() or nil
  if not itemLower then return nil end

  for _, entry in ipairs(entries) do
    if not entry.itemID and entry.itemName and entry.itemName ~= "" then
      if string.find(itemLower, entry.itemName:lower(), 1, true) ~= nil then
        return entry
      end
    end
  end

  return nil
end

function A:ItemInAutomailList(itemName, itemID)
  return A:GetAutoMailEntry(itemName, itemID) ~= nil
end
