-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

--[[
  Covers the send state machine: the watchdog that ends a run the server never
  answers, and what a run reports once it has worked through its queue.

  C_Timer is faked rather than waited on: callbacks are collected and fired by
  hand, which is what makes "did the stale timer stay quiet?" an assertion
  instead of a twenty-second sleep.

  Send.lua drives the mail form entirely through the Core seam
  (A:ClearSendForm, A:SetSendRecipient, A:AttachToSlot, A:CommitSend, etc.),
  so InstallFakeMailForm below fakes at that boundary instead of standing up
  the underlying WoW globals. That is what lets a whole run be driven here:
  the sent tally, the mails-sent count and the per-mail chat line all live
  past the point where Send.lua touches the seam.
]]

local Testkit = require("tests.testkit")

local function NewSendAddon()
  local A = Testkit.NewAddonTable()

  -- Send.lua registers a StaticPopup and reads YES/NO at load time.
  _G.StaticPopupDialogs = {}
  _G.YES = "Yes"
  _G.NO = "No"

  local timers = {}
  _G.C_Timer = {
    After = function(delay, fn)
      tinsert(timers, { delay = delay, fn = fn })
    end,
  }

  -- Fires every timer pending at the moment of the call. Timers registered by
  -- those callbacks are left for the next call, so a test can step the run
  -- forward one hop at a time. Also advances any in-flight bag move (see
  -- A.TickBagPlacement), so a hop of fake time moves the bags as well as the
  -- timers - which is what lets the split-settle poll in A:AttachItemToMail
  -- actually be exercised here.
  local function FireTimers()
    if A.TickBagPlacement then A.TickBagPlacement() end
    local due = timers
    timers = {}
    for _, timer in ipairs(due) do
      timer.fn()
    end
    return #due
  end

  Testkit.LoadModule("Locale.lua", A)
  Testkit.LoadModule("Core.lua", A)
  Testkit.LoadModule("Profile.lua", A)
  Testkit.LoadModule("MailQueue.lua", A)
  Testkit.LoadModule("Send.lua", A)

  A.printed = {}
  function A:Print(...) tinsert(A.printed, table.concat({ ... }, " ")) end
  function A:Log() end
  function A:GetMoney() return 0 end

  A.FireTimers = FireTimers
  A.PendingTimers = function() return #timers end

  -- The state SendMailBatch leaves behind at the moment it hands off to
  -- SendMail: a run in progress, this batch unconfirmed, watchdog armed.
  function A:SimulateSendHandoff()
    A.sendingMail = true
    A.awaitConfirmSent = true
    A:ArmSendWatchdog()
  end

  function A:PrintedContains(text)
    for _, line in ipairs(A.printed) do
      if line:find(text, 1, true) then return true end
    end
    return false
  end

  return A
end

