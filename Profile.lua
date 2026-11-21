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

-- Saved variables, profile switching, and the per-item mail rules. Free of WoW
-- UI dependencies so tests/test_profile.lua can exercise it directly.

local _, A = ...

-- The "mailing profile": duplicated between AutoMailer and AutoMailerGlobal
-- and swapped wholesale by the "use global profile" option.
function A:DefaultProfile()
  return {
    items = {},
    recipient = "",
    boeRecipient = "",
    boeRarityLimit = 4,
    sendBoe = false,
    limitBoeLevel = false,
    limitBoeRarity = false,
    sendReagents = false,
    sendExcessGold = false,
    goldThreshold = 50000,
    confirmGoldSends = false,
  }
end

-- Addon-level preferences; always on the per-character AutoMailer table.
function A:DefaultMeta()
  return {
    loginMessage = true,
    debugLogging = false,
    useGlobalProfile = true,
    autoSendOnShiftOpen = false,
  }
end

-- Parses the pre-4.9 "Item Name = Recipient" newline-delimited string. Migrated
-- rules deliberately carry no itemID, so they keep loose name matching and an
-- upgrade can't change what gets mailed.
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

-- Ordered schema migrations for AutoMailer / AutoMailerGlobal. New fields are
-- covered by ApplyDefaults; a step only exists for renames and format changes
-- that ApplyDefaults would drop or reset instead of carrying forward.
local CURRENT_SCHEMA_VERSION = 2

-- Step 1: the pre-4.9 string item list.
local function MigrateItemsFormat(t)
  if type(t.items) == "string" then
    t.items = A:MigrateItemsString(t.items)
  end
end

