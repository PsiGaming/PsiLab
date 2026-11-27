-- PsiLab module: ShadyBusiness.
-- Collects what ShadyBusiness relies on (its DESIGN.md, open questions 1-7):
--   * chat messaging lockdown: C_ChatInfo.InChatMessagingLockdown() in the open world, dungeons, combat and
--     encounters; whether a hidden addon message to the group is accepted, and whether it echoes back;
--     whether incoming party/raid chat arrives as secret values
--   * group members: assigned role, max mana (normal and unmodified), whether max mana is secret, distance
--   * loot method: value, available methods, and when PARTY_LOOT_METHOD_CHANGED fires
--   * inspect: tries each group member every few seconds until it works, recording distance and timing (the
--     inspect range); then their gear links, C_Item.GetItemStats per item, and talent points per tree
--   * your own gear stats, talent trees and mana, which need no group
-- Sends hidden addon messages (prefix PsiLabSB) to your group when the situation changes. Visible chat is
-- only sent by "/lab sb say".

local _, lab = ...

local PREFIX = "PsiLabSB"
local TICK_SECONDS = 4        -- lockdown check and inspect retry interval
local MAX_LOCKDOWN_LOG = 120  -- situation changes kept (oldest dropped)
local MAX_LOG = 40            -- entries kept per other log
local MAX_PLAYERS = 25        -- inspected group members kept (oldest dropped)
local MAX_OTHERS = 100        -- other inspected players kept (other addons' mouseover inspects; oldest dropped)
local MAX_MEMBERS = 60        -- group members kept (least recently seen dropped)
local MAX_ATTEMPTS = 30       -- inspect attempts kept per player
local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
local INSPECT_CONFIG_ID = (Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID) or -1
local TEST_TEXT = "PsiLab test: checking whether addons may post in group chat here (please ignore)"

local module = {
  command = "sb",
  description = "Addon chat restrictions (open world, dungeons, combat), group roles and max mana, the loot "
    .. "method, and inspecting group members (range, gear stats, talents). Sends hidden addon messages to your "
    .. "group; /lab sb say sends one visible test line.",
  events = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_START", "ENCOUNTER_END", "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED", "ROLE_CHANGED_INFORM",
    "PARTY_LOOT_METHOD_CHANGED", "INSPECT_READY", "CHAT_MSG_ADDON", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "UNIT_INVENTORY_CHANGED", "UNIT_MODEL_CHANGED", "PARTY_LEADER_CHANGED", "READY_CHECK" },
}

---------------------------------------------------------------------------
-- Secret-safe recording (Forever can hand addons "secret" values; comparing or saving them is an error)
---------------------------------------------------------------------------

local function IsSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) or false
end

local function SafeCopy(v, depth)
  if IsSecret(v) then return "<secret>" end
  local t = type(v)
  if t == "nil" then return nil end
  if t == "string" or t == "number" or t == "boolean" then return v end
  if t ~= "table" then return "<" .. t .. ">" end
  depth = depth or 0
  if depth >= 6 then return "<table, depth limit>" end
  local out = {}
  for k, val in pairs(v) do
    if not IsSecret(k) and (type(k) == "string" or type(k) == "number") then out[k] = SafeCopy(val, depth + 1) end
  end
  return out
end

local function Pack(...)
  return { n = select("#", ...), ... }
end

-- Calls fn(...) in pcall and returns a saveable list of its results ("<secret>", "<nil>" kept visible), or
-- { error = ... }. Missing functions give "<no function>".
local function Get(label, fn, ...)
  if type(fn) ~= "function" then return "<no function>" end
  local r = Pack(pcall(fn, ...))
  if not r[1] then
    lab.RecordError("ShadyBusiness " .. label .. ": " .. tostring(r[2]))
    return { error = tostring(r[2]) }
  end
  local out = { n = r.n - 1 }
  for i = 2, r.n do
    local v = r[i]
    if IsSecret(v) then out[i - 1] = "<secret>"
    elseif v == nil then out[i - 1] = "<nil>"
    else out[i - 1] = SafeCopy(v) end
  end
  return out
