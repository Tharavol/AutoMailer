-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

local Testkit = require("tests.testkit")

-- A tiny fake bag: bagContents[bag][slot] = { itemLink, locked, soulbound, count }.
-- Overrides the Core.lua container/item wrappers so BuildMailQueue's logic
-- runs against controlled data instead of a real client's bags.
local function NewFakeAddon(bagContents, opts)
  opts = opts or {}
  local A = Testkit.NewAddonTable()
  -- Same order as the TOC: MailQueue captures A.L at file scope.
  Testkit.LoadModule("Locale.lua", A)
  Testkit.LoadModule("Core.lua", A)
  Testkit.LoadModule("Profile.lua", A)
  Testkit.LoadModule("MailQueue.lua", A)

  A.db = A:DefaultProfile()

  function A:GetContainerNumSlots(bag)
    local bagData = bagContents[bag]
    return bagData and #bagData or 0
  end

  function A:GetContainerItemInfo(bag, slot)
    local entry = bagContents[bag] and bagContents[bag][slot]
    if not entry then return nil end
    -- Matches the (icon, count, locked, quality, ..., itemLink, ...) shape
    -- BuildMailQueue reads: count (2nd), locked (3rd) and itemLink (7th).
    return nil, entry.count or 1, entry.locked or false, entry.quality or 1, false, false, entry.itemLink
  end

  function A:ItemIsSoulbound(bag, slot)
    local entry = bagContents[bag] and bagContents[bag][slot]
    return entry and entry.soulbound or false
  end

  local itemInfoByLink = opts.itemInfoByLink or {}
  function A:GetItemInfo(itemLink)
    local info = itemInfoByLink[itemLink]
    if not info then return itemLink end -- fall back to the link as a name
    -- An `uncached` item stands in for one the client can't answer for yet:
    -- the real GetItemInfo returns nothing at all in that case.
    if info.uncached then return nil end
    return info.name, nil, info.rarity, nil, info.minLevel, nil, nil, nil, nil, nil, nil, nil, nil, info.bindType
  end

  A.requestedItemLoads = {}
  function A:RequestItemDataLoad(itemID)
    tinsert(A.requestedItemLoads, itemID)
  end

  function A:GetItemIDFromLink(itemLink)
    local info = itemInfoByLink[itemLink]
    return info and info.itemID
  end

  function A:IsCurrentCharacter(recipient)
    return recipient == (opts.currentCharacter or "CurrentToon")
  end

  -- A:IsDebugLogging reads A.meta, and the run summary only collects skip
  -- reasons when it is on.
  _G.AutoMailer = { debugLogging = opts.debugLogging or false }
  A.meta = AutoMailer

  A.logged = {}
  function A:Log(...) tinsert(A.logged, table.concat({ ... }, " ")) end
  function A:LoggedContains(text)
    for _, line in ipairs(A.logged) do
      if line:find(text, 1, true) then return true end
    end
    return false
  end

  _G.GetMoney = function() return opts.money or 0 end
  _G.UnitLevel = function() return opts.playerLevel or 60 end
  _G.NUM_BAG_SLOTS = opts.numBagSlots or 4
  _G.REAGENTBAG_CONTAINER = 5

  return A
end

Testkit.Test("BuildMailQueue routes an item-list match to that rule's recipient", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(#batches, 1)
  Testkit.AssertEqual(batches[1].recipient, "Bankalt")
end)

Testkit.Test("BuildMailQueue falls back to the default recipient when a rule's own recipient is blank", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "" })

  local batches = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(batches[1].recipient, "DefaultRecipient")
end)

Testkit.Test("BuildMailQueue skips locked and soulbound items", function()
  local A = NewFakeAddon({
    [0] = {
      { itemLink = "item:1", locked = true, soulbound = false },
      { itemLink = "item:2", locked = false, soulbound = true },
    },
  }, {
    itemInfoByLink = {
      ["item:1"] = { name = "Locked Item", itemID = 1, bindType = 0 },
      ["item:2"] = { name = "Soulbound Item", itemID = 2, bindType = 0 },
    },
  })
  tinsert(A:GetAutoMailEntries(), { itemName = "Item", recipient = "Bankalt" }) -- loose match on both

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 0, "locked and soulbound items must never be queued")
  Testkit.AssertEqual(#batches, 0)
end)

Testkit.Test("BuildMailQueue skips a rule whose recipient is the currently logged in character", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    currentCharacter = "Bankalt",
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 0, "mailing to yourself should be skipped")
  Testkit.AssertEqual(#batches, 0)
end)

