-- Options/Wizard.lua : the guided "add widget" flow — hub, Browse, the custom pick/setup
-- steps, and the seeds→picks pipeline that feeds them.
--
-- Split out of Options/Panel.lua. Its three entry points (buildWizard / openWizard /
-- closeWizard) live on the shared ns.OPT table; everything else is private to this file.
-- Panel.lua helpers it needs (RefreshList / RefreshEditor / applyStructural / spellRow / …)
-- also come in via OPT, resolved at call time.
--
-- `P` (the panel frame) is bound once by Panel.lua's build() through OPT.OnBind, so the rest
-- of this file reads it exactly as it did when it lived in Panel.lua.

local ADDON, ns = ...

local OPT = ns.OPT
local T  = ns.Theme
local UI = ns.UI
local border, bgTex = UI.border, UI.bgTex
local Label, Button, Check, Slider, EditBox, Dropdown = UI.Label, UI.Button, UI.Check, UI.Slider, UI.EditBox, UI.Dropdown
local tip, spellTip = UI.tip, UI.spellTip

local P
OPT.OnBind(function(panel) P = panel end)

-- The wizard's own internals are mutually recursive (RefreshWizard <-> the step fns), so forward-
-- declare them as file-scoped locals — never globals.
local RefreshWizard, wizardNext, wizardFinish, showWizResults

-- ══ Guided "add widget" wizard ════════════════════════════════════════
-- The ONE way to add a widget (the "+ Widget (guided)" button). NAME-FIRST and
-- class-tailored: the hub leads with things you recognize — your own common spells,
-- your resources, and any class specials — each a single click that lands you in the
-- editor. "Build something custom" opens the full kind → spell → setup path for anything
-- not on a tile. All per-class data lives in ns.Maintenance (Core/Maintenance.lua).
--
-- Steps: "hub" (fast start) · "type" → "pick" → "setup" (the custom path). A hub tile
-- already knows its kind, so it skips straight to create; a hub search or a custom build
-- goes through "setup".

-- Custom-path kinds (only reached via "Build custom"; a hub tile knows its own kind).
local WIZ_TYPES = {
    { k = "aura",  l = "Aura",         d = "A buff, shield, or proc on you — " .. OPT.classEx("aura") .. "." },
    { k = "power", l = "Resource",     d = "A resource bar — " .. OPT.classEx("res") .. "." },
    { k = "imbue", l = "Weapon imbue", d = OPT.classEx("imbue") .. " — a temporary weapon enchant." },
}
local WIZ_PICK = { aura = "Pick the aura", power = "Pick the resource", imbue = "Pick the imbue" }
local WIZ_CAVEAT = {
    aura  = "Buffs and class auras (" .. OPT.classEx("aura") .. "…) track fine in combat. A few defensive/utility auras (e.g. " .. OPT.classEx("def") .. ") are hidden from addons in combat — for those, set 'Aura lasts (sec)' in its options so it's timed from your cast instead. Out of combat, all of it is reliable.",
    power = "A resource bar. Once it exists, its own options add colour-by-fill and value / percent text.",
    imbue = "A temporary weapon enchant (" .. OPT.classEx("imbue") .. ") — reads live in combat and the timer ticks. Attach the spell below so a mid-fight recast clears a 'missing' reminder. Slot = which weapon to watch.",
}

-- The default spec scope for a new widget: just the current spec (nil = all specs).
-- The specs a newly-added widget lands on, from the hub's spec-filter dropdown: a specific spec
-- (view/add for e.g. Resto while in Enhancement), or "all" (nil = every spec). Defaults to the
-- current spec (set in openWizard). Falls back to the live spec before the dropdown exists.
local function wizFilterSpec() return (P and P._wizSpecFilter) or ns.specID end
local function wizCurrentSpecs()
    local f = P and P._wizSpecFilter
    if f == "shared" then return nil end   -- shared = every spec (no restriction)
    local sid = f or ns.specID
    return sid and { [sid] = true } or nil
end

-- Seed-driven picks (the data-driven replacement for the hand-curated ClassKit list): the
-- current class+spec's MAINTENANCE entries from ns.Maintenance (Core/Maintenance.lua) — the
-- class-wide raid buff plus the spec's own. Talent-pruned (a petless build drops its pet pick)
-- and research stubs (ally/debuff/poisons — no tracker yet) skipped. Each becomes a wizard pick
-- entry that pickDef turns into the right tracker (aura / imbue / form / pet); all default to a
-- "missing" reminder since that's what maintenance is. NOTE: keyed by English spec NAME for now
-- (the seed's header note flags the eventual switch to specID for localization).
local function seedToPickEntry(e)
    if e.research then return nil end   -- ally / debuff / poison stubs: no tracker exists yet
    if e.m == "pet" and e.petlessTalent and ns.SpellTaken(e.petlessTalent) then
        return nil                       -- petless build (Avian / Grimoire of Sacrifice / Lonely Winter)
    end
    -- Icon from the spell id when we have one, else resolve it from the name; the TILE always
    -- shows the seed's friendly name (e.g. "Water Elemental", "Moonkin Form", "Pet").
    local iconId = e.spellID or (e.matchAny and e.matchAny[1])   -- a category (poison) has no single spell → use a member's icon
    if not iconId then
        local matches = ns.SearchSpells(e.name, 4) or {}
        local m
        for _, s in ipairs(matches) do if s.name == e.name then m = s; break end end
        m = m or matches[1]
        iconId = m and m.id
    end
    -- Manual (estimated) counters aren't a "missing" reminder — they're a live stack bar.
    local isManual = (e.m == "manual")
    -- Choice-node imbue (Lightsmith Rites): the two Rites share the weapon slot and GetWeaponEnchant-
    -- Info can't tell them apart, so we gate by SPELL ID and name the widget + icon after whichever
    -- Rite you ACTUALLY have (IsPlayerSpell/IsSpellKnown) — so it isn't mislabeled "Sanctification"
    -- when you run Adjuration. "Rite" if you have neither (a non-Lightsmith adding it).
    local displayName = e.name
    if e.riteIds then
        local found
        for _, id in ipairs(e.riteIds) do
            if ns.SpellTaken(id) then
                iconId = id
                displayName = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or e.name
                found = true; break
            end
        end
        if not found then displayName = "Rite"; iconId = iconId or e.riteIds[1] end
    end
    -- Imbue talent gate: resolve a spell="self" marker to the imbue's own resolved spell id (gate on
    -- knowing this imbue = its granting talent is taken). A rite gate is id-driven in the tracker.
    local talentGate = e.talentGate
    if talentGate and talentGate.spell == "self" then
        if e.riteIds then talentGate = { mode = talentGate.mode }
        else talentGate = { mode = talentGate.mode, spell = iconId } end
    end
    return { s = { id = iconId, name = displayName }, kind = e.m, slot = e.slot, missing = not isManual,
             spellID = e.spellID, aura = e.aura, choose = e.choose, matchAny = e.matchAny,
             requireCount = e.requireCount, requireCountTalent = e.requireCountTalent,
             petlessTalent = e.petlessTalent, reviveWhenDead = e.reviveWhenDead,
             segments = isManual or nil, riteIds = e.riteIds,
             max = e.max, gen = e.gen, con = e.con, duration = e.duration,
             resetOnCombatEnd = e.resetOnCombatEnd, requiredTalent = e.requiredTalent, manualAura = e.aura,
             talentGate = talentGate }   -- imbue talent gate
end

