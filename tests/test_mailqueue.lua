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
    return info.name, nil, info.rarity, nil, info.minLevel, nil, nil, nil, nil, nil, nil, nil, nil, info.bindType
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
