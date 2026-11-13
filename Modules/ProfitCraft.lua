-- PsiLab module: ProfitCraft.
-- Collects what ProfitCraft 0.1 relies on: the recipe API, recipe data (output quantities, reagents),
-- item stack sizes and sell prices, Auctionator's public API on Forever, and the profession window's layout.
-- Captures automatically each time a profession window opens; "/lab run" captures again.

local _, lab = ...

local CALLER_ID = "PsiLab"
local MAX_RECIPES = 40  -- recipes recorded in detail per profession

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
	events = { "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED",
		"BAG_UPDATE_DELAYED", "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
		"GET_ITEM_INFO_RECEIVED" },
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
	local ids = filtered and type(filtered[1]) == "table" and filtered[1] or {}
	p.filteredCount = #ids
	p.filteredIDs = ids
	if C_TradeSkillUI.GetAllRecipeIDs then
		local all = lab.Try("GetAllRecipeIDs", C_TradeSkillUI.GetAllRecipeIDs)
		p.allCount = all and type(all[1]) == "table" and #all[1] or "<error>"
	else
		p.allCount = "<no function>"
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
	lab.Print(string.format("ProfitCraft: captured %s (%d recipes listed, %d recorded in detail).", key,
		p.filteredCount, #p.recipes))
end

function module:Run()
	self:CheckApis()
	self:CheckItems()
	self:CheckAuctionator()
	if type(ProfessionsFrame) == "table" and ProfessionsFrame:IsShown() then self:CheckProfession() end
end

local capturePending = false
function module:OnEvent(event)
	if event == "TRADE_SKILL_SHOW" and not capturePending then
		-- Wait a moment after the window opens so the recipe list is filled.
		capturePending = true
		C_Timer.After(1, function()
			capturePending = false
			local ok, err = pcall(self.CheckProfession, self)
			if not ok then lab.RecordError("ProfitCraft.CheckProfession: " .. tostring(err)) end
		end)
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		self:CheckItems()
	end
end

lab:RegisterModule("ProfitCraft", module)
