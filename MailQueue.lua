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

local L = A.L

A.MAX_MAIL_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12

function A:AutomailBoe(bindType)
  return A.db.SendBOE and bindType == 2
end

--[[
  The excess-gold arithmetic, kept here as two plain functions over plain
  numbers rather than inline at the two places that need it.

  This is the only part of a send run that can't be undone by mailing things
  back, and it's had the most bugs: the amount can't be worked out when the
  queue is built (postage scales with attachments and is only honest once the
  send form has a recipient), so the decision to queue and the decision of how
  much to send happen in different files, minutes apart, off a GetMoney() that
  moves underneath them. Splitting the arithmetic out means both callers share
  one definition of it and it can be tested directly.
]]
function A:HasExcessGold(currentCopper, thresholdCopper)
  return (currentCopper or 0) > (thresholdCopper or 0)
end

-- What to actually put on the mail. Postage comes in as an argument because
-- only the caller, at send time, can ask the game for it. Clamped at zero:
-- postage can exceed the excess when the balance is barely over the threshold,
-- and a negative amount would be nonsense to hand to SetSendMailMoney.
function A:ExcessGoldToSend(currentCopper, thresholdCopper, postageCopper)
  return math.max(0, (currentCopper or 0) - (thresholdCopper or 0) - (postageCopper or 0))
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

  -- One pass over a single bag. The Reagent Bag differs from the ordinary
  -- bags in exactly two ways, both of them captured by mailEverything:
  -- nothing in it has to match a rule to be mailed, and BoE handling doesn't
  -- apply to it. Keeping that difference as a flag rather than as a second
  -- copy of this loop is deliberate - the two had already drifted apart.
  local function scanBag(bag, mailEverything)
    local slotCount = A:GetContainerNumSlots(bag)
    for slot = 1, slotCount do
      local _, _, locked, _, _, _, itemLink = A:GetContainerItemInfo(bag, slot)
      if itemLink and not locked and not A:ItemIsSoulbound(bag, slot) then
        local itemName, _, rarity, _, itemMinLevel, _, _, _, _, _, _, _, _, bindType = A:GetItemInfo(itemLink)
        local itemID = A:GetItemIDFromLink(itemLink)

        -- GetItemInfo returns nothing for an item the client hasn't cached
        -- yet, which used to pass through here silently: bindType came back
        -- nil, so the item quietly failed the BoE check and a run could
        -- under-send while reporting success. itemID rules still work (they
        -- don't need the cache), so say so in the log and ask the client to
        -- load the data for next time.
        if not itemName then
          A:Log("Item data not cached yet for", itemLink, "- name rules and BoE handling",
              "can't be applied to it on this run; requesting a load")
          A:RequestItemDataLoad(itemID)
        end

        local entry = A:GetAutoMailEntry(itemName, itemID)
        local targetRecipient = nil

        if entry then
          if entry.recipient and entry.recipient ~= "" then
            targetRecipient = entry.recipient
          else
            targetRecipient = recipient
          end

        elseif mailEverything then
          targetRecipient = recipient

        elseif A:AutomailBoe(bindType) then
          local rarityOk = (not A.db.limitBoeRarity) or rarity <= A.db.boeRarityLimit
          local levelOk = (not A.db.LimitBoeLevel) or itemMinLevel < A:GetPlayerLevel()
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

  for bag = 0, NUM_BAG_SLOTS do
    scanBag(bag, false)
  end

  -- The Reagent Bag (bag 5) is a dedicated container the game auto-sorts
  -- crafting materials into. Rather than trying to identify "is this a
  -- reagent" via item classification (which proved unreliable - GetItemInfo
  -- fields can be uncached, and classID/type schemes shift between
  -- expansions), just mail out anything non-soulbound sitting in that bag.
  if A.db.SendReagents then
    scanBag(REAGENTBAG_CONTAINER or 5, true)
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
    elseif A:HasExcessGold(A:GetMoney(), thresholdCopper) and goldRecipient and #goldRecipient > 0 then
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
    return L["Gold"]
  end
  local first = batch.items[1]
  local name = first and A:GetItemInfo(first.itemLink)
  if not name or name == "" then
    name = L["Item"]
  end
  if #batch.items > 1 then
    return string.format(L["%s +%d more"], name, #batch.items - 1)
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
      -- Zero postage: the confirmation is showing an approximate figure, and
      -- this mail's real postage isn't knowable until it's about to go out.
      summary.goldCopper = A:ExcessGoldToSend(A:GetMoney(), batch.goldThresholdCopper, 0)
      summary.goldRecipient = batch.recipient
    end
  end

  table.sort(summary.recipients)
  return summary
end
