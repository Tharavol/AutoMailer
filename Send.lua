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

  A:Log("StartMailSend invoked")

  local recipient = A.db.recipient or ""
  local boeRecipient = A.db.boeRecipient or ""

  if #recipient == 0 and #boeRecipient == 0 then
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
  if summary.goldCopper > 0 and A.db.confirmGoldSends then
    A:Log("Awaiting confirmation for a run including roughly", summary.goldCopper, "copper")
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
    A:Print(string.format(L["AutoMailer finished: sent %d mail(s)."], A.mailQueueIndex - 1))
    A:ResetMailSendState()
    return
  end

  A:Log("Processing batch", A.mailQueueIndex, "/", #A.mailQueue, "recipient=", batch.recipient, "items=", #batch.items)
  A:SendMailBatch(batch)
end

-- Attaches a single bag item to the given send-mail attachment slot using
-- the real Blizzard attach flow: pick the item up onto the cursor, then
-- click the attachment slot to drop it in. Returns true/false and logs the
-- outcome at every step so a failure can be pinpointed from the chat log.
function A:AttachItemToMail(bag, slot, attachIndex, itemLink)
  A:Log("Attach start: bag=", bag, "slot=", slot, "attachIndex=", attachIndex, "item=", itemLink or "<unknown>")

  -- A queue isn't always consumed the instant it's built - a confirmation
  -- dialog can sit in between, and earlier mails in the same run move items
  -- around - so re-check that this slot still holds what was queued instead
  -- of blindly picking up whatever happens to be there now.
  local _, _, _, _, _, _, currentLink = A:GetContainerItemInfo(bag, slot)
  if currentLink ~= itemLink then
    A:Log("Slot changed since the queue was built: expected", itemLink or "<unknown>",
        "but found", currentLink or "<empty>", "- skipping")
    return false
  end

  if CursorHasItem() then
    A:Log("Cursor already held an item before pickup; clearing it")
    ClearCursor()
  end

  C_Container.PickupContainerItem(bag, slot)

  if not CursorHasItem() then
    A:Log("Pickup failed: cursor is empty after PickupContainerItem for", itemLink or "<unknown>")
    return false
  end

  ClickSendMailItemButton(attachIndex)

  local attachedName = GetSendMailItem(attachIndex)
  if not attachedName then
    A:Log("Attach verification failed at index", attachIndex, "for", itemLink or "<unknown>")
    if CursorHasItem() then
      ClearCursor()
    end
    return false
  end

  A:Log("Attached", attachedName, "at index", attachIndex)
  return true
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

  ClearSendMail()

  SendMailNameEditBox:SetText(batch.recipient)
  SendMailNameEditBox:SetCursorPosition(0)

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
  SendMailSubjectEditBox:SetText(subject)
  SendMailSubjectEditBox:SetCursorPosition(0)

  -- Money isn't a SendMail() argument. MoneyInputFrame_SetCopper only updates
  -- the SendMailMoney editbox's displayed text - the actual amount staged for
  -- SendMail() is only committed when Blizzard's own send-mail button handler
  -- reads that editbox and calls SetSendMailMoney(). Since we call SendMail()
  -- directly and skip that handler, we must call SetSendMailMoney() ourselves
  -- or the mail goes out with no gold attached.
  local money = batch.money or 0
  if MoneyInputFrame_SetCopper and SendMailMoney then
    MoneyInputFrame_SetCopper(SendMailMoney, money)
  end
  if SetSendMailMoney then
    SetSendMailMoney(money)
  end

  A.itemsSent[batch.recipient] = A.itemsSent[batch.recipient] or {}

  local attachedCount = 0
  for i, item in ipairs(batch.items) do
    if A:AttachItemToMail(item.bag, item.slot, i, item.itemLink) then
      attachedCount = attachedCount + 1
      local itemName = A:GetItemInfo(item.itemLink) or item.itemLink
      A.itemsSent[batch.recipient][itemName] = (A.itemsSent[batch.recipient][itemName] or 0) + 1
    end
  end

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
  SendMail(batch.recipient, subject, "")

  if money > 0 then
    A:Print(string.format(L["Sent %d item(s) and %s to %s"],
        attachedCount, GetCoinTextureString(money), batch.recipient))
  else
    A:Print(string.format(L["Sent %d item(s) to %s"], attachedCount, batch.recipient))
  end
end

function A:OnMailSuccess(mailID)
  A:Log("MAIL_SUCCESS mailID=", mailID)
  A.awaitConfirmSent = false
  if not A.sendingMail then return end

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