-- Step 2: PascalCase fields renamed to camelCase (#19).
local RENAMED_PROFILE_FIELDS = {
  SendBOE = "sendBoe",
  LimitBoeLevel = "limitBoeLevel",
  SendReagents = "sendReagents",
}
local function MigrateFieldNames(t)
  for oldKey, newKey in pairs(RENAMED_PROFILE_FIELDS) do
    if t[oldKey] ~= nil then
      if t[newKey] == nil then
        t[newKey] = t[oldKey]
      end
      t[oldKey] = nil
    end
  end
end

-- Indexed by the schemaVersion each step produces.
local SCHEMA_MIGRATIONS = { MigrateItemsFormat, MigrateFieldNames }

-- Runs every step a table hasn't seen yet (no schemaVersion = 0). Must run
-- before ApplyDefaults/RepairFieldTypes, which would wipe pre-migration values.
function A:MigrateProfile(t)
  local version = type(t.schemaVersion) == "number" and t.schemaVersion or 0
  for step = version + 1, CURRENT_SCHEMA_VERSION do
    local migrate = SCHEMA_MIGRATIONS[step]
    if migrate then migrate(t) end
  end
  t.schemaVersion = CURRENT_SCHEMA_VERSION
end

-- Rebuilds the rule list from saved variables, dropping malformed rows and rows
-- with neither a name nor an itemID.
function A:SanitizeItemEntries(list)
  local cleaned = {}
  for _, entry in ipairs(list) do
    if type(entry) == "table" then
      local itemID = type(entry.itemID) == "number" and entry.itemID or nil
      local itemName = type(entry.itemName) == "string" and A:Trim(entry.itemName) or ""
      local recipient = type(entry.recipient) == "string" and A:Trim(entry.recipient) or ""
      -- Retain (#78): clamped rather than dropping the rule on a bad value.
      local retain = type(entry.retain) == "number" and math.max(0, math.floor(entry.retain)) or 0
      if itemID or itemName ~= "" then
        tinsert(cleaned, { itemID = itemID, itemName = itemName, recipient = recipient, retain = retain })
      end
    end
  end
  return cleaned
end

-- Resets any field whose stored type doesn't match its default's type.
function A:RepairFieldTypes(t, defaults)
  for key, default in pairs(defaults) do
    if type(t[key]) ~= type(default) then
      t[key] = default
    end
  end
end

function A:SanitizeProfile(t)
  -- MigrateProfile has already converted the legacy string format.
  if type(t.items) == "table" then
    t.items = A:SanitizeItemEntries(t.items)
  else
    t.items = {}
  end
  A:RepairFieldTypes(t, A:DefaultProfile())
end

-- A.db is the active mailing profile; A.meta (always AutoMailer) holds the
-- addon-level preferences.
function A:RefreshActiveProfile()
  A.meta = AutoMailer
  A.db = AutoMailer.useGlobalProfile and AutoMailerGlobal or AutoMailer
end

function A:InitializeSavedVariables()
  if type(AutoMailer) ~= "table" then
    AutoMailer = {}
  end
  if type(AutoMailerGlobal) ~= "table" then
    AutoMailerGlobal = {}
  end

  A:MigrateProfile(AutoMailer)
  A:MigrateProfile(AutoMailerGlobal)

  local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
      if target[key] == nil then target[key] = value end
    end
  end

  ApplyDefaults(AutoMailer, A:DefaultMeta())
  -- One DefaultProfile() per table, so the profiles don't share an items list.
  ApplyDefaults(AutoMailer, A:DefaultProfile())
  ApplyDefaults(AutoMailerGlobal, A:DefaultProfile())

  A:RepairFieldTypes(AutoMailer, A:DefaultMeta())

  A:SanitizeProfile(AutoMailer)
  A:SanitizeProfile(AutoMailerGlobal)
  A:SanitizeKnownCharacters(AutoMailerGlobal)

  A:RefreshActiveProfile()
end

-- The live rule list, by reference so the options table can edit rules in
-- place; treat it as read-only everywhere else.
function A:GetAutoMailEntries()
  return A.db.items
end

-- Splits rules into exact (itemID) and name rules. The arrays hold the same
-- entry tables as A.db.items, not copies.
function A:SplitAutoMailEntries()
  local exact, loose = {}, {}
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    tinsert(entry.itemID and exact or loose, entry)
  end
  return exact, loose
end

-- Whether any rule carries its own recipient, so a run can produce mail even
-- with no default Recipient set.
function A:HasRuleRecipient()
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    if entry.recipient ~= "" then
      return true
    end
  end
  return false
end

-- Whether another name rule already uses this name (case-insensitive, like
-- A:GetAutoMailEntry).
function A:FindAutoMailEntryByName(itemName, ignoreEntry)
  local wanted = itemName and A:Trim(itemName):lower() or ""
  if wanted == "" then return nil end
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    if entry ~= ignoreEntry and not entry.itemID and entry.itemName:lower() == wanted then
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
  Applies typed text to a rule: a name the client resolves to an item makes
  the rule exact (Items table), anything else makes it a name rule.
  resolveItemID(text) may return an itemID and the item's canonical name.

  Returns "unchanged", "applied" (plus whether the rule changed kind), or
  "duplicate" (plus the rule already holding that item or name).

  Not called on load or migration: promoting stored rules would silently
  narrow what a pre-4.9 setup mails.
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

-- Two kinds of rule share one list:
--   * itemID set: matches that exact item only.
--   * itemID nil (name rule, or migrated pre-4.9): matches any item whose name
--     contains the rule's text. One-directional on purpose, so "Heavy Silken
--     Thread" does not also match Silken Thread.
-- Item rules are checked in a first pass, so an exact rule always beats a name
-- rule regardless of storage order.
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

--[[
  Account-wide roster of characters that have logged in with AutoMailer, used
  to softly flag unfamiliar recipients (#26). Stored on AutoMailerGlobal
  regardless of useGlobalProfile, since it describes the account. There is no
  addon API for the account's character list (#76), so it fills one login at
  a time.
]]
function A:SanitizeKnownCharacters(t)
  local cleaned = {}
  if type(t.knownCharacters) == "table" then
    for _, entry in ipairs(t.knownCharacters) do
      if type(entry) == "string" then tinsert(cleaned, entry) end
    end
  end
  t.knownCharacters = cleaned
end

function A:RecordKnownCharacter(name, realm)
  name = name and A:Trim(name) or ""
  realm = realm and A:Trim(realm):gsub(" ", "") or ""
  if name == "" or realm == "" then return end

  local key = (name .. "-" .. realm):lower()
  for _, entry in ipairs(AutoMailerGlobal.knownCharacters) do
    if entry:lower() == key then return end
  end
  tinsert(AutoMailerGlobal.knownCharacters, name .. "-" .. realm)
end

-- Whether recipient matches a known character. A soft typo signal only; never
-- block a send on it. A bare name matches any realm on the roster (as mail
-- resolves it); a "-Realm" recipient must match both. A roster under two
-- entries hasn't seen enough logins to say, so everything counts as known.
function A:IsKnownCharacter(recipient)
  recipient = recipient and A:Trim(recipient) or ""
  if recipient == "" then return true end

  local roster = AutoMailerGlobal.knownCharacters
  if #roster < 2 then return true end

  local recName, recRealm = recipient:match("^(.-)%-(.+)$")
  recName = (recName or recipient):lower()
  recRealm = recRealm and recRealm:lower()

  for _, entry in ipairs(roster) do
    local name, realm = entry:match("^(.-)%-(.+)$")
    if name and name:lower() == recName then
      if not recRealm or (realm and realm:lower() == recRealm) then
        return true
      end
    end
  end

  return false
end