--[[
  Stands the mail form up in front of an addon from NewSendAddon: the Core
  seam SendMailBatch drives (A:ClearSendForm, A:SetSendRecipient, ...), the
  bags behind it, and enough of a cursor for the real attach flow (pick the
  item up, click the attachment slot) to work.

  Bags are given as bags[bag][slot] = { itemLink, name, count }. A batch item
  pointing at a slot that holds something else - or nothing - fails to attach,
  which is how the "couldn't attach anything" path gets exercised.

  Sending deducts postage from the balance, because A:OnMailSuccess waits for
  GetMoney to actually move before starting the next batch. A fake that held
  the balance still would park every run in that poll loop.
]]
local function InstallFakeMailForm(A, opts)
  opts = opts or {}
  local bags = opts.bags or {}
  local names = opts.names or {}
  local postage = opts.postage or 30

  local form = {
    sent = {},          -- one entry per A:CommitSend call
    popups = {},        -- one entry per StaticPopup_Show call
    attachments = {},
    balance = opts.money or 0,
  }

  local staged = 0
  local cursor = nil

  A.itemsSent = {}

  function A:GetContainerNumSlots(bag)
    return bags[bag] and #bags[bag] or 0
  end

  function A:GetContainerItemInfo(bag, slot)
    local entry = bags[bag] and bags[bag][slot]
    if not entry then return nil end
    return nil, entry.count or 1, false, 1, false, false, entry.itemLink
  end

  function A:ItemIsSoulbound() return false end
  function A:GetItemInfo(itemLink) return names[itemLink] or itemLink end
  function A:GetItemIDFromLink(itemLink) return nil end
  function A:IsCurrentCharacter(recipient) return recipient == "CurrentToon" end
  function A:GetMoney() return form.balance end
  function A:GetSendMailPrice() return postage end

  -- A:IsDebugLogging reads this; pinned so a run here doesn't inherit whatever
  -- another test file happened to leave behind.
  _G.AutoMailer = { debugLogging = false }

  _G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
  _G.NUM_BAG_SLOTS = opts.numBagSlots or 0
  _G.REAGENTBAG_CONTAINER = 5
  _G.GetCoinTextureString = function(copper) return copper .. "c" end

  _G.MailFrame = { IsShown = function() return true end }
  _G.MailFrameTab2 = { Click = function() end }

  function A:ClearSendForm()
    form.attachments = {}
    staged = 0
  end

  function A:SetSendRecipient() end
  function A:SetSendSubject() end
  function A:SetSendMoney(copper) staged = copper or 0 end

  function A:CursorHasItem() return cursor ~= nil end
  function A:ClearCursor() cursor = nil end

  --[[
    Placing an item into a bag slot does not take effect immediately: on the
    real client it's a server round trip, and reading the slot back too early
    shows it still empty. Three attempts at #81 failed by treating that as a
    broken API rather than an unfinished move, so the fake models the delay
    explicitly - opts.splitSettleTicks says how many FireTimers() hops the
    move takes to land (default 3, 0 for instant).

    A:PickupContainerItem mirrors the real toggle: with an empty cursor it
    picks a slot up, with a full cursor it places into that slot.
  ]]
  local settleTicks = opts.splitSettleTicks or 3
  local pendingPlacement = nil

  function A:PickupContainerItem(bag, slot)
    if cursor then
      local placing = cursor
      cursor = nil
      if settleTicks <= 0 then
        bags[bag] = bags[bag] or {}
        bags[bag][slot] = placing
        return
      end
      pendingPlacement = { bag = bag, slot = slot, entry = placing, ticksLeft = settleTicks }
      return
    end
    cursor = bags[bag] and bags[bag][slot] or nil
  end

  -- Advances any in-flight bag move by one hop. Driven from the fake C_Timer
  -- so a test only has to call A.FireTimers() to let a placement land.
  A.TickBagPlacement = function()
    if not pendingPlacement then return end
    pendingPlacement.ticksLeft = pendingPlacement.ticksLeft - 1
    if pendingPlacement.ticksLeft > 0 then return end
    local p = pendingPlacement
    pendingPlacement = nil
    bags[p.bag] = bags[p.bag] or {}
    bags[p.bag][p.slot] = p.entry
  end

  -- Mirrors the real API: takes count off the slot's stack onto the cursor,
  -- leaving the remainder behind, rather than lifting the whole stack the way
  -- A:PickupContainerItem does (#81).
  function A:SplitContainerItem(bag, slot, count)
    local entry = bags[bag] and bags[bag][slot]
    if not entry then return end
    cursor = { itemLink = entry.itemLink, name = entry.name, count = count }
    entry.count = (entry.count or 0) - count
  end

  function A:AttachToSlot(index)
    if cursor then
      form.attachments[index] = cursor
      cursor = nil
    end
  end

  -- The 4th return is the attached quantity (#81: confirmed live against
  -- GetSendMailItem's real output). A plain pickup always attaches the
  -- slot's whole count, which is what lets a Retain mismatch be modeled here
  -- too: a batch item queued for less than the slot holds shows up attached
  -- for the full amount, same as it does on the real client.
  function A:GetAttachedItem(index)
    local entry = form.attachments[index]
    if not entry then return nil end
    return entry.name or entry.itemLink, entry.itemID, entry.texture, entry.count
  end

  function A:CommitSend(recipient, subject)
    local items = {}
    for _, entry in pairs(form.attachments) do
      tinsert(items, entry.itemLink)
    end
    tinsert(form.sent, {
      recipient = recipient,
      subject = subject,
      money = staged,
      itemCount = #items,
    })
    form.balance = form.balance - staged - postage
  end

  _G.StaticPopup_Show = function(name, text, _, data)
    tinsert(form.popups, { name = name, text = text, data = data })
    return {}
  end

  return form
end

-- Puts a hand-built batch in flight as the only entry in the queue, so
-- A:OnMailSuccess and A:OnMailFailed have something to confirm against.
local function SendSingleBatch(A, batch)
  A.mailQueue = { batch }
  A.mailQueueIndex = 1
  A.mailsSent = 0
  A.sendingMail = true
  A:SendMailBatch(batch)
end

Testkit.Test("the watchdog ends a run whose mail is never confirmed", function()
  local A = NewSendAddon()
  A:SimulateSendHandoff()

  Testkit.AssertEqual(A.PendingTimers(), 1, "handing off to SendMail should arm exactly one watchdog")
  A.FireTimers()

  Testkit.AssertEqual(A.sendingMail, false, "an unanswered send must not leave the run stuck")
  Testkit.AssertEqual(A.awaitConfirmSent, false)
  Testkit.AssertTrue(A:PrintedContains("No response from the server"),
      "the abort has to be visible in chat, not silent")
end)

-- The bug the whole change exists to prevent: before this, nothing read
-- awaitConfirmSent, so a run in this state stayed sendingMail = true forever
-- and every later click answered "already in progress".
Testkit.Test("a stuck run can be started again after the watchdog fires", function()
  local A = NewSendAddon()
  A:SimulateSendHandoff()
  A.FireTimers()

  Testkit.AssertEqual(A.sendingMail, false, "StartMailSend's re-entry guard must be clear again")
end)

Testkit.Test("MAIL_SUCCESS before the timeout keeps the watchdog quiet", function()
  local A = NewSendAddon()
  A.mailQueue = {}
  A.mailQueueIndex = 0
  A:SimulateSendHandoff()

  A:OnMailSuccess(1)
  Testkit.AssertEqual(A.awaitConfirmSent, false, "MAIL_SUCCESS clears the flag the watchdog checks")

  A.FireTimers()
  Testkit.AssertTrue(not A:PrintedContains("No response from the server"),
      "a confirmed mail must never be reported as unanswered")
end)

Testkit.Test("MAIL_FAILED before the timeout keeps the watchdog quiet", function()
  local A = NewSendAddon()
  A:SimulateSendHandoff()

  A:OnMailFailed()
  Testkit.AssertEqual(A.sendingMail, false)

  A.printed = {}
  A.FireTimers()
  Testkit.AssertTrue(not A:PrintedContains("No response from the server"),
      "MAIL_FAILED already ended the run; the watchdog must not report on top of it")
end)

-- Without the generation counter a watchdog armed for one batch would fire
-- into whatever batch happened to be in flight when its timeout elapsed.
Testkit.Test("a watchdog from an earlier batch does not abort a later one", function()
  local A = NewSendAddon()

  A:SimulateSendHandoff()          -- batch 1 armed
  A.awaitConfirmSent = false       -- batch 1 confirmed, as MAIL_SUCCESS does
  A.awaitConfirmSent = true        -- batch 2 handed off...
  A:ArmSendWatchdog()              -- ...and armed, while batch 1's timer is still pending

  A.printed = {}
  A.FireTimers()                   -- both timers come due together

  Testkit.AssertEqual(A.sendingMail, false, "batch 2 is genuinely unanswered, so the run should end")
  local aborts = 0
  for _, line in ipairs(A.printed) do
    if line:find("No response from the server", 1, true) then aborts = aborts + 1 end
  end
  Testkit.AssertEqual(aborts, 1, "the stale watchdog must stay silent; only batch 2's should report")
end)

Testkit.Test("a watchdog left over from a finished run cannot end the next one", function()
  local A = NewSendAddon()

  A:SimulateSendHandoff()
  A:ResetMailSendState()  -- e.g. the player closed the mailbox

  -- A fresh run starts before the old timer comes due.
  A.sendingMail = true
  A.awaitConfirmSent = true

  A.printed = {}
  A.FireTimers()

  Testkit.AssertEqual(A.sendingMail, true, "the new run must survive the previous run's timer")
  Testkit.AssertTrue(not A:PrintedContains("No response from the server"))
end)

--[[ what a run records and reports ]]

local function NewMailingAddon(opts)
  local A = NewSendAddon()
  local form = InstallFakeMailForm(A, opts)
  return A, form
end

local function ClothBags()
  return {
    bags = { [0] = { { itemLink = "item:2589", name = "Linen Cloth", count = 200 } } },
    names = { ["item:2589"] = "Linen Cloth" },
    money = 1000000,
  }
end

local function ClothBatch()
  return {
    recipient = "Bankalt",
    items = { { bag = 0, slot = 1, itemLink = "item:2589", count = 200 } },
  }
end

-- An attachment is a slot, and a slot is usually a stack. Counting attachments
-- made /am list report a full stack of cloth as "Linen Cloth x1".
Testkit.Test("the sent tally counts a stack by its size, not as one attachment", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())
  A:OnMailSuccess(1)

  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 200)
end)

