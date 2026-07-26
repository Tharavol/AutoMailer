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
  Entry point: event registration and slash commands. Every handler here is a
  thin delegation to the module that owns the behavior (Profile, MailQueue,
  Send, OptionsPanel), so this file stays a map of what the addon reacts to.
]]

local _, A = ...

local E = CreateFrame("Frame")
E:RegisterEvent("ADDON_LOADED")
E:RegisterEvent("PLAYER_ENTERING_WORLD")
E:RegisterEvent("MAIL_SHOW")
E:RegisterEvent("MAIL_CLOSED")
E:RegisterEvent("MAIL_INBOX_UPDATE")
E:RegisterEvent("MAIL_SUCCESS")
E:RegisterEvent("MAIL_FAILED")

E:SetScript("OnEvent", function(self, event, ...)
  return self[event] and self[event](self, ...)
end)

function E:ADDON_LOADED(name)
  if name ~= "AutoMailer" then return end

  A:InitializeSavedVariables()

  -- Populated lazily per recipient as mail actually goes out; /am list reads it.
  A.itemsSent = {}

  SLASH_AUTOMAILER1 = "/automailer"
  SLASH_AUTOMAILER2 = "/am"
  SlashCmdList.AUTOMAILER = function(msg)
    A:SlashCommand(msg)
  end

  A.CreateOptionsMenu()
  A.loaded = true
end

function E:PLAYER_ENTERING_WORLD(login, reloadUI)
  if (login or reloadUI) and AutoMailer.loginMessage and A.loaded then
    print(A.addonName .. "loaded")
  end
end

function E:MAIL_SHOW()
  -- On the mailbox's first open in a session, Blizzard_MailFrame can still be
  -- loading when this event reaches us, so MailFrame doesn't exist yet.
  -- EnsureMailTriggerButton silently no-ops in that case; retry next frame
  -- instead of permanently missing this open (every later open works fine
  -- since Blizzard_MailFrame is already loaded by then).
  if not MailFrame then
    A:Log("MAIL_SHOW: MailFrame not ready yet, retrying next frame")
    C_Timer.After(0, function()
      E:MAIL_SHOW()
    end)
    return
  end

  A:EnsureMailTriggerButton()
  A.mailTriggerButton:Show()

  -- Shift is a heavily-used modifier and this kicks off a full run - including
  -- mailing gold - before you've had a chance to look at anything, so it's now
  -- off unless explicitly enabled.
  if IsShiftKeyDown() and AutoMailer.autoSendOnShiftOpen then
    A:Log("MAIL_SHOW with shift held; auto-starting send")
    A:StartMailSend()
  end
end

function E:MAIL_CLOSED()
  A:Log("MAIL_CLOSED")
  A:HideMailTriggerButton()
  if A.sendingMail then
    A:Print("Mail frame closed while AutoMailer was still sending; stopping.")
  end
  A:ResetMailSendState()
end

function E:MAIL_INBOX_UPDATE()
  A:Log("MAIL_INBOX_UPDATE")
end

function E:MAIL_SUCCESS(mailID)
  A:OnMailSuccess(mailID)
end

function E:MAIL_FAILED()
  A:OnMailFailed()
end

local function PrintSentSummary()
  local printedAnything = false

  for recipient, items in pairs(A.itemsSent) do
    local line = ""
    for itemName, count in pairs(items) do
      if #line > 0 then
        line = line .. ", " .. itemName .. "x" .. count
      else
        line = itemName .. "x" .. count
      end
    end

    if #line > 0 then
      A:Print("Items sent to " .. recipient)
      print(line)
      printedAnything = true
    end
  end

  if not printedAnything then
    A:Print("Nothing sent this session.")
  end
end

local function OpenOptions()
  if A.optionsPanel and A.optionsPanel.category and Settings and Settings.OpenToCategory then
    local categoryID = A.optionsPanel.category.ID
    Settings.OpenToCategory(categoryID or A.optionsPanel.category)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
  end
  OpenAllBags()
end

function A:SlashCommand(args)
  local command = strsplit(" ", args, 1):lower()

  if command == "list" then
    PrintSentSummary()
  elseif command == "debug" then
    AutoMailer.debugLogging = not AutoMailer.debugLogging
    A:Print("Debug logging " .. (AutoMailer.debugLogging and "enabled" or "disabled") .. ".")
  else
    OpenOptions()
  end
end
