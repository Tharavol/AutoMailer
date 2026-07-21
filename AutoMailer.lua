local _, A = ...


-- ".. tostringall(...)" only keeps tostringall's FIRST return value, since
-- concatenation isn't a multi-result context - every argument after the
-- first was silently getting dropped. strjoin's last argument position is a
-- multi-result context, so all of them make it into the message.
function A:Print(...)
  DEFAULT_CHAT_FRAME:AddMessage(A.addonName .. "- " .. strjoin(" ", tostringall(...)))
end

function A:Log(...)
  if not AutoMailer or not AutoMailer.debugLogging then return end
  DEFAULT_CHAT_FRAME:AddMessage("|cff888888" .. A.addonName .. "Debug|r " .. strjoin(" ", tostringall(...)))
end

-- Fields in DefaultProfile are the "mailing profile": what gets duplicated
-- between the per-character AutoMailer table and the global AutoMailerGlobal
-- table, and swapped out wholesale by the "use global profile" option.
local function DefaultProfile()
  return {
    items = "",
    recipient = "",
    boeRecipient = "",
    boeRarityLimit = 4,
    SendBOE = false,
    LimitBoeLevel = false,
    limitBoeRarity = false,
    SendReagents = false,
    sendExcessGold = false,
    goldThreshold = 50000,
  }
end

-- Fields in DefaultMeta are addon-level preferences that always stay on the
-- per-character AutoMailer table, even when a global profile is active.
local function DefaultMeta()
  return {
    loginMessage = true,
    debugLogging = false,
    useGlobalProfile = true,
  }
end

local function SanitizeProfile(t)
  if type(t.items) ~= "string" then t.items = "" end
  if type(t.recipient) ~= "string" then t.recipient = "" end
  if type(t.boeRecipient) ~= "string" then t.boeRecipient = "" end
  if type(t.boeRarityLimit) ~= "number" then t.boeRarityLimit = 4 end
  if type(t.SendBOE) ~= "boolean" then t.SendBOE = false end
  if type(t.LimitBoeLevel) ~= "boolean" then t.LimitBoeLevel = false end
  if type(t.limitBoeRarity) ~= "boolean" then t.limitBoeRarity = false end
  if type(t.SendReagents) ~= "boolean" then t.SendReagents = false end
  if type(t.sendExcessGold) ~= "boolean" then t.sendExcessGold = false end
  if type(t.goldThreshold) ~= "number" then t.goldThreshold = 50000 end
end

-- Points at whichever profile table (per-character AutoMailer or global
-- AutoMailerGlobal) is currently active. All mailing-profile reads/writes
-- should go through A.db; meta prefs (logging, login message, the toggle
-- itself) always read/write AutoMailer directly.
function A:RefreshActiveProfile()
  A.db = AutoMailer.useGlobalProfile and AutoMailerGlobal or AutoMailer
end

function A:InitializeSavedVariables()
  AutoMailer = AutoMailer or {}
  if type(AutoMailer) ~= "table" then
    AutoMailer = {}
  end
  AutoMailerGlobal = AutoMailerGlobal or {}
  if type(AutoMailerGlobal) ~= "table" then
    AutoMailerGlobal = {}
  end

  local defaultMeta = DefaultMeta()
  for key, value in pairs(defaultMeta) do
    if AutoMailer[key] == nil then
      AutoMailer[key] = value
    end
  end

  local defaultProfile = DefaultProfile()
  for key, value in pairs(defaultProfile) do
    if AutoMailer[key] == nil then AutoMailer[key] = value end
    if AutoMailerGlobal[key] == nil then AutoMailerGlobal[key] = value end
  end

  if type(AutoMailer.loginMessage) ~= "boolean" then AutoMailer.loginMessage = true end
  if type(AutoMailer.debugLogging) ~= "boolean" then AutoMailer.debugLogging = true end
  if type(AutoMailer.useGlobalProfile) ~= "boolean" then AutoMailer.useGlobalProfile = false end

  SanitizeProfile(AutoMailer)
  SanitizeProfile(AutoMailerGlobal)

  A:RefreshActiveProfile()
