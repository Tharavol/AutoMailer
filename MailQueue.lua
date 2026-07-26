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
  Turns the contents of your bags into a flat list of send batches. Knows
  nothing about actually sending mail - see Send.lua for that.
]]

local _, A = ...

A.MAX_MAIL_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12

function A:AutomailBoe(bindType)
  return A.db.SendBOE and bindType == 2
end

-- Scans all bags once and builds a flat list of send batches, each with a
-- recipient and at most MAX_MAIL_ATTACHMENTS items (one mail can only carry
-- so many attachments).
function A:BuildMailQueue(recipient, boeRecipient)
  local queuedByRecipient = {}
  local totalItems = 0

  local function queueItem(targetRecipient, bag, slot, itemLink)
    if A:IsCurrentCharacter(targetRecipient) then
      A:Log("Skipping", itemLink or "<unknown>", "- recipient", targetRecipient, "is the currently logged in character")
      return
    end
    queuedByRecipient[targetRecipient] = queuedByRecipient[targetRecipient] or {}
    tinsert(queuedByRecipient[targetRecipient], { bag = bag, slot = slot, itemLink = itemLink })
    totalItems = totalItems + 1
  end

  for bag = 0, NUM_BAG_SLOTS do
    local slotCount = A:GetContainerNumSlots(bag)
    for slot = 1, slotCount do
      local _, _, locked, _, _, _, itemLink = A:GetContainerItemInfo(bag, slot)
      if itemLink and not locked and not A:ItemIsSoulbound(bag, slot) then
        local itemName, _, rarity, _, itemMinLevel, _, _, _, _, _, _, _, _, bindType = A:GetItemInfo(itemLink)
        local targetRecipient = nil
        local entry = A:GetAutoMailEntry(itemName, A:GetItemIDFromLink(itemLink))

        if entry then
          if entry.recipient and entry.recipient ~= "" then
            targetRecipient = entry.recipient
          else
            targetRecipient = recipient
          end

        elseif A:AutomailBoe(bindType) then
          local rarityOk = (not A.db.limitBoeRarity) or rarity <= A.db.boeRarityLimit
          local levelOk = (not A.db.LimitBoeLevel) or itemMinLevel < UnitLevel("PLAYER")
          if rarityOk and levelOk then
            targetRecipient = (#boeRecipient > 0) and boeRecipient or recipient
          end
        end

        if targetRecipient and #targetRecipient > 0 then
          queueItem(targetRecipient, bag, slot, itemLink)
        end
      end
    end
  end

  -- The Reagent Bag (bag 5) is a dedicated container the game auto-sorts
  -- crafting materials into. Rather than trying to identify "is this a
  -- reagent" via item classification (which proved unreliable - GetItemInfo
  -- fields can be uncached, and classID/type schemes shift between
  -- expansions), just mail out anything non-soulbound sitting in that bag.
  if A.db.SendReagents then
    local reagentBag = REAGENTBAG_CONTAINER or 5
    local slotCount = A:GetContainerNumSlots(reagentBag)
    for slot = 1, slotCount do
      local _, _, locked, _, _, _, itemLink = A:GetContainerItemInfo(reagentBag, slot)
      if itemLink and not locked and not A:ItemIsSoulbound(reagentBag, slot) then
        local itemName = A:GetItemInfo(itemLink)
        local targetRecipient = recipient
        local entry = A:GetAutoMailEntry(itemName, A:GetItemIDFromLink(itemLink))
        if entry and entry.recipient and entry.recipient ~= "" then
          targetRecipient = entry.recipient
        end

        if targetRecipient and #targetRecipient > 0 then
          queueItem(targetRecipient, reagentBag, slot, itemLink)
        end
      end
    end
  end

  local recipients = {}
  for targetRecipient in pairs(queuedByRecipient) do
    tinsert(recipients, targetRecipient)
  end
  table.sort(recipients)

  local batches = {}
  for _, targetRecipient in ipairs(recipients) do
    local items = queuedByRecipient[targetRecipient]
    for i = 1, #items, A.MAX_MAIL_ATTACHMENTS do
      local chunk = {}
      for j = i, math.min(i + A.MAX_MAIL_ATTACHMENTS - 1, #items) do
        tinsert(chunk, items[j])
      end
      tinsert(batches, { recipient = targetRecipient, items = chunk })
    end
  end

  if A.db.sendExcessGold then
    local thresholdCopper = (A.db.goldThreshold or 50000) * 10000
    local goldRecipient = (#recipient > 0) and recipient or boeRecipient
    -- Postage isn't a flat per-mail fee - GetSendMailPrice() reflects the
    -- cost of whatever's currently attached to the send-mail form, and it
    -- scales up with items attached (confirmed live: a 9-item batch cost far
    -- more than the ~30c base rate). That means the total postage for this
    -- run can't be known upfront here. Queue a placeholder instead and work
    -- out the actual amount to send right before this batch goes out
    -- (SendMailBatch), using GetMoney() at that point - which by then
    -- already reflects every other mail's real postage - minus this mail's
    -- own (zero-item) postage queried fresh in that moment.
    if A:IsCurrentCharacter(goldRecipient) then
      A:Log("Skipping excess gold - recipient", goldRecipient, "is the currently logged in character")
    elseif GetMoney() > thresholdCopper and goldRecipient and #goldRecipient > 0 then
      A:Log("Queuing excess gold batch (amount computed at send time): threshold=", A.db.goldThreshold,
          "recipient=", goldRecipient)
      tinsert(batches, { recipient = goldRecipient, items = {}, goldThresholdCopper = thresholdCopper })
      totalItems = totalItems + 1
    end
  end

  return batches, totalItems
end

function A:GetBatchSubject(batch)
  if #batch.items == 0 and batch.money and batch.money > 0 then
    return "Gold"
  end
  local first = batch.items[1]
  local name = first and A:GetItemInfo(first.itemLink)
  if not name or name == "" then
    name = "Item"
  end
  if #batch.items > 1 then
    return name .. " +" .. (#batch.items - 1) .. " more"
  end
  return name
end

-- Rolls a built queue up into the numbers the pre-run confirmation shows.
--
-- goldCopper is necessarily an estimate: the real amount is only resolved in
-- SendMailBatch, immediately before the gold mail goes out, because postage
-- scales with attachments and can't be predicted upfront (see BuildMailQueue).
-- The confirmation labels it as approximate for that reason.
function A:SummarizeQueue(queue)
  local summary = {
    mailCount = #queue,
    itemCount = 0,
    goldCopper = 0,
    goldRecipient = nil,
    recipients = {},
  }

  local seen = {}
  for _, batch in ipairs(queue) do
    summary.itemCount = summary.itemCount + #batch.items
    if not seen[batch.recipient] then
      seen[batch.recipient] = true
      tinsert(summary.recipients, batch.recipient)
    end
    if batch.goldThresholdCopper then
      summary.goldCopper = math.max(0, GetMoney() - batch.goldThresholdCopper)
      summary.goldRecipient = batch.recipient
    end
  end

  table.sort(summary.recipients)
  return summary
end
