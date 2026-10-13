--============================================================
-- BFMDBCompat
-- Adds extra bars to Minimal Display Bars (B42 fork), fed by other mods:
--   bf_pregnancy   <- Being Female  (mod id "BF")        BFPregnancyUpdate event
--   bf_lactation   <- Being Female  (mod id "BF")        BFLactationUpdate event
--   zr_arousal     <- ZomboRut      (mod id "ZomboRut")  ZR_Arousal.get(player)
--   zl_excitation  <- ZomboLust     (mod id "ZomboLust") modData.ZL_Excitation
--
-- How it works (verified against the MDB B42 fork source):
--   * MDB keeps its bar list and DEFAULT_SETTINGS in file-local variables,
--     so we cannot register through MDB. But ISGenericMiniDisplayBarB4220,
--     MinimalDisplayBarsB4220.configTables and .displayBars are global, so
--     we build extra bars with MDB's own class and store them in MDB's own
--     tables. Dragging, colour, size, saving and Move-Bars-Together then
--     work for free.
--   * MDB only re-shows a bar from inside render(), which never runs while
--     a bar is hidden. So returning -1 would hide a bar forever. We control
--     visibility ourselves instead (syncVisibility below).
--   * This mod only READS values (public API / modData). It contains no code
--     from the other mods.
--============================================================

BFMDBCompat = BFMDBCompat or {}
-- Debug window state (see BFMDBCompat_Debug.lua). override=true replaces the real
-- lactation/pregnancy values for the local female player; shapeOff=true disables the
-- body shape entirely (vanilla model) so you can compare.
BFMDBCompat.debug = BFMDBCompat.debug or { override = false, lact = 0.0, preg = 0.0, shapeOff = false, avatar = false }

local STALE_HOURS = 0.05 -- ~3 in-game minutes without a BF event = "not active"

-- Lactation bar scale. Being Female doesn't publish a maximum, so this is the
-- amount that counts as a FULL bar. If your breasts are "full" at a different
-- value, hover the lactation bar (it shows the real value) and change this.
-- (The bar can still exceed it: the scale grows if a higher amount is ever seen.)
local MILK_CAPACITY = 1.0