end

function A:GetContainerNumSlots(bag)
  return C_Container.GetContainerNumSlots(bag)
end

function A:GetContainerItemInfo(bag, slot)
  local info = C_Container.GetContainerItemInfo(bag, slot)
  if not info then return nil end
  return info.iconFileID, info.stackCount, info.isLocked, info.quality, info.isReadable,
      info.hasLoot, info.hyperlink, info.isFiltered, info.noValue, info.itemID, info.isBound
end

function A:GetItemInfo(itemLink)
  return C_Item.GetItemInfo(itemLink)
end

A.TT = CreateFrame("GameTooltip", "AutoMailerTT", nil, "GameTooltipTemplate")
A.TT:SetOwner(WorldFrame, "ANCHOR_NONE")

A.slashPrefix = "|cff8d63ff/automailer|r "
A.addonName = "|cff8d63ffAutoMailer|r "
A.sendingMail = false
A.awaitConfirmSent = false
A.mailQueue = nil
A.mailQueueIndex = 0
A.mailTriggerButton = nil

--[[
    ---- EVENT FRAME ----
]]
local E = CreateFrame("Frame")
E:RegisterEvent("ADDON_LOADED")
E:RegisterEvent("MAIL_SHOW")
E:RegisterEvent("MAIL_CLOSED")
E:RegisterEvent("MAIL_INBOX_UPDATE")
E:RegisterEvent("MAIL_SUCCESS")
E:RegisterEvent("MAIL_FAILED")

--E:RegisterEvent("BAG_UPDATE_DELAYED")
E:RegisterEvent("PLAYER_ENTERING_WORLD")
E:SetScript("OnEvent", function(self, event, ...)
  return self[event] and self[event](self, ...)
end)


--[[
    -- ADDON LOADED --
]]
function E:ADDON_LOADED(name)
  if name ~= "AutoMailer" then return end

  A:InitializeSavedVariables()

  A.itemsSent = {}
  A.itemsSent[A.db.recipient] = {}
  A.itemsSent[A.db.boeRecipient] = {}

  SLASH_AUTOMAILER1= "/automailer"
  SLASH_AUTOMAILER2= "/am"
  SlashCmdList.AUTOMAILER = function(msg)
    A:SlashCommand(msg)
  end

  A.CreateOptionsMenu()
  A.loaded = true
end



--[[
    -- PLAYER ENTERING WORLD --
]]
function E:PLAYER_ENTERING_WORLD(login, reloadUI)
  if (login or reloadUI) and AutoMailer.loginMessage and A.loaded then
    print(A.addonName .. "loaded")
  end
end



function A:EnsureMailTriggerButton()
  if not MailFrame then return nil end

  if not A.mailTriggerButton then
    local button = CreateFrame("Button", "AutoMailerMailButton", UIParent, "UIPanelButtonTemplate")
    button:SetSize(140, 24)
    button:SetText("Send Mail")
    button:SetPoint("TOP", MailFrame, "TOP", 0, 30)
    button:SetFrameStrata(MailFrame:GetFrameStrata())
    button:SetFrameLevel(MailFrame:GetFrameLevel() + 5)
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

  if MailFrame and MailFrame:IsShown() then
    A.mailTriggerButton:Show()
    A.mailTriggerButton:ClearAllPoints()
    A.mailTriggerButton:SetPoint("TOP", MailFrame, "TOP", 0, 30)
    A.mailTriggerButton:SetFrameStrata(MailFrame:GetFrameStrata())
    A.mailTriggerButton:SetFrameLevel(MailFrame:GetFrameLevel() + 5)
  else
    A.mailTriggerButton:Hide()
  end

  return A.mailTriggerButton
end

