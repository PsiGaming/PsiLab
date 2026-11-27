-- PsiLab: settings, in the options design the author chose for their addons (2026-11-26, first used here as a preview
-- for Procable):
--   * A floating window (/lab settings) in a look inspired by Leatrix Plus: a flat dark panel, the categories in a
--     list on the left, the selected category's page on the right, a footer with the version and a Reload button.
--     Built from standard Blizzard controls. Closing it just closes it; it never goes through Blizzard's settings
--     panel, whose close always reopens the game menu (Forever source: SettingsPanelMixin:
--     TransitionBackOpeningPanel -> ToggleGameMenu).
--   * The same pages in Blizzard's Options > AddOns > PsiLab: the first page is PsiLab's own entry, the others are
--     its subcategories in Blizzard's list on the left.
-- Every page is built once per place by the same function, and re-reads the settings when shown and after any
-- change ("/lab disable" too), so the two places never disagree.

local _, lab = ...

local WIDTH, HEIGHT = 640, 420
local NAV_WIDTH = 150
local HEADER = 46      -- title area height
local FOOTER = 38      -- footer height
local PAD = 16
local PAGE_WIDTH = WIDTH - NAV_WIDTH - 2 * PAD

local COLOR_BG = { 0.05, 0.05, 0.05, 0.92 }
local COLOR_NAV = { 0.09, 0.09, 0.09, 0.95 }
local COLOR_LINE = { 1, 1, 1, 0.08 }
local COLOR_ACCENT = { 0.8, 0.4, 1 }  -- PsiLab's chat colour (cc66ff)

local pages = {}      -- page definitions, in order: { title, build }
local instances = {}  -- every built page: { frame, refresh = { fn, ... } }
local window

---------------------------------------------------------------------------
-- Controls (standard Blizzard templates), laid out top to bottom
---------------------------------------------------------------------------

