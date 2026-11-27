-- PsiLab module: ProfitCraft.
-- Collects what ProfitCraft 0.1 relies on: the recipe API, recipe data (output quantities, reagents),
-- item stack sizes and sell prices, Auctionator's public API on Forever, and the profession window's layout.
-- Also, for the trainer and recipe tooltips: trainer services and their tooltip data, recipe items in the
-- bags, and whether recipes can be read with no profession window open.
-- Captures automatically each time a profession window or trainer opens; "/lab run" captures again.

local _, lab = ...

local CALLER_ID = "PsiLab"
local MAX_RECIPES = 200          -- learned recipes recorded in detail per profession
local MAX_UNLEARNED_SAMPLE = 15  -- unlearned recipes recorded (id, name, profession) as examples
local MAX_SEEN_REALMS = 100      -- distinct realms recorded from targeted / hovered players
local MAX_TRAINER_SERVICES = 80  -- trainer services recorded per trainer
local MAX_RECIPE_ITEMS = 20      -- recipe items (Recipe:, Pattern:, Plans: ...) recorded from the bags
local MAX_CLOSED_CHECKS = 10     -- recipes read again while no profession window is open
local RECIPE_ITEM_CLASS = 9      -- Enum.ItemClass.Recipe

-- Items to check (Vanilla IDs; the recorded names show whether they match in Forever).
local TEST_ITEMS = {
  2318,  -- Light Leather
  2319,  -- Medium Leather
  4234,  -- Heavy Leather
  2320,  -- Coarse Thread
  2321,  -- Fine Thread
  2589,  -- Linen Cloth
  4289,  -- Salt
}

local module = {
  description = "Recipe API, recipe data, item stack sizes and sell prices, Auctionator's API, the profession "
    .. "window's layout, trainer services and recipe items. Captures when a profession window or trainer opens.",
  events = { "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED",
    "BAG_UPDATE_DELAYED", "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "GET_ITEM_INFO_RECEIVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "TRAINER_UPDATE" },
}

local function AuctionatorAPI()
  return type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1 or nil
end

function module:CheckItems()
  if not (C_Item and C_Item.GetItemInfo) then return end
  self.data.items = self.data.items or {}
  for _, itemID in ipairs(TEST_ITEMS) do
    local info = lab.Try("C_Item.GetItemInfo " .. itemID, C_Item.GetItemInfo, itemID)
    if info and info.n > 0 and info[1] ~= "<nil>" then
      self.data.items[itemID] = {
        name = info[1], stackCount = info[8], sellPrice = info[11],
        classID = info[12], subclassID = info[13], isCraftingReagent = info[17], all = info,
      }
    elseif type(self.data.items[itemID]) ~= "table" then
      self.data.items[itemID] = "not loaded yet"
      if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    end
  end
end

-- Records Auctionator's answers for one item (once per item per session).
function module:CheckAuctionatorItem(itemID)
  local api = AuctionatorAPI()
  if not api or not itemID then return end
  local prices = self.data.auctionator.prices
  if prices[itemID] and prices[itemID].session == lab.db.session.time then return end
  prices[itemID] = {
    session = lab.db.session.time,
    price = lab.Try("Auctionator price " .. itemID, api.GetAuctionPriceByItemID, CALLER_ID, itemID),
    age = lab.Try("Auctionator age " .. itemID, api.GetAuctionAgeByItemID, CALLER_ID, itemID),
    vendor = lab.Try("Auctionator vendor " .. itemID, api.GetVendorPriceByItemID, CALLER_ID, itemID),
    exact = api.IsAuctionDataExactByItemID
      and lab.Try("Auctionator exact " .. itemID, api.IsAuctionDataExactByItemID, CALLER_ID, itemID)
      or "<no function>",
  }
end

local registeredForUpdates = false
function module:CheckAuctionator()
  self.data.auctionator = self.data.auctionator or { prices = {} }
  local a = self.data.auctionator
  local api = AuctionatorAPI()
  a.apiPresent = api ~= nil
  if not api then return end
  a.functions = {}
  for name, value in pairs(api) do a.functions[name] = type(value) end
  for _, itemID in ipairs(TEST_ITEMS) do self:CheckAuctionatorItem(itemID) end
  a.dbUpdates = a.dbUpdates or { count = 0, times = {} }
  if not registeredForUpdates and type(api.RegisterForDBUpdate) == "function" then
    registeredForUpdates = true
    a.registerResult = lab.Try("Auctionator RegisterForDBUpdate", api.RegisterForDBUpdate, CALLER_ID, function()
      -- Look the table up on each call: "/lab reset ProfitCraft" replaces the module's data.
      local current = self.data.auctionator
      if not (current and current.dbUpdates) then return end
      local u = current.dbUpdates
      u.count = u.count + 1
      if #u.times < 30 then u.times[#u.times + 1] = lab.Now() end
    end)
  end