local function seedPicks(limit, specID)
    local M = ns.Maintenance and ns.Maintenance[ns.playerClass]
    if not M then return {} end
    local raw = {}
    -- The class-wide raid buff is shared by every spec, so it shows under "Shared" (specID nil) AND
    -- under each individual spec. A specID additionally folds in THAT spec's own maintained buffs.
    if M.raid then raw[#raw + 1] = M.raid end
    if specID ~= nil then
        local specList = M[specID]   -- keyed by specID (localization-safe)
        if type(specList) == "table" then for _, e in ipairs(specList) do raw[#raw + 1] = e end end
    end
    local out = {}
    for _, e in ipairs(raw) do
        local entry = seedToPickEntry(e)
        if entry then
            -- The class-wide RAID buff (Mark of the Wild, Arcane Intellect, Fortitude, Bronze,
            -- Battle Shout, Skyfury…) defaults to group-glow: nag from the game's "cast this"
            -- action-bar glow, which lights when ANY group member lacks it (see pickDef).
            if e == M.raid then entry.raid = true end
            out[#out + 1] = entry
        end
        if #out >= (limit or 8) then break end
    end
    return out
end

-- Build tracker + widget, apply common cfg, land the editor on the new widget.
-- o = { specs, name, folder, missing, warn(min), tab }. Returns the widget id.
local function wizCommit(def, disp, o)
    o = o or {}
    local trackerId = ns.AddTracker(def)
    if not trackerId then OPT.closeWizard(); return nil end
    local id = ns.AddWidget(o.specs, trackerId, disp)
    local c = id and ns.profile.widgets[id]
    if c then
        c.trackerId, c.display = trackerId, disp
        local nm = OPT.trimStr(o.name or "")
        if nm ~= "" then c.name = nm end
        if o.folder and o.folder ~= "" then c.folder = OPT.ensureFolder(o.folder) end
        if o.segments then c.segments = true end
        if o.missing then
            c.reminder = { mode = "missing" }
            if o.warn and o.warn > 0 then c.warnLowSec = o.warn * 60 end
        end
    end
    P.selectedId = id
    if o.tab then P._tab = o.tab end
    OPT.closeWizard()
    OPT.applyStructural(); OPT.RefreshList()
    -- Universal rule: adding a widget drops you straight into Move mode so you can place it —
    -- no hunting for the Move HUD button. Lock HUD when done.
    if ns.Layout and ns.Layout.SetUnlocked then ns.Layout.SetUnlocked(true) end
    OPT.RefreshEditor()
    if c then ns.Print(("added |cff40ff40%s|r — drag it where you want, then |cffffd100Lock HUD|r."):format(c.name or "widget")) end
    return id
end

-- The tracker def + natural display for a resolved pick (its kind is known).
local function pickDef(entry)
    local sid = entry.s and entry.s.id
    if entry.kind == "imbue" then return { type = "imbue", slot = entry.slot or "main", spellID = entry.spellID or sid,
                                           riteIds = entry.riteIds, talentGate = entry.talentGate }, "icon" end
    if entry.kind == "form"  then return { type = "form", name = entry.s and entry.s.name, spellID = entry.spellID or sid }, "icon" end
    if entry.kind == "pet"   then return { type = "pet", name = "Pet", spellID = entry.spellID or sid,
                                           petlessTalent = entry.petlessTalent, reviveWhenDead = entry.reviveWhenDead }, "icon" end
    if entry.kind == "ally"  then return { type = "ally", spellID = entry.spellID or sid, name = entry.s and entry.s.name }, "icon" end
    if entry.kind == "manual" then return { type = "manual", name = entry.s and entry.s.name, spellID = entry.spellID or sid,
                                            max = entry.max or 3, gen = entry.gen, con = entry.con,
                                            duration = entry.duration, resetOnCombatEnd = entry.resetOnCombatEnd,
                                            requiredTalent = entry.requiredTalent, aura = entry.manualAura }, "bar" end
    -- aura: read the AURA id when the cast id differs (Earth Shield cast 974 -> aura 383648).
    local def = { type = "aura", spellID = entry.aura or entry.spellID or sid, unit = "player" }
    if entry.max then def.max = entry.max end
    -- Raid buff: default to group-glow so it also nags when a GROUP member is missing it (paired
    -- with the "missing" reminder wizCommit sets). Solo it falls back to reading your own aura.
    if entry.raid then def.groupGlow = true end
    -- Interchangeable variants (Paladin Devotion vs Concentration): tracks the default now, but
    -- carries the option list so the editor can offer a picker to switch which one is watched.
    if entry.choose then def.chooseFrom = entry.choose end
    -- Category match (rogue poisons): the pool is matchAny, tracked as a COUNT (1 of the
    -- category, or the talent count while requireCountTalent is taken). We never pin the exact
    -- poisons you happen to have up now — that's what nagged for a slot you couldn't fill after
    -- a respec — so ANY member of the category satisfies it and a respec just adapts.
    if entry.matchAny then
        def.matchAny = entry.matchAny; def.spellID = entry.spellID or entry.matchAny[1]
        def.requireCount, def.requireCountTalent = entry.requireCount, entry.requireCountTalent
    end
    return def, (entry.disp or "icon")
end

-- True when a pick's aura is secret in combat (won't live-track) — drives the pre-combat
-- explainer modal. Only auras go secret; form/pet/imbue/resource read non-secret APIs.
local function pickIsPreCombat(entry)
    if not entry or entry.kind ~= "aura" then return false end
    local sid = entry.aura or entry.spellID or (entry.matchAny and entry.matchAny[1]) or (entry.s and entry.s.id)
    return (sid and ns.AuraTrackability and ns.AuraTrackability(sid) == "hidden") and true or false
end

-- One-click create from a hub Common tile (kind known) — smart defaults, → editor. Seed picks
-- carry entry.missing so maintenance lands as a "show when missing" reminder; ClassKit picks
-- (no .missing) stay plain displays as before. A pre-combat aura pops the explainer first.
local function wizInstantPick(entry)
    local function go()
        local def, disp = pickDef(entry)
        wizCommit(def, disp, {
            specs   = wizCurrentSpecs(),
            name    = (entry.kind == "pet" and "Pet") or (entry.s and entry.s.name),
            segments = entry.segments,
            missing = entry.missing,
            folder  = P._wizFolderSel,
        })
    end
    if entry.kind == "manual" then
        OPT.openWizConfirm({
            title = "This is a manual tracker",
            yes   = "Add it anyway",
            body  = ("|cffe58a4b%s|r can't be read directly in combat, so Custodian |cffffffffestimates|r it by "
                .. "watching your casts — a builder adds a stack, a spender removes one.\n\n"
                .. "It's right in the |cffffffffcommon case|r and resets when you leave combat, but it |cffffffffcan drift|r: "
                .. "a dodged/missed cast, lag, or a talent that changes which spells count. Treat it as a helpful guide, not gospel.")
                :format(entry.s and entry.s.name or "This buff"),
            onYes = go,
        })
    elseif pickIsPreCombat(entry) then OPT.openPreCombatWarning(go) else go() end
end

-- One-click create from a hub Resource chip.
local function wizInstantResource(key)
    wizCommit({ type = "power", power = key }, "bar", { specs = wizCurrentSpecs(), name = OPT.prettyPower(key), folder = P._wizFolderSel })
end

-- One-click create from a hub PSEUDO-resource chip: a spec resource that's mechanically an aura
-- STACK, not a PowerType (e.g. Enhancement's Maelstrom Weapon) — a segmented aura bar, so it
-- reads like the resource it is rather than a buff. desc = { name, auraId, max, segments }.
local function wizInstantAuraResource(desc)
    local def = { type = "aura", spellID = desc.auraId, unit = "player" }
    if desc.max then def.max = desc.max end
    wizCommit(def, "bar", { specs = wizCurrentSpecs(), name = desc.name, segments = desc.segments, folder = P._wizFolderSel })
end

-- Commit a chosen spell (suggestion or search hit) into the custom-path spell box.
local function wizPick(s)
    P._wizSpell:SetText(s.name); P._wizSpellText = s.name; P._wizSpellId = s.id
    if P._wizResults then P._wizResults:Hide() end
end

-- Resolve the custom-path spell box to an id (remembered pick → raw number → top hit).
local function wizResolveSpellId()
    local txt = P._wizSpell:GetText()
    if P._wizSpellId and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(P._wizSpellId) == txt then return P._wizSpellId end
    return ns.ResolveSpellText(txt)
end

-- The name to pre-fill on the setup step: the chosen spell / power (blank if unresolved).
local function wizDefaultName()
    if P._wizItemMode and P._wizItemId then
        return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(P._wizItemId)) or "Item"
    end
    if P._wizTypeSel == "power" then return (P._wizPowerSel and OPT.prettyPower(P._wizPowerSel)) or "" end
    local sid = wizResolveSpellId()
    if sid and C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(sid) or "" end
    return ""
end

-- Back navigation from the current step.
local function wizBack()
    local step = P._wizStep
    if step == "type" then P._wizStep = "hub"
    elseif step == "pick" then P._wizStep = P._wizCustom and "hub" or "type"
    elseif step == "setup" then P._wizStep = "pick" end
    RefreshWizard()
end

-- Dropdown of spell-search hits under `anchor`; clicking a row calls onPick(hit).
function showWizResults(matches, anchor, onPick)
    local res = P._wizResults
    if not matches or #matches == 0 then res:Hide(); return end
    local n = math.min(#matches, 7)
    res:SetHeight(n * 22 + 2); res:SetWidth(240)
    res:ClearAllPoints(); res:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    for i = 1, n do
        local m = matches[i]
        local r = P._wizResRows[i]
        if not r then
            r = OPT.spellRow(res)
            r:SetPoint("TOPLEFT", 1, -((i - 1) * 22 + 1)); r:SetPoint("TOPRIGHT", -1, -((i - 1) * 22 + 1))
            P._wizResRows[i] = r
        end
        OPT.fillSpellRow(r, m)
        r:SetScript("OnClick", function() onPick(m) end)
        r:Show()
    end
    for i = n + 1, #P._wizResRows do P._wizResRows[i]:Hide() end
    res:Show(); res:Raise()
end

-- ── Hub "Add a tracker" card grid (the mock-up look) ──────────────────
local CARD_W, CARD_H, CARD_GAP = 264, 46, 12                       -- 2 columns fit the scroll area (card 588 minus the scrollbar)
local TAG = {   -- status tag on a card: display text + colour
    LIVE      = { text = "LIVE",       color = { 0.37, 0.80, 0.53 } },
    PRECOMBAT = { text = "PRE-COMBAT", color = { 0.90, 0.66, 0.28 } },
    MANUAL    = { text = "MANUAL",     color = { 0.93, 0.48, 0.30 } },   -- estimated from casts — caution
}
local ADDED_BG = { 0.11, 0.20, 0.14 }                              -- green-tinted resting fill for an already-added card

-- Recolour a border() edge table (named sides) — green when a card is already on the HUD.
local function setEdge(edge, c)
    if not edge then return end
    for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        if edge[k] then edge[k]:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
    end
end

-- One tracker card: icon tile · name + status tag · subtitle line · a +/✓ affordance.
local function makeTrackerCard(parent)
    local b = CreateFrame("Button", nil, parent); b:SetSize(CARD_W, CARD_H)
    b._bg = bgTex(b, T.rgba(T.surface.controlAlt)); b._edge = border(b)
    b._tile = b:CreateTexture(nil, "ARTWORK"); b._tile:SetPoint("LEFT", 7, 0); b._tile:SetSize(32, 32)
    b._tile:SetColorTexture(T.rgba(T.surface.control))
    b._icon = b:CreateTexture(nil, "OVERLAY"); b._icon:SetPoint("CENTER", b._tile); b._icon:SetSize(28, 28); b._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b._letter = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); b._letter:SetPoint("CENTER", b._tile)
    b._tag = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); b._tag:SetPoint("TOPRIGHT", -42, -10); b._tag:SetJustifyH("RIGHT")
    b._name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); b._name:SetPoint("TOPLEFT", 47, -8); b._name:SetPoint("RIGHT", b._tag, "LEFT", -6, 0); b._name:SetJustifyH("LEFT"); b._name:SetWordWrap(false)
    b._sub = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); b._sub:SetPoint("TOPLEFT", 47, -26); b._sub:SetPoint("RIGHT", b, "RIGHT", -42, 0); b._sub:SetJustifyH("LEFT"); b._sub:SetWordWrap(false)
    b._add = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); b._add:SetPoint("RIGHT", -14, 0); b._add:SetText("|cff9fb0c8+|r")
    b._check = b:CreateTexture(nil, "OVERLAY"); b._check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check"); b._check:SetSize(22, 22); b._check:SetPoint("RIGHT", -9, 0); b._check:SetVertexColor(0.37, 0.80, 0.53); b._check:Hide()
    b:SetScript("OnEnter", function() b._bg:SetColorTexture(T.rgba(T.surface.controlHot)) end)
    b:SetScript("OnLeave", function() b._bg:SetColorTexture(T.rgba(b._added and ADDED_BG or T.surface.controlAlt)) end)
    spellTip(b, function() return b._sid end)
    return b
