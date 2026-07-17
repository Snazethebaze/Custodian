-- Core/Media.lua : LibSharedMedia access with safe fallbacks.
-- LSM is embedded, so fonts/textures work with ZERO required addons.
-- If the SharedMedia addon is present it simply adds more choices.

local ADDON, ns = ...
local LSM = LibStub("LibSharedMedia-3.0", true)

local Media = {}
ns.Media = Media

local FALLBACK_BAR  = "Interface\\TargetingFrame\\UI-StatusBar"
local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

-- ── Baseline media registered into SharedMedia ────────────────────────
-- A few of WoW's OWN status-bar textures (their Interface\ paths exist on every client, so no
-- files needed) — always available even without the bundled pack. The big bundled library of
-- textures + fonts lives in Core/MediaPack.lua. Distinct names so nothing already registered is
-- clobbered (LSM:Register is first-wins anyway).
local BUILTIN_BARS = {
    { name = "Solid",         path = "Interface\\Buttons\\WHITE8X8" },                        -- pure solid fill
    { name = "Blizzard Raid", path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },             -- subtle gradient
    { name = "Skillbar",      path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}
if LSM then
    for _, b in ipairs(BUILTIN_BARS) do LSM:Register("statusbar", b.name, b.path) end
end

function Media.Bar(name)
    if LSM then return LSM:Fetch("statusbar", name or "Blizzard") or FALLBACK_BAR end
    return FALLBACK_BAR
end

function Media.Font(name)
    if LSM then return LSM:Fetch("font", name or "Friz Quadrata TT") or FALLBACK_FONT end
    return FALLBACK_FONT
end

function Media.BarList()
    if LSM then return LSM:HashTable("statusbar") end
    return { Blizzard = "Blizzard" }
end

function Media.FontList()
    if LSM then return LSM:HashTable("font") end
    return { ["Friz Quadrata TT"] = "Friz Quadrata TT" }
end

function Media.SoundList()
    if LSM then return LSM:HashTable("sound") end
    return {}
end
