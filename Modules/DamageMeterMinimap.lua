local _, ns = ...
local L = ns.L

--------------------------------------------------
-- DAMAGE METER: DOCK BESIDE THE MINIMAP (Settings > Damage Meter > Beside the Minimap)
-- Blizzard's meter, in DamageMeter.lua's skin, held against the minimap's left, right or bottom edge:
-- as tall as the map beside it, as wide as the map under it. A small tab on that edge, shown while the
-- mouse is near the map or the meter, folds the meter away and brings it back: it slides toward the
-- map as it fades out, and back out as it fades in. The fold is kept in the profile.
-- Folded, the meter is hidden whatever its Visibility; open, its Visibility (Edit Mode dialog) decides
-- as ever (DamageMeter.lua ApplyVisibility asks DamageMeter.MapFolded).
-- Placing and sizing wait for the end of a fight: a fold in a fight only fades, and a meter folded
-- before the fight comes back once it ends (an addon can't show the meter in a fight). Off with the
-- Meter Tab in the Chat, which wins, and in the Gamepad UI. While Edit Mode is open the meter can be
-- dragged as ever; it goes back beside the map as Edit Mode closes.
--------------------------------------------------
local DamageMeter = ns.DamageMeter
local MapDock = {}
DamageMeter.MapDock = MapDock

local _G = _G
local math_max, math_min = math.max, math.min
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local LSM = LibStub("LibSharedMedia-3.0")

MapDock.PAD = 2              -- as DamageMeter.lua's SKIN_PADDING: the skin reaches this far past the window
MapDock.GAP = 4              -- between the map's edge and the meter's skin
MapDock.TAB_GAP = 2          -- between the tab and the edge it sits on
MapDock.SLIDE = 28           -- how far the meter travels toward the map as it folds
MapDock.TIME = 0.22          -- seconds a fold or an open takes
MapDock.TAB = { long = 40, short = 16, arrow = 12, edge = 12 }
MapDock.REACH = 24           -- how far past the map and the meter the mouse brings the tab
MapDock.HOVER_EVERY = 0.05   -- seconds between the tab's mouse checks
MapDock.TAB_FADE = 0.15      -- seconds the tab takes to show or hide
MapDock.SIZE = { min = 120, max = 400, default = 220 }
-- FlareUI's chevron (as the bags' section headers), pointing down; turned toward where the meter will go
MapDock.ARROW = "Interface\\AddOns\\FlareUI\\Media\\Panel\\Chevron.tga"
-- per side: the meter's point on the map's, which way is out (x, y), the tab's points, the arrow's
-- turn while open (folding goes toward the map) and while folded (opening goes away from it), turned
-- counter-clockwise from the chevron's down
MapDock.SIDES = {
    left   = { point = "TOPRIGHT", rel = "TOPLEFT",    x = -1, y = 0,  tab = "RIGHT", tabRel = "LEFT",   open = math.pi / 2,  folded = -math.pi / 2 },
    right  = { point = "TOPLEFT",  rel = "TOPRIGHT",   x = 1,  y = 0,  tab = "LEFT",  tabRel = "RIGHT",  open = -math.pi / 2, folded = math.pi / 2 },
    bottom = { point = "TOPLEFT",  rel = "BOTTOMLEFT", x = 0,  y = -1, tab = "TOP",   tabRel = "BOTTOM", open = math.pi,      folded = 0 },
}

MapDock.slide = 1            -- how far out the meter is: 0 folded, 1 open (only between the two while animating)
MapDock.goal = 1
MapDock.animating = false

local function GetDb()
    local profile = ns.db and ns.db.profile
    return profile and profile.damagemeter or nil
end

local function IsEditModeActive()
    return _G.EditModeManagerFrame and _G.EditModeManagerFrame:IsShown() or false
end

local function Side(db)
    return MapDock.SIDES[db and db.minimapDockSide] or MapDock.SIDES.left
end

-- The skin's width beside the map (its height under it), within the slider's range
local function DockSize(db)
    local size = tonumber(db and db.minimapDockSize) or MapDock.SIZE.default
    return math_max(MapDock.SIZE.min, math_min(MapDock.SIZE.max, size))
end

--------------------------------------------------
-- 1. STATE
--------------------------------------------------
-- Switched on, the meter module on, not in the chat (the Meter tab wins) nor in the Gamepad UI
function MapDock.On()
    local db = GetDb()
    if not (db and db.enabled and db.minimapDock) then return false end
    if ns.IsGamepadUI() then return false end
    if DamageMeter.ChatTabOn and DamageMeter.ChatTabOn() then return false end
    return _G.DamageMeter ~= nil and MapDock.Anchor() ~= nil
