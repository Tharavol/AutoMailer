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
  The send state machine: takes a queue built by MailQueue.lua and works
  through it one mail at a time, driven by MAIL_SUCCESS/MAIL_FAILED.
]]

local _, A = ...

local L = A.L

A.sendingMail = false
A.awaitConfirmSent = false
A.mailQueue = nil
A.mailQueueIndex = 0
A.mailTriggerButton = nil

-- Whether the gold confirmation is on screen waiting to be answered. Separate
-- from sendingMail, which only goes up once that popup is accepted: without
-- this, clicking the trigger button again while the dialog was open built a
-- second queue and stacked a second dialog behind the first.
A.pendingConfirmation = false

-- Mails actually handed to SendMail this run, as opposed to positions worked
-- through in the queue. The completion message used to report mailQueueIndex,
-- which counts batches that were skipped for having nothing attachable too.
A.mailsSent = 0

--[[
  How long to wait for MAIL_SUCCESS or MAIL_FAILED after calling SendMail
  before giving up on the run.

  Every batch ends by handing off to the server and waiting for one of those
  two events to drive the next one. If neither arrives, nothing else moves the
  state machine: sendingMail stays true, every later click on the trigger
  button answers "A mail send is already in progress.", and only closing the
  mailbox clears it. awaitConfirmSent existed to catch exactly this and was
  never read by anything - this is the missing half.

  Generous on purpose. It is a stuck-run backstop, not a latency budget: a
  slow server round-trip must never trip it, because aborting a run that is
  merely slow would be worse than the stall it protects against.
]]
local SEND_CONFIRM_TIMEOUT = 20

-- Bumped every time a run starts or a batch is handed off, so a timer that
-- fires late can tell whether it is still guarding the send it was armed for.
-- Without it, a watchdog armed for batch 3 could abort batch 4 after batch 3
-- confirmed normally.
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
        GetCoinTextureString(summary.goldCopper), summary.goldRecipient))
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
  -- Clears the re-entry guard however the dialog leaves the screen - accepted,
  -- cancelled, or dismissed with Escape. Doing it here rather than in the two
  -- button handlers means no dismissal path can leave the guard stuck on, with
  -- the trigger button refusing every later run for the rest of the session.
  OnHide = function()
    A.pendingConfirmation = false
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  -- Keeps the dialog off the low indices Blizzard's own popups use, the
  -- standard way of avoiding taint from an addon-registered popup.
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

-- Arms the stuck-run backstop for the batch just handed to SendMail. Fires
-- only if that same batch is still unconfirmed when the timeout elapses:
-- ResetMailSendState and every subsequent hand-off bump the generation, so a
-- stale timer recognizes itself and does nothing.
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

-- Creates the button if it doesn't exist yet and (re)anchors it to the mail
-- frame, returning it. Deliberately does not decide whether it should be
-- visible: MAIL_SHOW shows it, and MAIL_CLOSED plus MailFrame's own OnHide
-- hide it. This used to also show/hide based on MailFrame:IsShown(), while
-- the caller unconditionally showed it afterwards - two places owning one
-- decision, and the caller always won, because MailFrame isn't necessarily
-- shown yet at the moment MAIL_SHOW fires.
function A:EnsureMailTriggerButton()
  if not MailFrame then return nil end

  if not A.mailTriggerButton then
    local button = CreateFrame("Button", "AutoMailerMailButton", UIParent, "UIPanelButtonTemplate")
    button:SetSize(140, 24)
    button:SetText(L["Send Mail"])
    button:SetScript("OnClick", function()
      A:StartMailSend()
    end)
    A.mailTriggerButton = button
  end

  if not A.mailFrameHooked then
    MailFrame:HookScript("OnHide", function()
      A:HideMailTriggerButton()
    end)
    A.mailFrameHooked = true
  end

  A.mailTriggerButton:ClearAllPoints()
  A.mailTriggerButton:SetPoint("TOP", MailFrame, "TOP", 0, 30)
  A.mailTriggerButton:SetFrameStrata(MailFrame:GetFrameStrata())
  A.mailTriggerButton:SetFrameLevel(MailFrame:GetFrameLevel() + 5)

  return A.mailTriggerButton
end

function A:HideMailTriggerButton()
  if A.mailTriggerButton then
    A.mailTriggerButton:Hide()
  end
end

