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

local _, A = ...

local L = A.L

-- Registration reparents the canvas frames, so it runs once both panels are built.
local function RegisterCategories(mainPanel, subPanels)
  local category = Settings.RegisterCanvasLayoutCategory(mainPanel, mainPanel.name)
  Settings.RegisterAddOnCategory(category)
  mainPanel.category = category
  for _, sub in ipairs(subPanels) do
    sub.category = Settings.RegisterCanvasLayoutSubcategory(category, sub, sub.name)
  end
end

local ROW_HEIGHT = 26
local LIST_WIDTH = 280
-- The two lists share a non-scrolling column, so their heights are a budget.
local ITEM_LIST_HEIGHT = 156
local NAME_LIST_HEIGHT = 78
local UNKNOWN_ITEM_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local LIST_BACKDROP = {
  bgFile = "Interface\\TutorialFrame\\TutorialFrameBackground",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  edgeSize = 16,
  tile = true,
  tileSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 }
}

--[[
  Builds the "Items to AutoMail" and "Name Matches" tables: two ScrollBox views
  onto A.db.items, split by whether a rule has an itemID. A rule moves between
  them only in CommitName. Returns the Items backdrop for anchoring.
]]
local function CreateItemTable(optionsPanel, anchorTo)
  local itemList, nameList
  local RefreshLists

  --[[ SHARED ROW BEHAVIOR ]]

  local function UpdateRecipientHint(row)
    local typed = A:Trim(row.Recipient:GetText())
    local isEmpty = typed == ""
    local fallback = A:Trim(A.db.recipient)
    row.RecipientHint:SetText(fallback ~= "" and fallback or L["no default set"])
    row.RecipientHint:SetShown(isEmpty and not row.Recipient.hasFocus)

    -- Non-blocking nudge (#26); a blank row uses the default Recipient.
    if not isEmpty and not A:IsKnownCharacter(typed) then
      row.Recipient:SetTextColor(1, 0.82, 0.4)
    else
      row.Recipient:SetTextColor(1, 1, 1)
    end
  end

  -- Items-table rows only. The question mark stands in for an itemID the client
  -- has no data for.
  local function UpdateRowItem(row, entry)
    local icon, quality

    if entry.itemID then
      icon = select(5, C_Item.GetItemInfoInstant(entry.itemID))
      local name, _, itemQuality = C_Item.GetItemInfo(entry.itemID)
      if name then
        entry.itemName = name
        quality = itemQuality
        if not row.Name:HasFocus() then
          row.Name:SetText(name)
          row.Name:SetCursorPosition(0)
        end
      else
        -- Not cached yet; redraw once loaded, unless the row was recycled.
        local item = Item:CreateFromItemID(entry.itemID)
        if not item:IsItemEmpty() then
          item:ContinueOnItemLoad(function()
            if row.entry == entry then
              UpdateRowItem(row, entry)
            end
          end)
        end
      end
    end

    row.IconButton.Icon:SetTexture(icon or UNKNOWN_ITEM_ICON)

    local color = quality and ITEM_QUALITY_COLORS[quality]
    if color then
      row.Name:SetTextColor(color.r, color.g, color.b)
    else
      row.Name:SetTextColor(1, 1, 1)
    end
  end

  -- Every add is announced in chat and logged with its itemID (#88).
  local function AddItemByID(itemID, fallbackName)
    if not itemID then return false end
    local itemName = C_Item.GetItemInfo(itemID) or fallbackName or ""
    local displayName = (itemName ~= "" and itemName) or L["That item"]
    if A:FindAutoMailEntryByItemID(itemID) then
      A:Print(string.format(L["%s is already in your list."], displayName))
      return false
    end
    tinsert(A:GetAutoMailEntries(), {
      itemID = itemID,
      itemName = itemName,
      recipient = "",
      retain = 0,
    })
    A:Log("Rule added: itemID", itemID, "name", itemName)
    A:Print(string.format(L["Added %s to your mailing rules."], displayName))
    RefreshLists()
    return true
  end

  -- Serves both drag-and-drop and pick-up-then-click.
  local function TakeCursorItem()
    local kind, id, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    ClearCursor()
    return id or A:GetItemIDFromLink(link), link
  end

  local function AddFromCursor()
    local itemID, link = TakeCursorItem()
    if not itemID then return false end
    return AddItemByID(itemID, link and C_Item.GetItemInfo(link))
  end

  -- Logged like an add, since it also changes what a rule matches (#88).
  local function ReplaceRowFromCursor(row)
    if not row.entry then return end
    local itemID = TakeCursorItem()
    if not itemID then return end
    if A:FindAutoMailEntryByItemID(itemID, row.entry) then
      A:Print(string.format(L["%s is already in your list."], L["That item"]))
      return
    end
    row.entry.itemID = itemID
    row.entry.itemName = C_Item.GetItemInfo(itemID) or row.entry.itemName
    A:Log("Rule row changed: itemID", itemID, "name", row.entry.itemName)
    RefreshLists()
  end

  local function DeleteRow(row)
    local target = row.entry
    if not target then return end
    local entries = A:GetAutoMailEntries()
    for i, entry in ipairs(entries) do
      if entry == target then
        tremove(entries, i)
        break
      end
    end
    RefreshLists()
  end

  -- GetItemInfoInstant only resolves names in the local cache, so a name may
  -- resolve in one session and not the next; a full-name rule still matches.
  local function ResolveItemID(itemName)
    local itemID = C_Item.GetItemInfoInstant(itemName)
    if not itemID then return nil end
    return itemID, C_Item.GetItemInfo(itemID)
  end

  local function ResetName(row)
    row.Name:SetText(row.entry and row.entry.itemName or "")
    row.Name:SetCursorPosition(0)
  end

  -- Display half of A:ApplyRuleName.
  local function CommitName(row)
    if not row.entry then return end

    local status, duplicate = A:ApplyRuleName(row.entry, row.Name:GetText(), ResolveItemID)
    if status == "unchanged" then return end

    if status == "duplicate" then
      A:Print(string.format(L["%s is already in your list."],
          duplicate.itemName ~= "" and duplicate.itemName or L["That item"]))
      ResetName(row)
      return
    end

    RefreshLists()
  end

  local function CommitRecipient(row)
    local entry = row.entry
    if not entry then return end
    entry.recipient = A:Trim(row.Recipient:GetText())
    UpdateRecipientHint(row)
  end

  -- A Retain of 0 is dimmed like a placeholder.
  local function UpdateRetainColor(row)
    local entry = row.entry
    if entry and entry.retain > 0 then
      row.Retain:SetTextColor(1, 1, 1)
    else
      row.Retain:SetTextColor(0.5, 0.5, 0.5)
    end
  end

  -- Blank or invalid text becomes 0 (mail everything).
  local function CommitRetain(row)
    local entry = row.entry
    if not entry then return end
    entry.retain = math.max(0, math.floor(tonumber(row.Retain:GetText()) or 0))
    row.Retain:SetText(tostring(entry.retain))
    row.Retain:SetCursorPosition(0)
    UpdateRetainColor(row)
  end

  -- Tabbing between a rule's fields. Deferred a frame and found by entry,
  -- because committing a name can rebuild both lists and recycle the row.
  local function FocusEntryField(entry, key)
    if not entry then return end
    C_Timer.After(0, function()
      for _, list in ipairs({ itemList, nameList }) do
        local frame = list.scrollBox:FindFrame(entry)
        if frame and frame[key] then
          frame[key]:SetFocus()
          return
        end
      end
    end)
  end

  -- Wired once per recycled frame; handlers read row.entry at call time.
  local function InitRowScripts(row)
    row.RecipientHint:SetPoint("LEFT", row.Recipient, "LEFT", 6, 0)

    row.Name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.Name:SetScript("OnEscapePressed", function(self)
      ResetName(row)
      self:ClearFocus()
    end)
    row.Name:SetScript("OnEditFocusLost", function() CommitName(row) end)
    -- Shift-tab just leaves: nothing precedes the name.
    row.Name:SetScript("OnTabPressed", function(self)
      local entry = row.entry
      self:ClearFocus()
      if not IsShiftKeyDown() then
        FocusEntryField(entry, "Retain")
      end
    end)

    row.Retain:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.Retain:SetScript("OnTabPressed", function(self)
      local entry = row.entry
      self:ClearFocus()
      if IsShiftKeyDown() then
        FocusEntryField(entry, "Name")
      else
        FocusEntryField(entry, "Recipient")
      end
    end)
    row.Retain:SetScript("OnEscapePressed", function(self)
      self:SetText(tostring(row.entry and row.entry.retain or 0))
      self:ClearFocus()
    end)
    row.Retain:SetScript("OnEditFocusLost", function() CommitRetain(row) end)
    row.Retain:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["How many of this item to leave in your bags. 0 mails all of them."])
      GameTooltip:Show()
    end)
    row.Retain:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.Recipient:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.Recipient:SetScript("OnTabPressed", function(self)
      local entry = row.entry
      self:ClearFocus()
      if IsShiftKeyDown() then
        FocusEntryField(entry, "Retain")
      end
    end)
    row.Recipient:SetScript("OnEscapePressed", function(self)
      self:SetText(row.entry and row.entry.recipient or "")
      self:ClearFocus()
    end)
    row.Recipient:SetScript("OnEditFocusGained", function(self)
      self.hasFocus = true
      UpdateRecipientHint(row)
    end)
    row.Recipient:SetScript("OnEditFocusLost", function(self)
      self.hasFocus = false
      CommitRecipient(row)
    end)

    -- Name Matches rows have no icon.
    if row.IconButton then
      row.IconButton:SetScript("OnEnter", function(self)
        local entry = row.entry
        if not (entry and entry.itemID) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(entry.itemID)
        GameTooltip:Show()
      end)
      row.IconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row.IconButton:SetScript("OnClick", function() ReplaceRowFromCursor(row) end)
      row.IconButton:SetScript("OnReceiveDrag", function() ReplaceRowFromCursor(row) end)
    end

    row.Delete:SetScript("OnClick", function() DeleteRow(row) end)
    row.Delete:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["Remove this rule"])
      GameTooltip:Show()
    end)
    row.Delete:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- A drop on either table adds an exact item rule.
    row:SetScript("OnClick", function() AddFromCursor() end)
    row:SetScript("OnReceiveDrag", function() AddFromCursor() end)
  end

  local function InitRow(row, entry, list)
    row.entry = entry

    if not row.scriptsInitialized then
      row.scriptsInitialized = true
      InitRowScripts(row)
    end

    row.Name:SetText(entry.itemName)
    row.Name:SetCursorPosition(0)
    row.Retain:SetText(tostring(entry.retain))
    row.Retain:SetCursorPosition(0)
    UpdateRetainColor(row)
    row.Recipient:SetText(entry.recipient)
    row.Recipient:SetCursorPosition(0)
    row.Recipient.hasFocus = false

    if row.IconButton then
      UpdateRowItem(row, entry)
    end
    UpdateRecipientHint(row)

    local dataProvider = list.scrollBox:GetDataProvider()
    local index = dataProvider and dataProvider:FindIndex(entry)
    row.Stripe:SetShown((index or 1) % 2 == 0)
  end

  --[[ LIST CONSTRUCTION ]]

  -- Both tables share this layout; spec supplies template, inset and button.
  local function CreateRuleList(spec)
    local list = {}

    local header = optionsPanel:CreateFontString(nil, "OVERLAY")
    header:SetPoint("TOPLEFT", spec.anchorTo, "BOTTOMLEFT", spec.anchorX, spec.anchorY)
    header:SetFontObject("GameFontNormal")
    header:SetText(L[spec.header])

    local instructions = optionsPanel:CreateFontString(nil, "OVERLAY")
    instructions:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    instructions:SetFontObject("GameFontDisableSmall")
    instructions:SetJustifyH("LEFT")
    instructions:SetWidth(LIST_WIDTH)
    instructions:SetText(L[spec.instructions])

    -- x offsets match the row templates' widgets.
    local function ColumnLabel(xOffset, text)
      local label = optionsPanel:CreateFontString(nil, "OVERLAY")
      label:SetPoint("TOPLEFT", instructions, "BOTTOMLEFT", xOffset, -8)
      label:SetFontObject("GameFontNormalSmall")
      label:SetText(L[text])
      return label
    end

    local itemColumn = ColumnLabel(spec.columnInset, spec.itemColumn)
    ColumnLabel(132, "Retain")
    ColumnLabel(170, "Recipient")

    local scrollBox = CreateFrame("Frame", nil, optionsPanel, "WowScrollBoxList")
    scrollBox:SetSize(LIST_WIDTH, spec.height)
    scrollBox:SetPoint("TOPLEFT", itemColumn, "BOTTOMLEFT", -spec.columnInset, -6)
    scrollBox:EnableMouse(true)

    local scrollBar = CreateFrame("EventFrame", nil, optionsPanel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 8, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 8, 0)

    local backdrop = CreateFrame("Frame", nil, optionsPanel, "BackdropTemplate")
    backdrop:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", -8, 8)
    backdrop:SetPoint("BOTTOMRIGHT", scrollBar, "BOTTOMRIGHT", 8, -8)
    backdrop.backdropInfo = LIST_BACKDROP
    backdrop:ApplyBackdrop()
    backdrop:SetFrameLevel(math.max(1, scrollBox:GetFrameLevel() - 1))

    local emptyText = scrollBox:CreateFontString(nil, "OVERLAY")
    emptyText:SetPoint("TOP", scrollBox, "TOP", 0, -12)
    emptyText:SetWidth(LIST_WIDTH - 30)
    emptyText:SetFontObject("GameFontDisableSmall")
    emptyText:SetJustifyH("CENTER")
    emptyText:SetText(L[spec.emptyText])

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetPadding(2, 2, 2, 2, 2)
    view:SetElementInitializer(spec.template, function(row, entry)
      InitRow(row, entry, list)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    scrollBox:SetScript("OnReceiveDrag", AddFromCursor)
    scrollBox:SetScript("OnMouseUp", AddFromCursor)

    local button = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    button:SetSize(spec.buttonWidth, 22)
    button:SetText(L[spec.buttonText])
    button:SetPoint("TOPLEFT", backdrop, "BOTTOMLEFT", 4, -6)
    button:SetScript("OnReceiveDrag", AddFromCursor)
    button:SetScript("OnClick", spec.onClick)

    list.scrollBox = scrollBox
    list.backdrop = backdrop
    list.button = button
    -- Rebuilt rather than mutated; RetainScrollPosition keeps the scroll offset.
    list.SetEntries = function(entries)
      scrollBox:SetDataProvider(CreateDataProvider(entries), ScrollBoxConstants.RetainScrollPosition)
      emptyText:SetShown(#entries == 0)
    end

    return list
  end

  itemList = CreateRuleList({
    template = "AutoMailerItemRowTemplate",
    height = ITEM_LIST_HEIGHT,
    anchorTo = anchorTo,
    anchorX = -5,
    anchorY = -15,
    columnInset = 34,
    header = "Items to AutoMail",
    itemColumn = "Item",
    instructions = "Drag an item from your bags onto this list to add it. "
        .. "Leave a recipient blank to use the default Recipient. "
        .. "Retain keeps that many out of the mail.",
    emptyText = "No items yet.\n\nDrag an item from your bags onto this list.",
    buttonText = "Add Item",
    buttonWidth = 110,
    onClick = function()
      if AddFromCursor() then return end
      A:Print(L["Drag an item from your bags onto this list to add it, "
          .. "or use Add Name Rule to match items by name."])
    end,
  })

  nameList = CreateRuleList({
    template = "AutoMailerNameRowTemplate",
    height = NAME_LIST_HEIGHT,
    anchorTo = itemList.button,
    anchorX = -4,
    anchorY = -14,
    columnInset = 10,
    header = "Name Matches",
    itemColumn = "Text to match",
    instructions = "Mails every item whose name contains this text. "
        .. "Retain keeps that many out of the mail.",
    emptyText = "No name rules.",
    buttonText = "Add Name Rule",
    buttonWidth = 130,
    onClick = function()
      if AddFromCursor() then return end

      local entry = { itemName = "", recipient = "", retain = 0 }
      tinsert(A:GetAutoMailEntries(), entry)
      RefreshLists()
      nameList.scrollBox:ScrollToEnd()
      -- The new row frame only exists after the ScrollBox lays out.
      C_Timer.After(0, function()
        local row = nameList.scrollBox:FindFrame(entry)
        if row then
          row.Name:SetFocus()
        end
      end)
    end,
  })

  RefreshLists = function()
    local exact, loose = A:SplitAutoMailEntries()
    itemList.SetEntries(exact)
    nameList.SetEntries(loose)
  end

  -- Deliberately no shift-click hook: rules are added only by dropping an item
  -- on this panel. A HandleModifiedItemClick hook can't tell its click apart
  -- from dress-up, stack splitting or warbank clicks (#88, see CHANGELOG 6.3.2).

  optionsPanel.RefreshItemList = RefreshLists
  -- Repaints row placeholders without rebuilding the lists under the focused box.
  optionsPanel.UpdateRecipientHints = function()
    for _, list in ipairs({ itemList, nameList }) do
      list.scrollBox:ForEachFrame(UpdateRecipientHint)
    end
  end

  RefreshLists()

  return itemList.backdrop
end

--[[ WIDGET HELPERS ]]

-- Frames are unnamed on purpose, to keep generic names out of _G.
local function CreateCheckbox(parent, label, getter, setter)
  local checkbox = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")

  local text = checkbox:CreateFontString(nil, "OVERLAY")
  text:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
  text:SetFontObject("GameFontNormal")
  text:SetText(L[label])
  checkbox.Label = text

  checkbox:SetScript("OnClick", function(self)
    setter(self:GetChecked() and true or false)
  end)
  checkbox.Refresh = function(self)
    self:SetChecked(getter() and true or false)
  end
  checkbox:Refresh()

  return checkbox
end

-- OnTextChanged with the userInput guard catches pastes but not the addon's
-- own SetText. warnIfUnknown tints unfamiliar recipients (#26).
local function CreateTextBox(parent, width, getter, setter, numeric, warnIfUnknown)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 30)
  box:SetFontObject("ChatFontNormal")
  box:SetMultiLine(false)
  box:SetAutoFocus(false)
  if numeric then
    box:SetNumeric(true)
  end

  local function UpdateWarningColor(self)
    if not warnIfUnknown then return end
    local typed = A:Trim(self:GetText())
    if typed ~= "" and not A:IsKnownCharacter(typed) then
      self:SetTextColor(1, 0.82, 0.4)
    else
      self:SetTextColor(1, 1, 1)
    end
  end

  box.Refresh = function(self)
    self:SetText(getter())
    self:SetCursorPosition(0)
    UpdateWarningColor(self)
  end
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      setter(self:GetText())
    end
    UpdateWarningColor(self)
  end)
  box:SetScript("OnEnterPressed", function(self)
    setter(self:GetText())
    self:Refresh()
    self:ClearFocus()
  end)
  box:SetScript("OnEscapePressed", function(self)
    self:Refresh()
    self:ClearFocus()
  end)
  box:Refresh()

  return box
end

local function CreateHeader(parent, label, anchorTo, xOff, yOff, fontObject)
  local header = parent:CreateFontString(nil, "OVERLAY")
  header:SetFontObject(fontObject or "GameFontNormal")
  header:SetText(L[label])
  if anchorTo then
    header:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", xOff or 0, yOff or -12)
  end
  return header
end

local function RarityText(quality)
  return _G["ITEM_QUALITY" .. (quality or 4) .. "_DESC"] or tostring(quality)
end

--[[ MAIN PANEL - recipient and the item rule table ]]

local function CreateMainPanel()
  local panel = CreateFrame("Frame", "AutoMailerOptions", UIParent)
  panel.name = "AutoMailer"

  local title = panel:CreateFontString(nil, "OVERLAY")
  title:SetFontObject("GameFontNormalHuge")
  title:SetText(L["AutoMailer Options"])
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -10)

  local versionText = panel:CreateFontString(nil, "OVERLAY")
  versionText:SetFontObject("GameFontDisableSmall")
  -- No "v" prefix: the release tag already carries one.
  versionText:SetText(A:GetVersion())
  versionText:SetPoint("LEFT", title, "RIGHT", 8, -2)

  local recipientHeader = CreateHeader(panel, "Recipient", title, 0, -15)

  local recipientBox = CreateTextBox(panel, 200,
      function() return A.db.recipient end,
      function(value)
        A.db.recipient = value
        -- Blank-recipient rows show this value as a placeholder.
        panel.UpdateRecipientHints()
      end, nil, true)
  recipientBox:SetPoint("TOPLEFT", recipientHeader, "BOTTOMLEFT", 5, 0)
  panel.recipientBox = recipientBox

  local itemsBG = CreateItemTable(panel, recipientBox)

  local globalProfileCB = CreateCheckbox(panel, "Use one global profile for all characters",
      function() return A.meta.useGlobalProfile end,
      function(value)
        A.meta.useGlobalProfile = value
        A:RefreshActiveProfile()
        -- Both pages read from the swapped table.
        A:RefreshOptionsPanels()
      end)
  globalProfileCB:SetPoint("TOPLEFT", itemsBG, "TOPRIGHT", 20, 0)
  panel.globalProfileCB = globalProfileCB

  local moreSettings = panel:CreateFontString(nil, "OVERLAY")
  moreSettings:SetFontObject("GameFontDisableSmall")
  moreSettings:SetJustifyH("LEFT")
  moreSettings:SetWidth(240)
  moreSettings:SetText(L["BoE, reagent, gold and general settings live on the "
      .. "\"Filters & Automation\" page under this one."])
  moreSettings:SetPoint("TOPLEFT", globalProfileCB, "BOTTOMLEFT", 4, -16)

  panel.RefreshValues = function(self)
    self.RefreshItemList()
    self.recipientBox:Refresh()
    self.globalProfileCB:Refresh()
  end

  panel:SetScript("OnShow", panel.RefreshValues)

  return panel
end

--[[ FILTERS & AUTOMATION SUBPANEL ]]

local function CreateFiltersPanel()
  local panel = CreateFrame("Frame", "AutoMailerOptionsFilters", UIParent)
  panel.name = L["Filters & Automation"]
  local refreshers = {}

  local function Track(widget)
    tinsert(refreshers, widget)
    return widget
  end

  local title = panel:CreateFontString(nil, "OVERLAY")
  title:SetFontObject("GameFontNormalHuge")
  title:SetText(L["Filters & Automation"])
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -10)

  -- Bind-on-Equip
  local boeHeader = CreateHeader(panel, "Bind-on-Equip Items", title, 0, -18, "GameFontNormalLarge")

  local boeCB = Track(CreateCheckbox(panel, "Automatically send BoEs",
      function() return A.db.sendBoe end,
      function(value) A.db.sendBoe = value end))
  boeCB:SetPoint("TOPLEFT", boeHeader, "BOTTOMLEFT", 0, -6)

  local boeLevelCB = Track(CreateCheckbox(panel, "Only BoEs with required level lower than yours",
      function() return A.db.limitBoeLevel end,
      function(value) A.db.limitBoeLevel = value end))
  boeLevelCB:SetPoint("TOPLEFT", boeCB, "BOTTOMLEFT", 16, 0)

  local boeRarityCB = Track(CreateCheckbox(panel, "Limit rarity",
      function() return A.db.limitBoeRarity end,
      function(value) A.db.limitBoeRarity = value end))
  boeRarityCB:SetPoint("TOPLEFT", boeLevelCB, "BOTTOMLEFT", 0, 0)

  -- UIDropDownMenuTemplate finds its sub-frames through _G, so it needs a name.
  local rarityDropdown = CreateFrame("Frame", "AutoMailerRarityLimitDropDown", panel, "UIDropDownMenuTemplate")
  rarityDropdown:SetPoint("TOPLEFT", boeRarityCB, "BOTTOMLEFT", -8, -4)
  rarityDropdown.displayMode = "MENU"
  rarityDropdown.initialize = function(_, level)
    if not level then return end
    for _, quality in ipairs({ Enum.ItemQuality.Uncommon, Enum.ItemQuality.Rare, Enum.ItemQuality.Epic }) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = RarityText(quality)
      info.arg1 = quality
      info.checked = (A.db.boeRarityLimit == quality)
      info.func = function(_, chosen)
        A.db.boeRarityLimit = chosen
        UIDropDownMenu_SetText(rarityDropdown, RarityText(chosen))
        CloseDropDownMenus()
      end
      UIDropDownMenu_AddButton(info, 1)
    end
  end
  rarityDropdown.Refresh = function(self)
    UIDropDownMenu_SetText(self, RarityText(A.db.boeRarityLimit))
  end
  Track(rarityDropdown)
  panel.rarityDropdown = rarityDropdown

  local boeRecipientHeader = CreateHeader(panel, "BoE Recipient", rarityDropdown, 16, -8)

  local boeRecipientBox = Track(CreateTextBox(panel, 200,
      function() return A.db.boeRecipient end,
      function(value) A.db.boeRecipient = value end, nil, true))
  boeRecipientBox:SetPoint("TOPLEFT", boeRecipientHeader, "BOTTOMLEFT", 5, 0)
  panel.boeRecipientBox = boeRecipientBox

  -- Reagents
  local reagentHeader = CreateHeader(panel, "Crafting Reagents", boeRecipientBox, -5, -20, "GameFontNormalLarge")

  local reagentCB = Track(CreateCheckbox(panel, "Send all Crafting Reagents",
      function() return A.db.sendReagents end,
      function(value) A.db.sendReagents = value end))
  reagentCB:SetPoint("TOPLEFT", reagentHeader, "BOTTOMLEFT", 0, -6)

  -- Gold
  local goldHeader = CreateHeader(panel, "Gold", reagentCB, 0, -16, "GameFontNormalLarge")

  local goldCB = Track(CreateCheckbox(panel, "Send gold above threshold to Recipient",
      function() return A.db.sendExcessGold end,
      function(value) A.db.sendExcessGold = value end))
  goldCB:SetPoint("TOPLEFT", goldHeader, "BOTTOMLEFT", 0, -6)

  local goldThresholdHeader = CreateHeader(panel, "Gold Threshold", goldCB, 0, -10)

  local goldThresholdBox = Track(CreateTextBox(panel, 100,
      function() return tostring(A.db.goldThreshold) end,
      function(value)
        local number = tonumber(value)
        if number then
          A.db.goldThreshold = number
        end
      end, true))
  goldThresholdBox:SetPoint("TOPLEFT", goldThresholdHeader, "BOTTOMLEFT", 5, 0)
  panel.goldThresholdBox = goldThresholdBox

  local confirmGoldCB = Track(CreateCheckbox(panel, "Ask before sending gold",
      function() return A.db.confirmGoldSends end,
      function(value) A.db.confirmGoldSends = value end))
  confirmGoldCB:SetPoint("TOPLEFT", goldThresholdBox, "BOTTOMLEFT", -5, -4)

  -- General
  local generalHeader = CreateHeader(panel, "General", confirmGoldCB, 0, -16, "GameFontNormalLarge")

  local autoSendCB = Track(CreateCheckbox(panel, "Shift-clicking a mailbox starts a send run",
      function() return A.meta.autoSendOnShiftOpen end,
      function(value) A.meta.autoSendOnShiftOpen = value end))
  autoSendCB:SetPoint("TOPLEFT", generalHeader, "BOTTOMLEFT", 0, -6)

  local debugCB = Track(CreateCheckbox(panel, "Enable debug logging",
      function() return A.meta.debugLogging end,
      function(value) A.meta.debugLogging = value end))
  debugCB:SetPoint("TOPLEFT", autoSendCB, "BOTTOMLEFT", 0, 0)

  local loginCB = Track(CreateCheckbox(panel, "Display login message",
      function() return A.meta.loginMessage end,
      function(value) A.meta.loginMessage = value end))
  loginCB:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, 0)

  panel.RefreshValues = function()
    for _, widget in ipairs(refreshers) do
      widget:Refresh()
    end
  end

  panel:SetScript("OnShow", panel.RefreshValues)

  return panel
end

function A:RefreshOptionsPanels()
  if A.optionsPanel then
    A.optionsPanel:RefreshValues()
  end
  if A.optionsFiltersPanel then
    A.optionsFiltersPanel.RefreshValues()
  end
end

function A.CreateOptionsMenu()
  local mainPanel = CreateMainPanel()
  local filtersPanel = CreateFiltersPanel()

  A.optionsPanel = mainPanel
  A.optionsFiltersPanel = filtersPanel

  RegisterCategories(mainPanel, { filtersPanel })
end
