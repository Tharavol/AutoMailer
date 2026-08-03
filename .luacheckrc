std = "lua51"
max_line_length = 120

-- The luarocks CI action installs into .luarocks/ inside the workspace, so
-- `luacheck .` would otherwise lint the toolchain along with the addon.
exclude_files = {".luarocks/**", ".luarocks", "lua_modules/**"}

-- WoW event handlers always receive (self, event, ...); ignore unused args entirely
-- since callbacks must match Blizzard's fixed signatures.
ignore = {
    "212", -- unused argument
}

globals = {
    "AutoMailer",
    "AutoMailerGlobal",
    "SlashCmdList",
    "SLASH_AUTOMAILER1",
    "SLASH_AUTOMAILER2",
    "StaticPopupDialogs", -- mutated in place (new dialog keys added)
}

read_globals = {
    -- Lua extensions exposed by WoW
    "strjoin", "strsplit", "tinsert", "tremove", "tostringall",

    -- Frame / UI globals
    "CreateFrame", "UIParent", "WorldFrame", "MailFrame", "MailFrameTab2",
    "DEFAULT_CHAT_FRAME", "GameFontNormal", "BackdropTemplateMixin",
    "GameTooltip", "hooksecurefunc",

    -- ScrollBox / DataProvider API (10.0+ list rendering)
    "CreateScrollBoxListLinearView", "CreateDataProvider", "ScrollUtil",
    "ScrollBoxConstants",

    -- Static popups
    "StaticPopup_Show", "YES", "NO",

    -- Dropdown menu API
    "UIDropDownMenu_AddButton", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_SetText",
    "CloseDropDownMenus",

    -- Options / Settings API
    "Settings", "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptions_AddCategory",

    -- Namespaces / enums
    "C_Container", "C_Item", "C_Timer", "C_AddOns", "Enum",
    "Item", "ItemLocation",

    -- Addon metadata (GetAddOnMetadata is the legacy fallback for pre-C_AddOns clients)
    "GetAddOnMetadata",

    -- Bag / item API
    "GetContainerNumSlots", "GetContainerItemInfo", "GetItemInfo",
    "OpenAllBags", "NUM_BAG_SLOTS", "REAGENTBAG_CONTAINER",
    "CursorHasItem", "ClearCursor", "PickupContainerItem",
    "ITEM_SOULBOUND",
    "ITEM_QUALITY0_DESC", "ITEM_QUALITY1_DESC", "ITEM_QUALITY2_DESC",
    "ITEM_QUALITY3_DESC", "ITEM_QUALITY4_DESC", "ITEM_QUALITY_COLORS",
    "GetCursorInfo",

    -- Mail API
    "ClickSendMailItemButton", "GetSendMailItem", "ClearSendMail",
    "GetSendMailPrice", "SendMail", "ATTACHMENTS_MAX_SEND",
    "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailMoney",
    "SetSendMailMoney", "MoneyInputFrame_SetCopper",

    -- Money / misc
    "GetMoney", "GetCoinTextureString", "UnitLevel", "IsShiftKeyDown", "UnitName",

    -- Localization
    "GetLocale",
}

-- The offline test harness installs WoW stubs into _G on purpose, and falls
-- back to table.unpack (5.2+) where the client only exposes the 5.1 form.
files["tests/**"] = {
    ignore = {"143"}, -- accessing undefined field of a standard global
}