-- Switches the mail frame to the "Send Mail" tab. SetSendMailShowing is not
-- a real Blizzard API function (it doesn't exist in the current client) -
-- clicking the tab button is the correct, documented way to do this.
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

  -- A queue is built against the bags as they are right now, so a second one
  -- built while the first is still waiting to be accepted would be answering
  -- for slots the first run is about to empty.
  if A.pendingConfirmation then
    A:Print(L["A send is already waiting on the gold confirmation."])
    return
  end

  A:Log("StartMailSend invoked")

  local recipient = A.db.recipient or ""
  local boeRecipient = A.db.boeRecipient or ""

  -- Rules can name their own recipient, so a blank default is not on its own
  -- an unconfigured profile. This guard used to check only the two boxes on
  -- the panels and refuse to build the queue, which meant a perfectly valid
  -- rules-only setup never got the chance to match anything.
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

  -- Items can be mailed back; gold above a threshold is the one part of a run
  -- that's genuinely awkward to undo, so it gets a confirmation by default.
  -- Item-only runs stay a single click, exactly as before.
  local summary = A:SummarizeQueue(queue)

  -- A soft nudge, not a confirmation: mailing outside the account is
  -- legitimate, so this never blocks the run, only names what's unfamiliar
  -- before it goes out. Checked here rather than per-batch so it prints once
  -- per run regardless of which path below sends it. See #26.
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

  -- No "v" prefix here: the TOC version comes from the release tag, which
  -- already carries one.
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
  How long to keep watching for a split-off stack to actually appear in the
  bag slot it was moved into, and how often to look.

  Moving an item between bag slots is a server round trip, not a local edit:
  the slot reads back empty for a while after SplitContainerItem and the
  placement that follows it. Three fixes for #81 failed on exactly this -
  checking immediately, and checking one frame later via C_Timer.After(0) -
  and read "still empty" as "the API doesn't work" rather than "not yet".

  So this polls for the slot to actually hold what was put there, the same
  way A:OnMailSuccess polls for GetMoney() to actually move rather than
  guessing a delay.

  The budget is deliberately far wider than what a healthy round trip needs:
  a live split was measured landing after 12 checks (~1.2s), so a cap near
  that would turn ordinary lag into skipped items. This is a backstop for a
  move that is never coming, not a latency budget - the same reasoning as
  SEND_CONFIRM_TIMEOUT above, and it stays well inside that 20s watchdog so a
  stuck split still ends the run cleanly rather than racing it.
]]
local SPLIT_SETTLE_INTERVAL = 0.1
local SPLIT_SETTLE_ATTEMPTS = 100

