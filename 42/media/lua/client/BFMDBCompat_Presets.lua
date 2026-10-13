--============================================================
-- BFMDBCompat layout presets
--
-- "Legacy + Compat": the exact geometry of MDB's Legacy_PreUpdate_Layout.cfg
-- for every native bar, plus a second row below it for the compat bars.
--
-- Why a Lua file and not a .cfg: MDB reads .cfg presets from inside its own mod
-- folder, and where a mod-relative path resolves in a B42 "42/" layout can't be
-- guaranteed. A Lua file in this mod always loads.
--
-- Edit freely. Only these keys are ever applied: x, y, width, height,
-- isVertical, l, t, r, b (same as MDB's presets). Colours, visibility and
-- icons are never touched.
--============================================================

local Presets = {}

Presets.legacyCompat = {

    -- Native MDB bars: copied verbatim from Legacy_PreUpdate_Layout.cfg
    native = {
        ["menu"] = { ["x"] = 70, ["y"] = 15, ["width"] = 15, ["height"] = 15, ["l"] = 3, ["t"] = 3, ["r"] = 3, ["b"] = 3, ["isVertical"] = true },
        ["hp"] = { ["x"] = 70, ["y"] = 30, ["width"] = 15, ["height"] = 150, ["l"] = 3, ["t"] = 3, ["r"] = 3, ["b"] = 3, ["isVertical"] = true },
        ["hunger"] = { ["x"] = 85, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["thirst"] = { ["x"] = 93, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["endurance"] = { ["x"] = 101, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["fatigue"] = { ["x"] = 109, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["boredomlevel"] = { ["x"] = 117, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["unhappynesslevel"] = { ["x"] = 125, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["temperature"] = { ["x"] = 133, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["calorie"] = { ["x"] = 141, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["stress"] = { ["x"] = 149, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["sickness"] = { ["x"] = 157, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["carbohydrates"] = { ["x"] = 165, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["proteins"] = { ["x"] = 173, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["fats"] = { ["x"] = 181, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["corpse_sickness"] = { ["x"] = 189, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
        ["discomfort"] = { ["x"] = 197, ["y"] = 30, ["width"] = 8, ["height"] = 150, ["l"] = 2, ["t"] = 3, ["r"] = 2, ["b"] = 3, ["isVertical"] = true },
    },

    -- Compat bars (Pregnancy, Lactation, Arousal, Excitation) are laid out left
    -- to right from (x, y), one slot per bar whose source mod is active (no gaps).
    -- Default: directly under the native row (legacy bars end at y = 180).
    compat = {
        x = 70, y = 190, step = 8,
        width = 8, height = 150,
        l = 2, t = 3, r = 2, b = 3,
        isVertical = true,
    },
}

BFMDBCompat_Presets = Presets
return Presets
