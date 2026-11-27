-- PsiLab module: Procable. Collects what Procable (the author's aura and alert addon) needs to
-- know about Forever, per character (its plan/RESEARCH.md, "To confirm in game"):
--   * Blizzard's Cooldown Manager catalogue for the class: every entry in every category, learned or not
--     (C_CooldownViewer.GetCooldownViewerCategorySet with allowUnlearned), with its spell and flags;
--   * the spellbook (every item with its spell ID) and talent points per tree;
--   * your own buffs and your debuffs on the target, out of combat (Inner Fire's charges, judgements);
--   * what stays readable in combat (a probe 2 s into every fight): own power and health, absorbs, target,
--     spell cooldown, usable, range, your buffs by the instance ID remembered before the fight;
--   * your own casts (UNIT_SPELLCAST_SUCCEEDED) in and out of combat, with nameplate counts, for the crowd
--     control tests (Fear, Entangling Roots, with nameplates on and off);
--   * whether Blizzard's Cooldown Manager viewers keep delivering timers in combat (counts calls to the
--     viewers' own frames; never changes them);
--   * whether the combat log's reader exists (never registered: the game blocks that, see CombatLogCheck);
--   * the addon profiler's numbers after each fight, for PsiLab and the aura addons that are loaded;
--   * which addons' slash commands use /pro, /pr, /proc or /procable.
-- Read-only like every PsiLab module. Values the game hides are saved as "<secret>", never read.

local _, lab = ...

local MAX_CASTS = 80      -- own casts kept per character (oldest dropped)
local MAX_FIGHTS = 12     -- fights kept per character (oldest dropped)
local MAX_DEPTH = 4       -- table depth when saving game data
local PROBE_DELAY = 2     -- seconds into a fight before the in-combat probe
local VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer",
  "BuffBarCooldownViewer" }
local SLASH_WATCH = { ["/pro"] = true, ["/pr"] = true, ["/proc"] = true, ["/procable"] = true }
-- Addons whose cost the profiler is asked about after each fight (when loaded).
local PROFILED = { "PsiLab", "Huntard", "Paltard", "PallySealCooldowns", "ForeverAuras", "TellMeWhen", "MageProcs",
  "MiniAuras", "SoulShardForever", "EverAuras" }
local PROFILER_METRICS = { "RecentAverageTime", "PeakTime", "EncounterAverageTime" }

local module = {
  command = "pro",
  description = "Data for Procable: Cooldown Manager catalogue, spellbook, talents, auras, what stays readable "
    .. "in combat, own casts with nameplates (crowd control tests), the combat log and the profiler.",
  events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "UNIT_SPELLCAST_SUCCEEDED", "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED", "COOLDOWN_VIEWER_DATA_LOADED", "SPELLS_CHANGED" },
}

---------------------------------------------------------------------------
-- Saving values the game may hide
---------------------------------------------------------------------------

local function IsSecret(value)
  return issecretvalue ~= nil and issecretvalue(value) or false
end

-- A copy that can be saved: hidden values become "<secret>", hidden tables "<secret table>".
local function Plain(value, depth)
  if IsSecret(value) then return "<secret>" end
  local t = type(value)
  if t == "string" or t == "number" or t == "boolean" then return value end
  if t == "nil" then return nil end
  if t ~= "table" then return "<" .. t .. ">" end
  if issecrettable and issecrettable(value) then return "<secret table>" end
  if canaccesstable and not canaccesstable(value) then return "<no access>" end
  if type(value.GetObjectType) == "function" then return "<frame>" end
  depth = depth or 0
  if depth >= MAX_DEPTH then return "<depth limit>" end
  local out = {}
  for k, v in pairs(value) do
    if (type(k) == "string" or type(k) == "number") and not IsSecret(k) then out[k] = Plain(v, depth + 1) end
  end
  return out
end

-- Calls fn(...) safely. Returns { ok, values = {...}, secret = true when any value is hidden } or { ok = false, err }.
local function Probe(fn, ...)
  if type(fn) ~= "function" then return { ok = false, err = "missing" } end
  local results = { pcall(fn, ...) }
  if not results[1] then return { ok = false, err = tostring(results[2]) } end
  local out = { ok = true, values = {} }
  for i = 2, table.maxn(results) do
    local v = results[i]
    if IsSecret(v) then out.secret = true end
    out.values[i - 1] = v == nil and "<nil>" or Plain(v)
  end
  return out
end