--[[ Retain trims that need a partial stack (#78/#81) ]]

-- Bag 0 slot 2 is free, so the split has somewhere to land.
local function SplittableClothBags(overrides)
  local opts = {
    bags = { [0] = { { itemLink = "item:2589", name = "Linen Cloth", count = 200 }, false } },
    names = { ["item:2589"] = "Linen Cloth" },
    money = 1000000,
  }
  for key, value in pairs(overrides or {}) do opts[key] = value end
  return opts
end

local function RetainBatch()
  return { recipient = "Bankalt", items = { { bag = 0, slot = 1, itemLink = "item:2589", count = 150 } } }
end

-- Steps fake time forward until the batch has actually been handed to
-- SendMail, and no further: FireTimers fires every pending timer regardless of
-- its delay, so hops taken after the hand-off would also fire the 20-second
-- send watchdog and abort the very run the test is waiting on.
local function FireUntilSent(A, form, maxHops)
  for _ = 1, maxHops or 30 do
    if #form.sent > 0 then return end
    A.FireTimers()
  end
end

-- The whole point of #81: only the amount above Retain ships, and the rest
-- stays in the bags. The split is a server round trip, so this only completes
-- once the placement has actually landed - which the fake models as taking
-- several hops (see InstallFakeMailForm).
Testkit.Test("a Retain trim sends only the allowed amount once the split lands", function()
  local A, form = NewMailingAddon(SplittableClothBags())

  A:BeginMailRun({ RetainBatch() })
  Testkit.AssertEqual(#form.sent, 0, "nothing can be sent while the split is still in flight")

  FireUntilSent(A, form)
  A:OnMailSuccess(1)

  Testkit.AssertEqual(#form.sent, 1, "once the split lands the mail goes out")
  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 150,
      "only the queued 150 should ship, not the full 200 the slot held")

  local _, remaining = A:GetContainerItemInfo(0, 1)
  Testkit.AssertEqual(remaining, 50, "the other 50 must stay behind in the bag")
end)

-- The bug that made three earlier fixes look like API failures: giving up on
-- the first look, before the move has landed, and sending nothing.
Testkit.Test("a Retain trim waits for a slow split rather than giving up on it", function()
  local A, form = NewMailingAddon(SplittableClothBags({ splitSettleTicks = 12 }))

  A:BeginMailRun({ RetainBatch() })
  for _ = 1, 3 do A.FireTimers() end
  Testkit.AssertEqual(#form.sent, 0, "still in flight - the run must keep waiting, not abandon the item")

  FireUntilSent(A, form)
  A:OnMailSuccess(1)

  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 150,
      "a slow split must still ship exactly what Retain allows")
end)

-- The safety net: if the split genuinely never lands, the fallback is to send
-- nothing, never to fall back to attaching the whole stack.
Testkit.Test("a split that never lands skips the batch instead of over-sending", function()
  local A, form = NewMailingAddon(SplittableClothBags({ splitSettleTicks = math.huge }))

  A:BeginMailRun({ RetainBatch() })
  -- Runs until the poll gives up on its own rather than counting hops against
  -- SPLIT_SETTLE_ATTEMPTS, so widening that budget doesn't break this test.
  for _ = 1, 500 do
    if A:PrintedContains("Could not honor a Retain limit") then break end
    A.FireTimers()
  end

  Testkit.AssertEqual(#form.sent, 0, "a stuck split must never fall back to sending the whole stack")
  Testkit.AssertTrue(A:PrintedContains("Could not honor a Retain limit"))
  Testkit.AssertEqual(A.itemsSent["Bankalt"], nil, "nothing shipped, so nothing should be tallied")
end)

-- Same protection one level down: whatever the attach step does, the form is
-- asked what it really took, and more than Retain allows is never sent.
Testkit.Test("attaching more than Retain allows pulls the batch back", function()
  local A, form = NewMailingAddon(SplittableClothBags({ splitSettleTicks = 0 }))

  -- Stands in for the live client behavior that broke the first fix: whatever
  -- was put on the cursor, the form reports the whole pre-split stack.
  local realGetAttached = A.GetAttachedItem
  function A:GetAttachedItem(index)
    local name = realGetAttached(A, index)
    if not name then return nil end
    return name, nil, nil, 200
  end

  A:BeginMailRun({ RetainBatch() })
  for _ = 1, 5 do A.FireTimers() end

  Testkit.AssertEqual(#form.sent, 0, "an over-attached stack must block the send")
  Testkit.AssertTrue(A:PrintedContains("Could not honor a Retain limit"))
end)

Testkit.Test("a batch item queued for the full stack still uses a plain pickup", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())
  A:OnMailSuccess(1)

  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 200,
      "queuing the whole stack must still ship all of it")
end)

Testkit.Test("nothing joins the sent tally until the server confirms the mail", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())
  Testkit.AssertEqual(A.itemsSent["Bankalt"], nil,
      "the tally is written at attach time, before the mail is known to have gone")

  A:OnMailSuccess(1)
  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 200)
end)

-- The half of the bug that misreported: a batch could be attached, fail, and
-- still show up in /am list as delivered.
Testkit.Test("a mail that fails never reaches the sent tally", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())
  A:OnMailFailed()

  Testkit.AssertEqual(A.itemsSent["Bankalt"], nil, "a failed mail delivered nothing")
end)

Testkit.Test("a confirmed batch is only ever tallied once", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())
  local batch = A.mailQueue[1]
  A:CommitSentItems(batch)
  A:CommitSentItems(batch)

  Testkit.AssertEqual(A.itemsSent["Bankalt"]["Linen Cloth"], 200)
end)