end

-- Populate a card from a model { name, tag, sub, icon, sig, add }. addedSet marks HUD-present sigs.
local function fillTrackerCard(b, m, addedSet)
    b._name:SetText(m.name or "?")
    local t = m.tag and TAG[m.tag]
    if t then b._tag:SetText(t.text); b._tag:SetTextColor(t.color[1], t.color[2], t.color[3])
    else b._tag:SetText("") end
    b._sub:SetText(m.sub or "")
    b._sid = m.spellID
    -- Resource cards tint the icon tile with the resource's in-game colour so a Rage
    -- pick reads red and a Mana pick reads blue at a glance (mirrors the bar default).
    if m.tint then
        b._tile:SetColorTexture(m.tint[1], m.tint[2], m.tint[3], 1)
        b._letter:SetTextColor(0.06, 0.06, 0.08)   -- dark glyph for contrast on the bright tile
    else
        b._tile:SetColorTexture(T.rgba(T.surface.control))
        b._letter:SetTextColor(1, 1, 1)
    end
    if m.icon then b._icon:SetTexture(m.icon); b._icon:Show(); b._letter:SetText("")
    else b._icon:Hide(); b._letter:SetText((m.name or "?"):sub(1, 1)) end
    local added = (m.sig and addedSet and addedSet[m.sig]) and true or false
    b._added = added
    b._bg:SetColorTexture(T.rgba(added and ADDED_BG or T.surface.controlAlt))
    setEdge(b._edge, added and { 0.24, 0.55, 0.35 } or T.surface.edge)
    b._add:SetShown(not added); b._check:SetShown(added)
    b:SetScript("OnClick", function()
        if m.confirm then       -- e.g. the Earth Shield special: needs the Elemental Orbit talent
            OPT.openWizConfirm({ title = m.confirm.title or "Check your talent", body = m.confirm.body, linkSpell = m.confirm.spell,
                             yes = "Add it", onYes = m.add })
        elseif added then       -- already on the HUD — offer to add a second one
            OPT.openWizConfirm({ title = "Already tracking this", yes = "Add another",
                             body = "You already have a widget for this buff. Add another one anyway?", onYes = m.add })
        else
            m.add()
        end
    end)