Testkit.Test("BuildMailQueue splits a recipient's items across MAX_MAIL_ATTACHMENTS-sized batches", function()
  local bag = {}
  local itemInfoByLink = {}
  for i = 1, 13 do
    local link = "item:" .. i
    bag[i] = { itemLink = link, locked = false, soulbound = false }
    itemInfoByLink[link] = { name = "Ore " .. i, itemID = i, bindType = 0 }
  end

  local A = NewFakeAddon({ [0] = bag }, { itemInfoByLink = itemInfoByLink })
  tinsert(A:GetAutoMailEntries(), { itemName = "Ore", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 13)
  Testkit.AssertEqual(#batches, 2, "13 items should split into a 12-item and a 1-item batch")
  Testkit.AssertEqual(#batches[1].items, 12)
  Testkit.AssertEqual(#batches[2].items, 1)
end)

-- The stack size is only ever read here, in the bag scan; Send.lua needs it to
-- report what actually went out, and by then the slot has been emptied.
Testkit.Test("BuildMailQueue carries each slot's stack size onto the queued item", function()
  local A = NewFakeAddon({
    [0] = {
      { itemLink = "item:2589", locked = false, soulbound = false, count = 200 },
      { itemLink = "item:2592", locked = false, soulbound = false },
    },
  }, {
    itemInfoByLink = {
      ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 },
      ["item:2592"] = { name = "Wool Cloth", itemID = 2592, bindType = 0 },
    },
  })
  tinsert(A:GetAutoMailEntries(), { itemName = "Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertEqual(batches[1].items[1].count, 200)
  Testkit.AssertEqual(batches[1].items[2].count, 1, "a single item is a stack of one")
  Testkit.AssertEqual(itemCount, 2,
      "the run's own totals stay in slots, since a slot is what occupies an attachment")
end)

--[[ Retain (#78): a rule can cap how much of a held item gets mailed ]]

Testkit.Test("BuildMailQueue sends only what's left over above a rule's Retain count", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 200 } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt", retain = 50 })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(batches[1].items[1].count, 150, "150 of the 200 held should ship, keeping 50 back")
end)

Testkit.Test("BuildMailQueue sends nothing when the held count is at or below Retain", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 30 } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt", retain = 50 })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 0, "nothing above Retain means nothing to mail")
  Testkit.AssertEqual(#batches, 0)
end)

Testkit.Test("BuildMailQueue tallies Retain across every bag holding the item, not per slot", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 40 } },
    [1] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 40 } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt", retain = 50 })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  -- 80 held across the two bags minus a Retain of 50 leaves 30 to mail. The
  -- first-scanned slot covers all 30 by itself, so the second is held back
  -- entirely rather than both shipping partially - Retain is a total, not a
  -- per-slot cap.
  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(batches[1].items[1].count, 30)
end)

Testkit.Test("BuildMailQueue leaves a rule with no Retain sending everything, as before", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 200 } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(batches[1].items[1].count, 200, "no Retain field means the whole stack ships")
end)

Testkit.Test("BuildMailQueue logs a Retain holdback when debug logging is on", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false, count = 10 } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    debugLogging = true,
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt", retain = 50 })

  A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertTrue(A:LoggedContains("held back by this rule's Retain setting"))
end)

Testkit.Test("BuildMailQueue honors a BoE rarity limit", function()
  local A = NewFakeAddon({
    [0] = {
      { itemLink = "item:common", locked = false, soulbound = false },
      { itemLink = "item:epic", locked = false, soulbound = false },
    },
  }, {
    itemInfoByLink = {
      ["item:common"] = { name = "Common BoE", itemID = 1, bindType = 2, rarity = 2 },
      ["item:epic"] = { name = "Epic BoE", itemID = 2, bindType = 2, rarity = 4 },
    },
  })
  A.db.sendBoe = true
  A.db.limitBoeRarity = true
  A.db.boeRarityLimit = 3 -- Rare and below

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "BoeAlt")
  Testkit.AssertEqual(itemCount, 1, "only the Common BoE should pass a Rare-or-below limit")
  Testkit.AssertEqual(batches[1].recipient, "BoeAlt")
end)

Testkit.Test("BuildMailQueue mails everything non-soulbound in the reagent bag when enabled", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:reagent", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:reagent"] = { name = "Some Reagent", itemID = 99, bindType = 0 } },
  })
  A.db.sendReagents = true

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(batches[1].recipient, "DefaultRecipient")
end)