end

function module:CheckApis()
  local apis = {}
  for _, path in ipairs({
    "C_TradeSkillUI", "C_TradeSkillUI.GetFilteredRecipeIDs", "C_TradeSkillUI.GetAllRecipeIDs",
    "C_TradeSkillUI.GetRecipeSchematic", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeOutputItemData",
    "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetChildProfessionInfo", "C_TradeSkillUI.OpenRecipe",
    "C_Item.GetItemInfo", "C_Item.RequestLoadItemDataByID", "C_Item.GetItemCount",
    "C_AuctionHouse", "C_MerchantFrame.GetItemInfo", "C_Timer.After",
    "ProfessionsFrame", "UISpecialFrames", "Auctionator", "Auctionator.API", "Auctionator.API.v1",
  }) do
    apis[path] = lab.Exists(path)
  end
  self.data.apis = apis
end

function module:CheckFrames()
  if type(ProfessionsFrame) ~= "table" then return end
  local f = { at = lab.Now() }
  f.ProfessionsFrame = lab.DescribeFrame(ProfessionsFrame)
  local page = ProfessionsFrame.CraftingPage
  f.CraftingPage = lab.DescribeFrame(page)
  if type(page) == "table" then
    f.SchematicForm = lab.DescribeFrame(page.SchematicForm)
    f.RecipeList = lab.DescribeFrame(page.RecipeList)
  end
  self.data.frames = f
end