end

-- A section header: caption + a one-line description.
local function makeSection(parent)
    local s = {}
    s.lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); s.lbl:SetJustifyH("LEFT")
    s.desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); s.desc:SetJustifyH("LEFT")
    return s
end

-- Signatures of every tracker already on the HUD, so a hub card can show it's added (✓).
-- Scoped to THIS character's class (+ truly shared widgets): the profile is cross-char, so a
-- Warrior's "Rage" and a Druid's "Rage" share the sig `power:RAGE` — without this scope, browsing
-- on the Druid would flag Rage as already-added because the Warrior owns one. (See ns.ClassOfCfg.)
local function hubAddedSet()
    local set = {}
    local W = ns.profile and ns.profile.widgets
    local Tk = ns.profile and ns.profile.trackers
    if not (W and Tk) then return set end
    for _, c in pairs(W) do
        local tr = c.trackerId and Tk[c.trackerId]
        if tr and ns.CfgClassActive(c) then
            if tr.type == "power" and tr.power then set["power:" .. tr.power] = true
            elseif tr.spellID then set["spell:" .. tr.spellID] = true end
        end
    end
    return set
end

-- The subtitle + status tag + HUD signature for a recommended (seed) pick, by mechanism.
local PICK_SUB = { imbue = "Weapon imbue", form = "Form", pet = "Pet", ally = "On an ally", manual = "Estimated \226\128\148 counts your casts" }
local function pickCardMeta(entry)
    local kind = entry.kind
    if kind == "aura" then
        local sub = entry.matchAny and "Any of a set" or "Aura on you"
        return sub, (pickIsPreCombat(entry) and "PRECOMBAT" or "LIVE"),
               "spell:" .. tostring(entry.aura or entry.spellID or (entry.matchAny and entry.matchAny[1]) or (entry.s and entry.s.id))
    end
    local sid = entry.spellID or (entry.s and entry.s.id)
    if kind == "manual" then return PICK_SUB.manual, "MANUAL", sid and ("spell:" .. sid) or nil end
    return (PICK_SUB[kind] or "Aura"), "LIVE", sid and ("spell:" .. sid) or nil
end