-- Somewhere ordinary for a split-off partial stack to land. Only the ordinary
-- bags: this needs one free slot and those are what the rest of this file
-- already scans.
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
  Attaches a single bag item to the given send-mail attachment slot using the
  real Blizzard attach flow: pick the item up onto the cursor, then click the
  attachment slot to drop it in. Reports to callback(attached, retainViolated)
  and logs the outcome at every step so a failure can be pinpointed from chat.

  count is what the queue decided should ship, which a rule's Retain count
  (#78) can trim below the slot's actual stack size. Attaching straight from a
  cursor holding a freshly split stack does NOT work - confirmed live against
  GetSendMailItem, which reported the whole pre-split stack as attached (#81).
  The mail attachment button appears to resolve back to the source bag slot
  rather than taking what the cursor holds.

  What does work is making the partial stack an ordinary, settled stack of its
  own first: split it off into a free bag slot, wait for it to actually land
  there, and then attach that slot the completely ordinary way. The waiting is
  the part earlier attempts got wrong (see SPLIT_SETTLE_* above) - the slot
  reads empty for a while, and giving up on the first look reads a slow move
  as a failed one.

  Callback-based rather than returning a boolean precisely because of that
  wait: the split path can only answer several frames later.
]]
function A:AttachItemToMail(bag, slot, attachIndex, itemLink, count, callback)
  A:Log("Attach start: bag=", bag, "slot=", slot, "attachIndex=", attachIndex, "item=", itemLink or "<unknown>",
      "count=", count or "<all>")

  -- A queue isn't always consumed the instant it's built - a confirmation
  -- dialog can sit in between, and earlier mails in the same run move items
  -- around - so re-check that this slot still holds what was queued instead
  -- of blindly picking up whatever happens to be there now.
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

  -- Everything from "the cursor holds what should go out" onwards, shared by
  -- the plain and split paths. Verifies what the mail form says it actually
  -- took: a Retain trim that silently attached more than it should is the
  -- original bug, so it is reported rather than sent.
  local function attachFromCursor()
    if not A:CursorHasItem() then
      A:Log("Pickup failed: cursor is empty after pickup for", itemLink or "<unknown>")
      callback(false)
      return
    end

    A:AttachToSlot(attachIndex)

    -- GetSendMailItem's 4th return is the attached quantity - confirmed live
    -- against real output (#81), not assumed.
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

  -- The excess-gold batch defers its money amount to here (see BuildMailQueue)
  -- since postage isn't a flat fee and can't be predicted upfront. GetSendMailPrice()
  -- only reports the real postage once the form actually has a recipient on it -
  -- queried against a still-blank form (as this used to, right after ClearSendMail(),
  -- before the recipient above was set) it under-reports, landing the balance short
  -- by one postage's worth once the mail actually sends. Querying it now, with the
  -- recipient already set and before any items get attached below (0 items for this
  -- batch), reflects this specific mail's real postage. Must happen before
  -- GetBatchSubject below, which depends on batch.money to pick the "Gold" subject.
  if batch.goldThresholdCopper then
    local postage = A:GetSendMailPrice()
    batch.money = A:ExcessGoldToSend(A:GetMoney(), batch.goldThresholdCopper, postage)
    A:Log("Resolved excess gold at send time: postage=", postage, "money=", batch.money)
  end

  local subject = A:GetBatchSubject(batch)
  A:SetSendSubject(subject)

  local money = batch.money or 0
  A:SetSendMoney(money)

  -- What this mail would add to the /am list tally, held on the batch rather
  -- than folded straight in: attaching an item is not the same as sending it,
  -- and a batch that fails from here on never went anywhere. A:CommitSentItems
  -- applies this when MAIL_SUCCESS says the mail is really away.
  local pendingSent = {}
  local attachedCount = 0

  -- Attaches batch.items one at a time via callback rather than a plain loop
  -- with a boolean return: a Retain violation (#78/#81) needs to abort the
  -- rest of THIS batch outright (pull everything back out of the send form)
  -- rather than just skip the one item, which a simple per-item loop can't
  -- express cleanly partway through.
  local function attachNext(i)
    local item = batch.items[i]
    if not item then
      A:FinishSendMailBatch(batch, subject, money, attachedCount, pendingSent)
      return
    end

    A:AttachItemToMail(item.bag, item.slot, i, item.itemLink, item.count, function(attached, retainViolated)
      -- A Retain rule needed a partial stack that this client won't actually
      -- split (#81) - pull everything this batch has attached so far back
      -- into the bags and skip the whole batch rather than send the excess.
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
        -- By stack size, not by attachment: an attachment is one slot, which
        -- for most of what this addon mails is a stack of a couple hundred.
        -- The tally counted attachments, so a full stack of Linen Cloth read
        -- "Linen Cloth x1".
        pendingSent[itemName] = (pendingSent[itemName] or 0) + (item.count or 1)
      end
      attachNext(i + 1)
    end)
  end

  attachNext(1)
end

-- The rest of what SendMailBatch used to do inline once every item in the
-- batch has had an attach attempt: decide whether there was anything to send,
-- and either hand off to SendMail or skip the batch. Split out because
-- A:SendMailBatch's own attach loop is callback-driven (see attachNext above)
-- and this only runs once that recursion bottoms out.
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
  -- MAIL_SUCCESS confirms the mail queued server-side, but GetMoney() doesn't
  -- necessarily reflect this mail's postage the instant that event fires -
  -- recorded here so MAIL_SUCCESS can confirm the balance actually moved
  -- before letting the next batch (e.g. an excess-gold batch reading GetMoney()
  -- to compute its amount) proceed. See A:OnMailSuccess for why.
  A.moneyBeforeSend = A:GetMoney()
  A:ArmSendWatchdog()
  A:CommitSend(batch.recipient, subject)
  A.mailsSent = A.mailsSent + 1

  -- Three cases, not two: the excess-gold batch carries no items at all, and
  -- announcing "Sent 0 item(s) and 3306g to Siannodel" made the interesting
  -- half of the sentence share billing with a zero. A mixed mail is only
  -- theoretical today - BuildMailQueue gives the gold batch an empty item list
  -- - but the branch stays honest rather than assuming that holds.
  if attachedCount > 0 and money > 0 then
    A:Print(string.format(L["Sent %d item(s) and %s to %s"],
        attachedCount, GetCoinTextureString(money), batch.recipient))
  elseif money > 0 then
    A:Print(string.format(L["Sent %s to %s"], GetCoinTextureString(money), batch.recipient))
  else
    A:Print(string.format(L["Sent %d item(s) to %s"], attachedCount, batch.recipient))
  end
end

-- Folds a confirmed mail's contents into the session tally /am list reads.
function A:CommitSentItems(batch)
  if not batch or not batch.pendingSent then return end

  A.itemsSent = A.itemsSent or {}
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

  -- This is the first point at which the mail is known to have gone, so it is
  -- where its contents join the tally.
  A:CommitSentItems(A.mailQueue and A.mailQueue[A.mailQueueIndex])

  -- GetMoney() doesn't necessarily update the instant MAIL_SUCCESS fires -
  -- this mail's postage lands on the client's money value with a variable
  -- delay (network latency dependent). A fixed 0.3s wait here used to just
  -- guess that delay was over; when it wasn't, the next batch's excess-gold
  -- math (see BuildMailQueue/SendMailBatch) read a stale, too-high GetMoney()
  -- that still hadn't subtracted this mail's postage, silently landing the
  -- final balance short by exactly that postage amount. Poll for the actual
  -- change instead of guessing, with a generous fallback so a run can't stall
  -- forever if postage was somehow already reflected before this ran.
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
