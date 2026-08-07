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
  return A.db.sendBoe and bindType == 2
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

  --[[
    Why an item was passed over, collected while scanning so the run can
    account for every occupied slot afterwards.

    A run that queues nothing used to report exactly one line - "produced 0
    batch(es) covering 0 item(s)" - with no way to tell an empty bag from
    soulbound contents from rules that simply didn't match. That is precisely
    when the log is most needed and it said least.

    Grouped by reason rather than logged per slot: a full bag of unmatched
    items would otherwise bury everything else. Item names are sampled, not
    listed exhaustively, for the same reason.
  ]]
  local SKIP_SAMPLE_LIMIT = 8
  local skipped = {}
  local debugging = A:IsDebugLogging()

  local function noteSkip(reason, itemLink)
    -- Collection is the one piece of debug work heavy enough to be worth
    -- skipping outright when nobody will read it.
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

  -- count is how many the slot holds, carried through so the sent tally can
  -- report a stack as its real size. Everything else here counts slots, since
  -- a slot is what occupies an attachment: totalItems and the batch chunking
  -- below are both about how many mails this needs, not how many objects.
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

  -- One pass over a single bag. The Reagent Bag differs from the ordinary
  -- bags in two ways, and they are now separate flags because they turned out
  -- to be independent questions:
  --
  --   mailEverything - nothing in the bag has to match a rule to be mailed.
  --                    This is the "Send all Crafting Reagents" option.
  --   boeApplies     - whether BoE handling considers this bag at all. Always
  --                    off for the Reagent Bag, which can only hold
  --                    tradeskill items.
  --
  -- These used to be one flag, which conflated them with a third thing: the
  -- Reagent Bag was only scanned when the option was on, so a rule naming an
  -- item that lives there never matched unless you also opted into sweeping
  -- the whole bag. Keeping this as one loop rather than a second copy is
  -- still deliberate - the two had already drifted apart once.
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
        local skipReason = nil

        if entry then
          if entry.recipient and entry.recipient ~= "" then
            targetRecipient = entry.recipient
          else
            targetRecipient = recipient
            -- Reachable since a run can start on rule recipients alone: this
            -- rule matched but names nobody, and there is no default to fall
            -- back to. Silently dropping it looks like the rule is broken.
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
          queueItem(targetRecipient, bag, slot, itemLink, stackCount)
        else
          noteSkip(skipReason or "matched no rule", itemLink)
        end
      end
    end
  end

  for bag = 0, NUM_BAG_SLOTS do
    scanBag(bag, false, true)
  end

  -- The Reagent Bag (bag 5) is a dedicated container the game auto-sorts
  -- crafting materials into. Rather than trying to identify "is this a
  -- reagent" via item classification (which proved unreliable - GetItemInfo
  -- fields can be uncached, and classID/type schemes shift between
  -- expansions), the sendReagents option just mails out anything non-soulbound
  -- sitting in that bag.
  --
  -- Scanned unconditionally, though. The option controls whether everything in
  -- there is swept up, not whether the bag is looked at: because the game files
  -- cloth, ore and herbs in here automatically, gating the scan on the option
  -- meant an explicit rule for exactly those items silently never matched - and
  -- silently, since an unscanned bag produces nothing to log either.
  scanBag(REAGENTBAG_CONTAINER or 5, A.db.sendReagents, false)

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
    if #goldRecipient == 0 then
      -- Gold has no per-rule equivalent: rules attach recipients to items, and
      -- gold isn't an item. A run can now start on rule recipients alone, so
      -- this is reachable with the gold option enabled and nothing to send it
      -- to - and dropping it silently reads as the option being ignored.
      -- Only worth saying when there was actually gold to send.
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

--[[
  The per-run debug account: what is going to whom, and what was passed over.

  Split out of BuildMailQueue so the queue-building logic stays readable, and
  so the formatting cost only happens when debug logging is on.

  Reasons are sorted so two runs over the same bags produce the same output -
  pairs() order would otherwise shuffle the lines and make two logs awkward to
  compare, which is the main thing anyone does with these.
]]
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