function OPT.buildWizard()
    local wiz = CreateFrame("Frame", nil, P); wiz:SetAllPoints(P); wiz:SetFrameStrata("DIALOG")
    wiz:EnableMouse(true); wiz:Hide(); bgTex(wiz, 0, 0, 0, 0.55)
    P._wiz = wiz
    local card = CreateFrame("Frame", nil, wiz); card:SetSize(588, 578); card:SetPoint("CENTER")
    bgTex(card, T.rgba(T.surface.panel)); border(card)
    P._wizCard = card

    P._wizTitle = Label(card, "", "GameFontNormalLarge"); P._wizTitle:SetPoint("TOPLEFT", 18, -16)
    P._wizSubtitle = Label(card, "", "GameFontDisableSmall"); P._wizSubtitle:SetPoint("TOPLEFT", 18, -38)
    P._wizStepLbl = Label(card, "", "GameFontDisableSmall"); P._wizStepLbl:SetPoint("TOPRIGHT", -16, -18)

    -- Spec filter (top-right of the hub): browse the widgets for any spec of your class (default:
    -- the current spec), or "All specs". Also sets which spec a newly-added widget lands on — so you
    -- can set up Resto from your Enhancement spec, for example.
    P._wizSpecDrop = Dropdown(card, 150, function(v)
        P._wizSpecFilter = v
        P._wizSpecs = wizCurrentSpecs()   -- keep the add-target in lockstep with what you're viewing
        RefreshWizard()
    end)

    -- Legend: Live / Reminder swatches, so the tags on the cards read at a glance.
    local function legendItem(colorTag, label)
        local f = CreateFrame("Frame", nil, card)
        f._sw = f:CreateTexture(nil, "ARTWORK"); f._sw:SetSize(10, 10); f._sw:SetPoint("LEFT", 0, 0)
        local c = TAG[colorTag].color; f._sw:SetColorTexture(c[1], c[2], c[3])
        f._t = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); f._t:SetPoint("LEFT", f._sw, "RIGHT", 6, 0); f._t:SetText(label)
        f:SetSize(260, 14)
        return f
    end
    P._wizLegendLive = legendItem("LIVE", "|cffffffffLive|r — readable in combat, running timer")
    P._wizLegendRem  = legendItem("PRECOMBAT", "|cffffffffPre-combat|r — hidden in combat, shows when it drops")
    P._wizLegendManual = legendItem("MANUAL", "|cffffffffManual|r — estimated from your casts")

    P._wizCards, P._wizSecs = {}, {}   -- pooled tracker cards + section headers

    -- The hub's content SCROLLS: the header (title / spec dropdown / legend) and the bottom nav row
    -- stay pinned to the card; everything between (sections, cards, folder, custom) lives in this
    -- scroll child, so a class with many buffs — or the taller "All specs" view — never bleeds off.
    local hview = CreateFrame("ScrollFrame", nil, card); hview:SetClipsChildren(true); hview:Hide()
    local hchild = CreateFrame("Frame", nil, hview); hchild:SetSize(1, 1)
    hview:SetScrollChild(hchild)
    P._wizHubScroll, P._wizHubChild = hview, hchild
    local hMax = function() return math.max(0, (hchild:GetHeight() or 0) - (hview:GetHeight() or 0)) end
    P._wizHubSb = ns.UI.MakeScrollbar(card, hview, {
        getMax = hMax,
        get    = function() return hview:GetVerticalScroll() end,
        set    = function(v) hview:SetVerticalScroll(math.max(0, math.min(hMax(), v))) end,
        frac   = function() local h = hchild:GetHeight() or 1; return (h > 0) and ((hview:GetHeight() or 1) / h) or 1 end,
    })
    hview:EnableMouseWheel(true)
    hview:SetScript("OnMouseWheel", function(_, d)
        hview:SetVerticalScroll(math.max(0, math.min(hMax(), hview:GetVerticalScroll() - d * 40)))
        if P._wizHubSb then P._wizHubSb() end
    end)

    -- Shared spell-search results dropdown (used by both the hub search and the custom
    -- spell box, with a per-use onPick).
    local res = CreateFrame("Frame", nil, card); res:SetFrameStrata("FULLSCREEN_DIALOG"); res:SetClipsChildren(true)
    bgTex(res, T.rgba(T.surface.panel)); border(res); res:Hide()
    P._wizResults, P._wizResRows = res, {}

    -- ── Hub (pick-first start) ──
    -- No global search here: the two entry cards below cover it (Browse = this spec's trackable
    -- buffs; Custom = search ANY spell / resource / imbue), so a third search box on the hub was
    -- just ambiguous. Search now lives only in the Custom flow (the "pick" step's spell box).

    -- The custom entry card at the foot of the hub — the neutral "build from scratch" flow, flagged
    -- experimental (an accompanying banner sits beside it). Rests at controlAlt, brightens on hover.
    local function entryCard()
        local b = CreateFrame("Button", nil, card); b:SetSize(408, 44)
        b._bg = bgTex(b, T.rgba(T.surface.controlAlt)); border(b)
        b._l = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); b._l:SetPoint("TOPLEFT", 14, -7)
        b._d = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b._d:SetPoint("TOPLEFT", 14, -24); b._d:SetPoint("RIGHT", -30, 0); b._d:SetJustifyH("LEFT"); b._d:SetWordWrap(false)
        b:SetScript("OnEnter", function() b._bg:SetColorTexture(T.rgba(T.surface.controlHot)) end)
        b:SetScript("OnLeave", function() b._bg:SetColorTexture(T.rgba(T.surface.controlAlt)) end)
        return b
    end
    P._wizCustomBtn = entryCard()
    P._wizCustomBtn._l:SetText("Build something custom")
    P._wizCustomBtn._d:SetText("Search a buff by name or ID.")
    -- Straight to the custom picker (skip the type cards — resources & imbues are already all shown
    -- on the hub). Starts in Buff mode.
    P._wizCustomBtn:SetScript("OnClick", function()
        P._wizTypeSel = "aura"; P._wizCustom = true; P._wizItemMode = false
        P._wizSpellText, P._wizSpellId = "", nil
        P._wizStep = "pick"; RefreshWizard()
    end)
    P._wizExperimental = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P._wizExperimental:SetJustifyH("LEFT"); P._wizExperimental:SetJustifyV("TOP"); P._wizExperimental:SetWordWrap(true); P._wizExperimental:SetSpacing(3)

    -- ── Custom: type cards (Buff / Resource / Imbue) ──
    P._wizType = {}
    for _, t in ipairs(WIZ_TYPES) do
        local b = CreateFrame("Button", nil, card); b:SetSize(400, 46)
        b._bg = bgTex(b, T.rgba(T.surface.controlAlt)); border(b)
        local l = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); l:SetPoint("TOPLEFT", 12, -7); l:SetText(t.l)
        local d = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); d:SetPoint("TOPLEFT", 12, -25); d:SetPoint("RIGHT", -10, 0); d:SetJustifyH("LEFT"); d:SetText(t.d)
        b:SetScript("OnEnter", function() b._bg:SetColorTexture(T.rgba(T.surface.controlHot)) end)
        b:SetScript("OnLeave", function() b._bg:SetColorTexture(T.rgba(T.surface.controlAlt)) end)
        b:SetScript("OnClick", function() P._wizTypeSel = t.k; P._wizStep = "pick"; RefreshWizard() end)
        P._wizType[t.k] = b
    end

    -- ── Pick (custom): spell search / power / slot + caveat ──
    P._wizSpellLbl = Label(card, "Spell")
    P._wizSpell = EditBox(card, 232, function(t) P._wizSpellText = t end)
    spellTip(P._wizSpell, function() return tonumber(P._wizSpell:GetText()) end)
    P._wizSpell:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local t = self:GetText(); P._wizSpellText = t; P._wizSpellId = nil   -- typing overrides a prior pick
        if t == "" or tonumber(t) then P._wizResults:Hide(); return end
        showWizResults(ns.SearchSpells(t, 7), P._wizSpell, wizPick)
    end)
    P._wizPower = Dropdown(card, 160, function(v) P._wizPowerSel = v; P._wizPower:SetText(v) end)
    P._wizSlot = {}
    for _, s in ipairs({ { k = "main", l = "Main-hand" }, { k = "off", l = "Off-hand" }, { k = "either", l = "Either" } }) do
        local b = Button(card, s.l, 86, 22); b:SetScript("OnClick", function() P._wizSlotSel = s.k; RefreshWizard() end); P._wizSlot[s.k] = b
    end

    -- Custom flow: BUFF (a buff you have → aura tracker; optionally the item that grants it, e.g.
    -- an augment rune, for click-to-cast) vs WEAPON OIL (a temporary weapon enchant → imbue + item
    -- applied to a slot). A mode toggle swaps the picker; oil mode reuses the slot buttons above.
    P._wizMode = {}
    for _, m in ipairs({ { k = "aura", l = "Aura" }, { k = "item", l = "Weapon oil" } }) do
        local b = Button(card, m.l, 108, 24)
        b:SetScript("OnClick", function()
            P._wizItemMode = (m.k == "item")
            P._wizTypeSel  = P._wizItemMode and "imbue" or "aura"
            RefreshWizard()
        end)
        P._wizMode[m.k] = b
    end
    P._wizItemLbl = Label(card, "Item")
    P._wizItem = UI.ItemField(card, 232, function(id) P._wizItemId = id; RefreshWizard() end)   -- shared field + hook (UIKit)
    P._wizItemIcon = P._wizItem._icon
    tip(P._wizItem, "Item", "The item to remind about — a weapon oil or an augment rune. Type its ID or shift-click the item in. For an oil, pick the weapon slot above; clicking the widget applies it there.")

    P._wizCaveat = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P._wizCaveat:SetJustifyH("LEFT"); P._wizCaveat:SetJustifyV("TOP"); P._wizCaveat:SetTextColor(T.rgba(T.text.info))

    -- ── Setup: display + reminder ──
    P._wizDisp = {}
    for _, d in ipairs({ { k = "bar", l = "Bar" }, { k = "icon", l = "Icon" } }) do
        local b = Button(card, d.l, 92, 26); b:SetScript("OnClick", function() P._wizDispSel = d.k; RefreshWizard() end); P._wizDisp[d.k] = b
    end
    P._wizDispHint = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); P._wizDispHint:SetJustifyH("LEFT")
    P._wizDispHint:SetText("Icons suit auras & imbues; bars suit resources.")
    P._wizTrack = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); P._wizTrack:SetJustifyH("LEFT"); P._wizTrack:SetJustifyV("TOP")
    P._wizMissing = Check(card, "Show only when missing (reminder)", function(v) P._wizMissingSel = v and true or false; RefreshWizard() end)
    P._wizWarnLbl = Label(card, "Warn under (min)")
    P._wizWarn = Slider(card, 0, 60, 1, 130, function(v) P._wizWarnMin = v end)

    -- ── Setup: name / specs / folder (the "you own it" bits) ──
    P._wizNameLbl = Label(card, "Name")
    P._wizName = EditBox(card, 232, function(t) P._wizNameText = t; P._wizNameEdited = true end)
    P._wizDispLbl = Label(card, "Display")
    P._wizSpecLbl = Label(card, "Show on")
    P._wizSpecAll = Label(card, "", "GameFontDisableSmall")
    P._wizSpecBtns = {}
    for _, sp in ipairs(OPT.SPEC_LIST()) do
        P._wizSpecBtns[sp.id] = OPT.specToggle(card, sp, function(id)
            P._wizSpecs = P._wizSpecs or {}
            if P._wizSpecs[id] then P._wizSpecs[id] = nil else P._wizSpecs[id] = true end
            if not next(P._wizSpecs) then P._wizSpecs = nil end
            RefreshWizard()
        end)
    end
    P._wizFolderLbl = Label(card, "Folder")
    P._wizFolder = Dropdown(card, 160, function(v)
        if v == "__newfolder__" then
            OPT.promptFolderName("", function(name)
                name = OPT.ensureFolder(name); if not name then return end
                P._wizFolderSel = name; RefreshWizard()
            end)
            return
        end
        P._wizFolderSel = (v ~= "" and v) or nil
        P._wizFolder:SetText(P._wizFolderSel or "(No folder)")
    end, { menuWidth = 180 })

    -- Nav
    P._wizCancel = Button(card, "Cancel", 74, 24); P._wizCancel:SetScript("OnClick", function() OPT.closeWizard() end)
    P._wizBack = Button(card, "Back", 70, 24); P._wizBack:SetScript("OnClick", function() wizBack() end)
    P._wizNext = Button(card, "Next", 92, 24); P._wizNext:SetScript("OnClick", function() wizardNext() end)

    -- Inline validation error — amber, along the bottom bar to the LEFT of Next — so a failed
    -- Next reads AS a message, not a dead button (it used to print to chat behind the modal).
    P._wizErr = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    P._wizErr:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 20)
    P._wizErr:SetPoint("RIGHT", P._wizNext, "LEFT", -12, 0)
    P._wizErr:SetJustifyH("LEFT"); P._wizErr:SetWordWrap(true); P._wizErr:Hide()
