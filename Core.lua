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

-- Shared utilities: chat output, and thin wrappers over the WoW APIs so the
-- rest of the addon (and its tests) only touches them through A.

local ADDON_NAME, A = ...

A.addonName = "|cff8d63ffAutoMailer|r "

function A:GetVersion()
  return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
end

-- strjoin, not "..": concatenation would keep only tostringall's first value.
function A:Print(...)
  DEFAULT_CHAT_FRAME:AddMessage(A.addonName .. "- " .. strjoin(" ", tostringall(...)))
end

-- Lets callers skip expensive debug-only work (BuildMailQueue's skip summary).
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

-- Asks the client to cache an item's data, so the next run can classify an
-- item GetItemInfo couldn't answer for yet.
function A:RequestItemDataLoad(itemID)
  if itemID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
end

function A:PickupContainerItem(bag, slot)
  C_Container.PickupContainerItem(bag, slot)
end

-- Splits count off a slot's stack onto the cursor (Retain trimming, #81).
function A:SplitContainerItem(bag, slot, count)
  C_Container.SplitContainerItem(bag, slot, count)
end

function A:CursorHasItem()
  return CursorHasItem()
end

function A:ClearCursor()
  ClearCursor()
end

-- Money and player state; wrapped so tests can drive the excess-gold math.
function A:GetMoney()
  return GetMoney()
end

-- Postage for what is currently on the send-mail form. Scales with
-- attachments and is only accurate once the form has a recipient.
function A:GetSendMailPrice()
  return GetSendMailPrice()
end

function A:GetPlayerLevel()
  return UnitLevel("PLAYER")
end

-- Whether this bag slot's item is bound and so unmailable. Warbound-until-
-- equipped gear reports as bound but can be mailed to your own characters.
function A:ItemIsSoulbound(bag, slot)
  local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
  if not location:IsValid() then return false end
  if not C_Item.IsBound(location) then return false end
  if C_Item.IsBoundToAccountUntilEquip(location) then
    return false
  end
  return true
end

function A:GetPlayerName()
  return UnitName("player")
end

function A:GetRealmName()
  return GetRealmName()
end

-- Whether recipient is the logged-in character (ignoring any "-Realm"
-- suffix), so a global-profile rule doesn't queue a self-mail.
function A:IsCurrentCharacter(recipient)
  if not recipient or recipient == "" then return false end
  local playerName = A:GetPlayerName()
  if not playerName then return false end
  local recName = recipient:match("^(.-)%-.+$") or recipient
  return recName:lower() == playerName:lower()
end

-- The send-mail form, wrapped so tests can drive Send.lua's state machine (#15).
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

-- MoneyInputFrame_SetCopper only updates the displayed amount; SetSendMailMoney
-- stages it. Blizzard's send button does the latter, but SendMail() is called
-- directly here, so both are needed or the mail goes out with no gold.
function A:SetSendMoney(copper)
  MoneyInputFrame_SetCopper(SendMailMoney, copper)
  SetSendMailMoney(copper)
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
