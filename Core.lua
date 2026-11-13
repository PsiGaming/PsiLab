-- PsiLab: a development tool that collects facts about the game client and saves them to a file.
-- Read-only: modules only call "get" functions and record the answers in PsiLabDB, which the game
-- writes to WTF/Account/<account>/SavedVariables/PsiLab.lua on /reload or logout.
-- Every check runs inside pcall: failures are recorded in the session's error list, never shown as popups.
--
-- Modules (Modules/*.lua) each collect data for one project. A module registers itself with
--   lab:RegisterModule(name, { events = { "EVENT", ... }, OnEvent = fn(m, event, ...), Run = fn(m) })
-- and stores its data in m.data (saved, kept across /reload; "/lab reset <module>" empties it).

local ADDON_NAME, lab = ...

local MAX_DEPTH = 6         -- table depth when copying values for saving
local MAX_CHILDREN = 60     -- named children recorded per frame
local MAX_ERRORS = 200      -- errors kept per session
local MAX_EVENT_TIMES = 30  -- timestamps kept per event
local MAX_DUMPS = 100       -- saved /lab dump results

lab.modules = {}
lab.moduleOrder = {}

---------------------------------------------------------------------------
-- Helpers for modules
---------------------------------------------------------------------------

function lab.Print(msg)
	print("|cffcc66ffPsiLab:|r " .. msg)
end

-- Copies a value so it can be saved: keeps strings, numbers, booleans and tables of those.
function lab.Copy(value, depth)
	local t = type(value)
	if t == "nil" then return nil end
	if t == "string" or t == "number" or t == "boolean" then return value end
	if t ~= "table" then return "<" .. t .. ">" end
	depth = depth or 0
	if depth >= MAX_DEPTH then return "<table, depth limit>" end
	if type(value.GetObjectType) == "function" then return "<frame>" end
	local out = {}
	for k, v in pairs(value) do
		local kt = type(k)
		if kt == "string" or kt == "number" then out[k] = lab.Copy(v, depth + 1) end
	end
	return out
end

-- Packs all return values into a saveable list with their count, so nils stay visible as "<nil>".
function lab.Pack(...)
	local out = { n = select("#", ...) }
	for i = 1, out.n do
		local v = select(i, ...)
		if v == nil then out[i] = "<nil>" else out[i] = lab.Copy(v) end
	end
	return out
end

function lab.RecordError(text)
	local errors = lab.db and lab.db.errors
	if errors and #errors < MAX_ERRORS then errors[#errors + 1] = text end
end

-- Runs fn(...) in pcall. Returns the packed results, or nil after recording the error under `label`.
function lab.Try(label, fn, ...)
	if type(fn) ~= "function" then
		lab.RecordError(label .. ": not a function (" .. type(fn) .. ")")
		return nil
	end
	local results = { pcall(fn, ...) }
	if not results[1] then
		lab.RecordError(label .. ": " .. tostring(results[2]))
		return nil
	end
	return lab.Pack(unpack(results, 2, table.maxn(results)))
end

-- Returns the type of the value at a dotted path such as "C_Item.GetItemInfo", or false if it doesn't exist.
function lab.Exists(path)
	local value = _G
	for part in string.gmatch(path, "[^%.]+") do
		if type(value) ~= "table" then return false end
		value = value[part]
	end
	return value ~= nil and type(value) or false
end

function lab.Now()
	return { time = time(), date = date("%Y-%m-%d %H:%M:%S"), uptime = GetTime() }
end

-- Describes a frame: type, name, size, anchor points and its named children (parentKey fields), one level deep.
function lab.DescribeFrame(frame)
	if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then return tostring(frame) end
	local d = {
		type = frame:GetObjectType(),
		name = frame.GetName and frame:GetName() or nil,
		shown = frame.IsShown and frame:IsShown() or nil,
		size = lab.Pack(frame:GetSize()),
		points = {},
		children = {},
	}
	if frame.GetNumPoints then
		for i = 1, frame:GetNumPoints() do
			local point, relativeTo, relativePoint, x, y = frame:GetPoint(i)
			d.points[i] = {
				point = point, relativePoint = relativePoint, x = x, y = y,
				relativeTo = type(relativeTo) == "table" and relativeTo.GetName and relativeTo:GetName()
					or tostring(relativeTo),
			}
		end
	end
	local count = 0
	for key, value in pairs(frame) do
		if type(key) == "string" and type(value) == "table" and type(value.GetObjectType) == "function" then
			count = count + 1
			if count > MAX_CHILDREN then break end
			local ok, w, h = pcall(value.GetSize, value)
			d.children[key] = {
				type = value:GetObjectType(),
				shown = value.IsShown and value:IsShown() or nil,
				width = ok and w or nil, height = ok and h or nil,
			}
		end
	end
	return d
end

---------------------------------------------------------------------------
-- Modules and events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

function lab:RegisterModule(name, module)
	module.name = name
	self.modules[name] = module
	self.moduleOrder[#self.moduleOrder + 1] = name
	for _, event in ipairs(module.events or {}) do eventFrame:RegisterEvent(event) end
end

local function CountEvent(event)
	local e = lab.db.events[event]
	if not e then
		e = { count = 0, times = {} }
		lab.db.events[event] = e
	end
	e.count = e.count + 1
	if #e.times < MAX_EVENT_TIMES then e.times[#e.times + 1] = GetTime() end
end

-- Calls a module function safely; errors go to the session's error list.
local function CallModule(module, method, ...)
	local fn = module[method]
	if type(fn) ~= "function" then return end
	local ok, err = pcall(fn, module, ...)
	if not ok then lab.RecordError(module.name .. "." .. method .. ": " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- General information (collected for every module)
---------------------------------------------------------------------------

local function CollectGeneral()
	local g = { at = lab.Now() }
	g.buildInfo = lab.Try("GetBuildInfo", GetBuildInfo)
	g.realmName = lab.Try("GetRealmName", GetRealmName)
	g.normalizedRealmName = lab.Try("GetNormalizedRealmName", GetNormalizedRealmName)
	g.realmID = lab.Try("GetRealmID", GetRealmID)
	g.faction = lab.Try("UnitFactionGroup", UnitFactionGroup, "player")
	g.locale = lab.Try("GetLocale", GetLocale)
	if C_CVar then g.scriptErrors = lab.Try("C_CVar.GetCVar scriptErrors", C_CVar.GetCVar, "scriptErrors") end
	g.addons = {}
	if C_AddOns and C_AddOns.GetNumAddOns then
		for i = 1, C_AddOns.GetNumAddOns() do
			local name, title = C_AddOns.GetAddOnInfo(i)
			if name then
				g.addons[name] = {
					title = title,
					loaded = C_AddOns.IsAddOnLoaded(name),
					version = C_AddOns.GetAddOnMetadata(name, "Version"),
				}
			end
		end
	end
	lab.db.general = g
end

local function RunAll()
	local ok, err = pcall(CollectGeneral)
	if not ok then lab.RecordError("general: " .. tostring(err)) end
	for _, name in ipairs(lab.moduleOrder) do CallModule(lab.modules[name], "Run") end
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function InitDB()
	local old = type(PsiLabDB) == "table" and PsiLabDB or {}
	-- Module data and dumps are kept across /reload; errors and event counts are per session.
	PsiLabDB = {
		labVersion = 1,
		session = nil,
		errors = {},
		events = {},
		dumps = type(old.dumps) == "table" and old.dumps or {},
		modules = type(old.modules) == "table" and old.modules or {},
	}
	lab.db = PsiLabDB
	for _, name in ipairs(lab.moduleOrder) do
		local module = lab.modules[name]
		lab.db.modules[name] = lab.db.modules[name] or {}
		module.data = lab.db.modules[name]
	end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON_NAME then InitDB() end
		return
	end
	if not lab.db then return end
	CountEvent(event)
	if event == "PLAYER_LOGIN" then
		lab.db.session = lab.Now()
		RunAll()
		lab.Print("ready. /lab for commands. /reload or log out to write the file.")
	end
	for _, name in ipairs(lab.moduleOrder) do
		local module = lab.modules[name]
		for _, e in ipairs(module.events or {}) do
			if e == event then
				CallModule(module, "OnEvent", event, ...)
				break
			end
		end
	end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

local function Dump(expression)
	local entry = { expression = expression, at = lab.Now() }
	local chunk, compileError = loadstring("return " .. expression)
	if not chunk then
		entry.error = compileError
	else
		local results = { pcall(chunk) }
		if results[1] then
			entry.result = lab.Pack(unpack(results, 2, table.maxn(results)))
		else
			entry.error = tostring(results[2])
		end
	end
	local dumps = lab.db.dumps
	if #dumps >= MAX_DUMPS then table.remove(dumps, 1) end
	dumps[#dumps + 1] = entry
	lab.Print(entry.error and ("dump failed: " .. entry.error) or ("saved dump #" .. #dumps .. "."))
end

local function Status()
	local parts = {}
	for _, name in ipairs(lab.moduleOrder) do
		local count = 0
		for _ in pairs(lab.modules[name].data or {}) do count = count + 1 end
		parts[#parts + 1] = name .. " (" .. count .. " entries)"
	end
	lab.Print(string.format("modules: %s. Errors this session: %d. Saved dumps: %d.",
		#parts > 0 and table.concat(parts, ", ") or "none", #lab.db.errors, #lab.db.dumps))
end

SLASH_PSILAB1 = "/lab"
SLASH_PSILAB2 = "/psilab"  -- backup alias in case another addon takes /lab
SlashCmdList.PSILAB = function(msg)
	if not lab.db then return end
	msg = strtrim(msg or "")
	local command, rest = msg:match("^(%S*)%s*(.-)$")
	command = command:lower()
	if command == "run" then
		RunAll()
		Status()
	elseif command == "status" then
		Status()
	elseif command == "dump" and rest ~= "" then
		Dump(rest)
	elseif command == "reset" and lab.modules[rest] then
		wipe(lab.modules[rest].data)
		lab.Print("emptied module " .. rest .. ".")
	else
		lab.Print("commands:")
		print("  /lab run - collect everything now")
		print("  /lab status - what has been collected")
		print("  /lab dump <lua expression> - save the expression's result to the file")
		print("  /lab reset <module> - empty one module's data")
		print("  Data is written to the file on /reload or logout.")
	end
end