end

function MapDock.Open()
    local db = GetDb()
    return not (db and db.minimapDockOpen == false)
end

function MapDock.Folded() return not MapDock.Open() end

-- FlareUI's square map frame (Minimap.lua) while it's there, else Blizzard's map
function MapDock.Anchor()
    local MM = ns.Minimap
    local frame = MM and MM.Frame
    if frame and frame:IsShown() then return frame end
    return _G.Minimap
end

-- A frame's size in another frame's units (the meter may have its own Edit Mode scale)
local function SizeIn(frame, units)
    local w, h = frame:GetSize()
    if type(w) ~= "number" or type(h) ~= "number" then return nil end
    local ratio = frame:GetEffectiveScale() / units:GetEffectiveScale()
    return w * ratio, h * ratio
end

-- The smoothed slide: eased in and out
local function Eased(s) return s * s * (3 - 2 * s) end

--------------------------------------------------
-- 2. PLACING THE METER
-- Edit Mode wraps SetPoint / ClearAllPoints on its frames: the base setters it keeps place the meter
-- without telling Edit Mode of a new position (as DamageMeter.lua MatchChatSize).
--------------------------------------------------
local placing = false

local function PlaceBody()
    local meter, anchor, db = _G.DamageMeter, MapDock.Anchor(), GetDb()
    if not (meter and anchor and db) then return end
    local mapW, mapH = SizeIn(anchor, meter)
    if not mapW then return end
    local side, pad, size = Side(db), MapDock.PAD, DockSize(db)
    -- the skin's outer size, then the window inside it
    local width, height
    if side.y ~= 0 then width, height = mapW, size else width, height = size, mapH end
    width, height = width - 2 * pad, height - 2 * pad
    if width <= 0 or height <= 0 then return end
    -- pulled toward the map by the part of the slide still to go
    local back = (1 - Eased(MapDock.animating and MapDock.slide or 1)) * MapDock.SLIDE
    local out = MapDock.GAP + pad - back
    local x, y
    if side.y ~= 0 then x, y = pad, side.y * out else x, y = side.x * out, -pad end
    placing = true
    meter:SetSize(width, height)
    local clear = meter.ClearAllPointsBase or meter.ClearAllPoints
    local set = meter.SetPointBase or meter.SetPoint
    clear(meter)
    set(meter, side.point, anchor, side.rel, x, y)
    placing = false
    -- (RestoreEditModeAnchor puts it back where Edit Mode keeps it, once undocked)
    DamageMeter.chatAnchored = true
end

function MapDock.Place()
    if InCombatLockdown() then
        MapDock.placePending = true
        return
    end
    if IsEditModeActive() or not MapDock.On() then return end
    MapDock.placePending = nil
    local ok, err = pcall(PlaceBody)
    placing = false
    if not ok then geterrorhandler()(err) end
end

-- Blizzard or Edit Mode moved or sized the meter, or the map changed size: back beside the map a
-- frame later, once every point they set is in
local againQueued = false
local function PlaceAgain()
    if placing or againQueued or not MapDock.applied then return end
    againQueued = true
    C_Timer.After(0, function()
        againQueued = false
        if MapDock.On() then MapDock.Place() MapDock.PlaceTab() end
    end)
end