end

-- Show / clear the inline wizard error.
local function wizError(msg) if P._wizErr then P._wizErr:SetText("|cffe58a4b" .. msg .. "|r"); P._wizErr:Show() end end
local function wizClearError() if P._wizErr then P._wizErr:Hide() end end

function RefreshWizard()
    if not P or not P._wizCard then return end
    wizClearError()   -- a fresh step render clears any stale validation message
    for _, b in pairs(P._wizType) do b:Hide() end
    for _, b in pairs(P._wizSlot) do b:Hide() end
    if P._wizMode then for _, b in pairs(P._wizMode) do b:Hide() end end
    if P._wizDisp then for _, b in pairs(P._wizDisp) do b:Hide() end end
    if P._wizSpecBtns then for _, b in pairs(P._wizSpecBtns) do b:Hide() end end
    if P._wizCards then for _, r in ipairs(P._wizCards) do r:Hide() end end
    if P._wizSecs then for _, s in ipairs(P._wizSecs) do s.lbl:Hide(); s.desc:Hide() end end
    for _, k in ipairs({ "_wizSubtitle", "_wizSpecDrop", "_wizHubScroll", "_wizLegendLive", "_wizLegendRem", "_wizLegendManual",
                         "_wizCustomBtn", "_wizExperimental",
                         "_wizSpellLbl", "_wizSpell", "_wizPower", "_wizItemLbl", "_wizItem", "_wizCaveat", "_wizDispHint", "_wizTrack",
                         "_wizMissing", "_wizWarnLbl", "_wizWarn", "_wizNameLbl", "_wizName", "_wizDispLbl",
                         "_wizSpecLbl", "_wizSpecAll", "_wizFolderLbl", "_wizFolder" }) do
        if P[k] then P[k]:Hide() end
    end
    if P._wizResults then P._wizResults:Hide() end

    local step, ty, card = P._wizStep or "hub", P._wizTypeSel, P._wizCard
    local function put(ctrl, x, y) ctrl:ClearAllPoints(); ctrl:SetPoint("TOPLEFT", card, "TOPLEFT", x, -y); ctrl:Show() end
    local kit = ns.Maintenance and ns.Maintenance[ns.playerClass]   -- resources / resourcesBySpec / specials

    if step == "hub" then
        P._wizStepLbl:SetText("")
        P._wizTitle:SetText("|cffe8b84bAdd a widget|r")
        P._wizSubtitle:SetText("Pick what to watch — one click adds it and drops you into Move HUD."); P._wizSubtitle:Show()

        -- Spec filter dropdown (top-right): "Shared" (widgets every spec shares) + one per class spec.
        local items = { { value = "shared", text = "Shared" } }
        for _, sp in ipairs(OPT.SPEC_LIST()) do items[#items + 1] = { value = sp.id, text = sp.name } end
        local cur = P._wizSpecFilter or ns.specID
        local curText = (cur == "shared") and "Shared"
            or ((cur and ns.SpecName and ns.SpecName(cur)) or "Current spec")
        P._wizSpecDrop:SetItems(items); P._wizSpecDrop:SetText(curText)
        P._wizSpecDrop:ClearAllPoints(); P._wizSpecDrop:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -14); P._wizSpecDrop:Show()

        -- Legend on two lines (Live + Pre-combat, then Manual) so it never bleeds past the card edge.
        P._wizLegendLive:ClearAllPoints(); P._wizLegendLive:SetPoint("TOPLEFT", card, "TOPLEFT", 18, -62); P._wizLegendLive:Show()
        local lw = 16 + (P._wizLegendLive._t:GetStringWidth() or 200)
        P._wizLegendRem:ClearAllPoints(); P._wizLegendRem:SetPoint("TOPLEFT", P._wizLegendLive, "TOPLEFT", lw + 26, 0); P._wizLegendRem:Show()
        P._wizLegendManual:ClearAllPoints(); P._wizLegendManual:SetPoint("TOPLEFT", card, "TOPLEFT", 18, -80); P._wizLegendManual:Show()

        -- The scrollable content region (below the two-line legend, above the nav row).
        local HB, hview = P._wizHubChild, P._wizHubScroll
        hview:ClearAllPoints()
        hview:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -100)
        hview:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -20, 46)
        hview:Show(); HB:SetWidth(562)

        local added = hubAddedSet()
        local y = 6
        local ci, si = 0, 0
        local function section(label, desc)
            si = si + 1
            local s = P._wizSecs[si]; if not s then s = makeSection(HB); P._wizSecs[si] = s end
            s.lbl:SetParent(HB); s.lbl:ClearAllPoints(); s.lbl:SetPoint("TOPLEFT", HB, "TOPLEFT", 12, -y)
            s.lbl:SetText("|cff8fb8e0" .. label .. "|r"); s.lbl:Show()
            y = y + 20
            s.desc:SetParent(HB); s.desc:ClearAllPoints(); s.desc:SetPoint("TOPLEFT", HB, "TOPLEFT", 12, -y); s.desc:SetText(desc); s.desc:Show()
            y = y + 19
        end
        -- Anchor a shared control into the scroll child at the running y (re-parents it in).
        local function putH(ctrl, x) ctrl:SetParent(HB); ctrl:ClearAllPoints(); ctrl:SetPoint("TOPLEFT", HB, "TOPLEFT", x, -y); ctrl:Show() end
        local function gridCard(model, x)
            ci = ci + 1
            local b = P._wizCards[ci]; if not b then b = makeTrackerCard(HB); P._wizCards[ci] = b end
            fillTrackerCard(b, model, added)
            b:SetParent(HB); b:ClearAllPoints(); b:SetPoint("TOPLEFT", HB, "TOPLEFT", x, -y); b:Show()
        end
        local COL2 = 6 + CARD_W + CARD_GAP
        local function grid(models)
            for i = 1, #models, 2 do
                gridCard(models[i], 6)
                if models[i + 1] then gridCard(models[i + 1], COL2) end
                y = y + CARD_H + 8
            end
        end

        -- RESOURCES — power-key (live-max gated) or aura-stack descriptor (always shown). The
        -- per-spec pin (resourcesBySpec[specID]) keeps e.g. Maelstrom off Resto; see Maintenance.lua.
        local resKeys = (kit and kit.resourcesBySpec and ns.specID and kit.resourcesBySpec[ns.specID]) or (kit and kit.resources) or {}
        local resModels = {}
        for _, r in ipairs(resKeys) do
            if type(r) == "table" then
                resModels[#resModels + 1] = { name = r.name, tag = "LIVE", sub = "Stacks · segmented bar",
                    icon = ns.SpellIcon(r.auraId), spellID = r.auraId, sig = "spell:" .. tostring(r.auraId),
                    add = function() wizInstantAuraResource(r) end }
            else
                local mx = ns.PowerMax and ns.PowerMax(r)
                if (ns.IsSecret and ns.IsSecret(mx)) or (type(mx) == "number" and mx > 0) then
                    local cr, cg, cb
                    if ns.PowerColor then cr, cg, cb = ns.PowerColor(r) end
                    if not cr and r == "PRIMARY" and ns.CurrentPowerColor then cr, cg, cb = ns.CurrentPowerColor("player") end
                    resModels[#resModels + 1] = { name = OPT.prettyPower(r), tag = "LIVE", sub = "Resource · bar",
                        tint = cr and { cr, cg, cb } or nil,
                        sig = "power:" .. r, add = function() wizInstantResource(r) end }
                end
            end
        end
        if #resModels > 0 then
            section("RESOURCES", "Your spec's resource bars — detected automatically.")
            grid(resModels); y = y + 6
        end

        -- RECOMMENDED — the seed picks (filtered to the dropdown's spec, or ALL specs) plus class
        -- specials, folded into one grid. Specials are class-wide, so they always show.
        local fSpec = (P._wizSpecFilter == "shared") and nil or wizFilterSpec()
        local recModels = {}
        for _, entry in ipairs(seedPicks(8, fSpec)) do
            local sub, tag, sig = pickCardMeta(entry)
            recModels[#recModels + 1] = { name = (entry.s and entry.s.name) or "?", tag = tag, sub = sub,
                icon = entry.s and entry.s.id and ns.SpellIcon(entry.s.id), spellID = entry.s and entry.s.id, sig = sig,
                add = function() wizInstantPick(entry) end }
        end
        for _, sp in ipairs((kit and kit.specials) or {}) do
            recModels[#recModels + 1] = { name = sp.name, sub = sp.sub or "Class special",
                icon = sp.icon and ns.SpellIcon(sp.icon), spellID = sp.icon, confirm = sp.confirm,
                sig = sp.icon and ("spell:" .. sp.icon) or nil,
                add = function()
                    local id = sp.add and sp.add()
                    if id then
                        if P._wizFolderSel and ns.profile.widgets[id] then ns.profile.widgets[id].folder = OPT.ensureFolder(P._wizFolderSel) end
                        P.selectedId = id; P._tab = sp.tab or "trigger"; OPT.closeWizard(); OPT.applyStructural(); OPT.RefreshList()
                        if ns.Layout and ns.Layout.SetUnlocked then ns.Layout.SetUnlocked(true) end
                        OPT.RefreshEditor()
                    else OPT.closeWizard() end
                end }
        end
        if #recModels > 0 then
            local whose = (fSpec == nil) and "every spec shares"
                or ((fSpec == ns.specID) and "your spec maintains")
                or (((ns.SpecName and ns.SpecName(fSpec)) or "that spec") .. " maintains")
            section("RECOMMENDED — KEEP UP", "The buffs " .. whose .. " — auto-pruned by your talents.")
            grid(recModels); y = y + 6
        end

        -- WEAPON OIL — every class can run a main-hand oil, so it's a first-class one-click add here
        -- (moved out of the Custom builder). Lands as a "missing" reminder on the chosen spec.
        section("GENERAL", "Available to every spec.")
        grid({ {
            name = "Weapon oil", sub = "Main-hand enchant · reminder",
            icon = "Interface\\Icons\\INV_Potion_19", sig = "weaponoil",
            add = function()
                wizCommit({ type = "imbue", slot = "main", name = "Weapon oil" }, "icon",
                    { specs = wizCurrentSpecs(), name = "Weapon oil", missing = true, folder = P._wizFolderSel })
            end,
        } })
        y = y + 6

        -- FOLDER — a full section like the others so the hub reads as one flow. The chosen folder
        -- is the target for everything added here (1-click cards, resources, specials, custom), via
        -- the shared P._wizFolderSel. Only shown once you actually HAVE folders — on a fresh setup
        -- it's pure clutter (make folders from the sidebar's + New folder).
        if #OPT.foldersList() > 0 then
            section("FOLDER", "Drop what you add into a folder — pick one or make a new one.")
            putH(P._wizFolder, 12)
            P._wizFolder:SetItems(OPT.folderOptsFor(ns.playerClass, P._wizFolderSel)); P._wizFolder:SetText(P._wizFolderSel or "(No folder)")
            y = y + 34
        end

        -- Bottom: Build custom (search ANY buff). Flagged experimental — the freeform search + setup
        -- can produce a widget that doesn't track cleanly. (CooldownViewer "Browse" was removed; the
        -- spec dropdown above covers viewing another spec's widgets.)
        y = y + 4
        P._wizCustomBtn:SetWidth(CARD_W); P._wizCustomBtn._d:SetText("Search any buff by name or ID.")
        putH(P._wizCustomBtn, 6)
        P._wizExperimental:SetParent(HB); P._wizExperimental:ClearAllPoints()
        P._wizExperimental:SetPoint("LEFT", P._wizCustomBtn, "RIGHT", 12, 0); P._wizExperimental:SetWidth(CARD_W - 20)
        P._wizExperimental:SetText("|cffe6a53cExperimental|r — might not work as intended; use at your own risk.")
        P._wizExperimental:Show()
        y = y + CARD_H + 8

        -- Size the scroll child to the content, and update / clamp the scrollbar.
        HB:SetHeight(math.max(1, y))
        hview:SetVerticalScroll(math.min(hview:GetVerticalScroll(), math.max(0, y - hview:GetHeight())))
        if P._wizHubSb then P._wizHubSb() end

    elseif step == "type" then
        P._wizStepLbl:SetText("Build custom")
        P._wizTitle:SetText("What do you want to track?")
        local y = 54
        for _, t in ipairs(WIZ_TYPES) do put(P._wizType[t.k], 16, y); y = y + 54 end

    elseif step == "pick" then
        local custom = P._wizCustom
        local itemMode = custom and P._wizItemMode
        P._wizStepLbl:SetText("Custom")
        P._wizTitle:SetText(custom and (itemMode and "Track a weapon oil" or "Track an aura") or (WIZ_PICK[ty] or "Pick it"))
        local y = 58
        if ty == "power" and not custom then
            put(P._wizPower, 16, y); P._wizPower:SetItems(OPT.powerOpts()); P._wizPower:SetText(P._wizPowerSel and OPT.prettyPower(P._wizPowerSel) or "Choose a resource"); y = y + 40
        else
            -- Custom: a Buff (aura) with an optional item that grants it (rune, potion). Weapon oils
            -- are their own first-class hub card now, so the old Buff/Oil mode toggle is gone.
            local function itemField(lbl)
                P._wizItemLbl:SetText(lbl)
                put(P._wizItemLbl, 16, y + 4); put(P._wizItem, 76, y)
                P._wizItem:SetText(P._wizItemId and ("item:" .. P._wizItemId) or "")
                if P._wizItemId then
                    local ic = ns.ItemIcon(P._wizItemId)
                    P._wizItemIcon:SetTexture(ic or 134400); P._wizItemIcon:Show(); P._wizItem:SetTextInsets(24, 6, 0, 0)
                else
                    P._wizItemIcon:Hide(); P._wizItem:SetTextInsets(6, 6, 0, 0)
                end
                y = y + 36
            end
            local function slotButtons()
                local sx = 16
                for _, k in ipairs({ "main", "off", "either" }) do
                    local b = P._wizSlot[k]; put(b, sx, y); b:SetActive((P._wizSlotSel or "main") == k); sx = sx + 92
                end
                y = y + 36
            end
            if itemMode then
                itemField("Oil")
                slotButtons()   -- an oil applies to a weapon slot; let the user pick which
            else
                P._wizSpellLbl:SetText(custom and "Aura" or "Spell")
                put(P._wizSpellLbl, 16, y + 4)
                put(P._wizSpell, 76, y); P._wizSpell:SetText(P._wizSpellText or ""); y = y + 36
                if custom then
                    itemField("Item")   -- OPTIONAL: the item that grants this buff (rune, potion…)
                elseif ty == "imbue" then
                    slotButtons()
                end
            end
        end
        put(P._wizCaveat, 16, y + 6); P._wizCaveat:SetWidth(400)
        P._wizCaveat:SetText((custom and (WIZ_CAVEAT.aura .. "  Optionally add the item that grants it (a rune, potion…) so clicking the widget uses it."))
                              or (WIZ_CAVEAT[ty] or ""))

    elseif step == "setup" then
        P._wizStepLbl:SetText("")
        P._wizTitle:SetText("Set it up")
        local y = 50

        put(P._wizNameLbl, 16, y + 4); put(P._wizName, 70, y)
        P._wizName:SetText(P._wizNameText or ""); y = y + 34

        put(P._wizDispLbl, 16, y + 4)
        local dsel = P._wizDispSel or ((ty == "power") and "bar" or "icon")
        local dx = 70
        for _, k in ipairs({ "bar", "icon" }) do local b = P._wizDisp[k]; put(b, dx, y); b:SetActive(dsel == k); dx = dx + 100 end
        y = y + 30
        put(P._wizDispHint, 16, y); P._wizDispHint:SetWidth(400); y = y + 24

        -- Combat-trackability warning for a secret buff (inform, don't block).
        if ty == "aura" then
            local sid = P._wizSpellId or wizResolveSpellId()
            if sid and ns.AuraTrackability and ns.AuraTrackability(sid) == "hidden" then
                P._wizTrack:SetText("|cffd9a441Hidden from addons in combat.|r Works out of combat and as a 'missing' reminder — its live status won't update mid-fight.")
                put(P._wizTrack, 16, y); P._wizTrack:SetWidth(400); y = y + 40
            end
        end

        put(P._wizSpecLbl, 16, y + 3)
        local sx = 70
        for _, sp in ipairs(OPT.SPEC_LIST()) do
            local b = P._wizSpecBtns[sp.id]; put(b, sx, y)
            b:SetActive(P._wizSpecs and P._wizSpecs[sp.id] and true or false); sx = sx + 32
        end
        put(P._wizSpecAll, sx + 2, y + 3)
        P._wizSpecAll:SetText((not (P._wizSpecs and next(P._wizSpecs))) and "(all specs)" or "")
        y = y + 32

        if #OPT.foldersList() > 0 then   -- only offer a folder once you have some (see the hub note)
            put(P._wizFolderLbl, 16, y + 4); put(P._wizFolder, 70, y)
            P._wizFolder:SetItems(OPT.folderOptsFor(ns.playerClass, P._wizFolderSel)); P._wizFolder:SetText(P._wizFolderSel or "(No folder)")
            y = y + 34
        end

        if ty == "aura" or ty == "imbue" then
            put(P._wizMissing, 16, y); P._wizMissing:SetChecked(P._wizMissingSel and true or false); y = y + 30
            if P._wizMissingSel then
                put(P._wizWarnLbl, 16, y + 4); put(P._wizWarn, 130, y); P._wizWarn:Set(P._wizWarnMin or 0)
            end
        end
    end

    -- Nav row along the bottom of the card
    P._wizCancel:ClearAllPoints(); P._wizCancel:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 14); P._wizCancel:Show()
    if step == "hub" then
        P._wizBack:Hide()
    else
        P._wizBack:ClearAllPoints(); P._wizBack:SetPoint("LEFT", P._wizCancel, "RIGHT", 8, 0); P._wizBack:Show()
    end
    if step == "pick" or step == "setup" then
        P._wizNext._fs:SetText(step == "setup" and "Finish" or "Next")
        P._wizNext:ClearAllPoints(); P._wizNext:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -16, 14); P._wizNext:Show()
    else
        P._wizNext:Hide()
    end
