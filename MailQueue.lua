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

-- Turns the contents of your bags into a flat list of send batches. Sending
-- them is Send.lua's job.

local _, A = ...

local L = A.L

-- ATTACHMENTS_MAX_SEND lives in load-on-demand Blizzard_MailFrame, so it can
-- still be nil when this file loads.
A.MAX_MAIL_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12

function A:AutomailBoe(bindType)
  return A.db.sendBoe and bindType == 2
end

-- Excess-gold arithmetic, shared by queue-build and send time and tested
-- directly. The amount is only final at send time, once postage is known.
function A:HasExcessGold(currentCopper, thresholdCopper)
  return (currentCopper or 0) > (thresholdCopper or 0)
end

-- Clamped at zero: postage can exceed a small excess.
function A:ExcessGoldToSend(currentCopper, thresholdCopper, postageCopper)
  return math.max(0, (currentCopper or 0) - (thresholdCopper or 0) - (postageCopper or 0))
end

-- Scans all bags once and builds send batches of at most MAX_MAIL_ATTACHMENTS
-- items per recipient.
function A:BuildMailQueue(recipient, boeRecipient)
  local queuedByRecipient = {}
  local totalItems = 0

  -- Skip reasons for the debug log, grouped by reason with sampled item names
  -- so a full bag of unmatched items doesn't bury everything else.
  local SKIP_SAMPLE_LIMIT = 8
  local skipped = {}
  local debugging = A:IsDebugLogging()

  local function noteSkip(reason, itemLink)
    if not debugging then return end
    local bucket = skipped[reason]
    if not bucket then
      bucket = { count = 0, samples = {} }
      skipped[reason] = bucket
    end
    bucket.count = bucket.count + 1
    if #bucket.samples < SKIP_SAMPLE_LIMIT then
      tinsert(bucket.samples, itemLink or "<unknown>")
    end
  end

  -- count is the stack size (for the sent tally); totalItems and batching
  -- count slots, since a slot is what occupies an attachment.
  local function queueItem(targetRecipient, bag, slot, itemLink, count)
    if A:IsCurrentCharacter(targetRecipient) then
      noteSkip("recipient is the currently logged in character", itemLink)
      return
    end
    queuedByRecipient[targetRecipient] = queuedByRecipient[targetRecipient] or {}
    tinsert(queuedByRecipient[targetRecipient],
        { bag = bag, slot = slot, itemLink = itemLink, count = count or 1 })
    totalItems = totalItems + 1
  end

  -- Retain (#78) applies to the total across all bags, so slots for a
  -- Retain>0 rule are parked here, keyed by rule, until scanning finishes.
  local pendingByEntry = {}

  local function considerItem(entry, targetRecipient, bag, slot, itemLink, count)
    local retain = entry and entry.retain
    if not retain or retain <= 0 then
      queueItem(targetRecipient, bag, slot, itemLink, count)
      return
    end
    local pending = pendingByEntry[entry]
    if not pending then
      pending = {}
      pendingByEntry[entry] = pending
    end
    tinsert(pending, { targetRecipient = targetRecipient, bag = bag, slot = slot, itemLink = itemLink, count = count })
  end

  -- Sends total held minus Retain, in scan order, trimming a partial stack.
  local function resolvePendingRetain()
    for entry, pending in pairs(pendingByEntry) do
      local totalHeld = 0
      for _, item in ipairs(pending) do
        totalHeld = totalHeld + (item.count or 1)
      end
      local remaining = math.max(0, totalHeld - entry.retain)
      for _, item in ipairs(pending) do
        if remaining <= 0 then
          noteSkip("held back by this rule's Retain setting", item.itemLink)
        else
          local sendCount = math.min(remaining, item.count or 1)
          queueItem(item.targetRecipient, item.bag, item.slot, item.itemLink, sendCount)
          remaining = remaining - sendCount
        end
      end
    end
  end

  -- One pass over a bag.
  --   mailEverything: mail everything without a rule ("Send all Crafting Reagents").
  --   boeApplies: consider BoE handling (off for the Reagent Bag).
  local function scanBag(bag, mailEverything, boeApplies)
    local slotCount = A:GetContainerNumSlots(bag)
    for slot = 1, slotCount do
      local _, stackCount, locked, _, _, _, itemLink = A:GetContainerItemInfo(bag, slot)
      if itemLink and locked then
        noteSkip("locked by the client", itemLink)
      elseif itemLink and A:ItemIsSoulbound(bag, slot) then
        noteSkip("soulbound", itemLink)
      elseif itemLink then
        local itemName, _, rarity, _, itemMinLevel, _, _, _, _, _, _, _, _, bindType = A:GetItemInfo(itemLink)
        local itemID = A:GetItemIDFromLink(itemLink)

        -- GetItemInfo returns nothing for an uncached item. itemID rules still
        -- match; name rules and BoE handling can't, so request a load for next time.
        if not itemName then
          A:Log("Item data not cached yet for", itemLink, "- name rules and BoE handling",
              "can't be applied to it on this run; requesting a load")
          A:RequestItemDataLoad(itemID)
        end

        local entry = A:GetAutoMailEntry(itemName, itemID)
        local targetRecipient = nil
        local skipReason = nil

        if entry then
          if entry.recipient ~= "" then
            targetRecipient = entry.recipient
          else
            targetRecipient = recipient
            skipReason = "rule matched but has no recipient, and no default Recipient is set"
          end

        elseif mailEverything then
          targetRecipient = recipient
          skipReason = "no default Recipient set for the reagent sweep"

        elseif boeApplies and A:AutomailBoe(bindType) then
          local rarityOk = (not A.db.limitBoeRarity) or rarity <= A.db.boeRarityLimit
          local levelOk = (not A.db.limitBoeLevel) or itemMinLevel < A:GetPlayerLevel()
          if rarityOk and levelOk then
            targetRecipient = (#boeRecipient > 0) and boeRecipient or recipient
            skipReason = "BoE passed the filters but no BoE Recipient or Recipient is set"
          else
            skipReason = "BoE outside the configured rarity/level limits"
          end

        else
          skipReason = "matched no rule"
        end

        if targetRecipient and #targetRecipient > 0 then
          considerItem(entry, targetRecipient, bag, slot, itemLink, stackCount)
        else
          noteSkip(skipReason or "matched no rule", itemLink)
        end
      end
    end
  end

  for bag = 0, NUM_BAG_SLOTS do
    scanBag(bag, false, true)
  end

  -- The Reagent Bag is always scanned so explicit rules match items the game
  -- auto-sorts there; sendReagents only decides whether everything in it goes.
  scanBag(REAGENTBAG_CONTAINER or 5, A.db.sendReagents, false)

  resolvePendingRetain()

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
    local thresholdCopper = A.db.goldThreshold * 10000
    local goldRecipient = (#recipient > 0) and recipient or boeRecipient
    -- Postage scales with attachments, so the amount is a placeholder resolved
    -- in SendMailBatch once every earlier mail's postage has been paid.
    if #goldRecipient == 0 then
      -- Rule recipients only apply to items, so say why gold was not sent.
      if A:HasExcessGold(A:GetMoney(), thresholdCopper) then
        A:Print(L["Excess gold not sent: set a Recipient or BoE Recipient. "
            .. "A rule's own recipient only applies to items."])
      end
    elseif A:IsCurrentCharacter(goldRecipient) then
      A:Log("Skipping excess gold - recipient", goldRecipient, "is the currently logged in character")
    elseif A:HasExcessGold(A:GetMoney(), thresholdCopper) then
      A:Log("Queuing excess gold batch (amount computed at send time): threshold=", A.db.goldThreshold,
          "recipient=", goldRecipient)
      tinsert(batches, { recipient = goldRecipient, items = {}, goldThresholdCopper = thresholdCopper })
      totalItems = totalItems + 1
    end
  end

  A:LogQueueDetail(batches, skipped)

  return batches, totalItems
end

-- Per-run debug account of batches and skips. Reasons are sorted so two runs
-- over the same bags log identically.
function A:LogQueueDetail(batches, skipped)
  if not A:IsDebugLogging() then return end

  for i, batch in ipairs(batches) do
    if batch.goldThresholdCopper then
      A:Log("Batch", i, "to", batch.recipient .. ":", "excess gold, amount resolved at send time")
    else
      local names = {}
      for _, item in ipairs(batch.items) do
        tinsert(names, A:GetItemInfo(item.itemLink) or item.itemLink or "<unknown>")
      end
      A:Log("Batch", i, "to", batch.recipient .. ":", "subject=" .. A:GetBatchSubject(batch),
          "[" .. table.concat(names, ", ") .. "]")
    end
  end

  local reasons = {}
  for reason in pairs(skipped) do
    tinsert(reasons, reason)
  end
  table.sort(reasons)

  for _, reason in ipairs(reasons) do
    local bucket = skipped[reason]
    local sample = table.concat(bucket.samples, ", ")
    if bucket.count > #bucket.samples then
      sample = sample .. ", ... (" .. (bucket.count - #bucket.samples) .. " more)"
    end
    A:Log("Skipped", bucket.count, "item(s) -", reason .. ":", sample)
  end
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

-- Rolls a queue up for the pre-run confirmation. goldCopper is an estimate
-- (zero postage); the real amount is resolved in SendMailBatch.
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
      summary.goldCopper = A:ExcessGoldToSend(A:GetMoney(), batch.goldThresholdCopper, 0)
      summary.goldRecipient = batch.recipient
    end
  end

  table.sort(summary.recipients)
  return summary
end
