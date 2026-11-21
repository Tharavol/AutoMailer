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

-- The send state machine: works through a queue built by MailQueue.lua one
-- mail at a time, driven by MAIL_SUCCESS/MAIL_FAILED.

local _, A = ...

local L = A.L

A.sendingMail = false
A.awaitConfirmSent = false
A.mailQueue = nil
A.mailQueueIndex = 0
A.mailTriggerButton = nil

-- Session tally for /am list: recipient -> itemName -> count.
A.itemsSent = {}

-- The gold confirmation is on screen; blocks building a second queue.
A.pendingConfirmation = false

-- Mails actually handed to SendMail this run (skipped batches excluded).
A.mailsSent = 0

-- Seconds to wait for MAIL_SUCCESS/MAIL_FAILED before abandoning the run.
-- A stuck-run backstop, not a latency budget, so it is generous.
local SEND_CONFIRM_TIMEOUT = 20

-- Bumped on every run start and hand-off so a late watchdog timer can tell it
-- is no longer guarding the current send.
A.sendGeneration = 0

local function BuildConfirmationText(summary)
  local lines = {}

  if summary.itemCount > 0 then
    tinsert(lines, string.format(L["%d item(s) in %d mail(s) to: %s"],
        summary.itemCount, summary.mailCount, table.concat(summary.recipients, ", ")))
  end

  if summary.goldCopper > 0 then
    tinsert(lines, string.format(
        L["Roughly %s to %s.\n" ..
        "(The exact amount is worked out at send time so postage lands you on your threshold.)"],
        C_CurrencyInfo.GetCoinTextureString(summary.goldCopper), summary.goldRecipient))
  end

  return L["AutoMailer is about to send:"] .. "\n\n" .. table.concat(lines, "\n\n")
      .. "\n\n" .. L["Proceed?"]
end

StaticPopupDialogs["AUTOMAILER_CONFIRM_SEND"] = {
  text = "%s",
  button1 = YES,
  button2 = NO,
  OnAccept = function(self)
    A:BeginMailRun(self.data)
  end,
  OnCancel = function()
    A:Print(L["Send cancelled."])
  end,
  -- Single release point for the guard, covering accept, cancel and Escape.
  OnHide = function()
    A.pendingConfirmation = false
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  -- Avoids taint from sharing Blizzard's low popup indices.
  preferredIndex = 3,
}

function A:ResetMailSendState()
  A:Log("ResetMailSendState")
  A.sendingMail = false
  A.awaitConfirmSent = false
  A.mailQueue = nil
  A.mailQueueIndex = 0
  A.mailsSent = 0
  -- Invalidates any watchdog still pending, so it can't fire into the next run.
  A.sendGeneration = A.sendGeneration + 1
end

-- Arms the stuck-run backstop for the batch just handed to SendMail.
function A:ArmSendWatchdog()
  A.sendGeneration = A.sendGeneration + 1
  local generation = A.sendGeneration

  C_Timer.After(SEND_CONFIRM_TIMEOUT, function()
    if not A.sendingMail then return end
    if A.sendGeneration ~= generation then return end
    if not A.awaitConfirmSent then return end

    A:Log("Send watchdog fired after", SEND_CONFIRM_TIMEOUT, "seconds with no MAIL_SUCCESS or MAIL_FAILED")
    A:Print(L["No response from the server for the last mail; stopping AutoMailer run."])
    A:ResetMailSendState()
  end)
end

