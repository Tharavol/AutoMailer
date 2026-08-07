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

-- Registers the main canvas panel plus any subcategory pages hanging off it.
-- Registration reparents the canvas frames, so this runs once both panels are
-- fully built rather than at frame-creation time.
local function RegisterCategories(mainPanel, subPanels)
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(mainPanel, mainPanel.name)
    if category then
      Settings.RegisterAddOnCategory(category)
      mainPanel.category = category

      if Settings.RegisterCanvasLayoutSubcategory then
        for _, sub in ipairs(subPanels) do
          sub.category = Settings.RegisterCanvasLayoutSubcategory(category, sub, sub.name)
        end
      end
      return true
    end
  end

  if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(mainPanel)
    for _, sub in ipairs(subPanels) do
      sub.parent = mainPanel.name
      InterfaceOptions_AddCategory(sub)
    end
    return true
  end

  return false
end

local ROW_HEIGHT = 26
local LIST_WIDTH = 280
-- The two lists share the left column of a canvas panel that does not scroll,
-- so their heights are a budget, not a preference: together with the headers
-- and buttons around them they have to stay inside what the single 300px list
-- used to occupy.
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
  Builds the two rule tables: "Items to AutoMail" and "Name Matches".

  Both are ScrollBox-backed views onto the same A.db.items list, split by
  whether a rule carries an itemID (see A:SplitAutoMailEntries). The split is
  what the user sees, because the two kinds of rule behave differently: an
  itemID rule identifies one item, so it can show that item's icon and matches
  only that item; a name rule matches by substring, so there is no single item
  to draw an icon for. A rule moves between the tables by gaining or losing its
  itemID, which only happens in CommitName.

  Returns the Items backdrop frame so the caller can anchor the rest of the
  panel beside it.
]]
local function CreateItemTable(optionsPanel, anchorTo)
  local itemList, nameList
  local RefreshLists

  --[[ SHARED ROW BEHAVIOR ]]

  local function UpdateRecipientHint(row)
    local isEmpty = A:Trim(row.Recipient:GetText()) == ""
    local fallback = A:Trim(A.db.recipient)
    row.RecipientHint:SetText(fallback ~= "" and fallback or L["no default set"])
    row.RecipientHint:SetShown(isEmpty and not row.Recipient.hasFocus)
  end

  -- Only ever called for rows in the Items table, which are the only rows with
  -- an IconButton. The question mark is no longer a rule-kind cue - name rules
  -- live in their own table now - so it only stands in for an itemID whose
  -- item data the client can't produce at all.
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
      elseif Item and Item.CreateFromItemID then
        -- Item data isn't cached yet; redraw this row once the client has it,
        -- but only if the row hasn't been recycled onto a different rule.
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

  local function AddItemByID(itemID, fallbackName)
    if not itemID then return false end
    if A:FindAutoMailEntryByItemID(itemID) then
      A:Print(string.format(L["%s is already in your list."],
          C_Item.GetItemInfo(itemID) or fallbackName or L["That item"]))
      return false
    end
    tinsert(A:GetAutoMailEntries(), {
      itemID = itemID,
      itemName = C_Item.GetItemInfo(itemID) or fallbackName or "",
      recipient = "",
    })
    RefreshLists()
    return true
  end

  -- Handles both halves of the drag flow: an actual drag-and-drop (via
  -- OnReceiveDrag) and the pick-up-then-click flow, which delivers the item
  -- on the cursor rather than as a drag.
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

  -- The resolver A:ApplyRuleName decides rule kind with. GetItemInfoInstant
  -- only answers for items in the client's local cache, so the same name can
  -- resolve in one session and not the next; that is survivable because a name
  -- rule spelling an item out in full still matches that item, just loosely.
  local function ResolveItemID(itemName)
    local itemID = C_Item.GetItemInfoInstant(itemName)
    if type(itemID) ~= "number" then return nil end
    return itemID, C_Item.GetItemInfo(itemID)
  end

  local function ResetName(row)
    row.Name:SetText(row.entry and row.entry.itemName or "")
    row.Name:SetCursorPosition(0)
  end

  -- The decision itself lives in A:ApplyRuleName, where it can be tested
  -- without a frame; this is just the display half of it.
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

  --[[
    Moves focus to another field of the same rule, for tabbing between the
    name and recipient boxes.

    Deferred a frame, and located by entry rather than by frame, because
    leaving a field commits it - and committing a name can rebuild both lists
    (a name the client resolves to a real item turns that rule into an item
    rule and moves it to the other table). The row frame is recycled by that
    rebuild, so a reference captured before it can easily be pointing at a
    different rule by the time focus lands. Same reason the "Add Name Rule"
    button defers its SetFocus.
  ]]
  local function FocusEntryField(entry, key)
    if not entry then return end
    C_Timer.After(0, function()
      for _, list in ipairs({ itemList, nameList }) do
        local frame = list.scrollBox.FindFrame and list.scrollBox:FindFrame(entry)
        if frame and frame[key] then
          frame[key]:SetFocus()
          return
        end
      end
    end)
  end

  -- Scripts are wired once per frame, not once per rule: ScrollBox recycles
  -- row frames, so handlers read row.entry at call time rather than closing
  -- over whichever rule the row happened to show when it was created.
  local function InitRowScripts(row)
    row.RecipientHint:SetPoint("LEFT", row.Recipient, "LEFT", 6, 0)

    row.Name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.Name:SetScript("OnEscapePressed", function(self)
      ResetName(row)
      self:ClearFocus()
    end)
    row.Name:SetScript("OnEditFocusLost", function() CommitName(row) end)
    -- Tab goes to this rule's recipient; shift-tab just leaves the field,
    -- since nothing precedes the name in a row.
    row.Name:SetScript("OnTabPressed", function(self)
      local entry = row.entry
      self:ClearFocus()
      if not IsShiftKeyDown() then
        FocusEntryField(entry, "Recipient")
      end
    end)

    row.Recipient:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.Recipient:SetScript("OnTabPressed", function(self)
      local entry = row.entry
      self:ClearFocus()
      if IsShiftKeyDown() then
        FocusEntryField(entry, "Name")
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

    -- Name Matches rows have no icon: their template omits it, because a
    -- substring rule doesn't identify an item to draw or to look up.
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

    -- Dropping an item anywhere always means "mail this exact item", so both
    -- tables' rows add to the Items table rather than to the one dropped on.
    row:SetScript("OnClick", function() AddFromCursor() end)
    row:SetScript("OnReceiveDrag", function() AddFromCursor() end)
  end

  local function InitRow(row, entry, list)
    row.entry = entry

    if not row.scriptsInitialized then
      row.scriptsInitialized = true
      InitRowScripts(row)
    end

    row.Name:SetText(entry.itemName or "")
    row.Name:SetCursorPosition(0)
    row.Recipient:SetText(entry.recipient or "")
    row.Recipient:SetCursorPosition(0)
    row.Recipient.hasFocus = false

    if row.IconButton then
      UpdateRowItem(row, entry)
    end
    UpdateRecipientHint(row)

    local dataProvider = list.scrollBox:GetDataProvider()
    local index = dataProvider and dataProvider.FindIndex and dataProvider:FindIndex(entry)
    row.Stripe:SetShown((index or 1) % 2 == 0)
  end

  --[[ LIST CONSTRUCTION ]]

  -- Both tables are the same stack of widgets - header, blurb, column labels,
  -- a ScrollBox and scroll bar inside a backdrop, an empty-state message, and
  -- a button underneath - differing only in their row template, their column
  -- inset and what their button does.
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

    -- Column labels sit at the same x offsets as the matching widgets in the
    -- row template so they line up with the rows below. Both templates put
    -- Recipient at the same offset; only the first column differs, because
    -- one template starts with an icon and the other doesn't.
    local itemColumn = optionsPanel:CreateFontString(nil, "OVERLAY")
    itemColumn:SetPoint("TOPLEFT", instructions, "BOTTOMLEFT", spec.columnInset, -8)
    itemColumn:SetFontObject("GameFontNormalSmall")
    itemColumn:SetText(L[spec.itemColumn])

    local recipientColumn = optionsPanel:CreateFontString(nil, "OVERLAY")
    recipientColumn:SetPoint("TOPLEFT", instructions, "BOTTOMLEFT", 158, -8)
    recipientColumn:SetFontObject("GameFontNormalSmall")
    recipientColumn:SetText(L["Recipient"])

    local scrollBox = CreateFrame("Frame", nil, optionsPanel, "WowScrollBoxList")
    scrollBox:SetSize(LIST_WIDTH, spec.height)
    scrollBox:SetPoint("TOPLEFT", itemColumn, "BOTTOMLEFT", -spec.columnInset, -6)
    scrollBox:EnableMouse(true)

    local scrollBar = CreateFrame("EventFrame", nil, optionsPanel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 8, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 8, 0)

    local backdrop = CreateFrame("Frame", nil, optionsPanel, BackdropTemplateMixin and "BackdropTemplate")
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
    -- Rules are edited in place on A.db.items, so a list is redrawn by
    -- rebuilding its data provider around the current split rather than by
    -- mutating the provider. RetainScrollPosition keeps a deletion or an edit
    -- from bouncing the user back to the top of a long list.
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
    instructions = "Shift-click or drag an item from your bags to add it. "
        .. "Leave a recipient blank to use the default Recipient.",
    emptyText = "No items yet.\n\nShift-click an item in your bags or drag one onto this list.",
    buttonText = "Add Item",
    buttonWidth = 110,
    onClick = function()
      if AddFromCursor() then return end
      A:Print(L["Pick up or shift-click an item in your bags to add it, "
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
    instructions = "Mails every item whose name contains this text.",
    emptyText = "No name rules.",
    buttonText = "Add Name Rule",
    buttonWidth = 130,
    onClick = function()
      if AddFromCursor() then return end

      local entry = { itemName = "", recipient = "" }
      tinsert(A:GetAutoMailEntries(), entry)
      RefreshLists()
      if nameList.scrollBox.ScrollToEnd then
        nameList.scrollBox:ScrollToEnd()
      end
      -- The row frame for a brand new rule only exists after the ScrollBox has
      -- laid out the rebuilt provider, so grab it on the next frame.
      C_Timer.After(0, function()
        local row = nameList.scrollBox.FindFrame and nameList.scrollBox:FindFrame(entry)
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

  --[[
    SHIFT CLICKING ITEMS INTO THE LIST

    ContainerFrameItemButton_OnModifiedClick no longer exists as an
    overridable global as of patch 10.0 (bag item clicks moved into
    ContainerFrameItemButtonMixin). HandleModifiedItemClick is the current
    universal modified-click hook and is safe to post-hook with
    hooksecurefunc instead of replacing a Blizzard global outright.
  ]]
  hooksecurefunc("HandleModifiedItemClick", function(itemLink, itemLocation)
    if not itemLink then return end
    if not (itemLocation and itemLocation.IsBagAndSlot and itemLocation:IsBagAndSlot()) then return end
    if not optionsPanel:IsVisible() then return end

    AddItemByID(A:GetItemIDFromLink(itemLink), C_Item.GetItemInfo(itemLink))
  end)

  optionsPanel.RefreshItemList = RefreshLists
  -- Every row's placeholder shows the default Recipient, so editing that
  -- field has to repaint the rows - without rebuilding the lists out from
  -- under whichever edit box currently has focus.
  optionsPanel.UpdateRecipientHints = function()
    for _, list in ipairs({ itemList, nameList }) do
      if list.scrollBox.ForEachFrame then
        list.scrollBox:ForEachFrame(UpdateRecipientHint)
      end
    end
  end

  RefreshLists()

  return itemList.backdrop
end

--[[ WIDGET HELPERS ]]

-- All of these deliberately create frames with nil names. The panel used to
-- name them ("recipientBox", "boeRecipientBox" in particular), which put
-- generic identifiers straight into _G where any other addon creating the
-- same name would collide - whichever loaded second silently won.
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

-- OnTextChanged with the userInput guard replaces the old OnKeyUp handlers:
-- it catches pasted text (which fires no key event) and doesn't fire back on
-- the addon's own SetText calls during a refresh.
local function CreateTextBox(parent, width, getter, setter, numeric)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 30)
  box:SetFontObject("ChatFontNormal")
  box:SetMultiLine(false)
  box:SetAutoFocus(false)
  if numeric then
    box:SetNumeric(true)
  end

  box.Refresh = function(self)
    self:SetText(getter())
    self:SetCursorPosition(0)
  end
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      setter(self:GetText())
    end
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
  -- No "v" prefix here: the TOC version comes from the release tag, which
  -- already carries one.
  versionText:SetText(A:GetVersion())
  versionText:SetPoint("LEFT", title, "RIGHT", 8, -2)

  local recipientHeader = CreateHeader(panel, "Recipient", title, 0, -15)

  local recipientBox = CreateTextBox(panel, 200,
      function() return A.db.recipient or "" end,
      function(value)
        A.db.recipient = value
        -- Every row's blank-recipient placeholder shows this value.
        if panel.UpdateRecipientHints then
          panel.UpdateRecipientHints()
        end
      end)
  recipientBox:SetPoint("TOPLEFT", recipientHeader, "BOTTOMLEFT", 5, 0)
  panel.recipientBox = recipientBox

  local itemsBG = CreateItemTable(panel, recipientBox)

  local globalProfileCB = CreateCheckbox(panel, "Use one global profile for all characters",
      function() return A.meta.useGlobalProfile end,
      function(value)
        A.meta.useGlobalProfile = value
        A:RefreshActiveProfile()
        -- Switching profiles swaps the table every control reads from, so
        -- both pages have to resync, not just this one.
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

  -- UIDropDownMenuTemplate resolves its own sub-frames through _G by name, so
  -- unlike every other widget here this one has to keep a global name.
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
      function() return A.db.boeRecipient or "" end,
      function(value) A.db.boeRecipient = value end))
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
      function() return tostring(A.db.goldThreshold or 50000) end,
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