Testkit.Test("BuildMailQueue queues a placeholder excess-gold batch above the threshold", function()
  -- goldThreshold is stored in whole gold, not copper: BuildMailQueue computes
  -- thresholdCopper as goldThreshold * 10000.
  local A = NewFakeAddon({}, { money = 600000 }) -- 60g
  A.db.sendExcessGold = true
  A.db.goldThreshold = 5 -- 5g = 50000 copper

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(#batches, 1)
  Testkit.AssertEqual(batches[1].goldThresholdCopper, 50000)
  Testkit.AssertEqual(itemCount, 1, "the gold batch counts toward the total for the 'nothing to send' check")
end)

-- Gold has no per-rule equivalent, so a rules-only profile - which can now
-- start a run - has nothing to send gold to. Dropping it silently reads as
-- the gold option being ignored.
Testkit.Test("BuildMailQueue reports excess gold it has no recipient for", function()
  local A = NewFakeAddon({}, { money = 600000 })
  A.db.sendExcessGold = true
  A.db.goldThreshold = 5

  local printed = {}
  function A:Print(...) tinsert(printed, table.concat({ ... }, " ")) end

  local batches = A:BuildMailQueue("", "")
  Testkit.AssertEqual(#batches, 0)
  Testkit.AssertEqual(#printed, 1, "the skipped gold must be reported, not dropped silently")
  Testkit.AssertTrue(printed[1]:find("Excess gold not sent", 1, true) ~= nil)
end)

Testkit.Test("BuildMailQueue stays quiet about gold it has no recipient for when there is none to send", function()
  local A = NewFakeAddon({}, { money = 10000 })
  A.db.sendExcessGold = true
  A.db.goldThreshold = 5

  local printed = {}
  function A:Print(...) tinsert(printed, table.concat({ ... }, " ")) end

  A:BuildMailQueue("", "")
  Testkit.AssertEqual(#printed, 0, "below the threshold there is nothing to warn about")
end)

Testkit.Test("BuildMailQueue does not queue gold below the threshold", function()
  local A = NewFakeAddon({}, { money = 10000 }) -- 1g
  A.db.sendExcessGold = true
  A.db.goldThreshold = 5 -- 5g = 50000 copper

  local batches = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(#batches, 0)
end)

Testkit.Test("BuildMailQueue still applies itemID rules to an item whose data isn't cached", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { itemID = 2589, uncached = true } },
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertEqual(itemCount, 1, "an itemID rule doesn't need the item cache to match")
  Testkit.AssertEqual(batches[1].recipient, "Bankalt")
  Testkit.AssertDeepEqual(A.requestedItemLoads, { 2589 },
      "the uncached item's data should be requested for the next run")
end)

-- The bug this pins: bindType comes back nil for an uncached item, so it
-- silently failed the BoE check and the run under-sent while reporting
-- success. It still can't be classified on this run - there's nothing to
-- classify it from - but it must be logged and queued for a data load.
Testkit.Test("BuildMailQueue reports rather than silently skipping an uncached BoE", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:boe", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:boe"] = { itemID = 77, uncached = true } },
  })
  A.db.sendBoe = true

  local logged = {}
  function A:Log(...) tinsert(logged, table.concat({ ... }, " ")) end

  local _, itemCount = A:BuildMailQueue("DefaultRecipient", "BoeAlt")

  Testkit.AssertEqual(itemCount, 0, "an item the client can't describe can't be classified as BoE")
  Testkit.AssertDeepEqual(A.requestedItemLoads, { 77 })
  local mentioned = false
  for _, line in ipairs(logged) do
    if line:find("not cached", 1, true) then mentioned = true end
  end
  Testkit.AssertTrue(mentioned, "the skip must be visible in the debug log, not silent")
end)

Testkit.Test("BuildMailQueue lets a reagent-bag rule's own recipient win over the default", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:reagent", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:reagent"] = { name = "Some Reagent", itemID = 99, bindType = 0 } },
  })
  A.db.sendReagents = true
  tinsert(A:GetAutoMailEntries(), { itemID = 99, itemName = "Some Reagent", recipient = "ReagentAlt" })

  local batches = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(batches[1].recipient, "ReagentAlt")
end)

--[[
  The reagent bag used to be scanned only when sendReagents was on, so an
  explicit rule for an item the game files in there never matched. Retail
  auto-sorts cloth, ore and herbs into that bag, so this hit exactly the items
  people most want rules for - and silently, since an unscanned bag produces
  nothing to log.
]]
Testkit.Test("BuildMailQueue applies item rules in the reagent bag with sendReagents off", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  A.db.sendReagents = false
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 1, "a rule must match wherever the item lives")
  Testkit.AssertEqual(batches[1].recipient, "Bankalt")
