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

-- Entry point: event registration and slash commands, each delegating to the
-- module that owns the behaviour.

local _, A = ...

local L = A.L

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

  SLASH_AUTOMAILER1 = "/automailer"
  SLASH_AUTOMAILER2 = "/am"
  SlashCmdList.AUTOMAILER = function(msg)
    A:SlashCommand(msg)
  end

  A.CreateOptionsMenu()
  A.loaded = true
end

function E:PLAYER_ENTERING_WORLD(login, reloadUI)
  if login or reloadUI then
    -- Roster for the unfamiliar-recipient warning (#26); independent of the
    -- login message setting.
    A:RecordKnownCharacter(A:GetPlayerName(), A:GetRealmName())
  end

  if (login or reloadUI) and A.meta.loginMessage and A.loaded then
    -- No "v" prefix: the release tag already carries one.
    print(A.addonName .. string.format(L["%s loaded"], A:GetVersion()))
  end
end

-- Frames to wait for Blizzard_MailFrame before giving up (it normally loads
-- within one or two).
local MAIL_FRAME_WAIT_FRAMES = 20

function E:MAIL_SHOW(attempt)
  -- On the first open of a session Blizzard_MailFrame may still be loading,
  -- so MailFrame can be nil here; retry next frame.
  if not MailFrame then
    attempt = (attempt or 0) + 1
    if attempt > MAIL_FRAME_WAIT_FRAMES then
      A:Log("MAIL_SHOW: MailFrame still missing after", MAIL_FRAME_WAIT_FRAMES, "frames; giving up")
      return
    end
    A:Log("MAIL_SHOW: MailFrame not ready yet, retrying next frame")
    C_Timer.After(0, function()
      E:MAIL_SHOW(attempt)
    end)
    return
  end

  local triggerButton = A:EnsureMailTriggerButton()
  if triggerButton then
    triggerButton:Show()
  end

  -- Opt-in: this starts a full run, gold included, before anything is shown.
  if IsShiftKeyDown() and A.meta.autoSendOnShiftOpen then
    A:Log("MAIL_SHOW with shift held; auto-starting send")
    A:StartMailSend()
  end
end

function E:MAIL_CLOSED()
  A:Log("MAIL_CLOSED")
  A:HideMailTriggerButton()
  if A.sendingMail then
    A:Print(L["Mail frame closed while AutoMailer was still sending; stopping."])
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
    local parts = {}
    for itemName, count in pairs(items) do
      tinsert(parts, string.format(L["%s x%d"], itemName, count))
    end
    -- Not a translation key: a key-is-the-text scheme can't express ", ".
    local line = table.concat(parts, ", ")

    if #line > 0 then
      A:Print(string.format(L["Items sent to %s"], recipient))
      print(line)
      printedAnything = true
    end
  end

  if not printedAnything then
    A:Print(L["Nothing sent this session."])
  end
end

local function OpenOptions()
  Settings.OpenToCategory(A.optionsPanel.category:GetID())
  OpenAllBags()
end

-- Bare toggles and reports the new state; explicit on/off sets it; anything
-- else is rejected instead of silently doing nothing (S8/S12).
local function HandleDebug(rest)
  local value = rest and rest:match("^%s*(.-)%s*$")
  if value == "" then value = nil end
  value = value and value:lower()

  if value == "on" then
    A.meta.debugLogging = true
  elseif value == "off" then
    A.meta.debugLogging = false
  elseif value == nil then
    A.meta.debugLogging = not A.meta.debugLogging
  else
    A:Print(string.format(L["'%s' - expected 'on' or 'off'."], value))
    return
  end
  -- Whole sentences, so languages that inflect the adjective can translate them.
  A:Print(A.meta.debugLogging and L["Debug logging enabled."] or L["Debug logging disabled."])
end

local function PrintStatus()
  A:Print(string.format(L["Version: %s"], A:GetVersion()))
  print(string.format(L["Profile: %s"], A.meta.useGlobalProfile and L["global"] or L["per-character"]))
  print(string.format(L["Recipient: %s"], A.db.recipient ~= "" and A.db.recipient or L["(none)"]))
  print(string.format(L["Send crafting reagents: %s"], A.db.sendReagents and L["on"] or L["off"]))
  print(string.format(L["Send excess gold above %d: %s"], A.db.goldThreshold,
      A.db.sendExcessGold and L["on"] or L["off"]))
  print(string.format(L["Login message: %s"], A.meta.loginMessage and L["on"] or L["off"]))
  print(string.format(L["Debug logging: %s"], A.meta.debugLogging and L["on"] or L["off"]))
end

-- Restores addon-level preferences to defaults. Deliberately leaves the mailing
-- profile (recipients, rules, gold threshold) alone.
local function HandleReset()
  for key, value in pairs(A:DefaultMeta()) do
    A.meta[key] = value
  end
  A:Print(L["Settings restored to defaults."])
end

-- { name, help, handler }: help is derived from the dispatch table (S13).
-- "", "config" and "gui" are silent aliases of "options" (S5).
local COMMANDS
local function PrintHelp()
  A:Print(L["Commands:"])
  for _, entry in ipairs(COMMANDS) do
    for _, line in ipairs(entry.help) do
      print(line)
    end
  end
end

COMMANDS = {
  {name = "", help = {}, handler = OpenOptions},
  {
    name = "options",
    help = {L["/am, /am options, /am config, /am gui - open the options panel"]},
    handler = OpenOptions
  },
  {name = "config", help = {}, handler = OpenOptions},
  {name = "gui", help = {}, handler = OpenOptions},
  {name = "list", help = {L["/am list - recap what has been sent this session"]}, handler = PrintSentSummary},
  {name = "debug", help = {L["/am debug [on|off] - toggle or set debug logging"]}, handler = HandleDebug},
  {name = "status", help = {L["/am status - show current settings"]}, handler = PrintStatus},
  {
    name = "version",
    help = {L["/am version - show the addon version"]},
    handler = function() A:Print(string.format(L["Version: %s"], A:GetVersion())) end
  },
  {name = "reset", help = {L["/am reset - restore settings to defaults"]}, handler = HandleReset}
}

COMMANDS[#COMMANDS + 1] = {name = "help", help = {L["/am help - show this list"]}, handler = PrintHelp}

function A:SlashCommand(args)
  local command, rest = strsplit(" ", args or "", 2)
  -- Only the command word is lowercased (S11); `rest` is passed through as typed.
  command = command and command:lower() or ""

  for _, entry in ipairs(COMMANDS) do
    if entry.name == command then
      entry.handler(rest)
      return
    end
  end

  -- Unknown commands are reported, never treated as "options" (S4).
  A:Print(string.format(L["Unknown command: %s"], command))
  PrintHelp()
end
