-- Core/Glow.lua : glow the real action-bar button for a spell.
--
-- When a spender becomes affordable, we light up the actual button on the
-- player's action bars (the familiar Blizzard proc-glow) rather than only
-- nudging our marker line. Covers the default bars plus any LibActionButton
-- bar (ElvUI, Bartender4, Dominos, …). All calls are pcall-guarded and
-- feature-detected so a missing lib or a locked-down button never errors.

local ADDON, ns = ...

local LCG = LibStub("LibCustomGlow-1.0", true)

local Glow = {}
ns.Glow = Glow

-- Default Blizzard action bars (12 buttons each). Pet/stance bars are skipped —
-- spenders live on the standard bars.
local DEFAULT_BARS = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}

local function forEachButton(fn)
    for _, prefix in ipairs(DEFAULT_BARS) do
        for i = 1, 12 do
            local b = _G[prefix .. i]
            if b then fn(b) end
        end
    end
    -- LibActionButton bars (Bartender4, Dominos, ElvUI if it exposes LAB, …).
    -- GetAllButtons may return a set {button=true} or an array — handle both,
    -- and never let a bad return error the scan.
    local lab = LibStub and LibStub("LibActionButton-1.0", true)
    if lab and lab.GetAllButtons then
        local ok, all = pcall(lab.GetAllButtons, lab)
        if ok and type(all) == "table" then
            for k, v in pairs(all) do
                local btn = (type(k) == "table" and k) or (type(v) == "table" and v) or nil
                if btn then fn(btn) end
            end
        end
    end
end

-- The action slot a button currently shows. Default buttons expose `.action`;
-- LibActionButton buttons expose it via `_state_action` / the action attribute.
local function buttonAction(b)
    if type(b.action) == "number" then return b.action end
    if type(b._state_action) == "number" then return b._state_action end
    if b.GetAttribute then
        local a = b:GetAttribute("action")
        if type(a) == "number" then return a end
    end
    return nil
end

-- The spell a macro action currently represents (its #showtooltip / first
-- /cast). Global GetMacroSpell OR C_Macro.GetMacroSpell depending on client;
-- returns the spellID directly on modern clients, last on older ones.
local _GetMacroSpell = GetMacroSpell or (C_Macro and C_Macro.GetMacroSpell)
local function macroSpellID(macroIndex)
    if not _GetMacroSpell then return nil end
    local r1, _, r3 = _GetMacroSpell(macroIndex)
    if type(r1) == "number" then return r1 end
    if type(r3) == "number" then return r3 end
    return nil
end

-- Shared spell-name helper (defined in Core/Spells.lua, loaded first).
local spellName = ns.SpellName

-- Resolve a real (paged) Blizzard action slot to the spellID it shows.
local function slotSpell(slot)
    local atype, id = GetActionInfo(slot)   -- id is the player's own bar config, not secret
    if atype == "spell" then return id end
    if atype == "macro" then
        -- On 12.0, GetActionInfo already resolves a #showtooltip macro to its
        -- spellID here (id IS the spell). Only fall back to GetMacroSpell (id as
        -- a macro index) on clients / macros where id isn't itself a spell.
        if id and spellName(id) then return id end
        return macroSpellID(id)
    end
    return nil
end

-- The spellID a button currently represents. Blizzard buttons hold a paged
-- action slot; LibActionButton buttons carry a typed state, and a "spell"-type
-- one stores the spellID DIRECTLY in _state_action — reading that as an action
-- slot would resolve the wrong thing, so it's handled explicitly.
local function buttonSpellID(b)
    if b._state_type == "spell" and type(b._state_action) == "number" then
        return b._state_action
    end
    local slot = buttonAction(b)
    if slot then return slotSpell(slot) end
    return nil
end

-- Buttons currently displaying spellID — direct spell buttons AND macro buttons.
-- Matches by exact id, then by spell NAME (so the choice-node Earthquake variants,
-- which share a name but differ by id, still resolve whether dragged or macro'd).
local function buttonsForSpell(spellID)
    if not GetActionInfo then return nil end
    local wantName = spellName(spellID)
    local out
    forEachButton(function(b)
        local bid = buttonSpellID(b)
        if bid and not ns.IsSecret(bid) then
            if bid == spellID or (wantName and spellName(bid) == wantName) then
                out = out or {}; out[#out + 1] = b
            end
        end
    end)
    return out
end

local glowing = {}   -- spellID -> { button, … }

function Glow.Start(spellID)
    if not LCG or not spellID or glowing[spellID] then return end
    local btns = buttonsForSpell(spellID)
    if not btns then return end
    for _, b in ipairs(btns) do pcall(LCG.ButtonGlow_Start, b) end
    glowing[spellID] = btns
end

function Glow.Stop(spellID)
    if not spellID then return end
    local btns = glowing[spellID]
    if not btns then return end
    if LCG then for _, b in ipairs(btns) do pcall(LCG.ButtonGlow_Stop, b) end end
    glowing[spellID] = nil
end

-- Diagnostics for `/cust glow`: what the button scan resolves for each spender,
-- and a dump of every macro button + the spell it currently maps to.
function Glow.Debug()
    ns.Print(("|cffffd100glow dbg|r LCG=%s macroAPI=%s getActionInfo=%s"):format(
        tostring(LCG ~= nil), tostring(_GetMacroSpell ~= nil), tostring(GetActionInfo ~= nil)))

    local pw = ns.profile and ns.profile.widgets and ns.profile.widgets.ele_maelstrom
    if pw and pw.markers then
        for _, m in ipairs(pw.markers) do
            if m.mode == "spell" then
                local btns = buttonsForSpell(m.spellID)
                ns.Print(("  spell %s (%s): known=%s alert=%s buttons=%s"):format(
                    tostring(m.spellID), tostring(spellName(m.spellID)),
                    tostring(ns.SpellKnown(m.spellID)), tostring(m.alert and true or false),
                    tostring(btns and #btns or 0)))
            end
        end
    end

    local any = false
    forEachButton(function(b)
        local slot = buttonAction(b)
        if not slot then return end
        local atype, id = GetActionInfo(slot)
        if atype == "macro" then
            any = true
            local eff = (id and spellName(id)) and id or macroSpellID(id)
            ns.Print(("  [macro] %s slot=%s raw=%s -> spell %s (%s)"):format(
                tostring(b:GetName() or "?"), tostring(slot), tostring(id),
                tostring(eff), tostring(spellName(eff))))
        end
    end)
    if not any then ns.Print("  (no macro buttons found on the scanned bars)") end
end
