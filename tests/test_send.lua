-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

--[[
  Covers the send watchdog: the backstop that ends a run when the server never
  answers a SendMail with MAIL_SUCCESS or MAIL_FAILED.

  Send.lua as a whole still reaches for the mail-form globals directly and so
  can't be driven end to end offline yet (see the Core mail-form seam issue).
  The watchdog is reachable now because it only needs C_Timer plus the addon's
  own state, so it gets tests now rather than after that refactor.

  C_Timer is faked rather than waited on: callbacks are collected and fired by
  hand, which is what makes "did the stale timer stay quiet?" an assertion
  instead of a twenty-second sleep.
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
  -- forward one hop at a time.
  local function FireTimers()
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

return true
