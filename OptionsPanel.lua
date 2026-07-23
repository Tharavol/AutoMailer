local _, A = ...

local function RegisterOptionsCategory(optionsPanel)
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(optionsPanel, optionsPanel.name)
    if category then
      Settings.RegisterAddOnCategory(category)
      optionsPanel.category = category
      return true
    end
  end

  if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(optionsPanel)
    return true
  end

  return false
end

-- INTERFACE OPTIONS PANEL
function A.CreateOptionsMenu()
  local optionsPanel = CreateFrame("Frame", "AutoMailerOptions", UIParent)
  optionsPanel.name = "AutoMailer"
  optionsPanel:SetScript("OnShow", function(self)
    if self.RefreshValues then
      self:RefreshValues()
    end
  end)
  RegisterOptionsCategory(optionsPanel)

  local text = optionsPanel:CreateFontString(nil, "OVERLAY")
  text:SetFontObject("GameFontNormalHuge")
  text:SetText("AutoMailer Options")
  text:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 20, -10)

  local versionText = optionsPanel:CreateFontString(nil, "OVERLAY")
  versionText:SetFontObject("GameFontDisableSmall")
  versionText:SetText("v" .. A:GetVersion())
  versionText:SetPoint("LEFT", text, "RIGHT", 8, -2)

  local recipientHeader = optionsPanel:CreateFontString(nil, "OVERLAY")
  recipientHeader:SetFontObject("GameFontNormal")
  recipientHeader:SetText("Recipient")
  recipientHeader:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -15)



  local recipientBox = CreateFrame("EditBox", "recipientBox", optionsPanel, "InputBoxTemplate")
  recipientBox:SetPoint("TOPLEFT", recipientHeader, "BOTTOMLEFT", 5, 0)
  recipientBox:SetSize(200, 30)
  recipientBox:SetFontObject("ChatFontNormal")
  recipientBox:SetMultiLine(false)
  recipientBox:SetText(A.db.recipient)
  recipientBox:SetCursorPosition(0)
  recipientBox:SetAutoFocus(false)
  recipientBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  recipientBox:SetScript("OnKeyUp", function(self)
    A.db.recipient = self:GetText()
  end)
  recipientBox:SetScript("OnEnterPressed", function(self)
    A.db.recipient = self:GetText()
    self:ClearFocus()
  end)

  optionsPanel.recipientBox = recipientBox

  local itemsHeader = optionsPanel:CreateFontString(nil, "OVERLAY")
  itemsHeader:SetPoint("TOPLEFT", recipientBox, "BOTTOMLEFT", 0, -15)
  itemsHeader:SetFontObject("GameFontNormal")
  itemsHeader:SetText("Items to AutoMail")

  optionsPanel.itemsHeader = itemsHeader

  local listInstructions = optionsPanel:CreateFontString(nil, "OVERLAY")
  listInstructions:SetPoint("TOPLEFT", itemsHeader, "BOTTOMLEFT", 0, -6)
  listInstructions:SetFontObject("GameFontNormalSmall")
  listInstructions:SetText(
      "Format each line as Item Name = Recipient\nLeave the recipient blank to use the default recipient.")

  local backdrop = {
    bgFile = "Interface\\TutorialFrame\\TutorialFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    tile = true,
    tileSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  }

  local itemsFrame = CreateFrame("ScrollFrame", nil, optionsPanel, "UIPanelScrollFrameTemplate")
  itemsFrame:SetPoint("TOPLEFT", itemsHeader, "BOTTOMLEFT", 0, -5)
  itemsFrame:SetSize(275, 300)
  itemsFrame:SetScript("OnMouseUp", function(self)
    A.optionsPanel.items:SetFocus()
  end)

  optionsPanel.itemsFrame = itemsFrame

  local itemsBG = CreateFrame("Frame", nil, optionsPanel, BackdropTemplateMixin and "BackdropTemplate")
  itemsBG:SetPoint("CENTER", itemsFrame, "CENTER")
  itemsBG:SetSize(285, 310)
  itemsBG.backdropInfo = backdrop
  itemsBG:ApplyBackdrop()


  local items = CreateFrame("EditBox", nil, itemsFrame)
  items:SetFrameStrata("DIALOG")
  items:SetPoint("TOP", itemsFrame, "TOP", 0, -10)
  local fontPath, fontSize = GameFontNormal:GetFont()
  if fontPath and fontSize then
    items:SetFont(fontPath, fontSize, "")
  else
    items:SetFontObject("GameFontNormal")
  end
  items:SetWidth(265)
  items:SetHeight(300)
  items:SetText(A.db.items)
  items:SetAutoFocus(false)
  items:SetMultiLine(true)
  items:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  items:SetScript("OnKeyUp", function(self)
    A.db.items = self:GetText()
  end)

  itemsFrame:SetScrollChild(items)
  optionsPanel.items = items



  --[[
    SHIFT CLICKING ITEMS TO EDITBOX

    ContainerFrameItemButton_OnModifiedClick no longer exists as an
    overridable global as of patch 10.0 (bag item clicks moved into
    ContainerFrameItemButtonMixin). HandleModifiedItemClick is the current
    universal modified-click hook and is safe to post-hook with
    hooksecurefunc instead of replacing a Blizzard global outright.
  ]]
  hooksecurefunc("HandleModifiedItemClick", function(itemLink, itemLocation)
    if not itemLink then return end
    if not (itemLocation and itemLocation.IsBagAndSlot and itemLocation:IsBagAndSlot()) then return end
    if not (A.optionsPanel.items:IsVisible() and A.optionsPanel.items:HasFocus()) then return end

    local itemName = A:GetItemInfo(itemLink)
    if not itemName or itemName == "" then
      itemName = itemLink
    end
    local curPos = A.optionsPanel.items:GetCursorPosition()
    local newlineIndex = string.find(A.optionsPanel.items:GetText(), "\n", curPos-1)
    if newlineIndex and newlineIndex > curPos then
      A.optionsPanel.items:Insert("\n"..itemName)
    else
      A.optionsPanel.items:Insert(itemName.."\n")
    end
  end)



  local GlobalProfileCB = CreateFrame("CheckButton", "AMGlobalProfileCB", optionsPanel, "ChatConfigCheckButtonTemplate")
  GlobalProfileCB:SetChecked(AutoMailer.useGlobalProfile or false)
  GlobalProfileCB:SetPoint("TOPLEFT", itemsBG, "TOPRIGHT", 30, 0)
  GlobalProfileCB:SetScript("OnClick", function(self)
    AutoMailer.useGlobalProfile = self:GetChecked()
    A:RefreshActiveProfile()
    optionsPanel:RefreshValues()
  end)
  optionsPanel.globalProfileCB = GlobalProfileCB

  local GlobalProfileText = GlobalProfileCB:CreateFontString(nil, "OVERLAY")
  GlobalProfileText:SetPoint("LEFT", GlobalProfileCB, "RIGHT", 5, 0)
  GlobalProfileText:SetFontObject("GameFontNormal")
  GlobalProfileText:SetText("Use one global profile for all characters")



  local BOECB = CreateFrame("CheckButton", "AMBOECB", optionsPanel, "ChatConfigCheckButtonTemplate")
  BOECB:SetChecked(A.db.SendBOE or false)
  BOECB:SetPoint("TOPLEFT", GlobalProfileCB, "BOTTOMLEFT", 0, -10)
  BOECB:SetScript("OnClick", function(self)
    A.db.SendBOE = self:GetChecked()
  end)

  local BOETEXT = BOECB:CreateFontString(nil, "OVERLAY")
  BOETEXT:SetPoint("LEFT", BOECB, "RIGHT", 5, 0)
  BOETEXT:SetFontObject("GameFontNormal")
  BOETEXT:SetText("Automatically send BoEs")

  local BOELEVELLIMIT = CreateFrame("CheckButton", "AMBOELVLLIMITCB", optionsPanel, "ChatConfigCheckButtonTemplate")
  BOELEVELLIMIT:SetChecked(A.db.LimitBoeLevel or false)
  BOELEVELLIMIT:SetPoint("TOPLEFT", BOECB, "BOTTOMLEFT", 5, 0)
  BOELEVELLIMIT:SetScript("OnClick", function(self)
    A.db.LimitBoeLevel = self:GetChecked()
  end)

  local BOELIMITTEXT = BOELEVELLIMIT:CreateFontString(nil, "OVERLAY")
  BOELIMITTEXT:SetPoint("LEFT", BOELEVELLIMIT, "RIGHT", 5, 0)
  BOELIMITTEXT:SetFontObject("GameFontNormal")
  BOELIMITTEXT:SetText("Only BoEs with required level lower than yours")


  local boeRecipientHeader = optionsPanel:CreateFontString(nil, "OVERLAY")
  boeRecipientHeader:SetFontObject("GameFontNormal")
  boeRecipientHeader:SetText("BoE Recipient")
  boeRecipientHeader:SetPoint("TOPLEFT", BOELIMITTEXT, "BOTTOMLEFT", -30, -15)



  local boeRecipientBox = CreateFrame("EditBox", "boeRecipientBox", optionsPanel, "InputBoxTemplate")
  boeRecipientBox:SetPoint("TOPLEFT", boeRecipientHeader, "BOTTOMLEFT", 5, 0)
  boeRecipientBox:SetSize(200, 30)
  boeRecipientBox:SetFontObject("ChatFontNormal")
  boeRecipientBox:SetMultiLine(false)
  boeRecipientBox:SetText(A.db.boeRecipient)
  boeRecipientBox:SetCursorPosition(0)
  boeRecipientBox:SetAutoFocus(false)
  boeRecipientBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  boeRecipientBox:SetScript("OnKeyUp", function(self)
    A.db.boeRecipient = self:GetText()
  end)
  boeRecipientBox:SetScript("OnEnterPressed", function(self)
    A.db.boeRecipient = self:GetText()
    self:ClearFocus()
  end)
  optionsPanel.boeRecipientBox = boeRecipientBox


  local BOELIMITRARITYCB = CreateFrame("CheckButton", "AMBOELIMITRARITYCB", optionsPanel,
      "ChatConfigCheckButtonTemplate")
  BOELIMITRARITYCB:SetChecked(A.db.limitBoeRarity or false)
  BOELIMITRARITYCB:SetPoint("TOPLEFT", boeRecipientBox, "BOTTOMLEFT", 0, 0)
  BOELIMITRARITYCB:SetScript("OnClick", function(self)
    A.db.limitBoeRarity = self:GetChecked()
  end)

  local BOELIMITRARITYTEXT = BOELIMITRARITYCB:CreateFontString(nil, "OVERLAY")
  BOELIMITRARITYTEXT:SetPoint("LEFT", BOELIMITRARITYCB, "RIGHT", 5, 0)
  BOELIMITRARITYTEXT:SetFontObject("GameFontNormal")
  BOELIMITRARITYTEXT:SetText("Limit rarity")



  local rarities = {ITEM_QUALITY0_DESC, ITEM_QUALITY1_DESC, ITEM_QUALITY2_DESC, ITEM_QUALITY3_DESC, ITEM_QUALITY4_DESC}
  local RARITYLIMIT = CreateFrame("Frame", "AUTOMAILERRARITYLIMIT", optionsPanel, "UIDropDownMenuTemplate")
  RARITYLIMIT:SetPoint("TOPLEFT", BOELIMITRARITYCB, "BOTTOMLEFT", -24, -5)
  RARITYLIMIT.displayMode = "MENU"
  RARITYLIMIT.info = {}
  RARITYLIMIT.initialize = function(self, level)
    if not level then return end

    for i, rarity in pairs(rarities) do
      if i >= 3 then -- 3rd entry is uncommon
        local info = UIDropDownMenu_CreateInfo()

        info.text = rarity
        info.arg1 = rarity
        info.func = A.SetRarityLimit
        info.checked = rarity == _G["ITEM_QUALITY" .. A.db.boeRarityLimit .. "_DESC"]

        UIDropDownMenu_AddButton(info, 1)
      end
    end
  end
  optionsPanel.rarityLimit = RARITYLIMIT
  UIDropDownMenu_SetText(optionsPanel.rarityLimit, _G["ITEM_QUALITY" .. A.db.boeRarityLimit .. "_DESC"])



  local ReagentCB = CreateFrame("CheckButton", "AMReagentCB", optionsPanel, "ChatConfigCheckButtonTemplate")
  ReagentCB:SetChecked(A.db.SendReagents or false)
  ReagentCB:SetPoint("TOPLEFT", BOECB, "BOTTOMLEFT", 0, -180)
  ReagentCB:SetScript("OnClick", function(self)
    A.db.SendReagents = self:GetChecked()
  end)

  local ReagentText = ReagentCB:CreateFontString(nil, "OVERLAY")
  ReagentText:SetPoint("LEFT", ReagentCB, "RIGHT", 5, 0)
  ReagentText:SetFontObject("GameFontNormal")
  ReagentText:SetText("Send all Crafting Reagents")



  local GoldCB = CreateFrame("CheckButton", "AMGoldCB", optionsPanel, "ChatConfigCheckButtonTemplate")
  GoldCB:SetChecked(A.db.sendExcessGold or false)
  GoldCB:SetPoint("TOPLEFT", ReagentCB, "BOTTOMLEFT", 0, -15)
  GoldCB:SetScript("OnClick", function(self)
    A.db.sendExcessGold = self:GetChecked()
  end)
  optionsPanel.goldCB = GoldCB

  local GoldText = GoldCB:CreateFontString(nil, "OVERLAY")
  GoldText:SetPoint("LEFT", GoldCB, "RIGHT", 5, 0)
  GoldText:SetFontObject("GameFontNormal")
  GoldText:SetText("Send gold above threshold to Recipient")

  local goldThresholdHeader = optionsPanel:CreateFontString(nil, "OVERLAY")
  goldThresholdHeader:SetFontObject("GameFontNormal")
  goldThresholdHeader:SetText("Gold Threshold")
  goldThresholdHeader:SetPoint("TOPLEFT", GoldCB, "BOTTOMLEFT", 0, -10)

  local goldThresholdBox = CreateFrame("EditBox", "AMGoldThresholdBox", optionsPanel, "InputBoxTemplate")
  goldThresholdBox:SetPoint("TOPLEFT", goldThresholdHeader, "BOTTOMLEFT", 5, 0)
  goldThresholdBox:SetSize(100, 30)
  goldThresholdBox:SetFontObject("ChatFontNormal")
  goldThresholdBox:SetMultiLine(false)
  goldThresholdBox:SetNumeric(true)
  goldThresholdBox:SetText(tostring(A.db.goldThreshold or 50000))
  goldThresholdBox:SetCursorPosition(0)
  goldThresholdBox:SetAutoFocus(false)
  goldThresholdBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  goldThresholdBox:SetScript("OnKeyUp", function(self)
    local value = tonumber(self:GetText())
    if value then
      A.db.goldThreshold = value
    end
  end)
  goldThresholdBox:SetScript("OnEnterPressed", function(self)
    local value = tonumber(self:GetText())
    A.db.goldThreshold = value or A.db.goldThreshold
    self:SetText(tostring(A.db.goldThreshold))
    self:SetCursorPosition(0)
    self:ClearFocus()
  end)
  optionsPanel.goldThresholdBox = goldThresholdBox





  local loginMessage = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
  loginMessage:SetSize(25,25)
  loginMessage:SetPoint("BOTTOMLEFT", optionsPanel, "BOTTOMLEFT", 10, 3)
  loginMessage:SetScript("OnClick", function(self, button)
    AutoMailer.loginMessage = self:GetChecked()
  end)
  loginMessage:SetChecked(AutoMailer.loginMessage)
  optionsPanel.loginMessage = loginMessage

  local loginMessageText = loginMessage:CreateFontString(nil, "OVERLAY")
  loginMessageText:SetFontObject("GameFontNormal")
  loginMessageText:SetPoint("LEFT", loginMessage, "RIGHT", 3, 0)
  loginMessageText:SetText("Display login message")
  optionsPanel.loginMessageText = loginMessageText

  local debugLoggingCB = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
  debugLoggingCB:SetSize(25,25)
  debugLoggingCB:SetPoint("BOTTOMLEFT", loginMessage, "TOPLEFT", 0, 8)
  debugLoggingCB:SetScript("OnClick", function(self, button)
    AutoMailer.debugLogging = self:GetChecked()
  end)
  debugLoggingCB:SetChecked(AutoMailer.debugLogging)
  optionsPanel.debugLoggingCB = debugLoggingCB

  local debugLoggingText = debugLoggingCB:CreateFontString(nil, "OVERLAY")
  debugLoggingText:SetFontObject("GameFontNormal")
  debugLoggingText:SetPoint("LEFT", debugLoggingCB, "RIGHT", 3, 0)
  debugLoggingText:SetText("Enable debug logging")
  optionsPanel.debugLoggingText = debugLoggingText

  -- Re-syncs every control to the currently active profile (A.db) and the
  -- always-per-character meta prefs. Called on OnShow and whenever the
  -- global-profile toggle switches which table A.db points at.
  optionsPanel.RefreshValues = function(self)
    self.items:SetText(A.db.items or "")
    self.items:SetCursorPosition(0)
    self.recipientBox:SetText(A.db.recipient or "")
    self.recipientBox:SetCursorPosition(0)
    self.boeRecipientBox:SetText(A.db.boeRecipient or "")
    self.boeRecipientBox:SetCursorPosition(0)

    self.globalProfileCB:SetChecked(AutoMailer.useGlobalProfile or false)
    BOECB:SetChecked(A.db.SendBOE or false)
    BOELEVELLIMIT:SetChecked(A.db.LimitBoeLevel or false)
    BOELIMITRARITYCB:SetChecked(A.db.limitBoeRarity or false)
    UIDropDownMenu_SetText(self.rarityLimit, _G["ITEM_QUALITY" .. (A.db.boeRarityLimit or 4) .. "_DESC"])
    ReagentCB:SetChecked(A.db.SendReagents or false)

    self.goldCB:SetChecked(A.db.sendExcessGold or false)
    self.goldThresholdBox:SetText(tostring(A.db.goldThreshold or 50000))
    self.goldThresholdBox:SetCursorPosition(0)

    self.debugLoggingCB:SetChecked(AutoMailer.debugLogging or false)
    self.loginMessage:SetChecked(AutoMailer.loginMessage or false)
  end

  A.optionsPanel = optionsPanel
end


function A.SetRarityLimit(self, arg1, arg2, checked)
  local quals = {}
  quals[ITEM_QUALITY2_DESC] = Enum.ItemQuality.Uncommon
  quals[ITEM_QUALITY3_DESC] = Enum.ItemQuality.Rare
  quals[ITEM_QUALITY4_DESC] = Enum.ItemQuality.Epic

  A.db.boeRarityLimit = quals[arg1]
  UIDropDownMenu_SetText(A.optionsPanel.rarityLimit, arg1)
end