end)

Testkit.Test("BuildMailQueue applies name rules in the reagent bag with sendReagents off", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
  })
  A.db.sendReagents = false
  tinsert(A:GetAutoMailEntries(), { itemName = "Cloth", recipient = "Bankalt" })

  local batches, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 1)
  Testkit.AssertEqual(batches[1].recipient, "Bankalt")
end)

-- The other half of the fix: scanning the bag must not start sweeping it.
-- "Send all Crafting Reagents" is still what mails unmatched contents.
Testkit.Test("BuildMailQueue does not sweep unmatched reagent-bag items with sendReagents off", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:reagent", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:reagent"] = { name = "Some Reagent", itemID = 99, bindType = 0 } },
  })
  A.db.sendReagents = false

  local _, itemCount = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(itemCount, 0, "an item matching no rule must still need the option to be mailed")
end)

-- The reagent bag can only hold tradeskill items, so BoE handling has never
-- applied to it. Scanning it unconditionally must not change that.
Testkit.Test("BuildMailQueue does not apply BoE handling to the reagent bag with sendReagents off", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:epicboe", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:epicboe"] = { name = "Epic BoE", itemID = 5, bindType = 2, rarity = 4 } },
  })
  A.db.sendReagents = false
  A.db.sendBoe = true

  local _, itemCount = A:BuildMailQueue("DefaultRecipient", "BoeAlt")
  Testkit.AssertEqual(itemCount, 0, "BoE handling must stay out of the reagent bag")
end)

Testkit.Test("BuildMailQueue does not apply BoE handling to the reagent bag", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:epicboe", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:epicboe"] = { name = "Epic BoE", itemID = 5, bindType = 2, rarity = 4 } },
  })
  A.db.sendReagents = true
  A.db.sendBoe = true

  -- Everything in the reagent bag is mailed to the default recipient whatever
  -- it is, so a BoE sitting there must not be diverted to the BoE recipient.
  local batches = A:BuildMailQueue("DefaultRecipient", "BoeAlt")
  Testkit.AssertEqual(#batches, 1)
  Testkit.AssertEqual(batches[1].recipient, "DefaultRecipient")
end)

--[[
  The per-run debug account. A run that queues nothing used to log one line
  and no reason, which is exactly when the log matters most.
]]

Testkit.Test("LogQueueDetail records the recipient, subject and contents of each batch", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    debugLogging = true,
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertTrue(A:LoggedContains("Batch 1 to Bankalt"), "the batch's recipient should be logged")
  Testkit.AssertTrue(A:LoggedContains("subject=Linen Cloth"), "the mail subject should be logged")
  Testkit.AssertTrue(A:LoggedContains("[Linen Cloth]"), "the batch contents should be logged by name")
end)

Testkit.Test("LogQueueDetail describes the gold batch rather than treating it as items", function()
  local A = NewFakeAddon({}, { money = 600000, debugLogging = true })
  A.db.sendExcessGold = true
  A.db.goldThreshold = 5

  A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertTrue(A:LoggedContains("excess gold, amount resolved at send time"),
      "the gold batch has no items and no subject yet, so it needs its own line")
end)

Testkit.Test("BuildMailQueue accounts for soulbound and locked items it passed over", function()
  local A = NewFakeAddon({
    [0] = {
      { itemLink = "item:1", locked = true, soulbound = false },
      { itemLink = "item:2", locked = false, soulbound = true },
    },
  }, {
    itemInfoByLink = {
      ["item:1"] = { name = "Locked Item", itemID = 1, bindType = 0 },
      ["item:2"] = { name = "Soulbound Item", itemID = 2, bindType = 0 },
    },
    debugLogging = true,
  })
  tinsert(A:GetAutoMailEntries(), { itemName = "Item", recipient = "Bankalt" })

  A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertTrue(A:LoggedContains("soulbound"), "a soulbound skip must be accounted for")
  Testkit.AssertTrue(A:LoggedContains("locked by the client"), "a locked skip must be accounted for")
end)

-- The case that produced the original "0 batch(es), no reason given" report.
Testkit.Test("BuildMailQueue says so when nothing matched a rule", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    debugLogging = true,
  })

  local _, itemCount = A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertEqual(itemCount, 0)
  Testkit.AssertTrue(A:LoggedContains("matched no rule"), "an empty run must say why it is empty")
  -- Samples record the item link, not the name: in chat a link renders as a
  -- clickable, quality-coloured [Linen Cloth], which is what the rest of the
  -- run's logging already does.
  Testkit.AssertTrue(A:LoggedContains("item:2589"), "and identify what it passed over")