--[[
  Creates and anchors the button; visibility is left to MAIL_SHOW/MAIL_CLOSED.
  Parented to MailFrame with no explicit strata or level, so it draws with the
  mailbox (#86) and follows its visibility when another addon such as TSM
  hides and re-shows it without firing MAIL_SHOW (#87).
]]
function A:EnsureMailTriggerButton()
  if not MailFrame then return nil end

  if not A.mailTriggerButton then
    local button = CreateFrame("Button", "AutoMailerMailButton", MailFrame, "UIPanelButtonTemplate")
    button:SetSize(140, 24)
    button:SetText(L["Send Mail"])
    button:SetScript("OnClick", function()
      A:StartMailSend()
    end)
    A.mailTriggerButton = button
  end

  A.mailTriggerButton:ClearAllPoints()
  A.mailTriggerButton:SetPoint("TOP", MailFrame, "TOP", 0, 30)

  return A.mailTriggerButton
end

function A:HideMailTriggerButton()
  if A.mailTriggerButton then
    A.mailTriggerButton:Hide()
  end
end

-- Switches the mail frame to the "Send Mail" tab.
function A:ShowSendMailTab()
  if not MailFrame then
    A:Log("ShowSendMailTab: MailFrame does not exist")
    return false
  end
  if not MailFrameTab2 then
    A:Log("ShowSendMailTab: MailFrameTab2 does not exist")
    return false
  end
  MailFrameTab2:Click()
  return true
end

function A:StartMailSend()
  if A.sendingMail then
    A:Print(L["A mail send is already in progress."])
    return
  end

  -- A second queue would target slots the pending run is about to empty.
  if A.pendingConfirmation then
    A:Print(L["A send is already waiting on the gold confirmation."])
    return
  end

  A:Log("StartMailSend invoked")

  local recipient = A.db.recipient
  local boeRecipient = A.db.boeRecipient

  -- Rules can name their own recipient, so a blank default alone is not an
  -- unconfigured profile.
  if #recipient == 0 and #boeRecipient == 0 and not A:HasRuleRecipient() then
    A:Print(L["No recipient configured."])
    return
  end

  if not A:ShowSendMailTab() then
    A:Print(L["Mail frame is not available."])
    return
  end

  local queue, itemCount = A:BuildMailQueue(recipient, boeRecipient)
  A:Log("BuildMailQueue produced", #queue, "batch(es) covering", itemCount, "item(s)")

  if #queue == 0 then
    A:Print(L["No matching items found in your bags to mail."])
    return
  end

  local summary = A:SummarizeQueue(queue)

  -- A soft nudge, never a block (#26); printed once per run.
  local unknownRecipients = {}
  for _, recipientName in ipairs(summary.recipients) do
    if not A:IsKnownCharacter(recipientName) then
      tinsert(unknownRecipients, recipientName)
    end
  end
  if #unknownRecipients > 0 then
    A:Print(string.format(L["Heads up: mailing to a name not seen on this account before: %s"],
        table.concat(unknownRecipients, ", ")))
  end

  if summary.goldCopper > 0 and A.db.confirmGoldSends then
    A:Log("Awaiting confirmation for a run including roughly", summary.goldCopper, "copper")
    A.pendingConfirmation = true
    StaticPopup_Show("AUTOMAILER_CONFIRM_SEND", BuildConfirmationText(summary), nil, queue)
    return
  end

  A:BeginMailRun(queue)
end

function A:BeginMailRun(queue)
  if not queue or #queue == 0 then return end
  if A.sendingMail then
    A:Print(L["A mail send is already in progress."])
    return
  end

  -- No "v" prefix: the release tag already carries one.
  A:Print(string.format(L["Starting AutoMailer send run (%s)"], A:GetVersion()))

  A.mailQueue = queue
  A.mailQueueIndex = 0
  A.mailsSent = 0
  A.sendingMail = true
  A.awaitConfirmSent = false

  A:ProcessMailQueue()
end

function A:ProcessMailQueue()
  if not A.sendingMail then
    A:Log("ProcessMailQueue called while not sending; ignoring")
    return
  end

  A.mailQueueIndex = A.mailQueueIndex + 1
  local batch = A.mailQueue[A.mailQueueIndex]

  if not batch then
    A:Print(string.format(L["AutoMailer finished: sent %d mail(s)."], A.mailsSent))
    A:ResetMailSendState()
    return
  end

  A:Log("Processing batch", A.mailQueueIndex, "/", #A.mailQueue, "recipient=", batch.recipient, "items=", #batch.items)
  A:SendMailBatch(batch)
end

--[[
  Polling for a split-off stack to land in its new slot. Moving an item is a
  server round trip, so the slot reads empty for a while (#81). A live split
  took ~1.2s; the 10s cap is a backstop that stays inside the 20s watchdog.
]]
local SPLIT_SETTLE_INTERVAL = 0.1
local SPLIT_SETTLE_ATTEMPTS = 100

-- A free slot in the ordinary bags for a split-off partial stack.
function A:FindEmptyBagSlot()
  for bag = 0, NUM_BAG_SLOTS do
    local slotCount = A:GetContainerNumSlots(bag)
    for slot = 1, slotCount do
      local _, _, _, _, _, _, itemLink = A:GetContainerItemInfo(bag, slot)
      if not itemLink then
        return bag, slot
      end
    end
  end
  return nil
end

--[[
  Attaches one bag item (pick up, click the attachment slot) and reports to
  callback(attached, retainViolated).

  count can be below the stack size because of Retain (#78). Attaching a
  freshly split stack straight from the cursor attaches the whole source
  stack (confirmed live, #81), so a partial stack is split into a free slot,
  waited on until it lands, then attached normally. Hence the callback.
]]
function A:AttachItemToMail(bag, slot, attachIndex, itemLink, count, callback)
  A:Log("Attach start: bag=", bag, "slot=", slot, "attachIndex=", attachIndex, "item=", itemLink or "<unknown>",
      "count=", count or "<all>")

  -- The bags may have changed since the queue was built (confirmation dialog,
  -- earlier mails), so check the slot still holds what was queued.
  local _, stackCount, _, _, _, _, currentLink = A:GetContainerItemInfo(bag, slot)
  if currentLink ~= itemLink then
    A:Log("Slot changed since the queue was built: expected", itemLink or "<unknown>",
        "but found", currentLink or "<empty>", "- skipping")
    callback(false)
    return
  end

  if A:CursorHasItem() then
    A:Log("Cursor already held an item before pickup; clearing it")
    A:ClearCursor()
  end

  -- Shared by the plain and split paths. Checks what the form actually took,
  -- so a Retain over-attach is pulled back rather than sent.
  local function attachFromCursor()
    if not A:CursorHasItem() then
      A:Log("Pickup failed: cursor is empty after pickup for", itemLink or "<unknown>")
      callback(false)
      return
    end

    A:AttachToSlot(attachIndex)

    -- GetSendMailItem's 4th return is the attached quantity (confirmed live, #81).
    local attachedName, _, _, attachedCount = A:GetAttachedItem(attachIndex)

    if not attachedName then
      A:Log("Attach verification failed at index", attachIndex, "for", itemLink or "<unknown>")
      if A:CursorHasItem() then
        A:ClearCursor()
      end
      callback(false)
      return
    end

    if count and attachedCount and attachedCount > count then
      A:Log("Attached", attachedCount, "but this rule's Retain only allows", count, "to ship for",
          itemLink or "<unknown>", "- pulling this batch back rather than over-sending")
      callback(false, true)
      return
    end

    A:Log("Attached", attachedName, "x", attachedCount or "?", "at index", attachIndex)
    callback(true)
  end

  if count and stackCount and count < stackCount then
    local restBag, restSlot = A:FindEmptyBagSlot()
    if not restBag then
      A:Log("No empty bag slot free to split off", count, "of", stackCount, "for", itemLink or "<unknown>")
      callback(false, true)
      return
    end

    A:Log("Splitting", count, "of", stackCount, "into bag=", restBag, "slot=", restSlot, "to honor Retain")
    A:SplitContainerItem(bag, slot, count)
    A:PickupContainerItem(restBag, restSlot)

    -- The move is a server round trip; the slot stays empty until it lands.
    local attempts = 0
    local function waitForSplitToLand()
      local _, landedCount, _, _, _, _, landedLink = A:GetContainerItemInfo(restBag, restSlot)
      if landedLink == itemLink and landedCount == count then
        A:Log("Split landed after", attempts, "check(s); attaching bag=", restBag, "slot=", restSlot)
        A:PickupContainerItem(restBag, restSlot)
        attachFromCursor()
        return
      end

      attempts = attempts + 1
      if attempts >= SPLIT_SETTLE_ATTEMPTS then
        A:Log("Split never landed in bag=", restBag, "slot=", restSlot, "after", attempts, "checks - giving up on",
            itemLink or "<unknown>", "rather than risk sending the whole stack")
        if A:CursorHasItem() then
          A:ClearCursor()
        end
        callback(false, true)
        return
      end

      C_Timer.After(SPLIT_SETTLE_INTERVAL, waitForSplitToLand)
    end

    waitForSplitToLand()
  else
    A:PickupContainerItem(bag, slot)
    attachFromCursor()
  end
end

function A:SendMailBatch(batch)
  if not MailFrame or not MailFrame:IsShown() then
    A:Print(L["Mail frame is not open; stopping AutoMailer."])
    A:ResetMailSendState()
    return
  end

  if not A:ShowSendMailTab() then
    A:Print(L["Could not switch to the Send Mail tab; stopping AutoMailer."])
    A:ResetMailSendState()
    return
  end

  A:ClearSendForm()

  A:SetSendRecipient(batch.recipient)

  -- Excess gold is resolved here: GetSendMailPrice() only reports real postage
  -- once the form has a recipient, and before any attachments. Must precede
  -- GetBatchSubject, which reads batch.money.
  if batch.goldThresholdCopper then
    local postage = A:GetSendMailPrice()
    batch.money = A:ExcessGoldToSend(A:GetMoney(), batch.goldThresholdCopper, postage)
    A:Log("Resolved excess gold at send time: postage=", postage, "money=", batch.money)
  end

  local subject = A:GetBatchSubject(batch)
  A:SetSendSubject(subject)

  local money = batch.money or 0
  A:SetSendMoney(money)

  -- Tally for /am list, applied by A:CommitSentItems only on MAIL_SUCCESS.
  local pendingSent = {}
  local attachedCount = 0

  -- Callback-driven because attaching can wait on a split, and a Retain
  -- violation (#78/#81) aborts the whole batch.
  local function attachNext(i)
    local item = batch.items[i]
    if not item then
      A:FinishSendMailBatch(batch, subject, money, attachedCount, pendingSent)
      return
    end

    A:AttachItemToMail(item.bag, item.slot, i, item.itemLink, item.count, function(attached, retainViolated)
      -- Pull back everything attached and skip the batch rather than over-send.
      if retainViolated then
        A:ClearSendForm()
        A:Print(string.format(L["Could not honor a Retain limit for %s; skipping this batch."], batch.recipient))
        C_Timer.After(0.2, function()
          A:ProcessMailQueue()
        end)
        return
      end

      if attached then
        attachedCount = attachedCount + 1
        local itemName = A:GetItemInfo(item.itemLink) or item.itemLink
        -- Counted by stack size, not by attachment.
        pendingSent[itemName] = (pendingSent[itemName] or 0) + (item.count or 1)
      end
      attachNext(i + 1)
    end)
  end

  attachNext(1)
end

-- Runs once every item has had an attach attempt: sends the mail or skips it.
function A:FinishSendMailBatch(batch, subject, money, attachedCount, pendingSent)
  batch.pendingSent = pendingSent

  if attachedCount == 0 and money == 0 then
    A:Print(string.format(L["Could not attach any items for %s; skipping this batch."], batch.recipient))
    C_Timer.After(0.2, function()
      A:ProcessMailQueue()
    end)
    return
  end

  A:Log("Calling SendMail to", batch.recipient, "with", attachedCount, "item(s) attached, money=", money,
      "subject=", subject)
  A.awaitConfirmSent = true
  -- Lets A:OnMailSuccess wait for postage to reach GetMoney().
  A.moneyBeforeSend = A:GetMoney()
  A:ArmSendWatchdog()
  A:CommitSend(batch.recipient, subject)
  A.mailsSent = A.mailsSent + 1

  -- Gold batches carry no items; a mixed mail is not built today but handled.
  if attachedCount > 0 and money > 0 then
    A:Print(string.format(L["Sent %d item(s) and %s to %s"],
        attachedCount, C_CurrencyInfo.GetCoinTextureString(money), batch.recipient))
  elseif money > 0 then
    A:Print(string.format(L["Sent %s to %s"], C_CurrencyInfo.GetCoinTextureString(money), batch.recipient))
  else
    A:Print(string.format(L["Sent %d item(s) to %s"], attachedCount, batch.recipient))
  end
end

-- Folds a confirmed mail's contents into the session tally /am list reads.
function A:CommitSentItems(batch)
  if not batch or not batch.pendingSent then return end

  local tally = A.itemsSent[batch.recipient]
  if not tally then
    tally = {}
    A.itemsSent[batch.recipient] = tally
  end

  for itemName, count in pairs(batch.pendingSent) do
    tally[itemName] = (tally[itemName] or 0) + count
  end

  -- Cleared so a batch can only ever be counted once, however often this runs.
  batch.pendingSent = nil
end

function A:OnMailSuccess(mailID)
  A:Log("MAIL_SUCCESS mailID=", mailID)
  A.awaitConfirmSent = false
  if not A.sendingMail then return end

  A:CommitSentItems(A.mailQueue and A.mailQueue[A.mailQueueIndex])

  -- GetMoney() reflects this mail's postage only after a variable delay, and the
  -- next gold batch's math needs it. Poll for the change, capped at 2s.
  local moneyBeforeSend = A.moneyBeforeSend
  local attempts = 0
  local function waitForMoneyUpdate()
    if not A.sendingMail then return end
    attempts = attempts + 1
    if A:GetMoney() ~= moneyBeforeSend or attempts >= 20 then
      A:ProcessMailQueue()
    else
      C_Timer.After(0.1, waitForMoneyUpdate)
    end
  end
  waitForMoneyUpdate()
end

function A:OnMailFailed()
  A:Log("MAIL_FAILED")
  A.awaitConfirmSent = false
  if A.sendingMail then
    A:Print(L["A mail failed to send; stopping AutoMailer run."])
    A:ResetMailSendState()
  end
end
