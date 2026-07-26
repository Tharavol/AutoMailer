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

function A:Log(...)
  if not AutoMailer or not AutoMailer.debugLogging then return end
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

-- Recipients are matched against the currently logged-in character's name so
-- rules that happen to target yourself (e.g. a global profile rule meant for
-- a different alt) don't queue a pointless self-mail. Strips an optional
-- "-Realm" suffix off the recipient before comparing, since UnitName("player")
-- never includes one.
function A:IsCurrentCharacter(recipient)
  if not recipient or recipient == "" then return false end
  local playerName = UnitName("player")
  if not playerName then return false end
  local recName = recipient:match("^(.-)%-.+$") or recipient
  return recName:lower() == playerName:lower()
end
