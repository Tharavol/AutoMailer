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
  if login or reloadUI then
    -- Builds the known-character roster A:IsKnownCharacter warns against
    -- (see #26) one login at a time; independent of the login message below,
    -- so it still runs with that setting off.
    A:RecordKnownCharacter(A:GetPlayerName(), A:GetRealmName())
  end

  if (login or reloadUI) and A.meta.loginMessage and A.loaded then
    -- No "v" prefix: the TOC version comes from the release tag, which already
    -- carries one (same reason as Send.lua's run banner).
    print(A.addonName .. string.format(L["%s loaded"], A:GetVersion()))
  end
end

-- How many frames to wait for Blizzard_MailFrame before giving up. It loads
-- within a frame or two in practice; the cap is only here so a client where it
-- never loads at all fails visibly instead of retrying forever.
local MAIL_FRAME_WAIT_FRAMES = 20

function E:MAIL_SHOW(attempt)
  -- On the mailbox's first open in a session, Blizzard_MailFrame can still be
  -- loading when this event reaches us, so MailFrame doesn't exist yet.
  -- EnsureMailTriggerButton silently no-ops in that case; retry next frame
  -- instead of permanently missing this open (every later open works fine
  -- since Blizzard_MailFrame is already loaded by then).
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

  -- Shift is a heavily-used modifier and this kicks off a full run - including
  -- mailing gold - before you've had a chance to look at anything, so it's now
  -- off unless explicitly enabled.
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
    -- Left as plain punctuation rather than a translation key: a key whose
    -- English value is ", " would fall back to the literal string ", " as its
    -- own name, which is exactly what the key-is-the-text scheme can't
    -- express. If a locale needs a different list separator, that is the point
    -- to introduce a real key for it.
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
  if A.optionsPanel and A.optionsPanel.category and Settings and Settings.OpenToCategory then
    local categoryID = A.optionsPanel.category.ID
    Settings.OpenToCategory(categoryID or A.optionsPanel.category)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
  end
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
  -- Two whole sentences rather than a stem plus an "enabled"/"disabled"
  -- fragment: languages that inflect the adjective can't translate the
  -- fragment without seeing the rest of the sentence.
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

-- Restores addon-level preferences (login message, debug logging, global
-- profile, auto-send-on-shift-open) to their defaults. Deliberately does not
-- touch the mailing profile (recipients, item rules, gold threshold) -- that
-- is configuration a user builds up over time, not a "setting" this command
-- means to wipe.
local function HandleReset()
  for key, value in pairs(A:DefaultMeta()) do
    A.meta[key] = value
  end
  A:Print(L["Settings restored to defaults."])
end

-- Table of { name, help, handler }, so the help list is derived from the same
-- data Dispatch matches against instead of a second hand-maintained block
-- that could drift out of sync (S13). "", "config" and "gui" are silent
-- aliases of "options" (S5): each opens the panel but carries no help text of
-- its own, so help doesn't repeat the same line four times.
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
  -- Only the command word is lowercased for matching (S11); `rest` is passed
  -- through untouched, and the one handler that matches a keyword inside it
  -- (debug's on/off) lowercases it itself at the point of comparison.
  command = command and command:lower() or ""

  for _, entry in ipairs(COMMANDS) do
    if entry.name == command then
      entry.handler(rest)
      return
    end
  end

  -- A typo must be visibly a typo, never a silent fallback to opening the
  -- options panel as though it had worked (S4).
  A:Print(string.format(L["Unknown command: %s"], command))
  PrintHelp()
end