Testkit.Test("the completion message counts mails sent, not queue positions", function()
  local A, form = NewMailingAddon(ClothBags())

  A:BeginMailRun({
    -- Bag 3 is empty, so this batch reaches SendMailBatch and attaches nothing.
    { recipient = "Ghost", items = { { bag = 3, slot = 1, itemLink = "item:2589", count = 1 } } },
    ClothBatch(),
  })

  A.FireTimers()      -- the short hop the skipped batch schedules before moving on
  A:OnMailSuccess(1)

  Testkit.AssertEqual(#form.sent, 1, "only one of the two batches had anything to send")
  Testkit.AssertTrue(A:PrintedContains("sent 1 mail(s)"),
      "a batch that sent nothing must not be counted as a mail that went out")
end)

Testkit.Test("a gold-only mail announces the gold and no item count", function()
  local A = NewMailingAddon({ money = 5000 })

  SendSingleBatch(A, { recipient = "Bankalt", items = {}, money = 1200 })

  Testkit.AssertTrue(A:PrintedContains("Sent 1200c to Bankalt"))
  Testkit.AssertTrue(not A:PrintedContains("item(s)"),
      "a gold batch never had items, so a count of zero is only noise")
end)

Testkit.Test("a mail carrying both items and gold still announces both", function()
  local A = NewMailingAddon(ClothBags())

  local batch = ClothBatch()
  batch.money = 1200
  SendSingleBatch(A, batch)

  Testkit.AssertTrue(A:PrintedContains("Sent 1 item(s) and 1200c to Bankalt"))
end)

Testkit.Test("an item-only mail announces the item count", function()
  local A = NewMailingAddon(ClothBags())

  SendSingleBatch(A, ClothBatch())

  Testkit.AssertTrue(A:PrintedContains("Sent 1 item(s) to Bankalt"))
end)

--[[ the confirmation re-entry guard ]]

-- sendingMail only goes up once the dialog is accepted, so before this the
-- trigger button was free to build a second queue against bags the first run
-- was about to empty, and stack a second dialog behind the first.
Testkit.Test("a second run cannot be queued while the gold confirmation is open", function()
  local A, form = NewMailingAddon({ money = 600000000 })

  A.db = A:DefaultProfile()
  A.db.recipient = "Bankalt"
  A.db.sendExcessGold = true
  A.db.confirmGoldSends = true
  A.db.goldThreshold = 1

  A:StartMailSend()
  Testkit.AssertEqual(#form.popups, 1, "a run with excess gold should ask first")

  A:StartMailSend()
  Testkit.AssertEqual(#form.popups, 1, "a second click must not stack a second confirmation")
  Testkit.AssertTrue(A:PrintedContains("already waiting on the gold confirmation"))

  -- OnHide is the single release point, so cancelling and dismissing with
  -- Escape free the guard the same way accepting does.
  StaticPopupDialogs["AUTOMAILER_CONFIRM_SEND"].OnHide()
  A:StartMailSend()
  Testkit.AssertEqual(#form.popups, 2, "a dismissed dialog must not block every later run")
end)

--[[ the pre-run "not seen on this account before" warning (#26) ]]

local function GoldOnlyRun(A)
  A.db = A:DefaultProfile()
  A.db.recipient = "Bankalt"
  A.db.sendExcessGold = true
  A.db.goldThreshold = 1
end

Testkit.Test("StartMailSend warns about a recipient not on the known-character roster", function()
  local A = NewMailingAddon({ money = 600000000 })
  _G.AutoMailerGlobal = { knownCharacters = { "Mainchar-TestRealm", "Otheralt-TestRealm" } }
  GoldOnlyRun(A)

  A:StartMailSend()

  Testkit.AssertTrue(A:PrintedContains("Bankalt"),
      "the pre-run warning should name the recipient that isn't on the roster")
  _G.AutoMailerGlobal = nil
end)

Testkit.Test("StartMailSend stays quiet about a recipient already on the roster", function()
  local A = NewMailingAddon({ money = 600000000 })
  _G.AutoMailerGlobal = { knownCharacters = { "Mainchar-TestRealm", "Bankalt-TestRealm" } }
  GoldOnlyRun(A)

  A:StartMailSend()

  Testkit.AssertTrue(not A:PrintedContains("not seen on this account before"))
  _G.AutoMailerGlobal = nil
end)

Testkit.Test("StartMailSend stays quiet during the roster warm-up", function()
  local A = NewMailingAddon({ money = 600000000 })
  _G.AutoMailerGlobal = { knownCharacters = { "Mainchar-TestRealm" } }
  GoldOnlyRun(A)

  A:StartMailSend()

  Testkit.AssertTrue(not A:PrintedContains("not seen on this account before"),
      "a roster with fewer than two entries hasn't confirmed anything is actually absent")
  _G.AutoMailerGlobal = nil
end)

Testkit.Test("StartMailSend never blocks a send over an unrecognized recipient", function()
  local A, form = NewMailingAddon({ money = 600000000 })
  _G.AutoMailerGlobal = { knownCharacters = { "Mainchar-TestRealm", "Otheralt-TestRealm" } }
  GoldOnlyRun(A)

  A:StartMailSend()

  Testkit.AssertEqual(#form.sent, 1, "the warning is a nudge, not a block - the mail must still go out")
  _G.AutoMailerGlobal = nil
end)

return true
