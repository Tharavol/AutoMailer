-- AutoMailer - automatically mail items out of your bags in World of Warcraft.
-- Copyright (C) ChillFajita, RainForDays and the AutoMailer contributors.
-- SPDX-License-Identifier: GPL-3.0-only

local Testkit = require("tests.testkit")

-- A tiny fake bag: bagContents[bag][slot] = { itemLink, locked, soulbound }.
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
    -- BuildMailQueue reads; only locked (3rd) and itemLink (7th) are used.
    return nil, 1, entry.locked or false, entry.quality or 1, false, false, entry.itemLink
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
  A.db.SendBOE = true
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
  A.db.SendReagents = true

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
  A.db.SendBOE = true

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
  A.db.SendReagents = true
  tinsert(A:GetAutoMailEntries(), { itemID = 99, itemName = "Some Reagent", recipient = "ReagentAlt" })

  local batches = A:BuildMailQueue("DefaultRecipient", "")
  Testkit.AssertEqual(batches[1].recipient, "ReagentAlt")
end)

Testkit.Test("BuildMailQueue does not apply BoE handling to the reagent bag", function()
  local A = NewFakeAddon({
    [5] = { { itemLink = "item:epicboe", locked = false, soulbound = false } },
  }, {
    itemInfoByLink = { ["item:epicboe"] = { name = "Epic BoE", itemID = 5, bindType = 2, rarity = 4 } },
  })
  A.db.SendReagents = true
  A.db.SendBOE = true

  -- Everything in the reagent bag is mailed to the default recipient whatever
  -- it is, so a BoE sitting there must not be diverted to the BoE recipient.
  local batches = A:BuildMailQueue("DefaultRecipient", "BoeAlt")
  Testkit.AssertEqual(#batches, 1)
  Testkit.AssertEqual(batches[1].recipient, "DefaultRecipient")
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