function MapDock.Hook(meter)
    if not meter.FlareUI_MapDockHooked then
        meter.FlareUI_MapDockHooked = true
        hooksecurefunc(meter, "SetPoint", PlaceAgain)
        if type(meter.SetPointBase) == "function" then hooksecurefunc(meter, "SetPointBase", PlaceAgain) end
        hooksecurefunc(meter, "SetSize", PlaceAgain)
    end
    -- the map the meter sits by (FlareUI's square frame arrives with the Minimap module)
    local anchor = MapDock.Anchor()
    if anchor and not anchor.FlareUI_MapDockHooked then
        anchor.FlareUI_MapDockHooked = true
        anchor:HookScript("OnSizeChanged", PlaceAgain)
    end
end

-- Switched off (or given way to the Meter tab): the place and size Edit Mode keeps, and the meter
-- shown again if it was folded away
function MapDock.Undock()
    if InCombatLockdown() then
        MapDock.placePending = true
        return
    end
    MapDock.applied = nil
    MapDock.animating, MapDock.slide, MapDock.goal = false, 1, 1
    if MapDock.driver then MapDock.driver:Hide() end
    local db = GetDb()
    -- the Meter tab and Match Chat Size size it themselves (DamageMeter.lua Refresh, before this)
    if not (db and (db.matchChatSize or (DamageMeter.ChatTabOn and DamageMeter.ChatTabOn()))) then
        DamageMeter:RestoreEditModeSize()
    end
    if not (DamageMeter.ChatTabOn and DamageMeter.ChatTabOn()) then DamageMeter:RestoreEditModeAnchor() end
    DamageMeter:ApplyVisibility()
end

-- From DamageMeter.lua Refresh (out of a fight), and after a fight that held a change back
function MapDock.Apply()
    local meter = _G.DamageMeter
    if not meter then return end
    if not MapDock.On() then
        if MapDock.applied then MapDock.Undock() end
        if MapDock.tab then MapDock.tab:Hide() end
        return
    end
    MapDock.Hook(meter)
    local first = not MapDock.applied
    MapDock.applied = true
    MapDock.Place()
    MapDock.UpdateTab()
    -- folded away from the last session: hidden now (DamageMeter.lua ApplyVisibility)
    if first then DamageMeter:ApplyVisibility() end
end

--------------------------------------------------
-- 3. FOLD AND OPEN
-- The slide and the alpha run together for MapDock.TIME; the meter's own fade waits meanwhile
-- (DamageMeter.lua FadeStep), then its Visibility takes over again. In a fight only the alpha moves.
--------------------------------------------------
local function Finish()
    MapDock.animating = false
    MapDock.driver:Hide()
    MapDock.Place()
    MapDock.PlaceTab()
    -- folded: hidden now; open: its Visibility and its fade go on from here
    DamageMeter:ApplyVisibility()
end

local function Step(self, elapsed)
    local s, goal = MapDock.slide, MapDock.goal
    local step = (elapsed or 0) / MapDock.TIME
    if goal > s then s = math_min(goal, s + step) else s = math_max(goal, s - step) end
    MapDock.slide = s
    local meter = _G.DamageMeter
    if meter and meter:IsShown() and MapDock.fadeTo then
        meter:SetAlpha(MapDock.fadeTo * Eased(s))
    end
    if not InCombatLockdown() then
        local ok, err = pcall(PlaceBody)
        placing = false
        if not ok then geterrorhandler()(err) end
    end
    MapDock.PlaceTab()
    if s == goal then Finish() end
end

function MapDock.Toggle()
    local db, meter = GetDb(), _G.DamageMeter
    if not (db and meter and MapDock.On()) then return end
    local opening = MapDock.Folded()
    db.minimapDockOpen = opening
    if not MapDock.driver then
        MapDock.driver = CreateFrame("Frame")
        MapDock.driver:Hide()
        MapDock.driver:SetScript("OnUpdate", Step)
    end
    if not MapDock.animating then MapDock.slide = opening and 0 or 1 end
    MapDock.goal = opening and 1 or 0
    MapDock.animating = true
    if opening then
        -- its Visibility decides whether it comes up (shown at 0 then, the slide brings the alpha in);
        -- not wanted, or held back in a fight, the slide moves nothing
        if not meter:IsShown() then meter:SetAlpha(0) end
        DamageMeter:ApplyVisibility()
        MapDock.fadeTo = meter.FlareUI_Up and 1 or nil
    else
        -- from where it stands: a meter at its Faded Opacity fades from there
        local alpha = meter:IsShown() and meter:GetAlpha() or 0
        MapDock.fadeTo = alpha > 0 and alpha or nil
        DamageMeter:ApplyVisibility()
    end
    MapDock.UpdateTab()
    MapDock.driver:Show()
end

--------------------------------------------------
-- 4. THE FOLD TAB
-- In the meter's look: its background, its border at a smaller edge, the header's golds on the
-- arrow. Hidden until the mouse is near the map, the meter or the tab itself.
--------------------------------------------------
local function PaintArrow(tab)
    local c = DamageMeter.HEADER_COLORS
    c = c and (tab.hover and c.title or c.icon)
    if c then tab.Arrow:SetVertexColor(c.r, c.g, c.b, c.a or 1) end
end

local function TabTip(tab)
    if not GameTooltip then return end
    GameTooltip:SetOwner(tab, "ANCHOR_LEFT")
    GameTooltip:SetText(L["Damage Meter"], 1, 0.82, 0)
    GameTooltip:AddLine(MapDock.Open() and L["Click to fold the meter away."] or L["Click to bring the meter back."], 1, 1, 1, true)
    GameTooltip:Show()
end

-- Near: the pointer on the tab, the meter, or the map and a little past it
local function MouseNear(tab)
    if tab:IsMouseOver() then return true end
    local anchor = MapDock.Anchor()
    local r = MapDock.REACH
    if anchor and anchor:IsVisible() and anchor:IsMouseOver(r, -r, -r, r) then return true end
    local meter = _G.DamageMeter
    return meter ~= nil and meter:IsVisible() and meter:GetAlpha() > 0 and meter:IsMouseOver(r, -r, -r, r) or false
end

local function TabUpdate(tab, elapsed)
    tab.wait = (tab.wait or 0) + elapsed
    if tab.wait < MapDock.HOVER_EVERY then return end
    elapsed, tab.wait = tab.wait, 0
    local anchor = MapDock.Anchor()
    local target = (anchor and anchor:IsVisible() and MouseNear(tab)) and 1 or 0
    local alpha = tab:GetAlpha()
    if alpha == target then return end
    local step = elapsed / MapDock.TAB_FADE
    tab:SetAlpha(target > alpha and math_min(target, alpha + step) or math_max(target, alpha - step))
end

function MapDock.Tab()
    if MapDock.tab then return MapDock.tab end
    local tab = CreateFrame("Button", "FlareUI_MeterMapTab", UIParent, "BackdropTemplate")
    tab:SetFrameStrata("MEDIUM")
    tab:SetFrameLevel(20)
    tab:SetClampedToScreen(true)
    tab:RegisterForClicks("LeftButtonUp")
    local arrow = tab:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(MapDock.ARROW)
    arrow:SetSize(MapDock.TAB.arrow, MapDock.TAB.arrow)
    arrow:SetPoint("CENTER")
    tab.Arrow = arrow
    tab:SetScript("OnClick", function() MapDock.Toggle() end)
    tab:SetScript("OnEnter", function(self)
        self.hover = true
        PaintArrow(self)
        TabTip(self)
    end)
    tab:SetScript("OnLeave", function(self)
        self.hover = nil
        PaintArrow(self)
        if GameTooltip then GameTooltip:Hide() end
    end)
    tab:SetScript("OnUpdate", TabUpdate)
    tab:SetAlpha(0)
    MapDock.tab = tab
    return tab
end

local function PaintTab(tab, db)
    local edge = DamageMeter.BorderFile and DamageMeter.BorderFile(db)
    local bg = LSM:Fetch("background", "Blizzard Dialog Background Dark") or "Interface\\DialogFrame\\UI-DialogBox-Background-Dark"
    tab:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = false, tileSize = 0,
        edgeSize = ns.BorderEdgeSize(edge, MapDock.TAB.edge), insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    tab:SetBackdropColor(1, 1, 1, db.opacity or 0.75)
    local b = ns.BORDER_COLOR
    tab:SetBackdropBorderColor(b.r, b.g, b.b, b.a or 1)
end

-- On the meter's far edge while it's out, on the map's edge while folded, sliding between
function MapDock.PlaceTab()
    local tab, db, anchor, meter = MapDock.tab, GetDb(), MapDock.Anchor(), _G.DamageMeter
    if not (tab and db and anchor and meter) then return end
    local side = Side(db)
    -- in a fight the meter stays where it is: the tab goes straight to where it will rest
    local s = MapDock.animating and not InCombatLockdown() and Eased(MapDock.slide) or (MapDock.Open() and 1 or 0)
    local ratio = meter:GetEffectiveScale() / tab:GetEffectiveScale()
    local reach = MapDock.TAB_GAP + s * (MapDock.GAP + DockSize(db)) * ratio
    tab:ClearAllPoints()
    tab:SetPoint(side.tab, anchor, side.tabRel, side.x * reach, side.y * reach)
end

function MapDock.UpdateTab()
    local db = GetDb()
    if not (db and MapDock.On()) then
        if MapDock.tab then MapDock.tab:Hide() end
        return
    end
    local tab = MapDock.Tab()
    local side = Side(db)
    if side.y ~= 0 then tab:SetSize(MapDock.TAB.long, MapDock.TAB.short)
    else tab:SetSize(MapDock.TAB.short, MapDock.TAB.long) end
    PaintTab(tab, db)
    tab.Arrow:SetRotation(MapDock.Open() and side.open or side.folded)
    PaintArrow(tab)
    MapDock.PlaceTab()
    tab:Show()
end

--------------------------------------------------
-- 5. EVENTS
--------------------------------------------------
-- a place or a size held back in a fight; the map's size after a loading screen
local events = CreateFrame("Frame")
MapDock.events = events
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and not MapDock.placePending then return end
    C_Timer.After(0, function()
        if MapDock.On() or MapDock.applied then
            local ok, err = pcall(MapDock.Apply)
            if not ok then geterrorhandler()(err) end
        end
    end)
end)
