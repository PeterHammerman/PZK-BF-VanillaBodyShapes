--============================================================
-- BFMDBCompat debug window (TEMPORARY - delete this file when you are done tuning).
--
-- Open:  right-click the MDB menu bar > "Body Shape Debug Window"
--        or in the Lua console:  BFMDBCompat.toggleDebugWindow()
--
-- Shows every value that decides what you see (Being Female -> published -> Java renderer)
-- and lets you override lactation / pregnancy by hand or switch the body shape off to
-- compare with the vanilla model.
--============================================================

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"

BFMDBDebugWindow = ISCollapsableWindow:derive("BFMDBDebugWindow")

local FONT = UIFont.Small
local LINE_H = 16

local function f3(v) if v == nil then return "-" end return string.format("%.3f", v) end
local function yn(v) return v and "yes" or "no" end

local function mkBtn(win, x, y, w, title, fn)
    local b = ISButton:new(x, y, w, 22, title, win, fn)
    b:initialise()
    b:instantiate()
    b.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    win:addChild(b)
    return b
end

function BFMDBDebugWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "Body Shape Debug (temporary)"
    o.resizable = false
    return o
end

function BFMDBDebugWindow:setLevel(which, v)
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    BFMDBCompat.debug[which] = v
    BFMDBCompat.debug.override = true            -- touching a value turns the override on
end

function BFMDBDebugWindow:stepLevel(which, d)
    self:setLevel(which, (BFMDBCompat.debug[which] or 0) + d)
end

function BFMDBDebugWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local th = (self.titleBarHeight and self:titleBarHeight()) or 16
    self.infoTop = th + 8
    self.infoLines = 10
    local y = self.infoTop + self.infoLines * LINE_H + 8
    self.rowY = {}

    -- row 1: switches
    self.btnOverride = mkBtn(self, 10, y, 190, "Override: OFF", function(win)
        BFMDBCompat.debug.override = not BFMDBCompat.debug.override
    end)
    self.btnShape = mkBtn(self, 210, y, 220, "Body shape: ON", function(win)
        BFMDBCompat.debug.shapeOff = not BFMDBCompat.debug.shapeOff
    end)

    -- row 4 (added below, after rows 2/3): avatar patch switch
    -- rows 2/3: lactation, pregnancy
    local rows = { { "lact", "Lactation" }, { "preg", "Pregnancy" } }
    for i, r in ipairs(rows) do
        local ry = y + i * 30
        self.rowY[r[1]] = ry
        local bx = 108
        local key = r[1]
        for _, pct in ipairs({ 0, 25, 50, 75, 100 }) do
            mkBtn(self, bx, ry, 38, tostring(pct), function(win) win:setLevel(key, pct / 100) end)
            bx = bx + 41
        end
        mkBtn(self, bx + 4, ry, 36, "-5", function(win) win:stepLevel(key, -0.05) end)
        mkBtn(self, bx + 44, ry, 36, "+5", function(win) win:stepLevel(key, 0.05) end)
    end

    -- row 4: optional UI-avatar path (health panel preview). Per session, never saved.
    self.avatarY = y + 3 * 30
    self.btnAvatar = mkBtn(self, 10, self.avatarY, 300, "Health-panel avatar shaping: OFF", function(win)
        if not BFMDB_SetAvatarPatch then
            print("[BFMDBCompat] BFMDB_SetAvatarPatch not available: build the jar with enableAvatarPatch=true")
            win.avatarMissing = true
            return
        end
        BFMDBCompat.debug.avatar = not BFMDBCompat.debug.avatar
        BFMDB_SetAvatarPatch(BFMDBCompat.debug.avatar)
    end)
end

function BFMDBDebugWindow:prerender()
    ISCollapsableWindow.prerender(self)
    local dbg = BFMDBCompat.debug
    if self.btnOverride then self.btnOverride:setTitle("Override: " .. (dbg.override and "ON" or "OFF")) end
    if self.btnAvatar then self.btnAvatar:setTitle("Health-panel avatar shaping: " .. (dbg.avatar and "ON" or "OFF")) end
    if self.btnShape then self.btnShape:setTitle("Body shape: " .. (dbg.shapeOff and "OFF (vanilla)" or "ON")) end
end

function BFMDBDebugWindow:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed then return end

    local p = getSpecificPlayer(0)
    local lines = {}
    local function add(text, r, g, b) lines[#lines + 1] = { text, r or 1, g or 1, b or 1 } end

    if not p then
        add("no local player", 1, 0.5, 0.5)
    else
        local d = BFMDBCompat.getDebugInfo(p)
        local dbg = BFMDBCompat.debug
        add("eligible (local living female): " .. yn(d.eligible) .. "     BF mod active: " .. yn(d.bfActive),
            d.eligible and 0.6 or 1, d.eligible and 1 or 0.5, d.eligible and 0.6 or 0.5)
        add("BF pregnancy: progress " .. f3(d.pregProgress) .. "  age " .. f3(d.pregAge) .. "h  counts as active: " .. yn(d.pregActive))
        add("BF lactation: amount " .. f3(d.milkAmount) .. "  scale max " .. f3(d.milkMax) .. "  flag " .. yn(d.milkFlag)
            .. "  age " .. f3(d.milkAge) .. "h  active: " .. yn(d.lactActive))
        add("PUBLISHED to Java ->  chest factor " .. f3(d.pubLact) .. "   pregnancy " .. f3(d.pubPreg)
            .. (dbg.override and "   (OVERRIDE)" or ""), 0.7, 0.9, 1)
        if d.javaStatus then
            -- the status string is "a | b | c | d": one segment per line
            for seg in string.gmatch(d.javaStatus, "[^|]+") do
                add("JAVA " .. seg:gsub("^%s+", ""):gsub("%s+$", ""), 0.8, 1, 0.8)
            end
        else
            add("JAVA hook not loaded (BFMDB_BodyShapeStatus undefined)", 1, 0.5, 0.5)
        end
        add("manual: lactation ratio " .. f3(dbg.lact) .. "  pregnancy " .. f3(dbg.preg), 0.8, 0.8, 0.8)
        add("sandbox: min breast " .. f3(d.sbMin) .. "  max lactation " .. f3(d.sbMax)
            .. "   chest factor = min + L x (max - min)", 0.7, 0.7, 0.7)
    end

    for i, l in ipairs(lines) do
        if i > self.infoLines then break end
        self:drawText(l[1], 10, self.infoTop + (i - 1) * LINE_H, l[2], l[3], l[4], 1, FONT)
    end

    if self.avatarY then
        local msg = "needs jar built with enableAvatarPatch=true; if the game crashes, turn it off and send hs_err_pid log"
        if self.avatarMissing then msg = "NOT AVAILABLE: this jar was built without enableAvatarPatch=true" end
        self:drawText(msg, 10, self.avatarY + 26, 0.75, 0.75, 0.75, 1, FONT)
    end

    if self.rowY then
        self:drawText("Lactation", 12, self.rowY.lact + 3, 1, 1, 1, 1, FONT)
        self:drawText("Pregnancy", 12, self.rowY.preg + 3, 1, 1, 1, 1, FONT)
    end
end

function BFMDBDebugWindow:close()
    BFMDBCompat._dbgWin = nil
    ISCollapsableWindow.close(self)
end

function BFMDBCompat.toggleDebugWindow()
    if BFMDBCompat._dbgWin then
        BFMDBCompat._dbgWin:close()
        return
    end
    local win = BFMDBDebugWindow:new(220, 140, 470, 360)
    win:initialise()
    win:addToUIManager()
    win:setVisible(true)
    BFMDBCompat._dbgWin = win
end