end

function wizardNext()
    local step, ty = P._wizStep, P._wizTypeSel
    wizClearError()
    if step == "pick" then
        if P._wizItemMode then
            if not P._wizItemId then wizError("Pick an item — type its ID or shift-click it into the box."); return end
        elseif ty == "power" then
            if not P._wizPowerSel then wizError("Choose a resource."); return end
        elseif ty ~= "imbue" then   -- aura requires a spell; imbue's is optional
            if not wizResolveSpellId() then wizError("Pick a spell from the list, or type its exact name / id."); return end
        end
        if not P._wizNameEdited then P._wizNameText = wizDefaultName() end
        P._wizStep = "setup"; RefreshWizard()
    elseif step == "setup" then
        -- A pre-combat aura (a searched secret buff) pops the explainer once before committing;
        -- live auras / imbues / resources commit straight away.
        local sid = (ty == "aura") and wizResolveSpellId()
        if sid and ns.AuraTrackability and ns.AuraTrackability(sid) == "hidden" then
            OPT.openPreCombatWarning(wizardFinish)
        else
            wizardFinish()
        end
    end
end

function wizardFinish()
    local ty = P._wizTypeSel
    local sid = (ty ~= "power") and wizResolveSpellId() or nil
    local def, disp
    if ty == "power" then def, disp = { type = "power", power = P._wizPowerSel }, (P._wizDispSel or "bar")
    elseif P._wizItemMode then def, disp = { type = "imbue", slot = P._wizSlotSel or "main", itemID = P._wizItemId }, (P._wizDispSel or "icon")
    elseif ty == "imbue" then def, disp = { type = "imbue", slot = P._wizSlotSel or "main", spellID = sid }, (P._wizDispSel or "icon")
    else def, disp = { type = "aura", spellID = sid, unit = "player", itemID = P._wizItemId }, (P._wizDispSel or "icon") end
    local nm = OPT.trimStr(P._wizName and P._wizName:GetText() or P._wizNameText or "")
    if nm == "" then nm = wizDefaultName() end
    wizCommit(def, disp, {
        specs   = P._wizSpecs,
        name    = nm,
        folder  = P._wizFolderSel,
        missing = (ty == "aura" or ty == "imbue") and P._wizMissingSel or nil,
        warn    = P._wizWarnMin,
    })
end

function OPT.openWizard()
    if not P._wiz then OPT.buildWizard() end
    P._wizStep = "hub"
    P._wizTypeSel = nil
    P._wizSpellText, P._wizSpellId = "", nil
    P._wizPowerSel, P._wizSlotSel = nil, "main"
    P._wizDispSel, P._wizMissingSel, P._wizWarnMin = nil, false, 0
    P._wizNameText, P._wizNameEdited = "", false
    P._wizSpecFilter = ns.specID   -- the spec-filter dropdown opens on your current spec
    P._wizSpecs = wizCurrentSpecs()
    P._wizFolderSel = nil
    P._wizCustom = false
    P._wizItemMode, P._wizItemId = false, nil
    if P._wizHubScroll then P._wizHubScroll:SetVerticalScroll(0) end
    RefreshWizard()
    P._wiz:Show()
end

function OPT.closeWizard()
    if P._wiz then P._wiz:Hide() end
end
