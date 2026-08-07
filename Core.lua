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
  Shared utilities: chat output, and thin wrappers over the container/item
  APIs so the rest of the addon never touches C_Container/C_Item directly.
]]

local ADDON_NAME, A = ...

A.addonName = "|cff8d63ffAutoMailer|r "

function A:GetVersion()
  return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
end

-- ".. tostringall(...)" only keeps tostringall's FIRST return value, since
-- concatenation isn't a multi-result context - every argument after the
-- first was silently getting dropped. strjoin's last argument position is a
-- multi-result context, so all of them make it into the message.
function A:Print(...)
  DEFAULT_CHAT_FRAME:AddMessage(A.addonName .. "- " .. strjoin(" ", tostringall(...)))
end

-- Exposed separately from A:Log because some debug output is worth more than
-- it costs to produce: BuildMailQueue's run summary has to accumulate skip
-- reasons while it scans, which is wasted work when nobody will read it.
-- Callers that only format strings should just call A:Log and let it decide.
function A:IsDebugLogging()
  return (A.meta and A.meta.debugLogging) and true or false
end

function A:Log(...)
  if not A:IsDebugLogging() then return end
  DEFAULT_CHAT_FRAME:AddMessage("|cff888888" .. A.addonName .. "Debug|r " .. strjoin(" ", tostringall(...)))
end

function A:Trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

function A:GetContainerNumSlots(bag)
  return C_Container.GetContainerNumSlots(bag)
end

function A:GetContainerItemInfo(bag, slot)
  local info = C_Container.GetContainerItemInfo(bag, slot)
  if not info then return nil end
  return info.iconFileID, info.stackCount, info.isLocked, info.quality, info.isReadable,
      info.hasLoot, info.hyperlink, info.isFiltered, info.noValue, info.itemID, info.isBound
end

function A:GetItemInfo(itemLink)
  return C_Item.GetItemInfo(itemLink)
end

function A:GetItemIDFromLink(itemLink)
  if not itemLink then return nil end
  return (C_Item.GetItemInfoInstant(itemLink))
end

-- Asks the client to cache an item's data. A bag scan that finds an item
-- GetItemInfo can't answer for yet has to skip it (see BuildMailQueue); this
-- is what makes the next run able to classify it properly.
function A:RequestItemDataLoad(itemID)
  if itemID and C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
end

-- Picks up a bag item onto the cursor, and the cursor state around it - the
-- first leg of the real attach flow (pick up, then click the attachment
-- slot). Grouped with the container wrappers above rather than the mail-form
-- ones below since picking an item up isn't specific to mailing it.
function A:PickupContainerItem(bag, slot)
  C_Container.PickupContainerItem(bag, slot)
end

function A:CursorHasItem()
  return CursorHasItem()
end

function A:ClearCursor()
  ClearCursor()
end

--[[
  Money and player state, wrapped for the same reason the container and item
  APIs above are: nothing outside this file should reach for the game's
  globals directly.

  These three gate the excess-gold math specifically, which is the one part of
  a send run that can't be undone by mailing things back, and the part that has
  produced the most bugs (see the 4.7/4.8 postage notes and the 5.x shortfall).
  Going through here is what lets that math be driven by tests instead of only
  ever being exercised live.
]]
function A:GetMoney()
  return GetMoney()
end

-- Postage for whatever is currently on the send-mail form. Not a flat fee: it
-- scales with attachments, and only reports honestly once the form has a
-- recipient on it. See SendMailBatch for why it's queried where it is.
function A:GetSendMailPrice()
  return (GetSendMailPrice and GetSendMailPrice()) or 0
end

function A:GetPlayerLevel()
  return UnitLevel("PLAYER")
end

-- Whether this specific bag slot's item is bound to the character, which is
-- what makes it unmailable.
--
-- This used to be answered by building a hidden GameTooltip per bag slot,
-- calling SetBagItem on it, and string-matching ITEM_SOULBOUND against its
-- first four lines - fragile (the binding line isn't always in the first
-- four), slow (a tooltip rebuild for every occupied slot on every run), and
-- exactly the sort of tooltip scraping Blizzard keeps tightening. C_Item.IsBound
-- answers the same question directly off the item instance.
--
-- Warband-bound-until-equipped gear reports as bound but can still be mailed
-- to your own characters, which is the main thing people use this addon for,
-- so it's explicitly let through to match the old tooltip check's behavior.
function A:ItemIsSoulbound(bag, slot)
  local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
  if not location or not location:IsValid() then return false end
  if not C_Item.IsBound(location) then return false end
  if C_Item.IsBoundToAccountUntilEquip and C_Item.IsBoundToAccountUntilEquip(location) then
    return false
  end
  return true
end

function A:GetPlayerName()
  return UnitName("player")
end

-- The character's home realm, with no per-character resolution needed - used
-- alongside A:GetPlayerName to build the "Name-Realm" form recorded into the
-- known-character roster (see A:RecordKnownCharacter).
function A:GetRealmName()
  return GetRealmName()
end

-- Recipients are matched against the currently logged-in character's name so
-- rules that happen to target yourself (e.g. a global profile rule meant for
-- a different alt) don't queue a pointless self-mail. Strips an optional
-- "-Realm" suffix off the recipient before comparing, since A:GetPlayerName
-- never includes one.
function A:IsCurrentCharacter(recipient)
  if not recipient or recipient == "" then return false end
  local playerName = A:GetPlayerName()
  if not playerName then return false end
  local recName = recipient:match("^(.-)%-.+$") or recipient
  return recName:lower() == playerName:lower()
end

--[[
  The send-mail form, wrapped for the same reason as everything above:
  Send.lua's batch-sequencing state machine is the riskiest code in the
  addon, and it owns the irreversible gold math, so it needs to be drivable
  by tests rather than only ever exercised live. See issue #15.
]]
function A:ClearSendForm()
  ClearSendMail()
end

function A:SetSendRecipient(name)
  SendMailNameEditBox:SetText(name)
  SendMailNameEditBox:SetCursorPosition(0)
end

function A:SetSendSubject(text)
  SendMailSubjectEditBox:SetText(text)
  SendMailSubjectEditBox:SetCursorPosition(0)
end

-- Money isn't a SendMail() argument. MoneyInputFrame_SetCopper only updates
-- the SendMailMoney editbox's displayed text - the actual amount staged for
-- SendMail() is only committed when Blizzard's own send-mail button handler
-- reads that editbox and calls SetSendMailMoney(). Since Send.lua calls
-- SendMail() directly and skips that handler, both must be called here or
-- the mail goes out with no gold attached.
function A:SetSendMoney(copper)
  if MoneyInputFrame_SetCopper and SendMailMoney then
    MoneyInputFrame_SetCopper(SendMailMoney, copper)
  end
  if SetSendMailMoney then
    SetSendMailMoney(copper)
  end
end

function A:AttachToSlot(index)
  ClickSendMailItemButton(index)
end

function A:GetAttachedItem(index)
  return GetSendMailItem(index)
end

function A:CommitSend(recipient, subject, body)
  SendMail(recipient, subject, body or "")
end
