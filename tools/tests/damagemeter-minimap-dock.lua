-- Dock Beside the Minimap (Modules/DamageMeterMinimap.lua), loaded on its own with a stand-in for
-- DamageMeter.lua's few entry points: where the meter goes on each side, the fold tab, a fight
-- holding the place back, and the Meter tab in the chat taking over.
local Fixture = dofile("tools/tests/fixtures/settings-ui.lua")

local function setup(options)
    options = options or {}
    local ui = Fixture.new()
    local env = ui.env
    local db = {
        enabled = true, opacity = 0.75, minimapDock = true, minimapDockSide = options.side or "left",
        minimapDockSize = options.size or 220, minimapDockOpen = options.open ~= false,
    }
    local calls = { visibility = 0, anchor = 0, size = 0 }
    local meterUI = {
        ChatTabOn = function() return ui.chatTab == true end,
        ApplyVisibility = function() calls.visibility = calls.visibility + 1 end,
        RestoreEditModeSize = function() calls.size = calls.size + 1 end,
        RestoreEditModeAnchor = function() calls.anchor = calls.anchor + 1 end,
        BorderFile = function() return "border/FlareUI Frames" end,
        HEADER_COLORS = { title = { r = 0.8, g = 0.6, b = 0.34 }, icon = { r = 0.61, g = 0.48, b = 0.29 } },
    }
    local map = env.CreateFrame("Frame", "Minimap", env.UIParent)
    map:SetSize(200, 180)
    local meter = env.CreateFrame("Frame", "DamageMeter", env.UIParent)
    if options.meterScale then meter:SetScale(options.meterScale) end
    env.EditModeManagerFrame = env.CreateFrame("Frame", nil, env.UIParent)
    env.EditModeManagerFrame:Hide()
    local media = { Fetch = function(_, kind, name) return kind .. "/" .. name end }
    env.LibStub = function(name)
        assert(name == "LibSharedMedia-3.0", name)
        return media
    end
    local ns = {
        L = setmetatable({}, { __index = function(_, key) return key end }),
        db = { profile = { damagemeter = db } },
        DamageMeter = meterUI,
        IsGamepadUI = function() return false end,
        BORDER_COLOR = { r = 0.65, g = 0.49, b = 0.27, a = 1 },
        BorderEdgeSize = function(_, size) return size end,
    }
    ui:load("Modules/DamageMeterMinimap.lua", ns)
    local function runTimers()
        while #ui.timers > 0 do table.remove(ui.timers, 1).callback() end
    end
    return { ui = ui, env = env, db = db, dock = meterUI.MapDock, meter = meter, map = map, calls = calls, runTimers = runTimers }
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- Left of the map: the skin's top on the map's top, as tall as the map, the setting's width
do
    local t = setup()
    t.dock.Apply()
    local point, rel, relPoint, x, y = t.meter:GetPoint()
    assert(point == "TOPRIGHT" and rel == t.map and relPoint == "TOPLEFT", tostring(point))
    assert(x == -(t.dock.GAP + t.dock.PAD) and y == -t.dock.PAD, x .. " " .. y)
    assert(t.meter:GetWidth() == 220 - 2 * t.dock.PAD and t.meter:GetHeight() == 180 - 2 * t.dock.PAD)
    assert(t.dock.tab:IsShown() and t.dock.tab:GetWidth() == t.dock.TAB.short)
    assert(t.calls.visibility == 1, "the first dock re-checks the meter's visibility")
end

-- Below the map: as wide as the map, the setting's height
do
    local t = setup({ side = "bottom", size = 150 })
    t.dock.Apply()
    local point, _, relPoint, x, y = t.meter:GetPoint()
    assert(point == "TOPLEFT" and relPoint == "BOTTOMLEFT" and x == t.dock.PAD and y == -(t.dock.GAP + t.dock.PAD))
    assert(t.meter:GetWidth() == 200 - 2 * t.dock.PAD and t.meter:GetHeight() == 150 - 2 * t.dock.PAD)
    assert(t.dock.tab:GetWidth() == t.dock.TAB.long)
end

-- A meter with its own Edit Mode scale takes the map's height in its own units
do
    local t = setup({ meterScale = 0.5 })
    t.dock.Apply()
    assert(near(t.meter:GetHeight(), 180 * 2 - 2 * t.dock.PAD), tostring(t.meter:GetHeight()))
end

-- The tab folds the meter: saved, slid toward the map, then handed back to the visibility check
do
    local t = setup()
    t.dock.Apply()
    t.dock.tab:RunScript("OnClick")
    assert(t.db.minimapDockOpen == false and t.dock.Folded() and t.dock.animating)
    t.dock.driver:RunScript("OnUpdate", t.dock.TIME / 2)
    local _, _, _, x = t.meter:GetPoint()
    assert(x > -(t.dock.GAP + t.dock.PAD), "half way, the meter has moved toward the map")
    local checks = t.calls.visibility
    t.dock.driver:RunScript("OnUpdate", t.dock.TIME)
    assert(not t.dock.animating and t.dock.slide == 0 and t.calls.visibility == checks + 1)
    -- open again: back at its place once the slide ends
    t.dock.tab:RunScript("OnClick")
    t.dock.driver:RunScript("OnUpdate", t.dock.TIME)
    _, _, _, x = t.meter:GetPoint()
    assert(t.db.minimapDockOpen == true and not t.dock.animating and x == -(t.dock.GAP + t.dock.PAD))
end

-- In a fight the place waits for the fight's end
do
    local t = setup()
    t.ui.combat = true
    t.dock.Apply()
    assert(t.meter:GetNumPoints() == 0 and t.dock.placePending)
    t.ui.combat = false
    t.dock.events:RunScript("OnEvent", "PLAYER_REGEN_ENABLED")
    t.runTimers()
    assert(t.meter:GetNumPoints() == 1 and not t.dock.placePending)
end

-- The Meter tab in the chat wins: the dock lets go and the tab hides
do
    local t = setup()
    t.dock.Apply()
    t.ui.chatTab = true
    assert(not t.dock.On())
    t.dock.Apply()
    assert(not t.dock.applied and not t.dock.tab:IsShown())
    assert(t.calls.anchor == 0 and t.calls.size == 0, "the Meter tab places and sizes the meter itself")
end

-- Switched off: the place and size Edit Mode keeps
do
    local t = setup()
    t.dock.Apply()
    t.db.minimapDock = false
    t.dock.Apply()
    assert(not t.dock.applied and t.calls.anchor == 1 and t.calls.size == 1)
end

print("PASS: damage meter minimap dock")
