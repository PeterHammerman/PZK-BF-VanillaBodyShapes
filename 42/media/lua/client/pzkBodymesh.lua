

pzkBodyMeshBF = pzkBodyMeshBF or {}
-- Debug window state (see pzkBodyMeshBF_Debug.lua). override=true replaces the real
-- lactation/pregnancy values for the local female player; shapeOff=true disables the
-- body shape entirely (vanilla model) so you can compare.
pzkBodyMeshBF.debug = pzkBodyMeshBF.debug or { override = false, lact = 0.0, preg = 0.0, shapeOff = false, avatar = false }

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
    local sv = SandboxVars and SandboxVars.pzkBodyMeshBF
    local v = sv and tonumber(sv[key])
    if v == nil then v = default end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

function pzkBodyMeshBF.getSandbox()
    local minS = sandboxNumber("MinBreastSize", 0.0, 0.0, 1.0)
    local maxS = sandboxNumber("MaxLactationBreastSize", 1.0, 0.0, 3.0)
    if maxS < minS then maxS = minS end
    return minS, maxS
end

-- lactation ratio 0..1  ->  chest size factor the shader uses (0 basic .. 1 more_feminime .. 3)
function pzkBodyMeshBF.chestFactor(ratio)
    local minS, maxS = pzkBodyMeshBF.getSandbox()
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    return minS + ratio * (maxS - minS)
end

function pzkBodyMeshBF.getBodyShape(p)
    local eligible = (p ~= nil and p.isLocalPlayer ~= nil and p:isLocalPlayer()
            and p:getPlayerNum() == 0 and p:isFemale() and not p:isDead())
    if not eligible then return 0, 0, false end

    local dbg = pzkBodyMeshBF.debug
    if dbg.shapeOff then return 0, 0, false end            -- debug: vanilla model
    if dbg.override then return pzkBodyMeshBF.chestFactor(dbg.lact), dbg.preg, true end -- debug: manual values

    local lact, preg = 0, 0
    if isModActive("BF") then
        if lactationActive(p) then lact = getLactation(p, false) end
        if pregnancyActive(p) then preg = getPregnancy(p, false) end
    end
    return pzkBodyMeshBF.chestFactor(lact), preg, true
end

-- Everything the debug window shows, in one table.
function pzkBodyMeshBF.getDebugInfo(p)
    local now = nowHours()
    local function age(t) if t == nil then return nil end return now - t end
    local lact, preg, eligible = pzkBodyMeshBF.getBodyShape(p)
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
        sbMin = select(1, pzkBodyMeshBF.getSandbox()), sbMax = select(2, pzkBodyMeshBF.getSandbox()),
        javaStatus = BFMDB_BodyShapeStatus and BFMDB_BodyShapeStatus() or nil,
    }
end

local lastEligible = nil
local function publishBodyShape(p)
    local lact, preg, eligible = pzkBodyMeshBF.getBodyShape(p)

    -- mirror into modData (only when changed) for any other script to read
    local md = p:getModData()
    if md.BFMDB_BodyLactation ~= lact then md.BFMDB_BodyLactation = lact end
    if md.BFMDB_BodyPregnancy ~= preg then md.BFMDB_BodyPregnancy = preg end

    -- Java hook (present only when the BodyShapeHook mod + ZombieBuddy are active)
    if BFMDB_SetBodyShape then
        BFMDB_SetBodyShape(p, eligible, lact, preg)
        if lastEligible ~= eligible then
            lastEligible = eligible
            print("[pzkBodyMeshBF] body shape " .. (eligible and "ENABLED" or "disabled") .. " for the local player")
        end
    end
end


--------------------------------------------------------------
-- Poll loop (cheap: every 10 ticks)
--------------------------------------------------------------
local tick = 0
local function onTick()
    tick = tick + 1
    if tick % 10 ~= 0 then return end

    tryHookEvents()


    for i = 0, 3 do
        local p = getSpecificPlayer(i)
        if p and p:isLocalPlayer() then

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
        print("[pzkBodyMeshBF] 'ZombieBuddy' Lua global not found: ZombieBuddy is not running.")
    else
        if type(zb.getPolicy) == "function" then
            print("[pzkBodyMeshBF] ZombieBuddy policy=" .. tostring(zb.getPolicy()))
        end
        if type(zb.getJavaModStatus) == "function" then
            local mods = getActivatedMods()
            for i = 0, mods:size() - 1 do
                local id = mods:get(i)
                local st = zb.getJavaModStatus(id)
                if st then
                    print("[pzkBodyMeshBF] Java jar of mod '" .. tostring(id) .. "': loaded=" .. tostring(st.loaded)
                        .. " reason=" .. tostring(st.reason) .. " decision=" .. tostring(st.decision))
                end
            end
        else
            print("[pzkBodyMeshBF] (this ZombieBuddy version has no Java mod status API; that is fine)")
        end
    end

    if BFMDB_SetBodyShape then
        print("[pzkBodyMeshBF] body shape hook ACTIVE: " .. tostring(BFMDB_BodyShapeStatus and BFMDB_BodyShapeStatus() or "?"))
    else
        print("[pzkBodyMeshBF] body shape hook NOT active (BFMDB_SetBodyShape undefined): the Java jar is missing, empty, or not loaded. Shader stays vanilla for everyone.")
    end
end

Events.OnGameStart.Add(tryHookEvents)
Events.OnGameStart.Add(logHookStatus)
Events.OnTick.Add(onTick)