end)

Testkit.Test("BuildMailQueue accounts for a rule pointing at the current character", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    currentCharacter = "Bankalt",
    debugLogging = true,
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "Bankalt" })

  A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertTrue(A:LoggedContains("recipient is the currently logged in character"))
end)

-- A rule that matched but names nobody, with no default to fall back on, is
-- reachable now that a run can start on rule recipients alone.
Testkit.Test("BuildMailQueue accounts for a matched rule with no recipient anywhere", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    debugLogging = true,
  })
  tinsert(A:GetAutoMailEntries(), { itemID = 2589, itemName = "Linen Cloth", recipient = "" })

  A:BuildMailQueue("", "")
  Testkit.AssertTrue(A:LoggedContains("rule matched but has no recipient"))
end)

-- A full bag of unmatched items must not bury the rest of the log.
Testkit.Test("BuildMailQueue samples rather than lists every skipped item", function()
  local bag, itemInfoByLink = {}, {}
  for i = 1, 12 do
    local link = "item:" .. i
    bag[i] = { itemLink = link, locked = false, soulbound = false }
    itemInfoByLink[link] = { name = "Thing " .. i, itemID = i, bindType = 0 }
  end

  local A = NewFakeAddon({ [0] = bag }, { itemInfoByLink = itemInfoByLink, debugLogging = true })
  A:BuildMailQueue("DefaultRecipient", "")

  Testkit.AssertTrue(A:LoggedContains("Skipped 12 item(s)"), "the full count is still reported")
  Testkit.AssertTrue(A:LoggedContains("(4 more)"), "but only the first 8 are named")
end)

Testkit.Test("BuildMailQueue collects no skip reasons when debug logging is off", function()
  local A = NewFakeAddon({
    [0] = { { itemLink = "item:2589", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:2589"] = { name = "Linen Cloth", itemID = 2589, bindType = 0 } },
    debugLogging = false,
  })

  A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(#A.logged, 0, "the accounting shouldn't run when nobody will read it")
end)

--[[ Excess-gold arithmetic ]]

Testkit.Test("ExcessGoldToSend subtracts the threshold and this mail's postage", function()
  local A = NewFakeAddon({})

  Testkit.AssertEqual(A:ExcessGoldToSend(600000, 500000, 3000), 97000,
      "the balance should land exactly on the threshold once postage is paid")
  Testkit.AssertEqual(A:ExcessGoldToSend(600000, 500000, 0), 100000)
end)

-- The shortfall bug in 5.x came from postage not being accounted for here.
-- These pin the boundaries around it.
Testkit.Test("ExcessGoldToSend never returns a negative amount", function()
  local A = NewFakeAddon({})

  Testkit.AssertEqual(A:ExcessGoldToSend(500100, 500000, 3000), 0,
      "postage larger than the excess must clamp to zero, not go negative")
  Testkit.AssertEqual(A:ExcessGoldToSend(500000, 500000, 0), 0, "exactly on the threshold sends nothing")
  Testkit.AssertEqual(A:ExcessGoldToSend(100, 500000, 0), 0, "below the threshold sends nothing")
end)

Testkit.Test("HasExcessGold is strictly above the threshold", function()
  local A = NewFakeAddon({})

  Testkit.AssertEqual(A:HasExcessGold(500001, 500000), true)
  Testkit.AssertEqual(A:HasExcessGold(500000, 500000), false, "exactly on the threshold is not excess")
  Testkit.AssertEqual(A:HasExcessGold(0, 500000), false)
end)

Testkit.Test("SummarizeQueue rolls a queue up into totals for the confirmation dialog", function()
  local A = NewFakeAddon({}, { money = 600000 })
  local queue = {
    { recipient = "Bankalt", items = { {}, {} } },
    { recipient = "Bankalt2", items = { {} } },
    { recipient = "Bankalt", items = {}, goldThresholdCopper = 500000 },
  }

  local summary = A:SummarizeQueue(queue)
  Testkit.AssertEqual(summary.mailCount, 3)
  Testkit.AssertEqual(summary.itemCount, 3)
  Testkit.AssertEqual(summary.goldCopper, 100000)
  Testkit.AssertEqual(summary.goldRecipient, "Bankalt")
  Testkit.AssertEqual(#summary.recipients, 2)
end)

return true