local function Append(list, entry, max)
  if #list >= max then table.remove(list, 1) end
  list[#list + 1] = entry
end

---------------------------------------------------------------------------
-- Per-character record
---------------------------------------------------------------------------

-- "First Last": Forever has no realm names, so "First - <realm>" gave two characters with the same first name one
-- entry. Older "First - ..." entries are left as they are (they may mix two characters).
local function CharacterKey()
  local first, last = UnitFullName("player")
  first = tostring(first or UnitName("player"))
  if type(last) == "string" and last ~= "" and not IsSecret(last) then return first .. " " .. last end
  return first
end

function module:Character()
  self.data.characters = self.data.characters or {}
  local key = CharacterKey()
  local c = self.data.characters[key]
  if not c then
    c = { casts = {}, fights = {} }
    self.data.characters[key] = c
  end
  c.class = select(2, UnitClass("player"))
  c.level = UnitLevel("player")
  return c
end

---------------------------------------------------------------------------
-- Out-of-combat snapshot: catalogue, spellbook, talents, auras
---------------------------------------------------------------------------

local function SpellName(spellID)
  if type(spellID) ~= "number" or IsSecret(spellID) or not (C_Spell and C_Spell.GetSpellName) then return nil end
  local ok, name = pcall(C_Spell.GetSpellName, spellID)
  return ok and Plain(name) or nil
end

local function KnownState(spellID)
  if type(spellID) ~= "number" or IsSecret(spellID) or not C_SpellBook then return nil end
  local state = {}
  for _, fn in ipairs({ "IsSpellKnown", "IsSpellInSpellBook", "IsSpellKnownOrInSpellBook" }) do
    if C_SpellBook[fn] then
      local ok, value = pcall(C_SpellBook[fn], spellID)
      state[fn] = ok and Plain(value) or ("error: " .. tostring(value))
    end
  end
  return state
end

local function Catalogue()
  local out = { at = lab.Now() }
  if not (C_CooldownViewer and Enum and Enum.CooldownViewerCategory) then
    out.error = "C_CooldownViewer or Enum.CooldownViewerCategory missing"
    return out
  end
  out.available = Probe(C_CooldownViewer.IsCooldownViewerAvailable)
  out.cvarEnabled = C_CVar and Plain(C_CVar.GetCVar("cooldownViewerEnabled")) or nil
  local layout = Probe(C_CooldownViewer.GetLayoutData)
  out.layoutDataLength = layout.ok and type(layout.values[1]) == "string" and #layout.values[1] or nil
  out.categories = {}
  for name, value in pairs(Enum.CooldownViewerCategory) do
    if type(name) == "string" then
      local category = { id = value, entries = {} }
      local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, value, true)
      if not ok then
        category.error = tostring(ids)
      elseif type(ids) == "table" then
        for _, cooldownID in ipairs(ids) do
          local entry = { cooldownID = Plain(cooldownID) }
          local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
          if okInfo and type(info) == "table" then
            entry.info = Plain(info)
            entry.name = SpellName(info.spellID)
            entry.known = KnownState(info.spellID)
            if type(info.linkedSpellIDs) == "table" then
              entry.linkedNames = {}
              for i, id in ipairs(info.linkedSpellIDs) do entry.linkedNames[i] = SpellName(id) end
            end
          else
            entry.error = okInfo and "no info" or tostring(info)
          end
          category.entries[#category.entries + 1] = entry
        end
      end
      out.categories[name] = category
    end
  end
  return out
end

local function Spellbook()
  local out = { at = lab.Now(), lines = {} }
  if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then
    out.error = "C_SpellBook missing"
    return out
  end
  local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
  for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
    local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
    if type(info) == "table" then
      local line = { name = Plain(info.name), specID = Plain(info.specID), items = {} }
      for index = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
        local ok, item = pcall(C_SpellBook.GetSpellBookItemInfo, index, bank)
        if ok and type(item) == "table" then
          line.items[#line.items + 1] = {
            spellID = Plain(item.spellID), actionID = Plain(item.actionID), name = Plain(item.name),
            subName = Plain(item.subName), itemType = Plain(item.itemType), isPassive = Plain(item.isPassive),
            isOffSpec = Plain(item.isOffSpec), known = KnownState(item.spellID),
          }
        end
      end
      out.lines[#out.lines + 1] = line
    end
  end
  return out
end

local function Talents()
  local out = { at = lab.Now() }
  if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits) then
    out.error = "C_ClassTalents or C_Traits missing"
    return out
  end
  local configID = C_ClassTalents.GetActiveConfigID()
  out.configID = Plain(configID)
  if type(configID) ~= "number" then return out end
  local info = C_Traits.GetConfigInfo(configID)
  local treeID = type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs[1]
  out.treeID = Plain(treeID)
  if type(treeID) ~= "number" then return out end
  local groups = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
  out.trees = {}
  local byGroup, groupIDs = {}, {}
  for _, g in ipairs(type(groups) == "table" and groups or {}) do
    if type(g) == "table" and type(g.groupID) == "number" then
      local tree = { name = Plain(g.displayName), position = Plain(g.orderIndex), groupID = g.groupID, points = 0 }
      out.trees[#out.trees + 1] = tree
      byGroup[g.groupID] = tree
      groupIDs[#groupIDs + 1] = g.groupID
    end
  end
  local spent = C_Traits.GetGroupCurrencyInfo(configID, groupIDs)
  for _, s in ipairs(type(spent) == "table" and spent or {}) do
    local tree = type(s) == "table" and byGroup[s.traitNodeGroupID]
    local currency = tree and type(s.currencyInfos) == "table" and s.currencyInfos[1]
    if type(currency) == "table" and type(currency.spent) == "number" then tree.points = tree.points + currency.spent end
  end
  return out
end

-- Auras on `unit` with `filter` (e.g. "HELPFUL", "HARMFUL|PLAYER"), every field saved as far as the game allows.
local function Auras(unit, filter)
  local out = { unit = unit, filter = filter, exists = Plain(UnitExists(unit)), list = {} }
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    out.error = "C_UnitAuras.GetAuraDataByIndex missing"
    return out
  end
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
    if not ok then
      out.error = tostring(aura)
      break
    end
    if aura == nil then break end
    out.list[i] = Plain(aura)
  end
  return out
end

local function NameplateState()
  local count = 0
  for i = 1, 40 do
    local ok, exists = pcall(UnitExists, "nameplate" .. i)
    if ok and exists == true then count = count + 1 end
  end
  return {
    showEnemies = C_CVar and Plain(C_CVar.GetCVar("nameplateShowEnemies")) or nil,
    showFriends = C_CVar and Plain(C_CVar.GetCVar("nameplateShowFriends")) or nil,
    unitsNow = count,
  }
end

---------------------------------------------------------------------------
-- In-combat probe
---------------------------------------------------------------------------

-- A spell to ask about: the first active (not passive) spell in the spellbook's class lines.
local function SampleSpell(c)
  local book = c.spellbook
  for i = 2, #(book and book.lines or {}) do  -- line 1 is "General"
    for _, item in ipairs(book.lines[i].items) do
      if item.isPassive == false and type(item.spellID) == "number" then return item.spellID, item.name end
    end
  end
end

function module:Readability(c)
  local r = { at = lab.Now(), inCombat = InCombatLockdown() and true or false }
  r.power = Probe(UnitPower, "player")
  r.powerMax = Probe(UnitPowerMax, "player")
  r.health = Probe(UnitHealth, "player")
  r.absorbs = Probe(UnitGetTotalAbsorbs, "player")
  r.targetExists = Probe(UnitExists, "target")
  r.targetCanAttack = Probe(UnitCanAttack, "player", "target")
  r.shapeshiftForm = Probe(GetShapeshiftForm)
  local spellID, name = SampleSpell(c)
  r.sampleSpell = { id = spellID, name = name }
  if spellID and C_Spell then
    r.spellCooldown = Probe(C_Spell.GetSpellCooldown, spellID)
    r.spellUsable = Probe(C_Spell.IsSpellUsable, spellID)
    r.spellInRange = Probe(C_Spell.IsSpellInRange, spellID, "target")
  end
  -- Your buffs by the instance IDs remembered out of combat (how MageProcs keeps its shield bars in combat).
  r.playerAurasByInstance = {}
  for _, id in ipairs(self.instances or {}) do
    r.playerAurasByInstance[#r.playerAurasByInstance + 1] =
      { instance = id, result = Probe(C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID, "player", id) }
  end
  r.playerAuras = Auras("player", "HELPFUL")
  r.targetDebuffs = Auras("target", "HARMFUL|PLAYER")
  r.nameplates = NameplateState()
  return r
end

-- Remembers your buffs' instance IDs out of combat, for the in-combat probe.
function module:RememberInstances()
  self.instances = {}
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
    if not ok or aura == nil then break end
    local id = aura.auraInstanceID
    if type(id) == "number" and not IsSecret(id) then self.instances[#self.instances + 1] = id end
  end
end

---------------------------------------------------------------------------
-- Blizzard's Cooldown Manager viewers: count what they get in and out of combat (hooks only count)
---------------------------------------------------------------------------

local hooked = setmetatable({}, { __mode = "k" })

function module:Count(method)
  local phase = InCombatLockdown() and "combat" or "outOfCombat"
  local counts = self.viewerCalls
  if not counts then return end
  counts[phase] = counts[phase] or {}
  counts[phase][method] = (counts[phase][method] or 0) + 1
end

local function HookItem(item)
  if hooked[item] then return end
  hooked[item] = true
  for _, method in ipairs({ "SetAuraInstanceInfo", "OnUnitAuraUpdatedEvent", "RefreshData" }) do
    if type(item[method]) == "function" then hooksecurefunc(item, method, function() module:Count(method) end) end
  end
  local cooldown = item.Cooldown or item.cooldown
  if cooldown then
    for _, method in ipairs({ "SetCooldownFromDurationObject", "SetCooldown", "Clear" }) do
      if type(cooldown[method]) == "function" then
        hooksecurefunc(cooldown, method, function() module:Count("Cooldown:" .. method) end)
      end
    end
  end
  local bar = item.Bar
  if type(bar) == "table" and type(bar.SetValue) == "function" then
    hooksecurefunc(bar, "SetValue", function() module:Count("Bar:SetValue") end)
  end
end

function module:Viewers()
  local out = {}
  for _, name in ipairs(VIEWERS) do
    local viewer = _G[name]
    local v = { exists = viewer ~= nil }
    if viewer then
      v.shown = Probe(viewer.IsShown, viewer)
      v.alpha = Probe(viewer.GetAlpha, viewer)
      local ok, items = pcall(viewer.GetItemFrames, viewer)
      if ok and type(items) == "table" then
        v.items = #items
        for _, item in ipairs(items) do pcall(HookItem, item) end
      else
        v.itemsError = ok and "no table" or tostring(items)
      end
    end
    out[name] = v
  end
  return out
end

---------------------------------------------------------------------------
-- Combat log (only whether its reader exists) and profiler
---------------------------------------------------------------------------

-- Never register COMBAT_LOG_EVENT_UNFILTERED: Forever marks it restricted (HasRestrictions,
-- CombatLogDocumentation.lua), and unregistering it after a fight was blocked by the game ("PsiLab has been
-- blocked from an action ...", ADDON_ACTION_FORBIDDEN after every fight; stack trace from the game, 2026-11-27).
local function CombatLogCheck(fight)
  fight.combatLog = { exists = lab.Exists("CombatLogGetCurrentEventInfo") }
end

local function Profiler()
  if not (C_AddOnProfiler and C_AddOnProfiler.IsEnabled and Enum and Enum.AddOnProfilerMetric) then
    return { error = "C_AddOnProfiler or Enum.AddOnProfilerMetric missing" }
  end
  local out = { enabled = Probe(C_AddOnProfiler.IsEnabled), overall = {}, application = {}, addons = {} }
  for _, metricName in ipairs(PROFILER_METRICS) do
    local metric = Enum.AddOnProfilerMetric[metricName]
    if metric ~= nil then
      out.overall[metricName] = Probe(C_AddOnProfiler.GetOverallMetric, metric)
      out.application[metricName] = Probe(C_AddOnProfiler.GetApplicationMetric, metric)
      for _, addon in ipairs(PROFILED) do
        if C_AddOns.IsAddOnLoaded(addon) then
          out.addons[addon] = out.addons[addon] or {}
          out.addons[addon][metricName] = Probe(C_AddOnProfiler.GetAddOnMetric, addon, metric)
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Slash commands that clash with Procable's
---------------------------------------------------------------------------

local function SlashScan()
  local found = {}
  for key, value in pairs(_G) do
    if type(key) == "string" and key:sub(1, 6) == "SLASH_" and type(value) == "string"
        and SLASH_WATCH[value:lower()] then
      found[key] = value
    end
  end
  return found
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function module:Snapshot(why)
  local c = self:Character()
  c.lastSnapshot = { at = lab.Now(), why = why }
  local function Step(label, fn)
    local ok, result = pcall(fn)
    if ok then return result end
    lab.RecordError("Procable " .. label .. ": " .. tostring(result))
    return { error = tostring(result) }
  end
  c.spellbook = Step("spellbook", Spellbook)
  c.catalogue = Step("catalogue", Catalogue)
  c.talents = Step("talents", Talents)
  c.playerAuras = Step("player auras", function() return Auras("player", "HELPFUL") end)
  c.playerDebuffs = Step("player debuffs", function() return Auras("player", "HARMFUL") end)
  c.targetDebuffs = Step("target debuffs", function() return Auras("target", "HARMFUL|PLAYER") end)
  c.targetBuffs = Step("target buffs", function() return Auras("target", "HELPFUL") end)
  c.readableOutOfCombat = Step("readability", function() return self:Readability(c) end)
  c.nameplates = Step("nameplates", NameplateState)
  c.viewers = Step("viewers", function() return self:Viewers() end)
  c.viewerCalls = self.viewerCalls
  self:RememberInstances()
  return c
end

function module:Run()
  self.viewerCalls = self.viewerCalls or {}
  self.plateEvents = self.plateEvents or { added = 0, removed = 0 }
  -- At login most of the data isn't there yet; take the snapshot a few seconds in.
  C_Timer.After(6, function()
    if not lab.IsEnabled(module.name) then return end
    local ok, err = pcall(function()
      local c = module:Snapshot("login")
      c.slashClashes = SlashScan()
    end)
    if not ok then lab.RecordError("Procable login snapshot: " .. tostring(err)) end
  end)
end

function module:OnEvent(event, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if IsSecret(unit) then  -- comparing a hidden value is an error; count these instead
      self.secretCastUnits = (self.secretCastUnits or 0) + 1
      self.data.secretCastUnits = self.secretCastUnits
      return
    end
    if unit ~= "player" then return end
    local c = self:Character()
    local target = UnitExists("target")
    Append(c.casts, {
      at = GetTime(), spellID = Plain(spellID), name = SpellName(spellID), inCombat = InCombatLockdown() and true or false,
      spellIDSecret = IsSecret(spellID) or nil, targetExists = Plain(target), nameplates = NameplateState(),
    }, MAX_CASTS)
    if self.fight then self.fight.casts = (self.fight.casts or 0) + 1 end
  elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
    local key = event == "NAME_PLATE_UNIT_ADDED" and "added" or "removed"
    self.plateEvents[key] = self.plateEvents[key] + 1
    if self.fight then self.fight.plateEvents[key] = self.fight.plateEvents[key] + 1 end
  elseif event == "PLAYER_REGEN_DISABLED" then
    local c = self:Character()
    local fight = { start = lab.Now(), plateEvents = { added = 0, removed = 0 }, viewerCallsBefore = Plain(self.viewerCalls) }
    self.fight = fight
    CombatLogCheck(fight)
    C_Timer.After(PROBE_DELAY, function()
      if self.fight ~= fight or not lab.IsEnabled(module.name) then return end
      local ok, result = pcall(self.Readability, self, c)
      fight.probe = ok and result or { error = tostring(result) }
    end)
  elseif event == "PLAYER_REGEN_ENABLED" then
    local fight = self.fight
    if not fight then return end
    self.fight = nil
    local c = self:Character()
    fight.duration = GetTime() - fight.start.uptime
    fight.viewerCallsAfter = Plain(self.viewerCalls)
    fight.profiler = Profiler()
    fight.targetDebuffsAfter = Auras("target", "HARMFUL|PLAYER")
    Append(c.fights, fight, MAX_FIGHTS)
    self:RememberInstances()
  elseif event == "COOLDOWN_VIEWER_DATA_LOADED" or event == "SPELLS_CHANGED" then
    -- New item frames may exist now; hook them (counting only).
    if not InCombatLockdown() then pcall(self.Viewers, self) end
  end
end

function module:OnCommand(rest)
  rest = (rest or ""):lower()
  if rest == "" or rest == "snap" then
    if InCombatLockdown() then
      lab.Print("Procable: leave combat first (fights are recorded on their own).")
      return
    end
    local c = self:Snapshot("command")
    c.slashClashes = SlashScan()
    local entries = 0
    for _, category in pairs(c.catalogue.categories or {}) do entries = entries + #category.entries end
    local spells = 0
    for _, line in ipairs(c.spellbook.lines or {}) do spells = spells + #line.items end
    local clashes = 0
    for _ in pairs(c.slashClashes) do clashes = clashes + 1 end
    lab.Print(string.format("Procable: saved %s (%s %s): %d Cooldown Manager entries, %d spellbook items, "
      .. "%d own buffs, %d own debuffs on target, %d fights, %d casts, %d slash clashes. /reload to write the file.",
      CharacterKey(), tostring(c.class), tostring(c.level), entries, spells, #(c.playerAuras.list or {}),
      #(c.targetDebuffs.list or {}), #c.fights, #c.casts, clashes))
  else
    lab.Print("Procable: /lab pro - save a snapshot now (out of combat). Fights and your casts are recorded "
      .. "on their own.")
  end
end

lab:RegisterModule("Procable", module)