-- Placeholder icon (only shown if the player enables MDB's icon option).
-- Replace with your own PNG, e.g. "media/ui/BFMDB_Pregnancy.png".
local PLACEHOLDER_ICON = "media/ui/Moodles/32/Mood_Bored.png"

--------------------------------------------------------------
-- Helpers
--------------------------------------------------------------
local activeCache = {}
local function isModActive(id)
    local v = activeCache[id]
    if v == nil then
        v = (getActivatedMods():contains(id) == true)
        activeCache[id] = v
    end
    return v
end

local function clamp01(v)
    if type(v) ~= "number" or v ~= v then return 0 end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function pick(v, default)
    if v == nil then return default end
    return v
end

local function nowHours()
    return getGameTime():getWorldAgeHours()
end

local function isFresh(lastSeen)
    if lastSeen == nil then return false end
    local d = nowHours() - lastSeen
    return d >= 0 and d < STALE_HOURS
end

local function isMainPlayer(p)
    return p ~= nil and p:getPlayerNum() == 0 -- BF / ZomboLust are single-character
end

--------------------------------------------------------------
-- Source 1: Being Female events
--------------------------------------------------------------
local state = {
    preg = { progress = 0, lastSeen = nil },
    lact = { amount = 0, active = false, lastSeen = nil },
}

local function onPregnancyUpdate(d)
    if type(d) ~= "table" then return end
    state.preg.progress = tonumber(d.progress) or 0
    state.preg.lastSeen = nowHours()
end

local function onLactationUpdate(d)
    if type(d) ~= "table" then return end
    local l = state.lact
    l.active = (d.isActive == true)
    l.amount = tonumber(d.milkAmount) or 0
    l.lastSeen = nowHours()

    -- Remember the highest amount ever seen so the scale can grow past
    -- MILK_CAPACITY. New key on purpose: the old BFMDB_milkMax stored the very
    -- first reading, which is what made the bar start full.
    local p = getPlayer()
    if p then
        local md = p:getModData()
        if l.amount > (md.BFMDB_milkSeen or 0) then
            md.BFMDB_milkSeen = l.amount
        end
    end
end

local hooked = false
local function tryHookEvents()
    if hooked then return end
    if not (Events.BFPregnancyUpdate and Events.BFLactationUpdate) then return end
    Events.BFPregnancyUpdate.Add(onPregnancyUpdate)
    Events.BFLactationUpdate.Add(onLactationUpdate)
    if Events.BFPregnancyStop then
        Events.BFPregnancyStop.Add(function() state.preg.lastSeen = nil end)
    end
    hooked = true
end

local function pregnancyActive(p)
    return isMainPlayer(p) and not p:isDead() and isFresh(state.preg.lastSeen)
end

local function lactationActive(p)
    return isMainPlayer(p) and not p:isDead()
        and state.lact.active and isFresh(state.lact.lastSeen)
end

local function getPregnancy(p, useRealValue)
    if useRealValue then return state.preg.progress * 100 end -- tooltip: percent
    return clamp01(state.preg.progress)
end

local function getLactation(p, useRealValue)
    if useRealValue then return state.lact.amount end
    local max = MILK_CAPACITY
    if p then
        local seen = p:getModData().BFMDB_milkSeen or 0
        if seen > max then max = seen end
    end
    if state.lact.amount > max then max = state.lact.amount end
    if max <= 0 then max = 1 end
    return clamp01(state.lact.amount / max)
end

--------------------------------------------------------------
-- Source 2: ZomboRut arousal (public API ZR_Arousal.get -> 0..100)
--------------------------------------------------------------
-- Mirrors ZomboRut's own on/off rule: its sandbox table must exist and neither
-- enableMod nor arousalEnabled may be false.
local function zrArousalEnabled()
    local sv = SandboxVars and SandboxVars.ZomboRut
    if not sv then return false end
    return sv.enableMod ~= false and sv.arousalEnabled ~= false
end

local function arousalActive(p)
    return p ~= nil and not p:isDead()
        and ZR_Arousal ~= nil and ZR_Arousal.get ~= nil
        and zrArousalEnabled()
end

local function getArousal(p, useRealValue)
    local v = 0
    if p and ZR_Arousal and ZR_Arousal.get then v = ZR_Arousal.get(p) end
    if useRealValue then return v end
    return clamp01(v / 100)
end

--------------------------------------------------------------
-- Source 3: ZomboLust excitation (modData.ZL_Excitation -> 0..100)
--------------------------------------------------------------
local function excitationActive(p)
    return isMainPlayer(p) and not p:isDead() and ZomboLust_ExcitationSystem ~= nil
end

local function getExcitationValue(p, useRealValue)
    local v = 0
    if p then v = tonumber(p:getModData().ZL_Excitation) or 0 end
    if useRealValue then return v end
    return clamp01(v / 100)
end

--------------------------------------------------------------
-- Bar definitions
--   thresholds: optional ratio lines drawn by MDB (same as moodlet lines)
--------------------------------------------------------------
local function arousalIcon(p)
    local g = (p and p.isFemale and p:isFemale()) and "Female" or "Male"
    return "media/ui/ZRArousal_" .. g .. "Desire.png" -- ships with ZomboRut
end

local DEFS = {
    {
        id = "bf_pregnancy", modId = "BF", x = 100,
        color = { red = 1.0, green = 0.75, blue = 0.60 },
        value = getPregnancy, active = pregnancyActive,
    },
    {
        id = "bf_lactation", modId = "BF", x = 125,
        color = { red = 0.85, green = 0.92, blue = 1.0 },
        value = getLactation, active = lactationActive,
    },
    {
        id = "zr_arousal", modId = "ZomboRut", x = 150,
        color = { red = 0.70, green = 0.40, blue = 1.0 },
        value = getArousal, active = arousalActive,
        -- ZomboRut tiers: Stirred 30, Aroused 50, Pent-up 65, Desperate 85
        thresholds = { 0.30, 0.50, 0.65, 0.85 },
        icon = arousalIcon,
    },
    {
        id = "zl_excitation", modId = "ZomboLust", x = 175,
        color = { red = 1.0, green = 0.40, blue = 0.70 },
        value = getExcitationValue, active = excitationActive,
        -- 60%: breathing + thoughts start, 80%: groan reaches a plain shout's radius
        thresholds = { 0.60, 0.80 },
    },
}

local function makeColorFunc(id)
    return function(p)
        local mdb = MinimalDisplayBarsB4220
        local cfg = mdb and mdb.configTables[p:getPlayerNum() + 1]
        local s = cfg and cfg[id]
        return s and s.color or nil
    end
end

-- Same shape as an entry in MDB's DEFAULT_SETTINGS. Shared interaction options
-- are copied from the Health bar so the new bars match the player's setup.
local function makeSettings(cfg, def, isoPlayer)
    local hp = cfg["hp"] or {}
    local icon = PLACEHOLDER_ICON
    if def.icon then icon = def.icon(isoPlayer) end
    return {
        x = def.x, y = 250, width = 20, height = 200,
        l = 2, t = 3, r = 2, b = 3,
        color = { red = def.color.red, green = def.color.green,
                  blue = def.color.blue, alpha = 0.75 },
        isMovable = pick(hp.isMovable, true),
        isResizable = pick(hp.isResizable, false),
        isVisible = true,
        isVertical = true,
        alwaysBringToTop = pick(hp.alwaysBringToTop, false),
        showMoodletThresholdLines = def.thresholds ~= nil and pick(hp.showMoodletThresholdLines, true) or false,
        isCompact = pick(hp.isCompact, false),
        imageShowBack = true,
        imageName = icon,
        imageSize = 22,
        showImage = pick(hp.showImage, false),
    }
end

--------------------------------------------------------------
-- Bar creation / maintenance
--------------------------------------------------------------
local function ensureBars(playerIndex, isoPlayer)
    local mdb = MinimalDisplayBarsB4220
    if not (mdb and ISGenericMiniDisplayBarB4220 and mdb.displayBars) then return end

    local bars = mdb.displayBars[playerIndex]
    if not bars or not bars["hp"] then return end -- MDB not built yet / rebuilding

    local coopNum = playerIndex + 1
    local cfg = mdb.configTables[coopNum]
    if not cfg then return end

    local dirty, created = false, false

    for _, def in ipairs(DEFS) do
        -- Only build a bar when its source mod is actually enabled.
        if isModActive(def.modId) then
            local inserted = false
            if not cfg[def.id] then
                cfg[def.id] = makeSettings(cfg, def, isoPlayer)
                inserted, dirty = true, true
            end

            local bar = bars[def.id]
            if not bar then
                bar = ISGenericMiniDisplayBarB4220:new(
                    def.id,
                    mdb.configFileLocations[coopNum],
                    playerIndex, isoPlayer, coopNum,
                    cfg,
                    getPlayerScreenLeft(playerIndex), getPlayerScreenTop(playerIndex),
                    nil,
                    def.value,
                    makeColorFunc(def.id), true,
                    def.thresholds)
                bar:initialise()
                bar:addToUIManager()
                bars[def.id] = bar
                created = true
            elseif inserted then
                -- MDB's "Reset All" replaced the config table and wiped our entry.
                bar:resetToConfigTable()
            end
        end
    end

    if created and mdb.createMoveBarsTogetherPanel then
        mdb.createMoveBarsTogetherPanel(playerIndex)
    end

    if dirty and mdb.io_persistence then
        mdb.io_persistence.store(mdb.configFileLocations[coopNum], mdb.MOD_ID, cfg)
    end
end

-- Show a bar only while its source reports data (and the player hasn't hidden
-- it via the MDB menu).
local function syncVisibility(playerIndex, isoPlayer)
    local mdb = MinimalDisplayBarsB4220
    local bars = mdb and mdb.displayBars and mdb.displayBars[playerIndex]
    local cfg = mdb and mdb.configTables[playerIndex + 1]
    if not bars or not cfg then return end

    for _, def in ipairs(DEFS) do
        local bar, s = bars[def.id], cfg[def.id]
        -- Don't fight MDB's pause-menu hiding/restoring.
        if bar and s and not bar.temporarilyHiddenForPauseMenu then
            local want = (s.isVisible == true) and def.active(isoPlayer)
            if bar:isVisible() ~= want then bar:setVisible(want) end
        end
    end
end

--------------------------------------------------------------
-- Menu-bar entry: MDB's own Show/Hide commands skip unknown bar IDs, so a bar
-- hidden with right-click > Hide could never be brought back. This adds one
-- toggle to the Menu bar's right-click menu.
--------------------------------------------------------------
local function toggleCompatBars(menuBar)
    local mdb = MinimalDisplayBarsB4220
    local cfg = mdb and mdb.configTables[menuBar.coopNum]
    local bars = mdb and mdb.displayBars[menuBar.playerIndex]
    if not cfg or not bars then return end

    local anyVisible = false
    for _, def in ipairs(DEFS) do
        if bars[def.id] and cfg[def.id] and cfg[def.id].isVisible then anyVisible = true end
    end
    for _, def in ipairs(DEFS) do
        if bars[def.id] and cfg[def.id] then cfg[def.id].isVisible = not anyVisible end
    end

    if mdb.io_persistence then
        mdb.io_persistence.store(menuBar.fileSaveLocation, mdb.MOD_ID, cfg)
    end
    if mdb.createMoveBarsTogetherPanel then
        mdb.createMoveBarsTogetherPanel(menuBar.playerIndex)
    end
    -- actual setVisible happens in syncVisibility on the next poll
end

--------------------------------------------------------------
-- Own preset: "Apply Legacy + Compat Layout" (data in BFMDBCompat_Presets.lua)
-- Mirrors MDB's applyLayoutPreset(): geometry keys only, then refresh bars,
-- fix the Move-Bars-Together anchor and save.
--------------------------------------------------------------
local LAYOUT_KEYS = { "x", "y", "width", "height", "isVertical", "l", "t", "r", "b" }

local function buildLegacyCompatPreset()
    local ok, presets = pcall(require, "BFMDBCompat_Presets")
    if not ok or type(presets) ~= "table" then presets = BFMDBCompat_Presets end
    local def = presets and presets.legacyCompat
    if not def then return nil end

    local preset = {}
    for id, settings in pairs(def.native) do preset[id] = settings end

    local c = def.compat
    local x = c.x
    for _, d in ipairs(DEFS) do
        if isModActive(d.modId) then -- one slot per active bar, no gaps
            preset[d.id] = {
                x = x, y = c.y, width = c.width, height = c.height,
                l = c.l, t = c.t, r = c.r, b = c.b, isVertical = c.isVertical,
            }
            x = x + c.step
        end
    end
    return preset
end

local function applyLegacyCompatPreset(menuBar)
    local mdb = MinimalDisplayBarsB4220
    if not (mdb and menuBar) then return end
    local cfg = mdb.configTables[menuBar.coopNum]
    local preset = buildLegacyCompatPreset()
    if not cfg or not preset then
        print("[BFMDBCompat] Legacy+Compat preset unavailable")
        return
    end

    for id, ps in pairs(preset) do
        local cur = cfg[id]
        if type(ps) == "table" and type(cur) == "table" then
            for _, k in ipairs(LAYOUT_KEYS) do
                if ps[k] ~= nil then cur[k] = mdb.deepcopy(ps[k]) end
            end
        end
    end

    local menu = mdb.displayBarMenus[menuBar.playerIndex]
    if menu then menu:resetToConfigTable() end
    local bars = mdb.displayBars[menuBar.playerIndex]
    if bars then
        for _, bar in pairs(bars) do
            if bar then bar:resetToConfigTable() end
        end
    end

    mdb.createMoveBarsTogetherPanel(menuBar.playerIndex)
    if mdb.refreshMoveBarsTogetherAnchor then
        mdb.refreshMoveBarsTogetherAnchor(menuBar.playerIndex)
    end
    mdb.io_persistence.store(menuBar.fileSaveLocation, mdb.MOD_ID, cfg)
end

-- Put the entry inside MDB's "Layout Presets" submenu; fall back to the top level.
local function addPresetOption(menu, bar)
    local label = getText("ContextMenu_BFMDB_Preset_LegacyCompat")
    local added = false
    pcall(function()
        local opt = menu:getOptionFromName(getText("ContextMenu_MinimalDisplayBars_Layout_Presets"))
        if opt and opt.subOption then
            local sub = menu:getSubMenu(opt.subOption)
            if sub then
                sub:addOption(label, bar, applyLegacyCompatPreset)
                added = true
            end
        end
    end)
    if not added then menu:addOption(label, bar, applyLegacyCompatPreset) end
end

local menuHooked = false
local function installMenuHook()
    if menuHooked then return end
    local mdb = MinimalDisplayBarsB4220
    if not (mdb and mdb.showContextMenu and ISContextMenu and ISContextMenu.get) then return end

    local original = mdb.showContextMenu
    mdb.showContextMenu = function(bar, dx, dy)
        -- MDB keeps its menu in a file-local, so capture it from ISContextMenu.get.
        local realGet = ISContextMenu.get
        local captured
        ISContextMenu.get = function(...)
            captured = realGet(...)
            return captured
        end
        local ok, err = pcall(original, bar, dx, dy)
        ISContextMenu.get = realGet
        if not ok then
            print("[BFMDBCompat] MDB context menu error: " .. tostring(err))
            return
        end
        if captured and bar and bar.idName == "menu" then
            addPresetOption(captured, bar)
            captured:addOption(getText("ContextMenu_BFMDB_Toggle"), bar, toggleCompatBars)
            if BFMDBCompat.toggleDebugWindow then
                captured:addOption(getText("ContextMenu_BFMDB_DebugWindow"), bar, function() BFMDBCompat.toggleDebugWindow() end)
            end
        end
    end
    menuHooked = true
end

--------------------------------------------------------------
-- Body shape for the dynamic shader (BodyShape/basicEffect.vert).
-- Lua cannot set shader uniforms, so this DECIDES who is eligible and what the
-- two progress values are, then hands them to the BodyShapeHook Java mod through
-- the global BFMDB_SetBodyShape(player, enabled, lactation, pregnancy).
--
--   eligible = the local, living, FEMALE player (slot 0).
--   Males, zombies and NPCs (never local players) are never eligible, so the Java
--   hook leaves them completely vanilla (no vertex is moved on their models).
--   An eligible player is "enabled" even with 0 / 0 progress: she always gets the
--   static hybrid body; progress only drives the chest and belly growth.
--------------------------------------------------------------
-- Sandbox settings (media/sandbox-options.txt). Missing table (old saves) -> defaults.
--   MinBreastSize            0..1  chest size when NOT lactating (0 = basic/vanilla-like, 1 = fully feminine)
--   MaxLactationBreastSize   1..3  chest size at full lactation (1 = more_feminime, >1 = bigger)
local function sandboxNumber(key, default, lo, hi)
    local sv = SandboxVars and SandboxVars.BFMDBCompat
    local v = sv and tonumber(sv[key])
    if v == nil then v = default end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

function BFMDBCompat.getSandbox()
    local minS = sandboxNumber("MinBreastSize", 0.0, 0.0, 1.0)
    local maxS = sandboxNumber("MaxLactationBreastSize", 1.0, 0.0, 3.0)
    if maxS < minS then maxS = minS end
    return minS, maxS
end

-- lactation ratio 0..1  ->  chest size factor the shader uses (0 basic .. 1 more_feminime .. 3)
function BFMDBCompat.chestFactor(ratio)
    local minS, maxS = BFMDBCompat.getSandbox()
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    return minS + ratio * (maxS - minS)
end

function BFMDBCompat.getBodyShape(p)
    local eligible = (p ~= nil and p.isLocalPlayer ~= nil and p:isLocalPlayer()
            and p:getPlayerNum() == 0 and p:isFemale() and not p:isDead())
    if not eligible then return 0, 0, false end

    local dbg = BFMDBCompat.debug
    if dbg.shapeOff then return 0, 0, false end            -- debug: vanilla model
    if dbg.override then return BFMDBCompat.chestFactor(dbg.lact), dbg.preg, true end -- debug: manual values

    local lact, preg = 0, 0
    if isModActive("BF") then
        if lactationActive(p) then lact = getLactation(p, false) end
        if pregnancyActive(p) then preg = getPregnancy(p, false) end
    end
    return BFMDBCompat.chestFactor(lact), preg, true
end

-- Everything the debug window shows, in one table.
function BFMDBCompat.getDebugInfo(p)
    local now = nowHours()
    local function age(t) if t == nil then return nil end return now - t end
    local lact, preg, eligible = BFMDBCompat.getBodyShape(p)
    local maxMilk = MILK_CAPACITY
    if p then
        local seen = p:getModData().BFMDB_milkSeen or 0
        if seen > maxMilk then maxMilk = seen end
    end
    return {
        bfActive = isModActive("BF"),
        pregProgress = state.preg.progress, pregAge = age(state.preg.lastSeen),
        pregActive = pregnancyActive(p),
        milkAmount = state.lact.amount, milkMax = maxMilk, milkAge = age(state.lact.lastSeen),
        milkFlag = state.lact.active, lactActive = lactationActive(p),
        pubLact = lact, pubPreg = preg, eligible = eligible,
        sbMin = select(1, BFMDBCompat.getSandbox()), sbMax = select(2, BFMDBCompat.getSandbox()),
        javaStatus = BFMDB_BodyShapeStatus and BFMDB_BodyShapeStatus() or nil,
    }
end

local lastEligible = nil
local function publishBodyShape(p)
    local lact, preg, eligible = BFMDBCompat.getBodyShape(p)

    -- mirror into modData (only when changed) for any other script to read
    local md = p:getModData()
    if md.BFMDB_BodyLactation ~= lact then md.BFMDB_BodyLactation = lact end
    if md.BFMDB_BodyPregnancy ~= preg then md.BFMDB_BodyPregnancy = preg end

    -- Java hook (present only when the BodyShapeHook mod + ZombieBuddy are active)
    if BFMDB_SetBodyShape then
        BFMDB_SetBodyShape(p, eligible, lact, preg)
        if lastEligible ~= eligible then
            lastEligible = eligible
            print("[BFMDBCompat] body shape " .. (eligible and "ENABLED" or "disabled") .. " for the local player")
        end
    end
end

--------------------------------------------------------------
-- Layout presets ("Layout Presets" in the Menu bar's right-click menu).
-- MDB's applyLayoutPreset() loads the preset through
-- MinimalDisplayBarsB4220.io_persistence.load(), then applies the geometry
-- fields of every bar id it finds in the player's config and refreshes all
-- bars. So we wrap load(): when one of the two preset files is read, append
-- entries for our bars, placed right after the preset's last bar and copying
-- that bar's size and spacing. MDB's own code does the rest (and saves).
--------------------------------------------------------------
local PRESET_KEYS = { "y", "width", "height", "l", "t", "r", "b", "isVertical" }

local function appendCompatBarsToPreset(preset)
    -- Find the preset's right-most regular bar (the menu bar is not part of the row)
    local row = {}
    for id, s in pairs(preset) do
        if id ~= "menu" and type(s) == "table" and type(s.x) == "number" then
            row[#row + 1] = s
        end
    end
    if #row == 0 then return end
    table.sort(row, function(a, b) return a.x < b.x end)

    local last = row[#row]
    local step = last.x
    if #row >= 2 then step = last.x - row[#row - 1].x end
    if step <= 0 then step = (last.width or 20) + 5 end

    local nextX = last.x + step
    for _, def in ipairs(DEFS) do
        -- Only reserve a slot for bars that exist, so there are no gaps.
        if isModActive(def.modId) and preset[def.id] == nil then
            local entry = { x = nextX }
            for _, k in ipairs(PRESET_KEYS) do
                if last[k] ~= nil then entry[k] = last[k] end
            end
            preset[def.id] = entry
            nextX = nextX + step
        end
    end
end

local presetHooked = false
local function installPresetHook()
    if presetHooked then return end
    local mdb = MinimalDisplayBarsB4220
    local persistence = mdb and mdb.io_persistence
    if not (persistence and persistence.load) then return end

    local originalLoad = persistence.load
    persistence.load = function(path, ...)
        local result, extra1, extra2 = originalLoad(path, ...)
        if type(result) == "table" and path ~= nil
                and (path == mdb.legacyLayoutPresetFileName
                  or path == mdb.currentLayoutPresetFileName) then
            local ok, err = pcall(appendCompatBarsToPreset, result)
            if not ok then
                print("[BFMDBCompat] could not extend layout preset: " .. tostring(err))
            end
        end
        return result, extra1, extra2
    end
    presetHooked = true
end

--------------------------------------------------------------
-- Poll loop (cheap: every 10 ticks)
--------------------------------------------------------------
local tick = 0
local function onTick()
    tick = tick + 1
    if tick % 10 ~= 0 then return end

    tryHookEvents()
    installMenuHook()
    installPresetHook()

    for i = 0, 3 do
        local p = getSpecificPlayer(i)
        if p and p:isLocalPlayer() then
            ensureBars(i, p)
            syncVisibility(i, p)
            if i == 0 then publishBodyShape(p) end
        end
    end
end

-- One-time diagnostics (console.txt). IMPORTANT: Kahlua prints a full stack trace for every
-- call to a nil function, even inside pcall, so ZombieBuddy's optional status API is only
-- called when it actually exists in the installed ZombieBuddy version.
local function logHookStatus()
    local zb = ZombieBuddy
    if not zb then
        print("[BFMDBCompat] 'ZombieBuddy' Lua global not found: ZombieBuddy is not running.")
    else
        if type(zb.getPolicy) == "function" then
            print("[BFMDBCompat] ZombieBuddy policy=" .. tostring(zb.getPolicy()))
        end
        if type(zb.getJavaModStatus) == "function" then
            local mods = getActivatedMods()
            for i = 0, mods:size() - 1 do
                local id = mods:get(i)
                local st = zb.getJavaModStatus(id)
                if st then
                    print("[BFMDBCompat] Java jar of mod '" .. tostring(id) .. "': loaded=" .. tostring(st.loaded)
                        .. " reason=" .. tostring(st.reason) .. " decision=" .. tostring(st.decision))
                end
            end
        else
            print("[BFMDBCompat] (this ZombieBuddy version has no Java mod status API; that is fine)")
        end
    end

    if BFMDB_SetBodyShape then
        print("[BFMDBCompat] body shape hook ACTIVE: " .. tostring(BFMDB_BodyShapeStatus and BFMDB_BodyShapeStatus() or "?"))
    else
        print("[BFMDBCompat] body shape hook NOT active (BFMDB_SetBodyShape undefined): the Java jar is missing, empty, or not loaded. Shader stays vanilla for everyone.")
    end
end

Events.OnGameStart.Add(tryHookEvents)
Events.OnGameStart.Add(logHookStatus)
Events.OnTick.Add(onTick)