function A:ResetMailSendState()
  A:Log("ResetMailSendState")
  A.sendingMail = false
  A.awaitConfirmSent = false
  A.mailQueue = nil
  A.mailQueueIndex = 0
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
    A:Print("A mail send is already in progress.")
    return
  end

  A:Print("Starting AutoMailer send run")
  A:Log("StartMailSend invoked")

  local recipient = A.db.recipient or ""
  local boeRecipient = A.db.boeRecipient or ""

  if #recipient == 0 and #boeRecipient == 0 then
    A:Print("No recipient configured.")
    return
  end

  if not A:ShowSendMailTab() then
    A:Print("Mail frame is not available.")
    return
  end

  local queue, itemCount = A:BuildMailQueue(recipient, boeRecipient)
  A:Log("BuildMailQueue produced", #queue, "batch(es) covering", itemCount, "item(s)")

  if #queue == 0 then
    A:Print("No matching items found in your bags to mail.")
    return
  end

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
    A:Print("AutoMailer finished: sent " .. (A.mailQueueIndex - 1) .. " mail(s).")
    A:ResetMailSendState()
    return
  end

  A:Log("Processing batch", A.mailQueueIndex, "/", #A.mailQueue, "recipient=", batch.recipient, "items=", #batch.items)
  A:SendMailBatch(batch)
end








--[[
    -- MAILING EVENTS --
]]
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

  if IsShiftKeyDown() then
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
  A:Log("MAIL_SUCCESS mailID=", mailID)
  A.awaitConfirmSent = false
  if A.sendingMail then
    C_Timer.After(0.3, function()
      A:ProcessMailQueue()
    end)
  end
end

function E:MAIL_FAILED()
  A:Log("MAIL_FAILED")
  A.awaitConfirmSent = false
  if A.sendingMail then
    A:Print("A mail failed to send; stopping AutoMailer run.")
    A:ResetMailSendState()
  end
end



function A:GetAutoMailEntries()
  local entries = {}
  local itemsList = A.db.items or ""
  for line in string.gmatch(itemsList .. "\n", "(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local itemName, recipient = trimmed:match("^(.-)%s*[%|=]%s*(.+)$")
      if not itemName then
        itemName = trimmed
        recipient = ""
      end
      entries[#entries + 1] = {
        itemName = itemName:match("^%s*(.-)%s*$"),
        recipient = recipient and recipient:match("^%s*(.-)%s*$") or "",
      }
    end
  end
  return entries
end

function A:GetAutoMailEntry(itemName)
  if not itemName then return nil end
  local itemLower = itemName:lower()
  for _, entry in ipairs(A:GetAutoMailEntries()) do
    if entry.itemName and entry.itemName ~= "" then
      local entryLower = entry.itemName:lower()
      if itemLower == entryLower
        or string.find(itemLower, entryLower, 1, true) ~= nil
        or string.find(entryLower, itemLower, 1, true) ~= nil then
        return entry
      end
    end
  end
  return nil
end

function A:ItemInAutomailList(itemName)
  return A:GetAutoMailEntry(itemName) ~= nil
end



function A:EscapePattern(string)
  return string:gsub("([^%w])", "%%%1")
end



-- Recipients are matched against the currently logged-in character's name so
-- rules that happen to target yourself (e.g. a global profile rule meant for
-- a different alt) don't queue a pointless self-mail. Strips an optional
-- "-Realm" suffix off the recipient before comparing, since UnitName("player")
-- never includes one.
function A:IsCurrentCharacter(recipient)
  if not recipient or recipient == "" then return false end
  local playerName = UnitName("player")
  if not playerName then return false end
  local recName = recipient:match("^(.-)%-.+$") or recipient
  return recName:lower() == playerName:lower()
end



function A:AutomailBoe(bindType)
  return A.db.SendBOE and bindType == 2
end



function A:ItemIsSoulbound(bag, slot)
  local t = A.TT
  local isSoulbound = false
  t:ClearLines()
  t:SetBagItem(bag, slot)
  t:Show()


  for i = 1, 4 do
    local text = _G["AutoMailerTTTextLeft"..i]:GetText()

    if text == ITEM_SOULBOUND then
      isSoulbound = true
    end
  end
  return isSoulbound
end



function A:SlashCommand(args)
  local command = strsplit(" ", args, 1)
  command = command:lower()

  if command == "list" then
    local sentMessage = false
    for recipient, items in pairs(A.itemsSent) do
      local string = ""
      for itemName, count in pairs(items) do
        if #string > 0 then
          string = string .. ", "..itemName.."x"..count
        else
          string = itemName.."x"..count
        end
      end

      if #string > 0 then
        A:Print("Items sent to ".. recipient)
        print(string)
        sentMessage = true
      end
    end
    if not sentMessage then
      A:Print("Nothing sent this session.")
    end
  elseif command == "debug" then
    AutoMailer.debugLogging = not AutoMailer.debugLogging
    A:Print("Debug logging " .. (AutoMailer.debugLogging and "enabled" or "disabled") .. ".")
  else
    if A.optionsPanel and A.optionsPanel.category and Settings and Settings.OpenToCategory then
      local categoryID = A.optionsPanel.category and A.optionsPanel.category.ID
      if categoryID then
        Settings.OpenToCategory(categoryID)
      else
        Settings.OpenToCategory(A.optionsPanel.category)
      end
    elseif InterfaceOptionsFrame_OpenToCategory then
      InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
      InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
    end
    OpenAllBags()
  end
end



function A:Count(T)
  local i = 0
  for _,_ in pairs(T) do
    i = i+1
  end
  return i
end



local MAX_MAIL_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12

-- Scans all bags once and builds a flat list of send batches, each with a
-- recipient and at most MAX_MAIL_ATTACHMENTS items (one mail can only carry
-- so many attachments).
function A:BuildMailQueue(recipient, boeRecipient)
  local queuedByRecipient = {}
  local totalItems = 0

  local function queueItem(targetRecipient, bag, slot, itemLink)
    if A:IsCurrentCharacter(targetRecipient) then
      A:Log("Skipping", itemLink or "<unknown>", "- recipient", targetRecipient, "is the currently logged in character")
      return
    end
    queuedByRecipient[targetRecipient] = queuedByRecipient[targetRecipient] or {}
    tinsert(queuedByRecipient[targetRecipient], { bag = bag, slot = slot, itemLink = itemLink })
    totalItems = totalItems + 1
  end

  for bag = 0, NUM_BAG_SLOTS do
    local slotCount = A:GetContainerNumSlots(bag)
    for slot = 1, slotCount do
      local _, _, locked, _, _, _, itemLink = A:GetContainerItemInfo(bag, slot)
      if itemLink and not locked and not A:ItemIsSoulbound(bag, slot) then
        local itemName, _, rarity, _, itemMinLevel, _, _, _, _, _, _, _, _, bindType = A:GetItemInfo(itemLink)
        local targetRecipient = nil

        if A:ItemInAutomailList(itemName) then
          local entry = A:GetAutoMailEntry(itemName)
          if entry and entry.recipient and entry.recipient ~= "" then
            targetRecipient = entry.recipient
          else
            targetRecipient = recipient
          end

        elseif A:AutomailBoe(bindType) then
          local rarityOk = (not A.db.limitBoeRarity) or rarity <= A.db.boeRarityLimit
          local levelOk = (not A.db.LimitBoeLevel) or itemMinLevel < UnitLevel("PLAYER")
          if rarityOk and levelOk then
            targetRecipient = (#boeRecipient > 0) and boeRecipient or recipient
          end
        end

        if targetRecipient and #targetRecipient > 0 then
          queueItem(targetRecipient, bag, slot, itemLink)
        end
      end
    end
  end

  -- The Reagent Bag (bag 5) is a dedicated container the game auto-sorts
  -- crafting materials into. Rather than trying to identify "is this a
  -- reagent" via item classification (which proved unreliable - GetItemInfo
  -- fields can be uncached, and classID/type schemes shift between
  -- expansions), just mail out anything non-soulbound sitting in that bag.
  if A.db.SendReagents then
    local reagentBag = REAGENTBAG_CONTAINER or 5
    local slotCount = A:GetContainerNumSlots(reagentBag)
    for slot = 1, slotCount do
      local _, _, locked, _, _, _, itemLink = A:GetContainerItemInfo(reagentBag, slot)
      if itemLink and not locked and not A:ItemIsSoulbound(reagentBag, slot) then
        local itemName = A:GetItemInfo(itemLink)
        local targetRecipient = recipient
        local entry = A:GetAutoMailEntry(itemName)
        if entry and entry.recipient and entry.recipient ~= "" then
          targetRecipient = entry.recipient
        end

        if targetRecipient and #targetRecipient > 0 then
          queueItem(targetRecipient, reagentBag, slot, itemLink)
        end
      end
    end
  end

  local recipients = {}
  for targetRecipient in pairs(queuedByRecipient) do
    tinsert(recipients, targetRecipient)
  end
  table.sort(recipients)

  local batches = {}
  for _, targetRecipient in ipairs(recipients) do
    local items = queuedByRecipient[targetRecipient]
    for i = 1, #items, MAX_MAIL_ATTACHMENTS do
      local chunk = {}
      for j = i, math.min(i + MAX_MAIL_ATTACHMENTS - 1, #items) do
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
    if A:IsCurrentCharacter(goldRecipient) then
      A:Log("Skipping excess gold - recipient", goldRecipient, "is the currently logged in character")
    elseif GetMoney() > thresholdCopper and goldRecipient and #goldRecipient > 0 then
      A:Log("Queuing excess gold batch (amount computed at send time): threshold=", A.db.goldThreshold,
          "recipient=", goldRecipient)
      tinsert(batches, { recipient = goldRecipient, items = {}, goldThresholdCopper = thresholdCopper })
      totalItems = totalItems + 1
    end
  end

  return batches, totalItems
end

function A:GetBatchSubject(batch)
  if #batch.items == 0 and batch.money and batch.money > 0 then
    return "Gold"
  end
  local first = batch.items[1]
  local name = first and A:GetItemInfo(first.itemLink)
  if not name or name == "" then
    name = "Item"
  end
  if #batch.items > 1 then
    return name .. " +" .. (#batch.items - 1) .. " more"
  end
  return name
end

-- Attaches a single bag item to the given send-mail attachment slot using
-- the real Blizzard attach flow: pick the item up onto the cursor, then
-- click the attachment slot to drop it in. Returns true/false and logs the
-- outcome at every step so a failure can be pinpointed from the chat log.
function A:AttachItemToMail(bag, slot, attachIndex, itemLink)
  A:Log("Attach start: bag=", bag, "slot=", slot, "attachIndex=", attachIndex, "item=", itemLink or "<unknown>")

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
    A:Print("Mail frame is not open; stopping AutoMailer.")
    A:ResetMailSendState()
    return
  end

  if not A:ShowSendMailTab() then
    A:Print("Could not switch to the Send Mail tab; stopping AutoMailer.")
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
    local postage = (GetSendMailPrice and GetSendMailPrice()) or 0
    batch.money = math.max(0, GetMoney() - batch.goldThresholdCopper - postage)
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
    A:Print("Could not attach any items for " .. batch.recipient .. "; skipping this batch.")
    C_Timer.After(0.2, function()
      A:ProcessMailQueue()
    end)
    return
  end

  A:Log("Calling SendMail to", batch.recipient, "with", attachedCount, "item(s) attached, money=", money,
      "subject=", subject)
  A.awaitConfirmSent = true
  SendMail(batch.recipient, subject, "")

  if money > 0 then
    A:Print("Sent " .. attachedCount .. " item(s) and " .. GetCoinTextureString(money) .. " to " .. batch.recipient)
  else
    A:Print("Sent " .. attachedCount .. " item(s) to " .. batch.recipient)
  end
end