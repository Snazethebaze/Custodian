-- Trackers/Form.lua : a SHAPESHIFT form / stance you should be in — Druid Moonkin / Cat / Bear,
-- Priest Shadowform, Warrior Defensive Stance. Drives a "not in the right form" reminder via the
-- standard icon path; click-to-cast shifts you into it.
--
-- Config: { type = "form", spellID = <the form's spell>, name = <form name, for matching> }
--
-- Read off the shapeshift bar (GetShapeshiftFormInfo) — these are core UI state, never secret,
-- so it works in and out of combat with no oracle. Matches the configured form by spellID OR
-- name (an override can change the id, but the name is stable):
--   in the form             -> present = true  (have it)
--   form known, not active  -> present = false (remind + click to shift in)
--   form not on the bar      -> present = nil   (this spec/build doesn't have it -> silent)

local ADDON, ns = ...
local spellIcon = ns.SpellIcon
local snap = ns.PresenceSnap

ns.RegisterTracker("form", {
    events = { "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS", "PLAYER_ENTERING_WORLD",
               "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" },
    read = function(cfg)
        local icon = cfg.icon or spellIcon(cfg.spellID)
        if ns.PlayerDead() then return snap(nil, icon) end
        if not GetShapeshiftFormInfo then return snap(nil, icon) end

        local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
        for i = 1, n do
            local formIcon, active, _, sid = GetShapeshiftFormInfo(i)
            local match = (cfg.spellID and sid == cfg.spellID) or false
            if not match and cfg.name and sid and C_Spell and C_Spell.GetSpellName then
                match = (C_Spell.GetSpellName(sid) == cfg.name)
            end
            if match then
                return snap(active and true or false, icon or formIcon)
            end
        end
        -- Not on the shapeshift bar — this spec/build doesn't have the form, so don't nag.
        return snap(nil, icon)
    end,
})