end

-- First result of Get, or nil if it failed, was secret or missing.
local function First(result)
  local v = type(result) == "table" and result[1]
  if v == "<secret>" or v == "<nil>" then return nil end
  return v
end

local function Append(list, entry, max, dropOldest)
  if #list >= max then
    if not dropOldest then return end
    table.remove(list, 1)
  end
  list[#list + 1] = entry
end

local function Log(self, key, entry, max, dropOldest)
  self.data[key] = self.data[key] or {}
  Append(self.data[key], entry, max or MAX_LOG, dropOldest)
end

-- Per-situation totals that build up over any number of sessions: data[bucket][key] = { count, first, last }.
-- A rare situation (a dungeon boss fight) keeps its own entry however much else happens.
local function Tally(self, bucket, key, entry)
  self.data[bucket] = self.data[bucket] or {}
  local t = self.data[bucket][key]
  if not t then
    t = { count = 0, first = entry }
    self.data[bucket][key] = t
  end
  t.count = t.count + 1
  t.last = entry
  return t
end

local function CountKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Removes the entry of `map` with the smallest `field` (the oldest), to make room.
local function DropOldest(map, field)
  local oldestKey, oldest
  for k, v in pairs(map) do
    local value = type(v) == "table" and type(v[field]) == "number" and v[field] or 0
    if not oldest or value < oldest then oldestKey, oldest = k, value end
  end
  if oldestKey ~= nil then map[oldestKey] = nil end
end

---------------------------------------------------------------------------
-- Where am I
---------------------------------------------------------------------------

local encounterActive = false

local function GroupKind()
  if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "instance" end
  if IsInRaid() then return "raid" end
  if IsInGroup() then return "party" end
  return "solo"
end

local function GroupChannel()
  local kind = GroupKind()
  if kind == "instance" then return "INSTANCE_CHAT" end
  if kind == "raid" then return "RAID" end
  if kind == "party" then return "PARTY" end
  return nil
end

local function Where()
  local w = { at = lab.Now() }
  w.lockdown = Get("InChatMessagingLockdown", C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
  w.inInstance = Get("IsInInstance", IsInInstance)
  w.instanceInfo = Get("GetInstanceInfo", GetInstanceInfo)
  w.zone = Get("GetRealZoneText", GetRealZoneText)
  w.mapID = Get("C_Map.GetBestMapForUnit", C_Map and C_Map.GetBestMapForUnit, "player")
  w.inCombat = InCombatLockdown() and true or false
  w.inEncounter = encounterActive
  w.group = GroupKind()
  return w
end

local function SituationKey(w)
  local info = type(w.instanceInfo) == "table" and w.instanceInfo or {}
  return table.concat({ tostring(w.lockdown and w.lockdown[1]), tostring(info[2]), tostring(info[1]),
    tostring(w.inCombat), tostring(w.inEncounter), w.group }, "|")
end

-- Shorter key for chat tallies: lockdown, instance type, combat, encounter.
local function ChatKey(w)
  local info = type(w.instanceInfo) == "table" and w.instanceInfo or {}
  return table.concat({ "lockdown=" .. tostring(w.lockdown and w.lockdown[1]), tostring(info[2]),
    w.inCombat and "combat" or "noCombat", w.inEncounter and "encounter" or "noEncounter" }, "|")
end

---------------------------------------------------------------------------
-- Chat lockdown and addon messages
---------------------------------------------------------------------------

local pingCount = 0
local lastKey

local function SendPing(reason)
  local channel = GroupChannel()
  if not channel or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return nil end
  pingCount = pingCount + 1
  return { channel = channel, number = pingCount,
    result = Get("SendAddonMessage", C_ChatInfo.SendAddonMessage, PREFIX, "ping " .. pingCount .. " " .. reason, channel) }
end

-- Records the situation when it changed since the last record (or always when `force`). Prints it only when
-- `force` (/lab sb snap): printing every combat start and end was too noisy (decided 2026-11-23).
function module:Snapshot(reason, force)
  local w = Where()
  local key = SituationKey(w)
  if key == lastKey and not force then return end
  lastKey = key
  w.reason = reason
  w.addonPing = SendPing(reason)
  Tally(self, "situations", key, w)
  Log(self, "lockdown", w, MAX_LOCKDOWN_LOG, true)  -- recent timeline only; "situations" keeps everything
  if force then
    local info = type(w.instanceInfo) == "table" and w.instanceInfo or {}
    lab.Print(string.format("ShadyBusiness: chat lockdown %s (%s, %s%s%s).", tostring(w.lockdown and w.lockdown[1]),
      tostring(info[1]), tostring(info[2]), w.inCombat and ", in combat" or "", w.inEncounter and ", encounter" or ""))
  end
end

-- Addon messages: tallied per situation and sender kind, so dungeon results survive any amount of other play.
function module:OnAddonMessage(prefix, text, channel, sender)
  local w = Where()
  if IsSecret(prefix) then
    Tally(self, "addonMessages", "prefixSecret|" .. ChatKey(w), { at = w.at })
    return
  end
  if prefix ~= PREFIX then return end
  -- The sender comes as "First Last" (PsiLab 0.1.5, 2026-11-22).
  local first, last = UnitName("player")
  local fromMe = not IsSecret(sender) and (sender == first or sender == (first .. " " .. tostring(last)))
  Tally(self, "addonMessages", (fromMe and "fromMe|" or "fromOthers|") .. ChatKey(w), { at = w.at,
    text = SafeCopy(text), channel = SafeCopy(channel), sender = SafeCopy(sender), where = w })
end

-- Incoming group chat: whether the values are secret and whether it was our own test line (no chat text saved).
function module:OnGroupChat(event, text, sender)
  local w = Where()
  local textSecret, senderSecret = IsSecret(text), IsSecret(sender)
  local isTestLine = not textSecret and text == TEST_TEXT
  local key = table.concat({ event, ChatKey(w), textSecret and "textSecret" or "textPlain",
    senderSecret and "senderSecret" or "senderPlain", isTestLine and "testLine" or "other" }, "|")
  Tally(self, "groupChat", key, { at = w.at, where = w })
end

-- "/lab sb say": one visible line to the group, sent from a timer (like an event-driven announcement).
function module:SayTest()
  local channel = GroupChannel()
  if not channel then
    lab.Print("ShadyBusiness: join a group first (the test line goes to party/raid chat).")
    return
  end
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  C_Timer.After(0.2, function()
    local entry = { at = lab.Now(), channel = channel, where = Where() }
    entry.result = Get("SendChatMessage", send, TEST_TEXT, channel)
    Log(self, "sayTests", entry)
    lab.Print("ShadyBusiness: test line sent to " .. channel .. "; check whether it appeared in chat.")
  end)
end

---------------------------------------------------------------------------
-- Group members, roles, mana
---------------------------------------------------------------------------

local function GroupUnits()
  local units = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      if not UnitIsUnit("raid" .. i, "player") then units[#units + 1] = "raid" .. i end
    end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
  end
  return units
end

local function DescribeUnit(unit)
  local d = { unit = unit }
  d.name = Get("UnitName", UnitName, unit)
  d.fullName = Get("UnitFullName", UnitFullName, unit)
  d.guid = Get("UnitGUID", UnitGUID, unit)
  d.class = Get("UnitClass", UnitClass, unit)
  d.level = Get("UnitLevel", UnitLevel, unit)
  d.role = Get("UnitGroupRolesAssigned", UnitGroupRolesAssigned, unit)
  d.powerType = Get("UnitPowerType", UnitPowerType, unit)
  d.maxMana = Get("UnitPowerMax", UnitPowerMax, unit, MANA)
  d.maxManaUnmodified = Get("UnitPowerMax unmodified", UnitPowerMax, unit, MANA, true)
  d.manaMaxSecret = Get("ShouldUnitPowerMaxBeSecret", C_Secrets and C_Secrets.ShouldUnitPowerMaxBeSecret, unit, MANA)
  d.connected = Get("UnitIsConnected", UnitIsConnected, unit)
  d.visible = Get("UnitIsVisible", UnitIsVisible, unit)
  d.distanceSquared = Get("UnitDistanceSquared", UnitDistanceSquared, unit)
  d.canInspect = Get("CanInspect", CanInspect, unit)
  d.inspectDistance = Get("CheckInteractDistance", CheckInteractDistance, unit, 1)
  return d
end

function module:CheckMembers(reason)
  local w = Where()
  local situation = (w.inCombat and "inCombat" or "outOfCombat") .. ((First(w.inInstance) and "InInstance") or "")
  self.data.members = self.data.members or {}
  for _, unit in ipairs(GroupUnits()) do
    local d = DescribeUnit(unit)
    local guid = First(d.guid) or unit
    local members = self.data.members
    if not members[guid] and CountKeys(members) >= MAX_MEMBERS then DropOldest(members, "lastSeen") end
    local m = members[guid] or {}
    m.name = First(d.name)
    m.lastSeen = time()
    m[situation] = { at = w.at, reason = reason, lockdown = w.lockdown, unit = d }
    self.data.members[guid] = m
  end
end

-- Your own character: max mana with and without modifiers, Intellect and Spirit (for base mana per level),
-- and the game's own spell power / bonus healing totals.
function module:CheckPlayer()
  local p = DescribeUnit("player")
  p.at = lab.Now()
  p.intellect = Get("UnitStat intellect", UnitStat, "player", LE_UNIT_STAT_INTELLECT or 4)
  p.spirit = Get("UnitStat spirit", UnitStat, "player", LE_UNIT_STAT_SPIRIT or 5)
  p.bonusHealing = Get("GetSpellBonusHealing", GetSpellBonusHealing)
  p.bonusHolyDamage = Get("GetSpellBonusDamage 2", GetSpellBonusDamage, 2)
  self.data.player = p
end

function module:OnRoleEvent(event, ...)
  Tally(self, "roleEvents", event .. "|" .. GroupKind(), { at = lab.Now(), args = SafeCopy(Pack(...)) })
end

---------------------------------------------------------------------------
-- Loot method
---------------------------------------------------------------------------

function module:CheckLoot(reason)
  local l = { at = lab.Now(), reason = reason, group = GroupKind(), isLeader = UnitIsGroupLeader("player") }
  l.method = Get("GetLootMethod", C_PartyInfo and C_PartyInfo.GetLootMethod)
  l.available = Get("GetAvailableLootMethods", C_PartyInfo and C_PartyInfo.GetAvailableLootMethods)
  l.availableEach = {}
  for i = 0, 5 do
    l.availableEach[i] = Get("IsLootMethodAvailable " .. i, C_PartyInfo and C_PartyInfo.IsLootMethodAvailable, i)
  end
  l.threshold = Get("GetLootThreshold", GetLootThreshold)
  Log(self, "loot", l)
  self.data.lootEnum = SafeCopy(Enum and Enum.LootMethod)
end

---------------------------------------------------------------------------
-- Gear and talents
---------------------------------------------------------------------------

-- GetItemStats returns nothing for items whose data the game hasn't loaded yet (0.1.5: 9 of 11 of a character's
-- own items at login), so such items are requested and saved as { link, loading = true } instead of with empty
-- stats. Returns the gear and the number of items still loading.
local function ReadGear(unit)
  local gear, loading = {}, 0
  for slot = 1, 19 do
    local link = First(Get("GetInventoryItemLink " .. slot, GetInventoryItemLink, unit, slot))
    if type(link) == "string" then
      local cached = First(Get("IsItemDataCachedByID", C_Item and C_Item.IsItemDataCachedByID, link))
      if cached == false then
        loading = loading + 1
        Get("RequestLoadItemDataByID", C_Item.RequestLoadItemDataByID, link)
        gear[slot] = { link = link, loading = true }
      else
        gear[slot] = { link = link, stats = Get("GetItemStats " .. slot, C_Item and C_Item.GetItemStats, link) }
      end
    end
  end
  return gear, loading
end

local function ReadTalents(configID)
  local t = { configID = configID }
  if not C_Traits then return "<no C_Traits>" end
  t.configInfo = Get("GetConfigInfo", C_Traits.GetConfigInfo, configID)
  local info = First(t.configInfo)
  local treeID = type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs[1]
  if type(treeID) ~= "number" then return t end
  t.treeID = treeID
  t.groups = Get("GetGroupDisplayInfoByTreeID", C_Traits.GetGroupDisplayInfoByTreeID, treeID)
  local groupIDs = {}
  for _, g in ipairs(type(First(t.groups)) == "table" and First(t.groups) or {}) do
    if type(g) == "table" and type(g.groupID) == "number" then groupIDs[#groupIDs + 1] = g.groupID end
  end
  t.groupIDs = groupIDs
  t.spent = Get("GetGroupCurrencyInfo", C_Traits.GetGroupCurrencyInfo, configID, groupIDs)
  return t
end

function module:CheckPlayerGearAndTalents()
  local gear, loading = ReadGear("player")
  self.data.playerGear = { at = lab.Now(), gear = gear, loadingItems = loading }
  local t = { at = lab.Now() }
  t.activeConfigID = Get("GetActiveConfigID", C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  t.activeSpecGroup = Get("GetActiveSpecGroup", C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup)
  local group = First(t.activeSpecGroup)
  if type(group) == "number" then
    t.combatConfigID = Get("GetCombatConfigIDForSpecGroup",
      C_SpecializationInfo.GetCombatConfigIDForSpecGroup, group)
  end
  local configID = First(t.activeConfigID) or First(t.combatConfigID)
  if type(configID) == "number" then t.talents = ReadTalents(configID) end
  self.data.playerTalents = t
end

---------------------------------------------------------------------------
-- Inspect
---------------------------------------------------------------------------

local requestedAt = {}  -- GUID -> GetTime() of our last NotifyInspect for that player

local function UnitForGUID(guid)
  for _, unit in ipairs(GroupUnits()) do
    if not IsSecret(UnitGUID(unit)) and UnitGUID(unit) == guid then return unit end
  end
  for _, unit in ipairs({ "target", "mouseover", "focus" }) do
    if UnitExists(unit) and not IsSecret(UnitGUID(unit)) and UnitGUID(unit) == guid then return unit end
  end
end

local function IsGroupUnit(unit)
  return type(unit) == "string" and (unit:match("^party%d") or unit:match("^raid%d")) ~= nil
end

-- The record for a player. Group members (cap MAX_PLAYERS) and everyone else (other addons' mouseover inspects,
-- cap MAX_OTHERS) are kept apart, so strangers can never push group members out.
function module:Record(guid, isMember)
  self.data.inspected = self.data.inspected or {}
  self.data.inspectedOthers = self.data.inspectedOthers or {}
  local map, cap = self.data.inspectedOthers, MAX_OTHERS
  if isMember then
    map, cap = self.data.inspected, MAX_PLAYERS
    if self.data.inspectedOthers[guid] then  -- a stranger who joined the group
      map[guid], self.data.inspectedOthers[guid] = self.data.inspectedOthers[guid], nil
    end
  end
  local p = map[guid]
  if not p then
    if CountKeys(map) >= cap then DropOldest(map, "firstSeen") end
    p = { attempts = {}, firstSeen = time() }
    map[guid] = p
  end
  return p
end

-- Sends NotifyInspect for `unit` and records the attempt with the distance (to learn the inspect range).
function module:TryInspect(unit, why)
  local guid = UnitGUID(unit)
  if IsSecret(guid) or not guid then return end
  local p = self:Record(guid, IsGroupUnit(unit))
  p.name = First(Get("UnitName", UnitName, unit)) or p.name
  local attempt = { at = lab.Now(), why = why, unit = unit, where = Where().instanceInfo,
    distanceSquared = Get("UnitDistanceSquared", UnitDistanceSquared, unit),
    canInspect = Get("CanInspect", CanInspect, unit),
    inspectDistance = Get("CheckInteractDistance", CheckInteractDistance, unit, 1),
    visible = Get("UnitIsVisible", UnitIsVisible, unit), inCombat = InCombatLockdown() and true or false }
  attempt.result = Get("NotifyInspect", NotifyInspect, unit)
  Append(p.attempts, attempt, MAX_ATTEMPTS, true)
  requestedAt[guid] = GetTime()
end

function module:OnInspectReady(guid)
  if IsSecret(guid) then
    self.data.inspectReadySecret = (self.data.inspectReadySecret or 0) + 1
    return
  end
  local unit = UnitForGUID(guid)
  if not unit then
    -- Not a group member, target, mouseover or focus (e.g. another addon's inspect): count only.
    self.data.inspectReadyOther = (self.data.inspectReadyOther or 0) + 1
    return
  end
  local isMember = IsGroupUnit(unit)
  local p = self:Record(guid, isMember)
  local sentAt = requestedAt[guid]
  local r = { at = lab.Now(), unit = unit, ours = sentAt ~= nil, inCombat = InCombatLockdown() and true or false,
    secondsAfterRequest = sentAt and (GetTime() - sentAt) or nil, where = Where().instanceInfo }
  p.name = First(Get("UnitName", UnitName, unit)) or p.name
  r.unitInfo = DescribeUnit(unit)
  r.gear, r.gearLoading = ReadGear(unit)
  r.hasValidInspectData = Get("HasValidInspectData", C_Traits and C_Traits.HasValidInspectData)
  r.talents = ReadTalents(INSPECT_CONFIG_ID)
  -- Read gear again 1 s and 4 s later (items arrive after INSPECT_READY, and item data may still be loading), and
  -- talents at 1 s. Only while the unit token still means the same player: a mouseover or target may have moved on
  -- (0.1.6 and earlier could save another player's gear here).
  local function SamePlayer()
    local g = UnitGUID(unit)
    return not IsSecret(g) and g == guid
  end
  C_Timer.After(1, function()
    if not lab.IsEnabled(module.name) then return end
    local ok, err = pcall(function()
      if not SamePlayer() then
        r.gearAfter1s = "unit changed"
        return
      end
      r.gearAfter1s, r.gearAfter1sLoading = ReadGear(unit)
      r.talentsAfter1s = ReadTalents(INSPECT_CONFIG_ID)
      r.hasValidInspectDataAfter1s = Get("HasValidInspectData", C_Traits and C_Traits.HasValidInspectData)
    end)
    if not ok then lab.RecordError("ShadyBusiness gear after 1s: " .. tostring(err)) end
  end)
  C_Timer.After(4, function()
    if not lab.IsEnabled(module.name) then return end
    local ok, err = pcall(function()
      if not SamePlayer() then
        r.gearAfter4s = "unit changed"
        return
      end
      r.gearAfter4s, r.gearAfter4sLoading = ReadGear(unit)
    end)
    if not ok then lab.RecordError("ShadyBusiness gear after 4s: " .. tostring(err)) end
  end)
  p.done = true
  if r.ours then
    p.ourRead = r  -- the reply to PsiLab's own request: kept apart, other addons' replies can't replace it
  else
    p.reads = p.reads or {}
    Append(p.reads, r, isMember and 2 or 1, true)
  end
  requestedAt[guid] = nil
  if isMember or r.ours then
    local items = 0
    for _ in pairs(r.gear) do items = items + 1 end
    lab.Print(string.format("ShadyBusiness: inspected %s (%d items).", tostring(p.name), items))
  end
end

-- Every few seconds: the next group member without a reply to PsiLab's own inspect (other addons' replies don't
-- count: the range data needs our own request and its distance). Skipped while Blizzard's Inspect window is open,
-- so it doesn't replace the player you are looking at.
function module:InspectNext()
  if type(InspectFrame) == "table" and InspectFrame:IsShown() then return end
  local inspected = self.data.inspected or {}
  local candidates = {}
  for _, unit in ipairs(GroupUnits()) do
    local guid = UnitGUID(unit)
    if not IsSecret(guid) and guid then
      local p = inspected[guid]
      if First(Get("UnitIsConnected", UnitIsConnected, unit)) and not (p and p.ourRead) then
        candidates[#candidates + 1] = unit
      end
    end
  end
  if #candidates == 0 then return end
  -- Rotate through the candidates so one unreachable member doesn't block the rest.
  self.rotation = ((self.rotation or 0) % #candidates) + 1
  self:TryInspect(candidates[self.rotation], "auto")
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local timersPending = {}
local function Later(key, delay, fn)
  if timersPending[key] then return end
  timersPending[key] = true
  C_Timer.After(delay, function()
    timersPending[key] = nil
    if not lab.IsEnabled(module.name) then return end
    local ok, err = pcall(fn)
    if not ok then lab.RecordError("ShadyBusiness " .. key .. ": " .. tostring(err)) end
  end)
end

local ticker
local lastGroup
function module:Run()
  -- PsiLab 0.1.4 saved these as lists; they are per-situation totals now.
  for _, bucket in ipairs({ "addonMessages", "groupChat", "roleEvents" }) do
    if type(self.data[bucket]) == "table" and self.data[bucket][1] ~= nil then self.data[bucket] = nil end
  end
  -- PsiLab 0.1.5 kept group members and strangers in one list; PsiLab only ever inspected group members itself,
  -- so entries without its own attempts are strangers.
  if not self.data.inspectedOthers and type(self.data.inspected) == "table" then
    self.data.inspectedOthers = {}
    for guid, p in pairs(self.data.inspected) do
      if type(p) == "table" and next(type(p.attempts) == "table" and p.attempts or {}) == nil then
        self.data.inspectedOthers[guid], self.data.inspected[guid] = p, nil
      end
    end
  end
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix and not self.prefixResult then
    self.prefixResult = Get("RegisterAddonMessagePrefix", C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    self.data.prefixRegistered = self.prefixResult
  end
  self.data.apis = {}
  for _, path in ipairs({ "issecretvalue", "C_Secrets.ShouldUnitPowerMaxBeSecret", "C_ChatInfo.InChatMessagingLockdown",
    "C_ChatInfo.SendChatMessage", "SendChatMessage", "C_ChatInfo.SendAddonMessage", "UnitGroupRolesAssigned",
    "UnitDistanceSquared", "NotifyInspect", "CanInspect", "ClearInspectPlayer", "C_Item.GetItemStats",
    "C_Traits.GetConfigInfo", "C_Traits.GetGroupCurrencyInfo", "C_Traits.HasValidInspectData",
    "C_ClassTalents.GetActiveConfigID", "C_PartyInfo.GetLootMethod", "C_PartyInfo.GetAvailableLootMethods",
    "GetLootThreshold" }) do
    self.data.apis[path] = lab.Exists(path)
  end
  self:CheckPlayer()
  self:CheckPlayerGearAndTalents()
  -- At login most of your own items aren't loaded yet; read again once they are.
  C_Timer.After(10, function()
    if not lab.IsEnabled(module.name) then return end
    local ok, err = pcall(module.CheckPlayerGearAndTalents, module)
    if not ok then lab.RecordError("ShadyBusiness player gear after 10s: " .. tostring(err)) end
  end)
  self:Snapshot("run", true)
  if IsInGroup() then
    self:CheckMembers("run")
    self:CheckLoot("run")
  end
  if not ticker then
    ticker = C_Timer.NewTicker(TICK_SECONDS, function()
      if not lab.IsEnabled(module.name) then return end
      local ok, err = pcall(function()
        module:Snapshot("tick")
        module:InspectNext()
      end)
      if not ok then lab.RecordError("ShadyBusiness tick: " .. tostring(err)) end
    end)
  end
end

function module:OnEvent(event, ...)
  if event == "CHAT_MSG_ADDON" then
    self:OnAddonMessage(...)
  elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" or event == "CHAT_MSG_RAID"
      or event == "CHAT_MSG_RAID_LEADER" then
    local text, sender = ...
    self:OnGroupChat(event, text, sender)
  elseif event == "INSPECT_READY" then
    self:OnInspectReady(...)
  elseif event == "UNIT_INVENTORY_CHANGED" or event == "UNIT_MODEL_CHANGED" then
    -- Do these fire for other players' gear changes? Shady Business re-checks healers on them.
    local unit = ...
    local kind = IsSecret(unit) and "secret" or unit == "player" and "player" or IsGroupUnit(unit) and "group"
      or (type(unit) == "string" and unit:match("^%a+")) or tostring(unit)
    Tally(self, "gearEvents", event .. "|" .. kind .. "|" .. GroupKind(), { at = lab.Now(), unit = SafeCopy(unit),
      name = kind == "group" and First(Get("UnitName", UnitName, unit)) or nil })
  elseif event == "PARTY_LEADER_CHANGED" or event == "READY_CHECK" then
    Tally(self, "groupEvents", event .. "|" .. GroupKind(), { at = lab.Now(), args = SafeCopy(Pack(...)),
      where = Where() })
  elseif event == "PARTY_LOOT_METHOD_CHANGED" then
    self:CheckLoot(event)
  elseif event == "GROUP_ROSTER_UPDATE" then
    self:OnRoleEvent(event, ...)
    Later("roster", 1, function()
      local group = GroupKind()
      if group ~= lastGroup then
        -- Joined, left or changed group type: does the loot method arrive with the group?
        module:CheckLoot("group " .. tostring(lastGroup) .. " -> " .. group)
        lastGroup = group
      end
      module:CheckMembers(event)
      module:Snapshot(event)
    end)
  elseif event == "PLAYER_ROLES_ASSIGNED" or event == "ROLE_CHANGED_INFORM" then
    self:OnRoleEvent(event, ...)
    Later("roles", 1, function() module:CheckMembers(event) end)
  elseif event == "PLAYER_REGEN_DISABLED" then
    self:Snapshot(event)
    Later("combat", 1, function() module:CheckMembers(event) end)
  elseif event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
    encounterActive = event == "ENCOUNTER_START"
    self:Snapshot(event)
  elseif event == "PLAYER_REGEN_ENABLED" or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
    Later(event, 1, function()
      module:Snapshot(event)
      if event == "PLAYER_REGEN_ENABLED" then module:CheckMembers(event) end
    end)
  end
end

function module:OnCommand(rest)
  rest = (rest or ""):lower()
  if rest == "say" then
    self:SayTest()
  elseif rest == "inspect" then
    if UnitExists("target") and UnitIsPlayer("target") then
      self:TryInspect("target", "command")
      lab.Print("ShadyBusiness: inspect request sent for your target.")
    else
      lab.Print("ShadyBusiness: target a player first.")
    end
  elseif rest == "snap" then
    self:Snapshot("command", true)
    if IsInGroup() then
      self:CheckMembers("command")
      self:CheckLoot("command")
    end
  else
    lab.Print("ShadyBusiness commands:")
    print("  /lab sb snap - record chat lockdown, group members and loot method now")
    print("  /lab sb inspect - inspect your target now")
    print("  /lab sb say - send ONE visible test line to party/raid chat (others will see it)")
  end
end

lab:RegisterModule("ShadyBusiness", module)