-- A layout cursor: each Add... call puts a control below the previous one. Controls that show a setting register
-- a refresh function, run when the page is shown.
local function NewLayout(frame, refresh, x, y)
  local L = { frame = frame, x = x, y = y }

  function L:Gap(height) self.y = self.y - height end

  function L:Heading(text)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", self.x, self.y)
    fs:SetText(text)
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(unpack(COLOR_LINE))
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4)
    line:SetSize(PAGE_WIDTH - 2 * self.x, 1)
    self.y = self.y - 26
  end

  -- Wrapped text; `getText` (a function) makes it live, refreshed when the page is shown.
  function L:Text(text, font, getText)
    local fs = frame:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", self.x, self.y)
    fs:SetWidth(PAGE_WIDTH - 2 * self.x)
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    if getText then
      refresh[#refresh + 1] = function() fs:SetText(getText()) end
      fs:SetText(getText())
    end
    self.y = self.y - fs:GetStringHeight() - 8
    return fs
  end

  function L:Check(label, tooltip, get, set)
    local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", self.x - 4, self.y + 4)
    box.Text:SetText(label)
    box.Text:SetFontObject("GameFontHighlight")
    box:SetScript("OnClick", function(b) set(b:GetChecked() and true or false) end)
    if tooltip then
      box:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:AddLine(label, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
      end)
      box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    refresh[#refresh + 1] = function() box:SetChecked(get() and true or false) end
    self.y = self.y - 28
    return box
  end

  -- Buttons go side by side on one row until Gap or another control moves the cursor down.
  function L:Button(text, tooltip, onClick, width)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(width or 140, 24)
    self.rowX = self.rowX or self.x
    button:SetPoint("TOPLEFT", self.rowX, self.y)
    self.rowX = self.rowX + (width or 140) + 8
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    if tooltip then
      button:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
      end)
      button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return button
  end

  function L:EndRow()
    if self.rowX then
      self.rowX = nil
      self.y = self.y - 32
    end
  end

  return L
end

local function RefreshInstance(instance)
  for _, fn in ipairs(instance.refresh) do fn() end
end

-- Builds one page into `frame`, starting at (x, y).
local function BuildInstance(page, frame, x, y)
  local instance = { frame = frame, refresh = {} }
  page.build(NewLayout(frame, instance.refresh, x, y))
  frame:HookScript("OnShow", function() RefreshInstance(instance) end)
  instances[#instances + 1] = instance
  return instance
end

function lab.SyncSettings()
  for _, instance in ipairs(instances) do
    if instance.frame:IsVisible() then RefreshInstance(instance) end
  end
end

---------------------------------------------------------------------------
-- The pages
---------------------------------------------------------------------------

local function EntryCount(name)
  local count = 0
  for _ in pairs(lab.modules[name].data or {}) do count = count + 1 end
  return count
end

pages[#pages + 1] = {
  title = "Modules",
  build = function(L)
    L:Heading("MODULES")
    L:Text("Each module collects data for one project. A module that is off collects nothing and stays off after "
      .. "/reload; its saved data is kept.", "GameFontDisableSmall")
    for _, name in ipairs(lab.moduleOrder) do
      local module = lab.modules[name]
      L:Check(name, module.description, function() return lab.IsEnabled(name) end,
        function(on) lab.SetEnabled(name, on) end)
    end
  end,
}

pages[#pages + 1] = {
  title = "Session",
  build = function(L)
    L:Heading("THIS SESSION")
    L:Text(nil, "GameFontHighlight", function()
      local build = { GetBuildInfo() }
      local lines = {
        "Game build: " .. tostring(build[1]) .. " (" .. tostring(build[2]) .. ")",
        "Errors this session: " .. (lab.db and #lab.db.errors or 0),
        "Saved dumps: " .. (lab.db and #lab.db.dumps or 0),
      }
      for _, name in ipairs(lab.moduleOrder) do
        lines[#lines + 1] = name .. ": " .. (lab.IsEnabled(name) and "" or "off, ") .. EntryCount(name) .. " entries"
      end
      return table.concat(lines, "\n")
    end)
    L:Gap(6)
    L:Button("Collect now", "Runs every module's checks again (same as /lab run).", function()
      if lab.RunAll then lab.RunAll() end
      lab.SyncSettings()
    end)
    L:Button("Reload UI", "Reloads the interface, which writes PsiLab.lua to the SavedVariables folder.", ReloadUI)
    L:EndRow()
    L:Text("The game writes PsiLab's file on /reload or logout: WTF/Account/<account>/SavedVariables/PsiLab.lua.",
      "GameFontDisableSmall")
  end,
}

---------------------------------------------------------------------------
-- The floating window
---------------------------------------------------------------------------

local function SolidTexture(parent, layer, color)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(unpack(color))
  return t
end

-- A one-pixel border around `frame`.
local function Border(frame, color)
  for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
      { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
    local t = SolidTexture(frame, "BORDER", color)
    t:SetPoint(side[1])
    t:SetPoint(side[2])
    if side[3] then t:SetWidth(side[3]) else t:SetHeight(side[4]) end
  end
end

local function SelectPage(index)
  for i, entry in ipairs(window.entries) do
    local selected = i == index
    entry.page:SetShown(selected)
    entry.marker:SetShown(selected)
    entry.label:SetFontObject(selected and "GameFontHighlight" or "GameFontNormal")
    if selected then entry.label:SetTextColor(1, 1, 1) else entry.label:SetTextColor(0.7, 0.7, 0.7) end
  end
  window.selected = index
end

local function CreateWindow()
  window = CreateFrame("Frame", "PsiLabOptions", UIParent)
  window:SetSize(WIDTH, HEIGHT)
  window:SetPoint("CENTER")
  window:SetFrameStrata("HIGH")
  window:SetToplevel(true)
  window:SetClampedToScreen(true)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  table.insert(UISpecialFrames, "PsiLabOptions")  -- Escape closes it
  window:Hide()

  SolidTexture(window, "BACKGROUND", COLOR_BG):SetAllPoints()
  Border(window, COLOR_LINE)

  local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", PAD, -12)
  title:SetText("PsiLab")
  title:SetTextColor(unpack(COLOR_ACCENT))
  local subtitle = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subtitle:SetPoint("LEFT", title, "RIGHT", 10, -1)
  subtitle:SetText("Development tool: collects game data for building addons")

  local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local nav = CreateFrame("Frame", nil, window)
  nav:SetPoint("TOPLEFT", 1, -HEADER)
  nav:SetPoint("BOTTOMLEFT", 1, FOOTER)
  nav:SetWidth(NAV_WIDTH)
  SolidTexture(nav, "BACKGROUND", COLOR_NAV):SetAllPoints()

  local top = SolidTexture(window, "BORDER", COLOR_LINE)
  top:SetPoint("TOPLEFT", 1, -HEADER)
  top:SetPoint("TOPRIGHT", -1, -HEADER)
  top:SetHeight(1)
  local bottom = SolidTexture(window, "BORDER", COLOR_LINE)
  bottom:SetPoint("BOTTOMLEFT", 1, FOOTER)
  bottom:SetPoint("BOTTOMRIGHT", -1, FOOTER)
  bottom:SetHeight(1)

  window.entries = {}
  for i, page in ipairs(pages) do
    local button = CreateFrame("Button", nil, nav)
    button:SetSize(NAV_WIDTH, 28)
    button:SetPoint("TOPLEFT", 0, -8 - (i - 1) * 30)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
    local marker = SolidTexture(button, "ARTWORK", { COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], 1 })
    marker:SetPoint("TOPLEFT")
    marker:SetPoint("BOTTOMLEFT")
    marker:SetWidth(3)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 14, 0)
    label:SetText(page.title)
    button:SetScript("OnClick", function() SelectPage(i) end)

    local frame = CreateFrame("Frame", nil, window)
    frame:SetPoint("TOPLEFT", nav, "TOPRIGHT", PAD, -8)
    frame:SetPoint("BOTTOMRIGHT", -PAD, FOOTER + 8)
    frame:Hide()
    BuildInstance(page, frame, 0, 0)
    window.entries[i] = { page = frame, marker = marker, label = label }
  end

  local version = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  version:SetPoint("BOTTOMLEFT", PAD, 13)
  version:SetText("PsiLab " .. tostring(C_AddOns.GetAddOnMetadata("PsiLab", "Version")))

  local reload = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
  reload:SetSize(110, 22)
  reload:SetPoint("BOTTOMRIGHT", -PAD, 8)
  reload:SetText("Reload UI")
  reload:SetScript("OnClick", ReloadUI)

  SelectPage(1)
end

function lab.ToggleSettings()
  if not window then CreateWindow() end
  window:SetShown(not window:IsShown())
end

---------------------------------------------------------------------------
-- Blizzard's Options > AddOns
---------------------------------------------------------------------------

-- A page as a canvas Blizzard sizes and shows itself, with the page's title at the top.
local function CreateCanvas(page, heading)
  local canvas = CreateFrame("Frame", nil, UIParent)
  canvas:Hide()
  local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(heading)
  BuildInstance(page, canvas, 16, -56)
  return canvas
end

local function RegisterBlizzardPages()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
  local main = Settings.RegisterCanvasLayoutCategory(CreateCanvas(pages[1], "PsiLab: " .. pages[1].title), "PsiLab")
  Settings.RegisterAddOnCategory(main)
  if not Settings.RegisterCanvasLayoutSubcategory then return end
  for i = 2, #pages do
    Settings.RegisterCanvasLayoutSubcategory(main, CreateCanvas(pages[i], "PsiLab: " .. pages[i].title), pages[i].title)
  end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
  local ok, err = pcall(RegisterBlizzardPages)
  if not ok then lab.RecordError("settings: " .. tostring(err)) end
end)