function module:CheckProfession()
  if not C_TradeSkillUI then return end
  local p = { at = lab.Now() }
  p.baseProfession = lab.Try("GetBaseProfessionInfo", C_TradeSkillUI.GetBaseProfessionInfo)
  p.childProfession = lab.Try("GetChildProfessionInfo", C_TradeSkillUI.GetChildProfessionInfo)
  local base = p.baseProfession and p.baseProfession[1]
  local key = type(base) == "table" and type(base.professionName) == "string" and base.professionName or "unknown"

  local filtered = lab.Try("GetFilteredRecipeIDs", C_TradeSkillUI.GetFilteredRecipeIDs)
  local filteredIDs = filtered and type(filtered[1]) == "table" and filtered[1] or {}
  p.filteredCount = #filteredIDs
  p.filteredIDs = filteredIDs

  -- GetAllRecipeIDs: which profession each recipe belongs to, and which are learned.
  local ids = {}  -- learned recipes, recorded in detail below
  if C_TradeSkillUI.GetAllRecipeIDs then
    local all = lab.Try("GetAllRecipeIDs", C_TradeSkillUI.GetAllRecipeIDs)
    local allIDs = all and type(all[1]) == "table" and all[1] or {}
    local inFiltered = {}
    for _, id in ipairs(filteredIDs) do inFiltered[id] = true end
    local summary = { total = #allIDs, learned = 0, byProfession = {}, unlearnedSample = {},
      learnedNotInFiltered = 0, filteredNotLearned = 0, infoMissing = 0 }
    for _, id in ipairs(allIDs) do
      local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
      local okProf, prof = pcall(C_TradeSkillUI.GetProfessionInfoByRecipeID, id)
      local profName = okProf and type(prof) == "table" and (prof.parentProfessionName or prof.professionName)
        or "<unknown>"
      if profName == "" then profName = "<empty>" end
      local bucket = summary.byProfession[profName]
      if not bucket then
        bucket = { total = 0, learned = 0 }
        summary.byProfession[profName] = bucket
      end
      bucket.total = bucket.total + 1
      if not (okInfo and type(info) == "table") then
        summary.infoMissing = summary.infoMissing + 1
      elseif info.learned then
        summary.learned = summary.learned + 1
        bucket.learned = bucket.learned + 1
        ids[#ids + 1] = id
        if not inFiltered[id] then summary.learnedNotInFiltered = summary.learnedNotInFiltered + 1 end
      else
        if inFiltered[id] then summary.filteredNotLearned = summary.filteredNotLearned + 1 end
        if #summary.unlearnedSample < MAX_UNLEARNED_SAMPLE then
          summary.unlearnedSample[#summary.unlearnedSample + 1] = { id = id, name = info.name, profession = profName }
        end
      end
    end
    p.allRecipes = summary
    p.allCount = #allIDs
  else
    p.allCount = "<no function>"
    ids = filteredIDs
  end

  self.data.auctionator = self.data.auctionator or { prices = {} }
  p.recipes = {}
  for i = 1, math.min(#ids, MAX_RECIPES) do
    local recipeID = ids[i]
    local r = { recipeID = recipeID }
    r.info = lab.Try("GetRecipeInfo " .. recipeID, C_TradeSkillUI.GetRecipeInfo, recipeID)
    r.schematic = lab.Try("GetRecipeSchematic " .. recipeID, C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    r.output = lab.Try("GetRecipeOutputItemData " .. recipeID, C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    local s = r.schematic and r.schematic[1]
    if type(s) == "table" then
      if s.outputItemID and C_Item and C_Item.GetItemInfo then
        local item = lab.Try("GetItemInfo output " .. s.outputItemID, C_Item.GetItemInfo, s.outputItemID)
        r.outputStackCount = item and item[8]
        r.outputSellPrice = item and item[11]
        self:CheckAuctionatorItem(s.outputItemID)
      end
      for _, slot in ipairs(type(s.reagentSlotSchematics) == "table" and s.reagentSlotSchematics or {}) do
        for _, reagent in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
          if type(reagent) == "table" and reagent.itemID then self:CheckAuctionatorItem(reagent.itemID) end
        end
      end
    end
    p.recipes[i] = r
  end

  self.data.professions = self.data.professions or {}
  self.data.professions[key] = p
  self:CheckFrames()
  lab.Print(string.format("ProfitCraft: captured %s (window lists %d; all recipes %s, learned %s; %d recorded in detail).",
    key, p.filteredCount, tostring(p.allCount), tostring(p.allRecipes and p.allRecipes.learned or "?"), #p.recipes))
end

-- Trainer and recipe-item checks (added 2026-11-14, for ProfitCraft's trainer and recipe tooltips).
-- What a recipe's details look like when read with no profession window open.
local function ReadRecipe(recipeID)
  local r = { recipeID = recipeID }
  r.info = lab.Try("GetRecipeInfo " .. recipeID, C_TradeSkillUI.GetRecipeInfo, recipeID)
  r.schematic = lab.Try("GetRecipeSchematic " .. recipeID, C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  r.profession = lab.Try("GetProfessionInfoByRecipeID " .. recipeID, C_TradeSkillUI.GetProfessionInfoByRecipeID,
    recipeID)
  return r
end

local function ProfessionWindowOpen()
  return type(ProfessionsFrame) == "table" and ProfessionsFrame:IsShown() or false
end

-- At a trainer: each service's info, cost and full tooltip data (does it carry the recipe's ID?), and the
-- recipe read from that ID while the profession window is (normally) closed.
function module:CheckTrainer()
  if type(GetNumTrainerServices) ~= "function" then return end
  local t = { at = lab.Now(), professionWindowOpen = ProfessionWindowOpen(), services = {} }
  local count = lab.Try("GetNumTrainerServices", GetNumTrainerServices)
  t.count = count and count[1]
  t.npc = lab.Try("UnitName npc", UnitName, "npc")
  for i = 1, math.min(type(t.count) == "number" and t.count or 0, MAX_TRAINER_SERVICES) do
    local s = { index = i }
    s.info = lab.Try("GetTrainerServiceInfo " .. i, GetTrainerServiceInfo, i)
    s.cost = lab.Try("GetTrainerServiceCost " .. i, GetTrainerServiceCost, i)
    s.skillLine = lab.Try("GetTrainerServiceSkillLine " .. i, GetTrainerServiceSkillLine, i)
    s.skillReq = lab.Try("GetTrainerServiceSkillReq " .. i, GetTrainerServiceSkillReq, i)
    if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
      local data = lab.Try("C_TooltipInfo.GetTrainerService " .. i, C_TooltipInfo.GetTrainerService, i)
      local tip = data and data[1]
      s.tooltip = tip
      if type(tip) == "table" and type(tip.id) == "number" and C_TradeSkillUI then s.recipe = ReadRecipe(tip.id) end
    end
    t.services[i] = s
  end
  self.data.trainers = self.data.trainers or {}
  local name = t.npc and t.npc[1]
  self.data.trainers[type(name) == "string" and name or "unknown"] = t
  lab.Print(string.format("ProfitCraft: captured trainer %s (%s services).", tostring(name), tostring(t.count)))
end

-- Recipe items in the bags: item info, the item's spell, its full tooltip data (does it name the recipe or
-- the crafted item?), and the recipe read from the spell ID.
function module:CheckRecipeItems()
  if not (C_Container and C_Item) then return end
  local found, seen = {}, {}
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local itemID = info and info.itemID
      if itemID and not seen[itemID] and #found < MAX_RECIPE_ITEMS
        and select(12, C_Item.GetItemInfo(itemID)) == RECIPE_ITEM_CLASS then
        seen[itemID] = true
        local r = { itemID = itemID, link = info.hyperlink, bag = bag, slot = slot }
        r.itemInfo = lab.Try("GetItemInfo " .. itemID, C_Item.GetItemInfo, itemID)
        r.itemSpell = lab.Try("GetItemSpell " .. itemID, C_Item.GetItemSpell, itemID)
        if C_TooltipInfo and C_TooltipInfo.GetBagItem then
          local data = lab.Try("C_TooltipInfo.GetBagItem " .. bag .. " " .. slot, C_TooltipInfo.GetBagItem, bag, slot)
          r.tooltip = data and data[1]
        end
        local spellID = r.itemSpell and r.itemSpell[2]
        if type(spellID) == "number" and C_TradeSkillUI then r.recipeFromSpell = ReadRecipe(spellID) end
        found[#found + 1] = r
      end
    end
  end
  self.data.recipeItems = { at = lab.Now(), professionWindowOpen = ProfessionWindowOpen(), items = found }
end

-- Reads recipes recorded earlier (learned and unlearned) again while no profession window is open: can
-- ProfitCraft read reagents and products away from the profession window?
function module:CheckRecipesWhileClosed()
  if ProfessionWindowOpen() or not (C_TradeSkillUI and self.data.professions) then return end
  local ids = {}
  for _, p in pairs(self.data.professions) do
    for _, r in ipairs(type(p.recipes) == "table" and p.recipes or {}) do
      if #ids < MAX_CLOSED_CHECKS / 2 then ids[#ids + 1] = r.recipeID end
    end
    local sample = type(p.allRecipes) == "table" and p.allRecipes.unlearnedSample or {}
    for _, r in ipairs(sample) do
      if #ids < MAX_CLOSED_CHECKS then ids[#ids + 1] = r.id end
    end
  end
  local out = { at = lab.Now(), recipes = {} }
  for _, id in ipairs(ids) do out.recipes[#out.recipes + 1] = ReadRecipe(id) end
  self.data.recipesWhileClosed = out
end

function module:Run()
  self:CheckApis()
  self:CheckItems()
  self:CheckAuctionator()
  self:CheckRecipeItems()
  self:CheckRecipesWhileClosed()
  if ProfessionWindowOpen() then self:CheckProfession() end
  if type(ClassTrainerFrame) == "table" and ClassTrainerFrame:IsShown() then self:CheckTrainer() end
end

local capturePending, trainerPending = false, false
function module:OnEvent(event)
  if event == "TRAINER_UPDATE" and not trainerPending then
    -- TRAINER_UPDATE can fire several times in a row; capture once, a moment later.
    trainerPending = true
    C_Timer.After(1, function()
      trainerPending = false
      local ok, err = pcall(self.CheckTrainer, self)
      if not ok then lab.RecordError("ProfitCraft.CheckTrainer: " .. tostring(err)) end
    end)
  elseif event == "TRADE_SKILL_SHOW" and not capturePending then
    -- Wait a moment after the window opens so the recipe list is filled.
    capturePending = true
    C_Timer.After(1, function()
      capturePending = false
      local ok, err = pcall(self.CheckProfession, self)
      if not ok then lab.RecordError("ProfitCraft.CheckProfession: " .. tostring(err)) end
    end)
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    self:CheckItems()
  elseif event == "PLAYER_TARGET_CHANGED" then
    self:RecordRealm("target")
  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    self:RecordRealm("mouseover")
  end
end

-- Counts the realms of other players you target or hover over: shows whether players from
-- several realms share this ruleset's world (and so, probably, its AH).
function module:RecordRealm(unit)
  if not (UnitExists(unit) and UnitIsPlayer(unit)) or UnitIsUnit(unit, "player") then return end
  local _, realm = UnitFullName(unit)
  realm = (realm and realm ~= "") and realm or "<same as yours>"
  self.data.seenRealms = self.data.seenRealms or {}
  local seen = self.data.seenRealms
  if seen[realm] then
    seen[realm] = seen[realm] + 1
  else
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    if count < MAX_SEEN_REALMS then seen[realm] = 1 end
  end
end

lab:RegisterModule("ProfitCraft", module)
