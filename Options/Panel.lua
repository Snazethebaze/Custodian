-- Options/Panel.lua : the custom settings window.
--
-- Hand-built, dark/modern styling (no AceGUI/AceConfig). Left = class/folder widget
-- list (add/duplicate/delete/select); right = tabbed live editor for the selected
-- widget (Trigger/Display/When/Group); sharing via import/export strings (Core/Share.lua).
-- Everything applies instantly. Opened via /cust.

local ADDON, ns = ...

-- ── UI toolkit ────────────────────────────────────────────────────────
-- The widgets live in Options/UIKit.lua (loaded first). Re-localized here so every
-- call site below — Button(...), EditBox(...), tweenAlpha(...), ACCENT, … — is
-- unchanged. Add a widget there, add one line here, use it anywhere in the panel.
local T = ns.Theme   -- styling knobs (Core/Theme.lua)
local UI = ns.UI
local ACCENT = UI.ACCENT
local border, bgTex, tweenAlpha = UI.border, UI.bgTex, UI.tweenAlpha
local Label, Button, Check, Slider, EditBox, Dropdown = UI.Label, UI.Button, UI.Check, UI.Slider, UI.EditBox, UI.Dropdown
local ColorSwatch, tip, spellTip = UI.ColorSwatch, UI.tip, UI.spellTip
local openPrompt = UI.openPrompt

-- ── Spell-result row ──────────────────────────────────────────────────
-- Every spell search/suggestion list is the same row: an accent-hover button with
-- a spell icon, a name label, and the game tooltip on hover. This was copy-pasted
-- four times (source search, reusable picker, wizard search, wizard suggestions);
-- these two helpers are the single source. The CALLER still owns pooling, where the
-- row is positioned, and the click handler — only the chrome + fill are shared.
--   opts: h (row height, 22) · iconX/textX (left insets, 3/26) · rightX (text right
--   inset, -4) · hover (highlight alpha, 0.25).
local function spellRow(parent, opts)
    opts = opts or {}
    local r = CreateFrame("Button", nil, parent); r:SetHeight(opts.h or 22)
    local hl = bgTex(r, ACCENT[1], ACCENT[2], ACCENT[3], 0); r._hl = hl
    r._icon = r:CreateTexture(nil, "ARTWORK")
    r._icon:SetPoint("LEFT", opts.iconX or 3, 0); r._icon:SetSize(18, 18); r._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r._f = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r._f:SetPoint("LEFT", opts.textX or 26, 0); r._f:SetPoint("RIGHT", opts.rightX or -4, 0); r._f:SetJustifyH("LEFT"); r._f:SetWordWrap(false)
    local a = opts.hover or 0.25
    r:SetScript("OnEnter", function() hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], a) end)
    r:SetScript("OnLeave", function() hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0) end)
    spellTip(r, function() return r._sid end)
    return r
end
-- Fill a row from a match { id, name, icon }. `showId` (default true) appends the
-- grey spell id; pass false for the suggestion list (name only).
local function fillSpellRow(r, m, showId)
    r._sid = m.id
    -- Prefer the match's icon; else look it up live from the id so every pick list shows
    -- the real spell art instead of the "?" placeholder.
    local icon = m.icon or (m.id and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(m.id))
    r._icon:SetTexture(icon or 134400)
    if showId == false then r._f:SetText(m.name)
    else r._f:SetText(("%s  |cff808080%d|r"):format(m.name, m.id)) end
end

-- ── Static option lists ───────────────────────────────────────────────
local FORMAT_OPTS = {
    { value = "valuemax", text = "Value / max" }, { value = "value", text = "Value" },
    { value = "percent", text = "Percent" }, { value = "valuepercent", text = "Value (%)" },
}
local function fmtText(v) for _, o in ipairs(FORMAT_OPTS) do if o.value == v then return o.text end end return "Value / max" end
-- Reminder glow styles. "Outline" / "Fill" are art-agnostic (any icon set);
-- "Button border" is the Blizzard action-button look (only suits that art).
local GLOW_OPTS = {
    { value = "outline", text = "Outline" }, { value = "border", text = "Button border" }, { value = "fill", text = "Fill flash" },
    -- native LibCustomGlow effects (the familiar Blizzard-style glows)
    { value = "pixel", text = "Pixel glow" }, { value = "autocast", text = "Autocast shine" },
    { value = "proc", text = "Proc glow" }, { value = "blizzard", text = "Blizzard glow" },
}
local function glowText(v) for _, o in ipairs(GLOW_OPTS) do if o.value == v then return o.text end end return "Outline" end
-- Text anchor: drop the value/countdown/stack text into a corner, edge or dead
-- centre without hand-tuning the X/Y nudge. The value is a WoW anchor point.
local ANCHOR_OPTS = {
    { value = "CENTER", text = "Center" },
    { value = "TOP", text = "Top" },       { value = "BOTTOM", text = "Bottom" },
    { value = "LEFT", text = "Left" },      { value = "RIGHT", text = "Right" },
    { value = "TOPLEFT", text = "Top-left" },       { value = "TOPRIGHT", text = "Top-right" },
    { value = "BOTTOMLEFT", text = "Bottom-left" }, { value = "BOTTOMRIGHT", text = "Bottom-right" },
}
local function anchorText(v) for _, o in ipairs(ANCHOR_OPTS) do if o.value == v then return o.text end end return "Center" end

-- One-line explainers shown under each section caption (keyed by the caption text),
-- so a glance tells you what a group of settings does without hovering everything.
local SUBDESC = {
    BASICS             = "Name this widget so it's easy to find in the list.",
    TRIGGER            = "What this widget shows — pick a kind, then the spell.",
    TEXT               = "The text on the widget: font, size, and where it sits.",
    HIGHLIGHT          = "The icon's glow — steady while active/ready, or a pulse while reminding.",
    FILL               = "The bar's colour and texture.",
    DISPLAY            = "Show the widget as a fill bar or a spell icon. Sliders: drag, or click the number to type.",
    ["BAR OPTIONS"]    = "Fill motion, and a glow when the bar reads full.",
    ["WHERE IT SHOWS"] = "Limit to certain specs — none lit means every spec.",
    GROUP              = "Detach this widget, or size/space it with the group it's in.",
    ARRANGING         = "Unlock the HUD to drag widgets together into a group and move them as one.",
    REMINDER           = "When the widget appears — a missing aura, a ready cooldown, or a value threshold.",
    MARKERS            = "Vertical lines on the bar at a value or a spell's cost.",
    ["COLOUR STOPS"]   = "Recolour the bar as it fills, and optionally ping you at a stop.",
}

-- ── Spec (multi-select) ───────────────────────────────────────────────
-- A widget shows on a SET of specs (cfg.specs); none selected = all specs. The
-- editor and wizard drive this with three toggle buttons instead of a single
-- pick, so one tracker can serve e.g. Elemental AND Enhancement without cloning.
-- The player's class specs (dynamic — Ele/Enh/Resto for a shaman, Arms/Fury/Prot for a
-- warrior, …). A function so it resolves against the live class, not a hardcoded list.
local function SPEC_LIST() return ns.ClassSpecs() end
-- Flip one spec in a config's (or any table's) specs set; an emptied set collapses
-- back to nil so "no toggles lit" always means the same thing as "all specs".
local function toggleSpecIn(owner, id)
    local s = owner.specs or {}
    if s[id] then s[id] = nil else s[id] = true end
    if not next(s) then s = nil end
    owner.specs = s
end

-- An ICON-ONLY spec toggle (the spec's own icon, desaturated when off) — works for any
-- class and any number of specs, no text-fitting. Full name shows on hover. onClick(id).
local function specToggle(parent, sp, onClick)
    local b = Button(parent, "", 26, 24)
    if b._fs then b._fs:SetText("") end
    local ic = b:CreateTexture(nil, "OVERLAY")
    ic:SetPoint("CENTER"); ic:SetSize(18, 18); ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local _, _, _, specIcon = GetSpecializationInfoByID(sp.id)
    ic:SetTexture(specIcon or 134400)
    b._icon = ic
    local origSetActive = b.SetActive
    b.SetActive = function(self, on) origSetActive(self, on); ic:SetDesaturated(not on) end
    ic:SetDesaturated(true)
    b:SetScript("OnClick", function() onClick(sp.id) end)
    return b
end

-- ── Reminder mode (source-agnostic) ───────────────────────────────────
-- A widget can be a reminder off ANY source: buff missing/active, cooldown ready/not,
-- or a readable value crossing a threshold. Mirrors Widget:ReminderVisible.
local REMINDER_LABEL = {
    off = "Off (always show)", missing = "When missing", active = "When active",
    ready = "When ready", notready = "While on cooldown",
    atLeast = "When stacks \226\137\165 N", atMost = "When stacks \226\137\164 N",
}
local function reminderText(mode) return REMINDER_LABEL[mode or "off"] or REMINDER_LABEL.off end

-- Imbue talent gate: show a reminder only when a talent IS (require) or ISN'T (suppress) taken,
-- so two reminders on one weapon slot (Flametongue vs oil, a Lightsmith Rite vs nothing) never
-- both nag. Stored as cfg.talentGate = { mode, spell }.
local GATE_OPTS = {
    { value = "off",      text = "Always show" },
    { value = "require",  text = "Only when talented" },
    { value = "suppress", text = "Hide when talented" },
}
local function gateModeText(m)
    for _, o in ipairs(GATE_OPTS) do if o.value == m then return o.text end end
    return GATE_OPTS[1].text
end
local function reminderMode(c) return (c.reminder and c.reminder.mode) or c.showWhen or "off" end
local function reminderOpts(isAura, isImbue, isCooldown, isThresholdable)
    local o = { { value = "off", text = REMINDER_LABEL.off } }
    if isAura or isImbue then
        o[#o + 1] = { value = "missing", text = REMINDER_LABEL.missing }
        if isAura then o[#o + 1] = { value = "active", text = REMINDER_LABEL.active } end
    end
    if isCooldown then
        o[#o + 1] = { value = "ready",    text = REMINDER_LABEL.ready }
        o[#o + 1] = { value = "notready", text = REMINDER_LABEL.notready }
    end
    if isThresholdable then
        o[#o + 1] = { value = "atLeast", text = REMINDER_LABEL.atLeast }
        o[#o + 1] = { value = "atMost",  text = REMINDER_LABEL.atMost }
    end
    return o
end

-- ── Folders (user-defined, optional) ──────────────────────────────────
-- Folders are pure organization, decoupled from spec: profile.folders is the
-- ordered source of truth for which folders exist (and their collapse state);
-- each widget's cfg.folder names its folder (nil = loose / top level). This is
-- the "you decide the shape" pillar — nothing is foldered for you.
local function trimStr(s) return (s or ""):match("^%s*(.-)%s*$") end
local function foldersList() return (ns.profile and ns.profile.folders) or {} end
local function findFolder(name)
    for _, f in ipairs(foldersList()) do if f.name == name then return f end end
end
local function ensureFolder(name)
    name = trimStr(name)
    if name == "" then return nil end
    if not findFolder(name) then table.insert(ns.profile.folders, { name = name, collapsed = true }) end   -- new folders start collapsed
    return name
end
local function deleteFolder(name)
    local fl = ns.profile.folders
    for i, f in ipairs(fl) do if f.name == name then table.remove(fl, i); break end end
    for _, c in pairs(ns.profile.widgets) do if c.folder == name then c.folder = nil end end
end
local function renameFolder(old, new)
    new = trimStr(new)
    if new == "" or new == old then return end
    if findFolder(new) then   -- target exists -> merge old's widgets into it
        for i, f in ipairs(ns.profile.folders) do if f.name == old then table.remove(ns.profile.folders, i); break end end
    else
        local f = findFolder(old)
        if f then f.name = new else ensureFolder(new) end
    end
    for _, c in pairs(ns.profile.widgets) do if c.folder == old then c.folder = new end end
end
-- Folder options scoped to a CLASS: only folders that already hold a widget of that class
-- (plus `current`, always, so the selection shows). Keeps a widget from being filed into
-- another class's folder — matching the class-grouped sidebar + the row Move-to menu.
local function folderOptsFor(classToken, current)
    local used = {}
    for _, w in pairs(ns.profile.widgets) do
        if w.folder and w.folder ~= "" and ns.ClassOfCfg(w) == classToken then used[w.folder] = true end
    end
    if current and current ~= "" then used[current] = true end
    local t = { { value = "", text = "(No folder)" } }
    for _, f in ipairs(foldersList()) do if used[f.name] then t[#t + 1] = { value = f.name, text = f.name } end end
    t[#t + 1] = { value = "__newfolder__", text = "+ New folder" }
    return t
end

-- Folder-name and TTS-text prompts now use our own in-style composer (openPrompt),
-- not Blizzard's StaticPopup (which pops centre-screen and doesn't match the panel).
local function promptFolderName(initial, onAccept)
    openPrompt({ title = "Folder name", initial = initial, onAccept = onAccept })
end
local function promptTTS(initial, onAccept)
    openPrompt({ title = "Speak this at the threshold", initial = initial, onAccept = onAccept })
end

-- Toggle an optional sub-config (colorCurve, split, …) on/off WITHOUT losing the
-- user's tuning: switching OFF stashes it under `_kept_<key>` (so re-enabling
-- restores exactly what they had, not factory defaults); switching ON restores the
-- stash, or builds a default via mk() the first time. A separate Reset button
-- calls mk() to go back to defaults on purpose. This is the standard everywhere so
-- a stray click never wipes work.
local function toggleCfg(c, key, on, mk)
    local stash = "_kept_" .. key
    if on then
        c[key] = c[key] or c[stash] or (mk and mk())
        c[stash] = nil
    else
        if c[key] then c[stash] = c[key] end
        c[key] = nil
    end
end

-- Factory for the default "colour by fill" ramp (red -> yellow -> green).
local function defaultCurve()
    local pts = (ns.ColorCurve and ns.ColorCurve.DefaultPoints and ns.ColorCurve.DefaultPoints()) or {
        { pct = 0.0, color = { r = 0.85, g = 0.20, b = 0.20 } },
        { pct = 0.5, color = { r = 0.95, g = 0.85, b = 0.25 } },
        { pct = 1.0, color = { r = 0.30, g = 0.85, b = 0.40 } },
    }
    return { type = "Linear", points = pts }
end
-- "HOLY_POWER" -> "Holy Power" for the resource dropdown (value stays the raw key).
local function prettyPower(k) return ns.PrettyPowerName(k) or k end
-- Which resources each class can actually use comes from ns.Maintenance[class].resources
-- (Core/Maintenance.lua) — so a Shaman's Resource dropdown lists Mana / Maelstrom, not every
-- class's power. Keys match the Trackers/Power.lua POWER map; an unmapped class falls back
-- to the full list.
local function powerOpts()
    local t = {}
    local kit = ns.Maintenance and ns.Maintenance[ns.playerClass]
    local allow = kit and kit.resources
    if allow then
        for _, k in ipairs(allow) do if k == "PRIMARY" or (ns.PowerTypes and ns.PowerTypes[k]) then t[#t + 1] = { value = k, text = prettyPower(k) } end end
    elseif ns.PowerTypes then
        for k in pairs(ns.PowerTypes) do t[#t + 1] = { value = k, text = prettyPower(k) } end
    end
    table.sort(t, function(a, b) return a.text < b.text end)
    return t
end
-- Pet-summon picker options for a pet reminder: Hunter = the 5 Call Pet stable slots (static
-- ids; the beast in each slot is dynamic), Warlock = the demon summons the character knows.
-- The picked id becomes tr.spellID (the icon + the click-to-cast summon). nil for other classes
-- (Mage's Water Elemental is the only summon, so no choice).
local HUNTER_CALLPET = { 883, 83242, 83243, 83244, 83245 }
local WARLOCK_DEMONS = { 688, 697, 691, 366222, 30146 }   -- Imp / Voidwalker / Felhunter / Sayaad / Felguard
local function petSummonOpts(class)
    local ids = (class == "HUNTER" and HUNTER_CALLPET) or (class == "WARLOCK" and WARLOCK_DEMONS) or nil
    if not ids then return nil end
    local t = {}
    for i, id in ipairs(ids) do
        -- Hunter shows all 5 slots; Warlock only the demons this character has learned.
        if class == "HUNTER" or ns.SpellTaken(id) then
            local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
            local text = nm or tostring(id)
            -- Hunter: append the beast in this Call Pet slot ("Call Pet 1 — FeroBoy"); an
            -- empty slot (no name) just keeps the plain slot label.
            if class == "HUNTER" then
                local pet = ns.CallPetName and ns.CallPetName(i)
                if pet then text = text .. " \226\128\148 " .. pet end
            end
            t[#t + 1] = { value = id, text = text }
        end
    end
    return t
end
local function mediaOpts(hash)   -- LSM HashTable (name->name) -> dropdown items
    local t = {}
    if hash then for k in pairs(hash) do t[#t + 1] = { value = k, text = k } end end
    table.sort(t, function(a, b) return a.text < b.text end)
    return t
end

-- ── Class-flavoured copy ──────────────────────────────────────────────
-- Examples in the wizard/tooltips read for the class you're actually on (class is fixed
-- per session). `aura`/`res`/`imbue` = short example lists · `def` = a combat-hidden
-- defensive · `groupbuff` = a raid-wide buff · `learned` = an untalented-spell example ·
-- `spender` = a resource spender (for markers). Missing fields fall back to a generic.
local CLASS_EX = {
    WARRIOR     = { aura = "Shield Block, Enrage, Ignore Pain", res = "Rage", def = "Shield Wall", groupbuff = "Battle Shout", learned = "a stance/talent you're not in", spender = "Execute" },
    PALADIN     = { aura = "Shield of the Righteous, Avenging Wrath", res = "Holy Power / Mana", def = "Divine Shield", groupbuff = "a Blessing / aura", learned = "a spell from another spec", spender = "Templar's Verdict" },
    HUNTER      = { aura = "Aspects, Bestial Wrath, Trueshot", res = "Focus", def = "Aspect of the Turtle", groupbuff = "a hunter aura", learned = "a pet/spec ability you lack", spender = "Kill Command" },
    ROGUE       = { aura = "Slice and Dice, Stealth, Adrenaline Rush", res = "Energy / Combo Points", imbue = "poisons (Instant / Deadly)", def = "Cloak of Shadows", groupbuff = "Tricks of the Trade", learned = "a poison you haven't applied", spender = "Eviscerate" },
    PRIEST      = { aura = "Power Word: Shield, Shadowform", res = "Mana / Insanity", def = "Dispersion", groupbuff = "Power Word: Fortitude", learned = "a spell from another spec", spender = "Devouring Plague" },
    DEATHKNIGHT = { aura = "Bone Shield, Dancing Rune Weapon", res = "Runes / Runic Power", def = "Icebound Fortitude", groupbuff = "an Anti-Magic aura", learned = "a spec ability you lack", spender = "Death Coil / Frost Strike" },
    SHAMAN      = { aura = "Lightning Shield, Maelstrom Weapon", res = "Maelstrom / Mana", imbue = "Windfury / Flametongue Weapon", def = "Astral Shift", groupbuff = "Skyfury", learned = "Flametongue Weapon on an Elemental build", spender = "Earth Shock / Elemental Blast" },
    MAGE        = { aura = "Ice Barrier, Icy Veins, Combustion", res = "Mana / Arcane Charges", def = "Ice Block", groupbuff = "Arcane Intellect", learned = "a spell from another spec", spender = "Arcane Blast" },
    WARLOCK     = { aura = "Demon Skin, Unending Resolve", res = "Mana / Soul Shards", def = "Unending Resolve", groupbuff = "a Soulstone / summon", learned = "a spec ability you lack", spender = "Chaos Bolt / Soul-spender" },
    MONK        = { aura = "Shuffle, Storm/Earth/Fire", res = "Energy / Chi / Mana", def = "Fortifying Brew", groupbuff = "Mystic Touch", learned = "a stance/spec ability you lack", spender = "Blackout Kick" },
    DRUID       = { aura = "Ironfur, Savage Roar, a Form", res = "Astral Power / Combo Points / Rage / Energy", def = "Barkskin", groupbuff = "Mark of the Wild", learned = "a form/spec ability you lack", spender = "Ferocious Bite" },
    DEMONHUNTER = { aura = "Demon Spikes, Metamorphosis", res = "Fury / Pain", def = "Blur", groupbuff = "a Demon Hunter aura", learned = "a spec ability you lack", spender = "Chaos Strike" },
    EVOKER      = { aura = "Blessing of the Bronze, Essence Burst", res = "Essence / Mana", def = "Obsidian Scales", groupbuff = "Blessing of the Bronze", learned = "a spec ability you lack", spender = "Disintegrate / Pyre" },
}
local EX_GENERIC = { aura = "a shield, buff, or proc", res = "your resource", imbue = "Oils, stones, or poisons", def = "a defensive cooldown", groupbuff = "a raid-wide buff", learned = "an untalented spell", spender = "a spender" }
local function classEx(field)
    local c = CLASS_EX[ns.playerClass]
    return (c and c[field]) or EX_GENERIC[field]
end

-- ── Panel ─────────────────────────────────────────────────────────────
-- ns.OPT is the seam between this file and its satellites (PanelDialogs.lua, …). It replaces
-- the old forward-declared locals: a satellite defines its entry points as OPT.<name> and this
-- file calls them as OPT.<name>(). Everything is resolved at CALL time (from UI callbacks, all
-- post-build), so load order can't bite — the satellites only need ns.OPT to exist, which is
-- why they load after this file. OPT.P is the panel frame, published by build() below.
local OPT = {}
ns.OPT = OPT

-- Satellites keep their own file-local `P` rather than threading OPT.P through hundreds of
-- call sites: each registers a binder at load, and build() runs them the moment the panel
-- frame exists. The frame is created exactly once (OpenOptions guards with `if not P`), so a
-- one-time bind is enough, and every satellite function is reachable only from panel UI —
-- i.e. always after build().
OPT.binders = {}
function OPT.OnBind(fn) OPT.binders[#OPT.binders + 1] = fn end

local P
local function curCfg() return P and P.selectedId and ns.profile.widgets[P.selectedId] end

local function applyStyle(id)
    local w = ns.widgets[id]
    if w then w:ApplyStyle() end
    ns.Trackers.Refresh()
end
local function applyStructural()
    ns.Layout.Rebuild(); ns.Trackers.Rebuild()
end

-- Helpers shared with the satellites (Options/Wizard.lua, …) via the ns.OPT seam. Everything
-- above this line is a plain file-local; these are the ones another file legitimately needs.
OPT.SPEC_LIST, OPT.specToggle          = SPEC_LIST, specToggle
OPT.spellRow, OPT.fillSpellRow         = spellRow, fillSpellRow
OPT.trimStr                            = trimStr
OPT.ensureFolder, OPT.folderOptsFor    = ensureFolder, folderOptsFor
OPT.promptFolderName                   = promptFolderName
OPT.foldersList, OPT.findFolder        = foldersList, findFolder
OPT.deleteFolder, OPT.renameFolder     = deleteFolder, renameFolder
OPT.prettyPower, OPT.powerOpts         = prettyPower, powerOpts
OPT.classEx, OPT.applyStructural       = classEx, applyStructural
OPT.curCfg, OPT.applyStyle             = curCfg, applyStyle
-- Static option lists + their label resolvers: build() wires the controls, the editor
-- (Options/PanelEditor.lua) re-reads them when it stacks a widget's rows.
OPT.SUBDESC, OPT.GATE_OPTS, OPT.GLOW_OPTS = SUBDESC, GATE_OPTS, GLOW_OPTS
OPT.fmtText, OPT.glowText, OPT.anchorText = fmtText, glowText, anchorText
OPT.reminderText, OPT.gateModeText     = reminderText, gateModeText
OPT.reminderMode, OPT.reminderOpts     = reminderMode, reminderOpts
OPT.promptTTS                          = promptTTS
OPT.petSummonOpts, OPT.mediaOpts       = petSummonOpts, mediaOpts

-- The widget's OWN data source, edited in place. Copy-on-write: if the tracker is
-- shared with another widget (legacy), fork a private copy first so an edit here
-- never bleeds onto another widget; create one if the widget has none. This is what
-- lets the editor treat "what this shows" as a property OF the widget, so you can't
-- point Lightning Shield at Flametongue by accident.
local function ownTracker(c)
    if not c then return nil end
    local trs = ns.profile.trackers
    local tr = c.trackerId and trs[c.trackerId]
    if tr then
        for _, wc in pairs(ns.profile.widgets) do
            if wc ~= c and wc.trackerId == c.trackerId then      -- shared -> fork
                c.trackerId = ns.AddTracker(CopyTable(tr))
                return trs[c.trackerId]
            end
        end
        return tr
    end
    c.trackerId = ns.AddTracker({ type = "aura", unit = "player" })
    return trs[c.trackerId]
end

-- ── Connected-group helpers ───────────────────────────────────────────
-- A "group" is now an explicit object (Core/Groups.lua). These editor helpers resize /
-- space every member at once (so you don't open all four icons to change one shared
-- property). Members come from the group's order; standalone widgets are a group of one.
local function groupMemberIds(id)
    local W = ns.profile and ns.profile.widgets
    local c = W and W[id]
    local gid = c and ns.Groups and ns.Groups.GidOf(c)
    if not gid then return { id }, nil end
    return ns.Groups.Order(gid), gid
end
local function setGroupSize(v)
    for _, wid in ipairs(groupMemberIds(P.selectedId)) do
        local cfg = ns.profile.widgets[wid]
        if cfg and cfg.display == "icon" then
            cfg.width, cfg.height = v, v
            cfg._sizeByDisplay = cfg._sizeByDisplay or {}
            cfg._sizeByDisplay.icon = { v, v }   -- keep per-display memory in sync
            if ns.widgets[wid] then ns.widgets[wid]:ApplyStyle() end
        end
    end
    ns.Layout.Resolve()
end
local function setGroupGap(v)
    local _, gid = groupMemberIds(P.selectedId)
    local grp = gid and ns.Groups.Get(gid)
    if grp then grp.gap = (v and v > 0) and v or 0 end
    ns.Layout.Resolve()
end

-- Group slide direction: horizontal (default) or vertical. New groups are always horizontal;
-- this is the only place to switch a group to a vertical stack.
local function setGroupAxis(axis)
    local _, gid = groupMemberIds(P.selectedId)
    local grp = gid and ns.Groups.Get(gid)
    if grp then grp.axis = (axis == "v") and "v" or "h" end
    ns.Layout.Resolve()
end

-- Bars can share a WIDTH and/or HEIGHT across a group (icons share their square size).
-- grp.share = { w=bool, h=bool } picks which dims the group governs; a fresh bar group
-- defaults to width-shared, height-independent. Returns shareW, shareH.
local function groupShare(grp)
    local s = grp and grp.share
    if s then return s.w and true or false, s.h and true or false end
    return true, false
end
-- A representative bar member's current width/height, for the group slider readout.
local function firstBarDim(groupIds, dim)
    for _, wid in ipairs(groupIds) do
        local w = ns.profile.widgets[wid]
        if w and w.display == "bar" then return (dim == "w") and (w.width or 240) or (w.height or 26) end
    end
    return (dim == "w") and 240 or 26
end
local function setGroupBarDim(dim, v)
    for _, wid in ipairs(groupMemberIds(P.selectedId)) do
        local cfg = ns.profile.widgets[wid]
        if cfg and cfg.display == "bar" then
            if dim == "w" then cfg.width = v else cfg.height = v end
            cfg._sizeByDisplay = cfg._sizeByDisplay or {}
            local bd = cfg._sizeByDisplay.bar or { cfg.width or 240, cfg.height or 26 }
            bd[1], bd[2] = cfg.width or bd[1], cfg.height or bd[2]
            cfg._sizeByDisplay.bar = bd
            if ns.widgets[wid] then ns.widgets[wid]:ApplyStyle() end
        end
    end
    ns.Layout.Resolve()
end
-- Toggle whether the group governs a bar dimension. Turning it ON unifies every bar
-- member to the selected widget's current value, so "shared" holds immediately.
local function setGroupShareDim(dim, on)
    local _, gid = groupMemberIds(P.selectedId)
    local grp = gid and ns.Groups.Get(gid)
    if not grp then return end
    grp.share = grp.share or {}
    grp.share[dim] = on or nil
    if on then
        local c = ns.profile.widgets[P.selectedId]
        local v = c and c.display == "bar" and ((dim == "w") and c.width or c.height)
        if not v then v = firstBarDim(ns.Groups.Order(gid), dim) end
        if v then setGroupBarDim(dim, v) end
    end
    ns.Layout.Resolve()
end

-- Icon art for a widget's sidebar row: the tracked spell's texture (aura / imbue /
-- cooldown). Returns tex, unlearned — power bars have no spell art (nil).
local function widgetIcon(c)
    if not c then return nil end
    local tr = ns.TrackerOf(c)
    if not tr then return nil end
    -- Item-based reminders (oil / augment rune) show the ITEM icon — same priority as the HUD.
    local iic = ns.ItemIcon(tr.itemID)
    if iic then return iic, false end
    local sid = tr.spellID
    if sid and C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(sid), (not ns.SpellKnown(sid))
    end
    -- A generic "empty" imbue falls back to the equipped weapon's icon, matching the HUD.
    if tr.type == "imbue" and GetInventoryItemTexture then
        local tex = GetInventoryItemTexture("player", (tr.slot == "off") and 17 or 16)
        if tex then return tex, false end
    end
    return nil
end
OPT.widgetIcon = widgetIcon   -- the sidebar rows draw the same icon (Options/PanelList.lua)

-- Resolve a spell NAME to its id (exact-name match preferred, else the top hit) — used by the
-- aura-variant picker (Paladin Devotion / Concentration) to set the tracked spell from a name.
local function resolveSpellByName(name)
    if not name then return nil end
    local matches = ns.SearchSpells(name, 4) or {}
    for _, s in ipairs(matches) do if s.name == name then return s.id end end
    return matches[1] and matches[1].id
end

-- ── Per-display size memory ───────────────────────────────────────────
-- Bar and Icon keep their OWN width/height. Editing size stashes it under the
-- current display; swapping display restores that display's remembered size (or a
-- sensible default) instead of carrying the other one's dimensions across.
local DISPLAY_DEFAULT_SIZE = { bar = { 240, 26 }, icon = { 40, 40 } }
local function setDisplayMemory(c)
    if not c or not c.display then return end
    c._sizeByDisplay = c._sizeByDisplay or {}
    c._sizeByDisplay[c.display] = { c.width, c.height }
end
local function swapDisplay(c, newDisplay)
    if not c or c.display == newDisplay then return end
    setDisplayMemory(c)                              -- remember the outgoing display
    c.display = newDisplay
    local mem = c._sizeByDisplay and c._sizeByDisplay[newDisplay]
    local def = DISPLAY_DEFAULT_SIZE[newDisplay]
    c.width  = (mem and mem[1]) or (def and def[1]) or c.width
    c.height = (mem and mem[2]) or (def and def[2]) or c.height
end


-- The rest of the editor's shared surface (declared further down than the block above).
OPT.groupMemberIds, OPT.groupShare = groupMemberIds, groupShare
OPT.firstBarDim = firstBarDim


local function build()
    P = CreateFrame("Frame", "Custodian_Options", UIParent)
    OPT.P = P   -- publish before anything else builds, then let the satellites bind it
    for _, bind in ipairs(OPT.binders) do bind(P) end
    P:SetSize(750, 590); P:SetPoint("CENTER"); P:SetFrameStrata("HIGH")
    P:SetClampedToScreen(true); P:EnableMouse(true); P:SetMovable(true); P:Hide()
    bgTex(P, T.rgba(T.surface.window)); border(P)

    -- Header
    local header = CreateFrame("Button", nil, P)
    header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT"); header:SetHeight(38)
    bgTex(header, T.rgba(T.surface.header))
    local hline = header:CreateTexture(nil, "ARTWORK"); hline:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.5)
    hline:SetPoint("BOTTOMLEFT"); hline:SetPoint("BOTTOMRIGHT"); hline:SetHeight(2)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() P:StartMoving() end)
    header:SetScript("OnDragStop", function() P:StopMovingOrSizing() end)
    local logo = header:CreateTexture(nil, "ARTWORK"); logo:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3]); logo:SetSize(4, 18); logo:SetPoint("LEFT", 10, 0)
    local title = Label(header, "|cff4aa8ffCustodian|r Settings", "GameFontNormalLarge")
    title:SetPoint("LEFT", logo, "RIGHT", 9, 0)

    local close = Button(header, "X", 24, 22); close:SetPoint("RIGHT", -8, 0)
    close:SetScript("OnClick", function() P:Hide() end)

    local moveBtn = Button(header, "Move HUD", 90, 22); moveBtn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    moveBtn:SetScript("OnClick", function()
        local on = not (ns.profile and ns.profile.unlocked)
        ns.Layout.SetUnlocked(on)
        moveBtn:SetActive(on); moveBtn._fs:SetText(on and "Lock HUD" or "Move HUD")
    end)
    tip(moveBtn, "Move HUD", "Unlock the HUD to drag widgets into place. Drop one onto another to group them; drag a group's title tab to move it as one. Lock HUD when you're done.")
    P._moveBtn = moveBtn

    -- Home: back to the landing page (no widget selected). The panel opens here rather than
    -- diving straight into the first widget's settings.
    local homeBtn = Button(header, "Home", 58, 22); homeBtn:SetPoint("RIGHT", moveBtn, "LEFT", -8, 0)
    homeBtn:SetScript("OnClick", function() P.selectedId = nil; OPT.RefreshList(); OPT.RefreshEditor() end)
    tip(homeBtn, "Home", "Back to the start page.")
    P._homeBtn = homeBtn

    -- Left: widget list — a SCROLL viewport (rows can outgrow the box). `list` is the
    -- outer frame (border + button anchor); rows live on the scroll child `P._list`.
    local list = CreateFrame("Frame", nil, P)
    list:SetPoint("TOPLEFT", 14, -44); list:SetSize(205, 394)
    bgTex(list, T.rgba(T.surface.panel)); border(list)
    local listView = CreateFrame("ScrollFrame", nil, list)
    listView:SetPoint("TOPLEFT", 1, -1); listView:SetPoint("BOTTOMRIGHT", -1, 1)
    listView:SetClipsChildren(true)
    local listChild = CreateFrame("Frame", nil, listView)
    listChild:SetSize(203, 10)
    listView:SetScrollChild(listChild)
    P._list = listChild; P._listView = listView; P._listRows = {}

    -- Interactive scrollbar (draggable thumb + click-to-jump track), shown only on
    -- overflow. Hosted on `list` (outside the clipping viewport).
    local listMax = function() return math.max(0, listChild:GetHeight() - listView:GetHeight()) end
    P._listUpdateScrollbar = ns.UI.MakeScrollbar(list, listView, {
        getMax = listMax,
        get    = function() return listView:GetVerticalScroll() end,
        set    = function(v) listView:SetVerticalScroll(math.max(0, math.min(listMax(), v))) end,
        frac   = function() local h = listChild:GetHeight(); return (h > 0) and (listView:GetHeight() / h) or 1 end,
    })
    listView:EnableMouseWheel(true)
    listView:SetScript("OnMouseWheel", function(_, delta)
        listView:SetVerticalScroll(math.max(0, math.min(listMax(), listView:GetVerticalScroll() - delta * 44)))
        P._listUpdateScrollbar()
    end)

    -- Generic right-click context menu (folder headers: Rename/Delete · widget rows:
    -- Move to folder), rows built on demand by showContextMenu. A full-screen
    -- click-eater dismisses it on any outside click.
    local eater = CreateFrame("Button", nil, P)
    eater:SetFrameStrata("FULLSCREEN"); eater:SetAllPoints(UIParent); eater:Hide()
    P._menuEater = eater
    local cm = CreateFrame("Frame", nil, P); cm:SetSize(150, 20)
    cm:SetFrameStrata("FULLSCREEN_DIALOG"); cm:EnableMouse(true); cm:Hide()
    bgTex(cm, T.rgba(T.surface.panel)); border(cm)
    P._ctxMenu, P._ctxRows = cm, {}
    cm:SetScript("OnHide", function() eater:Hide() end)
    eater:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    eater:SetScript("OnClick", function(_, button)
        cm:Hide()
        -- Right-click while a menu is open: re-target to whichever sidebar row is under the cursor,
        -- so you can hop between rows without first closing the menu. Left-click just dismisses.
        if button == "RightButton" and P._listRows then
            for _, r in ipairs(P._listRows) do
                if r:IsShown() and r._ctxOpen and r:IsMouseOver() then r._ctxOpen(); break end
            end
        end
    end)

    -- The single way to add a widget: the guided flow (it covers Bar/Icon, resource /
    -- aura / imbue, and the class presets). Per-item actions — duplicate, delete, move to
    -- a folder — live on each row's right-click menu (see showWidgetMenu), not as buttons.
    local guided = Button(P, "+ Add widget", 205, 24)
    guided:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -6)
    guided:SetActive(true)   -- primary action: accent-lit so it reads as the main way in
    guided:SetScript("OnClick", function() OPT.openWizard() end)

    -- Make an (empty) folder up front; assign widgets to it from their right-click menu.
    local newFolder = Button(P, "+ New folder", 205, 20)
    newFolder:SetPoint("TOPLEFT", guided, "BOTTOMLEFT", 0, -6)
    newFolder:SetScript("OnClick", function()
        promptFolderName("", function(name) if ensureFolder(name) then OPT.RefreshList() end end)
    end)

    -- Import a shared string · Export all of THIS character's widgets. (Per-item / folder /
    -- class export also lives on each row/header's right-click menu.)
    local importBtn = Button(P, "Import…", 86, 20)
    importBtn:SetPoint("TOPLEFT", newFolder, "BOTTOMLEFT", 0, -6)
    importBtn:SetScript("OnClick", function() OPT.openShareImport() end)
    tip(importBtn, "Import", "Paste a string someone shared to add their widgets (with trackers, groups and folder) to your setup. Nothing is overwritten.")
    local exportBtn = Button(P, "Export all", 86, 20)
    exportBtn:SetPoint("LEFT", importBtn, "RIGHT", 3, 0)
    exportBtn:SetScript("OnClick", function()
        local mine = {}
        for _, id in ipairs(ns.profile.order) do
            local c = ns.profile.widgets[id]
            local cls = c and ns.ClassOfCfg(c)
            if c and (cls == nil or cls == ns.playerClass) then mine[#mine + 1] = id end
        end
        if #mine == 0 then ns.Print("Nothing to export."); return end
        OPT.openShareExport(ns.Share.EncodeWidgets(mine, "class", ns.ClassName(ns.playerClass)), ns.ClassName(ns.playerClass))
    end)
    tip(exportBtn, "Export all", "Export every widget on this character (its class + shared) to one string. Or export a single row / folder / class from its right-click menu.")

    -- (The shaman "keep 2 Earth Shields up" helper lives inside the guided wizard as a
    -- class special — see ns.Maintenance[class].specials / the wizard hub — not a sidebar button.)

    -- Right: editor. Controls are created here and STORED; RefreshEditor stacks
    -- the ones relevant to the selected widget top-to-bottom, so hidden rows
    -- collapse instead of leaving gaps (options differ per display / tracker).
    --
    -- The pane is a SCROLL VIEWPORT: `ed` (the scroll child) holds every control, so
    -- a tall widget's options scroll within the window instead of spilling past it.
    -- Controls still parent to `ed` and stack by y exactly as before — no per-control
    -- change needed. Dropdown popups parent to UIParent so they float above the clip.
    local edView = CreateFrame("ScrollFrame", nil, P)
    edView:SetPoint("TOPLEFT", 230, -104); edView:SetPoint("BOTTOMRIGHT", -14, 14)   -- top clears the fixed title + tab bar; bottom reclaims the old profile-bar space
    edView:SetClipsChildren(true)   -- content past the viewport is clipped, not spilled
    bgTex(edView, T.rgba(T.surface.panel)); border(edView)
    P._edView = edView
    local ed = CreateFrame("Frame", nil, edView)
    ed:SetSize(492, 10)   -- width fixed (content is left-stacked); height grows per refresh
    edView:SetScrollChild(ed)
    P._ed = ed

    -- Interactive scrollbar (draggable thumb + click-to-jump track), shown only on
    -- overflow. Hosted on P (outside the clipping viewport) so it isn't scrolled away.
    local edMax = function() return math.max(0, ed:GetHeight() - edView:GetHeight()) end
    P._edUpdateScrollbar = ns.UI.MakeScrollbar(P, edView, {
        getMax = edMax,
        get    = function() return edView:GetVerticalScroll() end,
        set    = function(v) edView:SetVerticalScroll(math.max(0, math.min(edMax(), v))) end,
        frac   = function() local h = ed:GetHeight(); return (h > 0) and (edView:GetHeight() / h) or 1 end,
    })
    edView:EnableMouseWheel(true)
    edView:SetScript("OnMouseWheel", function(_, delta)
        edView:SetVerticalScroll(math.max(0, math.min(edMax(), edView:GetVerticalScroll() - delta * 44)))
        P._edUpdateScrollbar()
    end)

    -- Fixed editor header: the "Edit: <name>" title + a tab bar, parented to P (not
    -- the scroll child) so the tabs stay put while the active tab's options scroll.
    P._edTitle = Label(P, "", "GameFontNormal")
    P._edTitle:SetPoint("TOPLEFT", 236, -52)

    P._tab = P._tab or "trigger"
    P._tabBtns = {}
    local TABS = { { k = "trigger", t = "Trigger" }, { k = "display", t = "Display" }, { k = "when", t = "When" }, { k = "layout", t = "Group" } }
    local tabX = 230
    for _, tb in ipairs(TABS) do
        local btn = Button(P, tb.t, 120, 24); btn:SetPoint("TOPLEFT", tabX, -74)
        btn:SetScript("OnClick", function()
            P._tab = tb.k
            if P._edView then P._edView:SetVerticalScroll(0) end
            OPT.RefreshEditor()
        end)
        P._tabBtns[tb.k] = btn
        tabX = tabX + 124
    end

    -- Home / start page: a neutral landing shown when no widget is selected (how the panel
    -- opens), so you don't drop straight into editing the first widget. Overlays the whole
    -- editor area — title, tabs and controls hide behind it. RefreshEditor toggles it.
    local home = CreateFrame("Frame", nil, P)
    home:SetPoint("TOPLEFT", 230, -52); home:SetPoint("BOTTOMRIGHT", -14, 14)
    home:SetFrameLevel(P:GetFrameLevel() + 8)
    bgTex(home, T.rgba(T.surface.panel)); border(home)
    P._home = home

    local hLogo = home:CreateTexture(nil, "ARTWORK"); hLogo:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3]); hLogo:SetSize(4, 26); hLogo:SetPoint("TOPLEFT", 24, -28)
    local hTitle = Label(home, "|cff4aa8ffCustodian|r", "GameFontNormalLarge"); hTitle:SetPoint("LEFT", hLogo, "RIGHT", 12, 0)
    P._homeTitle = hTitle
    local hSub = Label(home, "", "GameFontHighlightSmall"); hSub:SetPoint("TOPLEFT", hLogo, "BOTTOMLEFT", -4, -14); hSub:SetPoint("RIGHT", home, "RIGHT", -24, 0); hSub:SetJustifyH("LEFT")
    hSub:SetText("Your at-a-glance HUD: resource bars, buff and imbue reminders, and pre-combat checks — tuned per class and spec.")
    P._homeSub = hSub

    -- Primary action: add a tracker (straight into the guided hub).
    local addBtn = Button(home, "+  Add widget", 200, 30); addBtn:SetPoint("TOPLEFT", hSub, "BOTTOMLEFT", 4, -22)
    addBtn:SetActive(true); addBtn:SetScript("OnClick", function() OPT.openWizard() end)
    -- Secondary: toggle Move HUD from here too (the common next step after adding).
    local moveHome = Button(home, "Move HUD", 120, 30); moveHome:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    moveHome:SetScript("OnClick", function()
        local on = not (ns.profile and ns.profile.unlocked)
        ns.Layout.SetUnlocked(on)
        OPT.RefreshEditor()   -- refresh both move buttons' labels
    end)
    P._homeMove = moveHome

    -- A short "what you have" summary, filled by RefreshEditor (counts + a nudge to the list).
    local hStat = Label(home, "", "GameFontDisable"); hStat:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", -4, -26); hStat:SetPoint("RIGHT", home, "RIGHT", -24, 0); hStat:SetJustifyH("LEFT")
    hStat:SetSpacing(4)
    P._homeStat = hStat

    -- "How it works": the three ways Custodian tracks things, so the live / pre-combat / manual
    -- distinction (which shapes what a reminder can and can't do) is explained where you land.
    local hHowLogo = home:CreateTexture(nil, "ARTWORK"); hHowLogo:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3])
    hHowLogo:SetSize(3, 14); hHowLogo:SetPoint("TOPLEFT", hStat, "BOTTOMLEFT", 4, -26)
    local hHowTitle = Label(home, "HOW IT WORKS", "GameFontNormalSmall"); hHowTitle:SetPoint("LEFT", hHowLogo, "RIGHT", 8, 0); hHowTitle:SetTextColor(T.rgba(T.text.label))
    local hHow = home:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hHow:SetPoint("TOPLEFT", hHowLogo, "BOTTOMLEFT", -4, -10); hHow:SetPoint("RIGHT", home, "RIGHT", -24, 0)
    hHow:SetJustifyH("LEFT"); hHow:SetJustifyV("TOP"); hHow:SetWordWrap(true); hHow:SetSpacing(5)
    hHow:SetText(
        "Custodian watches what you're meant to keep up, three ways:\n\n"
        .. "|cffffd100Live|r — resources, buffs and cooldowns it can read moment to moment. Bars fill, timers tick, and a reminder clears the instant the buff lands.\n\n"
        .. "|cffffd100Pre-combat|r — some things (weapon imbues, poisons, shields) become hidden from addons once you're in combat. Custodian checks them BEFORE the pull and reminds you to top up; in a fight it holds quietly instead of nagging about something it can no longer see.\n\n"
        .. "|cffffd100Manual (estimated)|r — a few stacks can't be read at all, so it estimates by watching your casts (a builder adds one, a spender removes one). Right in the common case, resets when you leave combat, and can drift — treat it as a guide, not gospel.")

    local hContact = Label(home, "", "GameFontHighlightSmall")
    hContact:SetPoint("TOPLEFT", hHow, "BOTTOMLEFT", 0, -16); hContact:SetJustifyH("LEFT")
    hContact:SetText("|cff8fbfe0Questions or ideas?|r  Discord: |cffffffffSnazethebaze|r")

    P._esNote  = Label(ed, "|cff888888No reminder options for this widget.|r")   -- default note; repurposed as the Earth Shield group hint below
    P._lblSlot    = Label(ed, "Weapon")   -- imbue: which weapon (was "On" — collided with "Show on")
    P._subCaps    = {}                -- pool of in-tab sub-captions (makeSubCap)

    -- Manual-tracker caution: a wrapping banner on the Trigger tab of an estimated counter.
    P._manualWarn = ed:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P._manualWarn:SetJustifyH("LEFT"); P._manualWarn:SetJustifyV("TOP"); P._manualWarn:SetWordWrap(true)
    P._manualWarn:SetSpacing(3); P._manualWarn:SetWidth(456)

    -- GENERAL
    P._lblName = Label(ed, "Name")
    P._name = EditBox(ed, 200, function(t) local c = curCfg(); if c then c.name = t; applyStyle(P.selectedId); OPT.RefreshList() end end)

    P._lblTracks = Label(ed, "Trigger")   -- the inline kind+spell source editor renders under this
    -- Show-on specs: toggles (none lit = all specs) + a small summary. Buttons are pooled
    -- per spec id and built on demand, so a foreign-class widget's "Show on" row shows ITS
    -- class's specs (not the player's) — you can't accidentally stamp your own specs on it.
    P._lblOn = Label(ed, "Show on")
    P._specBtns = {}
    P._ensureSpecBtn = function(sp)
        local b = P._specBtns[sp.id]
        if not b then
            b = specToggle(ed, sp, function(id)
                local c = curCfg(); if not c then return end
                toggleSpecIn(c, id); applyStructural(); OPT.RefreshEditor()
            end)
            tip(b, "Show on " .. sp.text, "Light the specs this widget appears on. None lit = shows on every spec.")
            P._specBtns[sp.id] = b
        end
        return b
    end
    for _, sp in ipairs(SPEC_LIST()) do P._ensureSpecBtn(sp) end
    P._specAll = Label(ed, "", "GameFontDisableSmall")

    -- Folder: pick an existing one, clear it, or make a new one on the spot.
    P._lblFolder = Label(ed, "Folder")
    P._folder = Dropdown(ed, 200, function(v)
        local c = curCfg(); if not c then return end
        if v == "__newfolder__" then
            promptFolderName("", function(name)
                name = ensureFolder(name); if not name then return end
                c.folder = name; applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
            end)
            return
        end
        c.folder = (v ~= "" and v) or nil
        applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end, { menuWidth = 170 })

    P._lblDisplay = Label(ed, "Display")
    P._disp = {}
    for _, dt in ipairs({ "bar", "icon" }) do
        local b = Button(ed, dt:sub(1, 1):upper() .. dt:sub(2), 48, 20)   -- "Bar" / "Icon"
        b:SetScript("OnClick", function()
            local c = curCfg(); if not c then return end
            swapDisplay(c, dt)   -- remembers each display's own width/height
            applyStructural(); OPT.RefreshEditor()
        end)
        P._disp[dt] = b
    end

    -- New-tracker inline form (track anything: a buff/shield, a cooldown, a
    -- power). Opened by the "+ New tracker" item in the Tracks dropdown; binds
    -- the new tracker to the current widget on Create.
    -- The "Shows" source is a property OF the widget, edited LIVE and in place (via
    -- ownTracker, which forks a shared source first). Pick a kind, then type the spell.
    P._ntType = {}
    for _, t in ipairs({ { k = "aura", l = "Aura" }, { k = "power", l = "Resource" }, { k = "imbue", l = "Imbue" } }) do   -- Cooldown dropped: no reliable standalone in-combat readout in Midnight
        local b = Button(ed, t.l, 74, 20)
        b:SetScript("OnClick", function()
            local c = curCfg(); if not c then return end
            local tr = ownTracker(c)
            if tr.type == t.k then return end   -- already this kind: no-op (don't wipe fields)
            -- Recoverable: STASH the outgoing kind's identifying fields, and RESTORE the
            -- incoming kind's stashed ones — so a stray click (power -> buff -> power)
            -- brings your resource/spell back instead of silently clearing it forever.
            tr._stash = tr._stash or {}
            tr._stash[tr.type] = { power = tr.power, spellID = tr.spellID, slot = tr.slot }
            local s = tr._stash[t.k] or {}
            tr.type = t.k
            if t.k == "power" then tr.power = s.power; tr.spellID = nil; tr.slot = nil
            elseif t.k == "imbue" then tr.slot = s.slot or "main"; tr.spellID = s.spellID; tr.power = nil; tr.unit = nil
            else tr.spellID = s.spellID; tr.power = nil; tr.slot = nil; tr.unit = tr.unit or "player" end  -- aura
            applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
        end)
        P._ntType[t.k] = b
    end
    -- Weapon-imbue slot: Windfury is main-hand; Flametongue is often the off-hand.
    P._ntSlot = {}
    for _, s in ipairs({ { k = "main", l = "Main-hand" }, { k = "off", l = "Off-hand" }, { k = "either", l = "Either" } }) do
        local b = Button(ed, s.l, 80, 20)
        b:SetScript("OnClick", function()
            local c = curCfg(); if not c then return end
            ownTracker(c).slot = s.k; applyStructural(); OPT.RefreshEditor()
        end)
        P._ntSlot[s.k] = b
    end
    P._ntPower = Dropdown(ed, 180, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).power = v; P._ntPower:SetText(v); applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end)
    -- Pet reminder: which pet to summon (Call Pet slot / Warlock demon). Sets tr.spellID (icon
    -- + click-to-cast summon) and re-points the click-to-cast button.
    P._ntPetSummon = Dropdown(ed, 180, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).spellID = v
        local w = ns.widgets and ns.widgets[P.selectedId]
        if w and w.RefreshCast then w:RefreshCast() end
        applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end)
    P._ntSummonLbl = Label(ed, "Summon")
    -- Aura-variant picker (a `choose` aura like Paladin Devotion / Concentration): tracks the ONE
    -- specific aura you pick, so being on the wrong one — or none — reads as "missing" and reminds.
    P._ntChoose = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).spellID = resolveSpellByName(v)
        P._ntChoose:SetText(v)
        applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end)
    P._ntChooseLbl = Label(ed, "Aura")
    -- Category (rogue poisons): the reminder counts "any of the pool" (respec-safe), and this
    -- dropdown picks which poison CLICK-TO-CAST applies (the pool can't tell which you run).
    P._setLbl  = Label(ed, "")
    P._setHint = Label(ed, "", "GameFontDisableSmall")
    P._poisonCastLbl = Label(ed, "Cast on click")
    P._poisonCast = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).castPref = (v ~= "" and v) or nil   -- v is the poison id ("" = auto / first missing)
        applyStructural(); OPT.RefreshEditor()
    end)
    -- Second poison, only meaningful with a talent that lets you run two of the category (Dragon-
    -- Tempered Blades). Shown for those widgets with a note, so it never reads as a plain 2nd slot.
    P._poisonCast2Lbl = Label(ed, "2nd on click")
    P._poisonCast2 = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).castPref2 = (v ~= "" and v) or nil
        applyStructural(); OPT.RefreshEditor()
    end)
    P._poisonCast2Note = Label(ed, "", "GameFontDisableSmall")
    -- A live spell-search field: type a name (or raw id), pick from the shared results popup, commit
    -- on focus-lost/enter. Every such field re-fixes the same three focus/commit races, so they live
    -- HERE once: (1) a row was just clicked (_ntJustPicked) → don't let focus-lost re-resolve stale
    -- text to the FIRST match; (2) on some clients focus-lost fires BEFORE the row's OnMouseDown, so
    -- bail while the cursor is over the list and let the row pick; (3) the row commits on mouse-DOWN
    -- (in showResults). `commit(t)` runs the field's own resolve/store; `pick(m)` its row-pick store.
    -- Returns the box (its confirmation icon is box._icon). Shared results popup = P._ntResults below.
    local function spellField(width, commit, pick)
        local box = EditBox(ed, width, function(t)
            if P._ntJustPicked then P._ntJustPicked = nil; return end
            if P._ntResults and P._ntResults:IsShown() and P._ntResults:IsMouseOver() then return end
            commit(t)
        end)
        box:SetScript("OnTextChanged", function(self, user)
            if not user then return end                     -- ignore programmatic SetText
            local t = self:GetText()
            if t == "" or tonumber(t) or not P._showResults then if P._ntResults then P._ntResults:Hide() end; return end
            P._showResults(ns.SearchSpells(t, 8), box, pick)
        end)
        spellTip(box, function() return tonumber(box:GetText()) end)
        local icon = box:CreateTexture(nil, "OVERLAY")
        icon:SetSize(16, 16); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetPoint("LEFT", box, "LEFT", 4, 0); icon:Hide()
        box._icon = icon
        return box
    end

    P._ntSpellLbl = Label(ed, "Spell")
    P._ntSpell = spellField(190,
        function(t)   -- commit: resolve a typed NAME/id to a spell id on the widget's own source
            local c = curCfg(); if not c then return end
            local trc = ns.TrackerOf(c)
            local cur = trc and trc.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(trc.spellID)
            if t == (cur or "") then return end   -- unchanged: don't re-resolve to a possibly-different id
            local tr = ownTracker(c); tr.spellID = ns.ResolveSpellText(t)
            applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
        end,
        function(m)   -- pick a results row
            local c = curCfg(); if not c then return end
            ownTracker(c).spellID = m.id
            applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
        end)
    -- Confirmation of the resolved pick: the real spell art sits INSIDE the box on the left (like the
    -- search-result rows); the muted id rides just outside to the right (the id we actually track).
    P._ntSpellIcon = P._ntSpell._icon
    P._ntSpellId = Label(ed, "", "GameFontDisableSmall"); P._ntSpellId:Hide()

    -- Item field: point a reminder at a specific ITEM — a weapon oil, an augment rune — for its
    -- icon + click-to-cast. Type an item ID or shift-click the item into the box. On an imbue the
    -- click applies the oil to that reminder's weapon slot; elsewhere it just uses the item.
    P._lblItem = Label(ed, "Item")
    local function setTrackerItem(id)
        local c = curCfg(); if not c then return end
        ownTracker(c).itemID = id
        local w = ns.widgets and ns.widgets[P.selectedId]
        if w and w.RefreshCast then w:RefreshCast() end
        applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end
    P._ntItem = UI.ItemField(ed, 190, function(id) setTrackerItem(id) end)   -- shared field + hook (UIKit)
    P._ntItemIcon = P._ntItem._icon
    tip(P._ntItem, "Item", "The item this reminder uses — a weapon oil or augment rune. Type its ID or shift-click it in; clear the box to go back to the weapon icon.")

    -- Talent gate for an imbue reminder: only when a talent is (require) / isn't (suppress) taken.
    P._lblGate = Label(ed, "Talent gate")
    P._imbGate = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        local tr = ownTracker(c)
        if v == "off" then tr.talentGate = nil
        else
            -- Default the gated talent to THIS imbue's own spell (a talent-granted imbue like
            -- Flametongue / a Rite is known only when specced) — so "require" works out of the box;
            -- the user overrides it for a "suppress"-on-a-different-talent case (a weapon oil).
            local sp = (tr.talentGate and tr.talentGate.spell) or tr.spellID
            tr.talentGate = { mode = v, spell = sp }
        end
        applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
    end)
    tip(P._imbGate, "Talent gate", "Only show this reminder when a talent IS taken (e.g. a Lightsmith Rite, Elemental's Flametongue) — or HIDE it when a talent is taken (a weapon oil, once you run Flametongue). Keeps two reminders on one weapon slot from both nagging.")
    -- Live talent search (type "Flametongue", pick the exact spell — no blind ids). Same shared field
    -- as the Trigger spell, storing onto the imbue's talent gate instead of its spellID.
    P._lblGateSpell = Label(ed, "Talent")
    P._imbGateSpell = spellField(190,
        function(t)
            local c = curCfg(); if not c then return end
            local tr = ownTracker(c); if not tr.talentGate then return end
            local cur = tr.talentGate.spell and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.talentGate.spell)
            if t == (cur or "") then return end
            tr.talentGate.spell = ns.ResolveSpellText(t)
            applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
        end,
        function(m)
            local c = curCfg(); if not c then return end
            local tr = ownTracker(c); if not tr.talentGate then return end
            tr.talentGate.spell = m.id
            applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
        end)
    P._imbGateSpellIcon = P._imbGateSpell._icon
    P._gateHint = Label(ed, "", "GameFontDisableSmall")

    -- Shatter (Frost): a read-only note + a toggle to hide the game's own CDM Shatter icon.
    P._shatterNote = Label(ed, "", "GameFontHighlightSmall")
    P._shatterNote:SetJustifyH("LEFT"); P._shatterNote:SetJustifyV("TOP"); P._shatterNote:SetWordWrap(true); P._shatterNote:SetWidth(456)

    -- Lightsmith Rite: a read-only note explaining ONE widget covers both Rites (choice node).
    P._riteNote = Label(ed, "", "GameFontHighlightSmall")
    P._riteNote:SetJustifyH("LEFT"); P._riteNote:SetJustifyV("TOP"); P._riteNote:SetWordWrap(true); P._riteNote:SetWidth(456)
    P._shatterHide = Check(ed, "Hide the game's Shatter icon (Cooldown Manager)", function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).hideCdmIcon = v or nil
        applyStructural(); ns.Refresh()
    end)

    -- Cast-timer for combat-hidden defensive buffs (Astral Shift): time the buff from
    -- the cast instead of reading the (secret) aura. Only shown for such auras.
    P._lblCastTimer = Label(ed, "Aura lasts (sec)")
    P._castTimer = Slider(ed, 0, 300, 1, 150, function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).castTimer = v   -- explicit 0 = off (read aura); >0 = cast-timed
        applyStructural()
    end)
    tip(P._castTimer, "Aura lasts (sec)",
        "This aura is hidden from addons in combat, so we can't read it there. Set how long it lasts and we'll time it from your cast instead — reliable in and out of combat. 0 = read the aura normally.")

    -- Group-buff mode: for a raid-wide buff (Skyfury), mirror Blizzard's action-bar glow
    -- (someone in the group lacks it) instead of reading your own aura.
    P._groupGlow = Check(ed, "Group buff — remind from the action-bar glow", function(v)
        local c = curCfg(); if not c then return end
        ownTracker(c).groupGlow = v or nil
        applyStructural(); OPT.RefreshEditor()
    end)
    tip(P._groupGlow, "Group buff",
        "Remind when anyone in the group is missing it (like " .. classEx("groupbuff") .. "), not just you — it follows the game's own action-bar glow. Pair with the 'When missing' reminder.")

    -- "Aura lasts" + "Group buff" are niche — hidden behind this disclosure for a plain buff, but
    -- auto-revealed when they're actually relevant (a combat-hidden aura, or either already set),
    -- so it never buries the cast-timer a misdetected secret buff needs.
    P._auraAdv = Check(ed, "Advanced…", function(v) P._auraAdvOpen = v or nil; OPT.RefreshEditor() end)

    -- Live spell-NAME search: type "Lightning Shield", pick from the list; the
    -- box ends up holding the id. A raw number is treated as a direct id. Parented
    -- to UIParent (like the dropdown popups) so it floats above the scroll viewport
    -- instead of being clipped by it.
    local res = CreateFrame("Frame", nil, UIParent)
    res:SetFrameStrata("FULLSCREEN_DIALOG"); res:SetClipsChildren(true)
    bgTex(res, T.rgba(T.surface.panel)); border(res); res:Hide()
    P._ntResults, P._ntResRows = res, {}
    -- Reusable search-results popup: anchors under `anchor`, and clicking a row calls onPick(match).
    -- Shared by the Trigger spell field and the talent-gate field (only one is focused at a time).
    local function showResults(matches, anchor, onPick)
        anchor = anchor or P._ntSpell
        if not matches or #matches == 0 then res:Hide(); return end
        local n = math.min(#matches, 8)
        res:SetHeight(n * 22 + 2); res:SetWidth(232)
        res:ClearAllPoints(); res:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        for i = 1, n do
            local m = matches[i]
            local r = P._ntResRows[i]
            if not r then
                r = spellRow(res)
                r:SetPoint("TOPLEFT", 1, -((i - 1) * 22 + 1)); r:SetPoint("TOPRIGHT", -1, -((i - 1) * 22 + 1))
                P._ntResRows[i] = r
            end
            fillSpellRow(r, m)
            -- Commit on mouse-DOWN (not click) + set a guard: the field commits on focus-lost by
            -- resolving the typed text to the FIRST match, which otherwise races and overrides the
            -- row you clicked. OnMouseDown fires before that and the guard makes the focus-lost
            -- commit a no-op, so the picked row always wins.
            r:SetScript("OnMouseDown", function()
                res:Hide()
                P._ntJustPicked = true
                if onPick then onPick(m) end
            end)
            r:Show()
        end
        for i = n + 1, #P._ntResRows do P._ntResRows[i]:Hide() end
        res:Show(); res:Raise()
    end
    P._showResults = showResults
    -- (The Trigger + Talent-gate spell fields wire their own OnTextChanged via spellField above,
    -- through the now-published P._showResults; nothing extra to set here.)

    -- LOOK
    P._lblColour = Label(ed, "Colour")
    P._col = ColorSwatch(ed, function() return (curCfg() and curCfg().color) or { r = 1, g = 1, b = 1, a = 1 } end,
        function(r, g, b, a) local c = curCfg(); if c then c.color = { r = r, g = g, b = b, a = a }; c.autoPowerColor = nil; applyStyle(P.selectedId) end end)
    P._lblTexture = Label(ed, "Texture")
    P._tex = Dropdown(ed, 190, function(v) local c = curCfg(); if c then c.texture = v; applyStyle(P.selectedId); P._tex:SetText(v) end end, { kind = "texture" })

    P._lblWidth = Label(ed, "Width")
    P._w = Slider(ed, 20, 500, 1, 150, function(v) local c = curCfg(); if c then c.width = v; setDisplayMemory(c); applyStyle(P.selectedId); ns.Layout.Resolve() end end)
    P._lblHeight = Label(ed, "Height")
    P._h = Slider(ed, 6, 200, 1, 150, function(v) local c = curCfg(); if c then c.height = v; setDisplayMemory(c); applyStyle(P.selectedId); ns.Layout.Resolve() end end)

    -- Border: thickness (0 = none) + colour. Applies to both bar and icon frames.
    P._lblBorder = Label(ed, "Border")
    P._borderSize = Slider(ed, 0, 8, 1, 150, function(v) local c = curCfg(); if c then c.borderSize = v; applyStyle(P.selectedId) end end)
    tip(P._borderSize, "Border", "Thickness of the frame around this widget, in pixels. Set to 0 for no border.")
    P._lblBorderCol = Label(ed, "Border colour")
    P._borderColor = ColorSwatch(ed, function() return (curCfg() and curCfg().borderColor) or { r = 0, g = 0, b = 0, a = 1 } end,
        function(r, g, b, a) local c = curCfg(); if c then c.borderColor = { r = r, g = g, b = b, a = a }; applyStyle(P.selectedId) end end)

    -- CONNECTED GROUP — resize / space every linked member at once (shown only when
    -- the selected widget is connected to others).
    P._grpInfo = Label(ed, ""); P._grpInfo:SetTextColor(T.rgba(T.text.label))
    P._lblGrpSize = Label(ed, "Icon size")
    P._grpSize = Slider(ed, 16, 120, 1, 150, function(v) setGroupSize(v) end)
    -- Bar members: optionally share a width and/or height across the group.
    P._grpWMatch = Check(ed, "Match bar width", function(v) setGroupShareDim("w", v); OPT.RefreshEditor() end)
    P._grpHMatch = Check(ed, "Match bar height", function(v) setGroupShareDim("h", v); OPT.RefreshEditor() end)
    P._lblGrpWidth = Label(ed, "Bar width")
    P._grpWidth = Slider(ed, 40, 400, 1, 150, function(v) setGroupBarDim("w", v) end)
    P._lblGrpHeight = Label(ed, "Bar height")
    P._grpHeight = Slider(ed, 8, 80, 1, 150, function(v) setGroupBarDim("h", v) end)
    P._lblGrpAxis = Label(ed, "Direction")
    P._grpAxis = {}
    for _, a in ipairs({ { k = "h", l = "Horizontal" }, { k = "v", l = "Vertical" } }) do
        local b = Button(ed, a.l, 92, 22); b:SetScript("OnClick", function() setGroupAxis(a.k); OPT.RefreshEditor() end); P._grpAxis[a.k] = b
    end
    P._lblGrpGap = Label(ed, "Spacing")
    P._grpGap = Slider(ed, 0, 40, 1, 150, function(v) setGroupGap(v) end)
    tip(P._grpGap, "Spacing", "Gap between the grouped icons/bars. Shared by the whole group.")
    tip(P._grpAxis.h, "Direction", "How the group's icons/bars line up. New groups are horizontal; switch to Vertical to stack them.")
    tip(P._grpSize, "Icon size", "Resizes every grouped icon at once.")
    tip(P._grpWMatch, "Match bar width", "Give every bar in the group the same width. Off = each bar keeps its own width (set it on the bar's Display tab).")
    tip(P._grpHMatch, "Match bar height", "Give every bar in the group the same height. Off = each bar keeps its own height.")
    P._grpHelp = Label(ed, "In Move HUD (/cust unlock):\n\226\128\162 drag an icon ONTO another to group them\n\226\128\162 drag the group's title tab to move the whole group\n\226\128\162 drag an icon OUT to detach it \194\183 drag one INTO a group to add\n\226\128\162 drag an icon within the group to reorder \194\183 right-click to detach", "GameFontDisableSmall")
    P._grpHelp:SetJustifyH("LEFT"); P._grpHelp:SetWidth(440); P._grpHelp:SetTextColor(T.rgba(T.text.muted))

    P._lblFont = Label(ed, "Font")
    P._font = Dropdown(ed, 190, function(v) local c = curCfg(); if c then c.font = v; applyStyle(P.selectedId); P._font:SetText(v) end end, { kind = "font" })
    P._lblSize = Label(ed, "Size")
    P._fontSize = Slider(ed, 6, 36, 1, 70, function(v) local c = curCfg(); if c then c.fontSize = v; applyStyle(P.selectedId) end end)

    P._lblText = Label(ed, "Text")
    P._showText = Check(ed, "Show text", function(v) local c = curCfg(); if c then c.showText = v; applyStyle(P.selectedId) end end)
    P._fmt = Dropdown(ed, 160, function(v) local c = curCfg(); if c then c.textFormat = v; applyStyle(P.selectedId); P._fmt:SetText(fmtText(v)) end end)
    P._fmt:SetItems(FORMAT_OPTS)

    -- Text nudge — fonts drift out of centre as size grows, so allow a manual X/Y.
    P._lblPos = Label(ed, "Text  X")
    P._offX = Slider(ed, -60, 60, 1, 88, function(v) local c = curCfg(); if c then c.textOffsetX = v; applyStyle(P.selectedId) end end)
    P._lblOffY = Label(ed, "Y")
    P._offY = Slider(ed, -40, 40, 1, 88, function(v) local c = curCfg(); if c then c.textOffsetY = v; applyStyle(P.selectedId) end end)
    -- The Anchor (9-point) is the drag-first way to place text; the X/Y nudges are advanced,
    -- so they hide behind this disclosure until opened (or when an offset is already set).
    P._posAdv = Check(ed, "Fine-tune position", function(v) P._posAdvOpen = v or nil; OPT.RefreshEditor() end)

    -- Text anchor: a quick way to drop text to centre / a corner without nudging X/Y.
    P._lblAnchor = Label(ed, "Anchor")
    P._anchor = Dropdown(ed, 132, function(v)
        local c = curCfg(); if c then c.textAnchor = v; applyStyle(P.selectedId); P._anchor:SetText(anchorText(v)) end
    end)
    P._anchor:SetItems(ANCHOR_OPTS)

    -- Count-tracker only (MSW): dividers + 5+5. Hidden for continuous power bars.
    -- "Segmented" drives BOTH bar boxes and icon charge-pips (one cfg.segments field). On an ICON
    -- it becomes a row of pips, so widen the width to fit ~square pips (and restore on disable);
    -- a bar already spans its width, so it just gets overlaid boxes with no resize.
    P._segShow = Check(ed, "Segmented", function(v)
        local c = curCfg(); if not c then return end
        if v then
            if c.display == "icon" and not c.segments then
                c._preChargeWidth = c.width
                local tr = ns.TrackerOf(c)
                local n = (tr and type(tr.max) == "number" and tr.max) or 3
                local h = c.height or 40
                if (c.width or 0) < n * h then c.width = n * h + (n - 1) * 4 end   -- ~square pips to start
            end
            c.segments = true
        else
            c.segments = nil
            if c._preChargeWidth then c.width = c._preChargeWidth; c._preChargeWidth = nil end
        end
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    -- Spacing between segments: splits the bar into gapped boxes (combo points, runes…)
    -- rather than one bar cut by thin dividers.
    P._lblSegGap = Label(ed, "Segment gap")
    P._segGap = Slider(ed, 0, 12, 1, 150, function(v) local c = curCfg(); if c then c.segmentGap = v; applyStyle(P.selectedId) end end)
    tip(P._segGap, "Segment gap", "Gap in pixels between the boxes. 0 = a single bar with thin dividers.")
    P._split = Check(ed, "5+5 split", function(v)
        local c = curCfg(); if not c then return end
        toggleCfg(c, "split", v, function() return { at = 5, color = { r = 0.60, g = 0.20, b = 1, a = 1 } } end)
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    P._splitColor = ColorSwatch(ed,
        function() return (curCfg() and curCfg().split and curCfg().split.color) or { r = 0.6, g = 0.2, b = 1, a = 1 } end,
        function(r, g, b, a) local c = curCfg(); if c and c.split then c.split.color = { r = r, g = g, b = b, a = a }; applyStyle(P.selectedId) end end)
    P._splitLbl = Label(ed, "Colour past 5")

    -- Bar-fill motion. "Smooth" glides readable fills (MSW stacks, custom bars);
    -- a secret power fill (Maelstrom / Mana) can't be tweened by addon code, so
    -- the "Edge spark" — which rides the fill edge without reading the value — is
    -- the only motion those bars can show. Both are bar-only (icons have no fill).
    P._smooth = Check(ed, "Smooth fill", function(v) local c = curCfg(); if c then c.smooth = v; applyStyle(P.selectedId) end end)
    P._spark = Check(ed, "Leading spark", function(v) local c = curCfg(); if c then c.spark = v or nil; applyStyle(P.selectedId) end end)

    -- Reminder mode (source-agnostic): the widget appears only when its condition holds —
    -- a buff missing/active, a cooldown ready/on-CD, or a readable value over/under a
    -- threshold. Secret-safe (an unreadable value never fires a false reminder).
    P._lblReminder = Label(ed, "Reminder")
    P._reminder = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        c.showWhen = nil                              -- migrate off the legacy field
        if v == "off" then
            c.reminder = nil
        else
            c.reminder = c.reminder or {}
            c.reminder.mode = v
            if (v == "atLeast" or v == "atMost") and not c.reminder.value then c.reminder.value = 1 end
        end
        applyStyle(P.selectedId); OPT.RefreshEditor()      -- reveal/hide the value + warn rows
        if ns.Trackers.UpdateWarnTicker then ns.Trackers.UpdateWarnTicker() end
    end)
    tip(P._reminder, "Reminder", "Show this widget only when its condition holds — a missing aura, a ready cooldown, a value over/under a threshold — otherwise it stays hidden. 'Off' means it's always on screen.")
    P._lblRemVal = Label(ed, "Value")
    P._remVal = EditBox(ed, 70, function(t)
        local c = curCfg(); if not c or not c.reminder then return end
        c.reminder.value = tonumber(t) or c.reminder.value or 1
        applyStyle(P.selectedId)
    end)

    -- Low-duration warning: also fire the reminder while the buff/imbue is still UP
    -- but under N minutes left (0 = off). Uses the readable remaining time (out of
    -- combat); a hidden/secret expiry simply doesn't trigger it.
    P._lblWarn = Label(ed, "Warn under (min)")
    P._warn = Slider(ed, 0, 60, 1, 116, function(v)
        local c = curCfg(); if not c then return end
        c.warnLowSec = (v > 0) and (v * 60) or nil
        applyStyle(P.selectedId)
        if ns.Trackers.UpdateWarnTicker then ns.Trackers.UpdateWarnTicker() end
    end)
    tip(P._warn, "Warn under (min)", "Also fire the reminder while the buff is still up but has under this many minutes left — a low-time heads-up. 0 = off. Uses the readable remaining time (out of combat).")

    -- Don't nag for an ability you haven't learned/talented (e.g. Flametongue Weapon
    -- on an Elemental build). On by default; unchecking flags it regardless.
    P._learned = Check(ed, "Only when the ability is learned", function(v)
        local c = curCfg(); if not c then return end
        if v then c.onlyWhenLearned = nil else c.onlyWhenLearned = false end
        applyStyle(P.selectedId)
    end)
    tip(P._learned, "Only when learned",
        "Hide this reminder when you haven't learned/talented the ability — so an untalented spell (" .. classEx("learned") .. ") doesn't nag you. Item enhancements like weapon oils are never affected.")

    -- Click-to-cast: while the HUD is locked, clicking this reminder casts the spell it's
    -- reminding you about (recast the dropped shield / fire the ready ability). On by
    -- default. See Widget:RefreshCast — attributes are bound out of combat.
    P._clickCast = Check(ed, "Click the reminder to cast it", function(v)
        local c = curCfg(); if not c then return end
        c.clickToCast = (v == false) and false or nil   -- default (nil) = on
        applyStyle(P.selectedId)
    end)
    tip(P._clickCast, "Click to cast",
        "When the HUD is locked, click this reminder to cast the spell — recast a dropped shield or imbue, or fire a ready ability. The click is bound out of combat, so it works mid-fight for any reminder set up beforehand; a widget you create or re-point during combat becomes clickable once the fight ends.")

    -- "Only warn in combat": suppress the reminder while OOC (forms/stances you only care about
    -- mid-fight). Stored on cfg.reminder so it travels with the reminder. Doesn't help pre-combat
    -- reminders (poisons/imbues go secret in combat and hold there anyway — caveat shown + tipped).
    P._combatOnly = Check(ed, "Only warn in combat", function(v)
        local c = curCfg(); if not c then return end
        c.reminder = c.reminder or {}
        c.reminder.combatOnly = v or nil
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    tip(P._combatOnly, "Only warn in combat",
        "Hide this reminder while you're OUT of combat — handy for forms/stances you only care about mid-fight. Note: a PRE-COMBAT reminder (poisons, weapon imbues) goes secret in combat and already holds there, so this can't make one warn during a fight.")
    P._combatOnlyNote = Label(ed, "Won't affect pre-combat reminders (poisons, imbues) — those are already held in combat.", "GameFontDisableSmall")
    P._combatOnlyNote:SetJustifyH("LEFT")

    -- "Only in form": hide the widget unless in a chosen shapeshift form (Druid combo -> Cat, a
    -- Bear-only defensive, …). Only offered when the class HAS forms (ns.PlayerForms non-empty).
    P._lblFormGate = Label(ed, "Only in form")
    P._formGate = Dropdown(ed, 190, function(v)
        local c = curCfg(); if not c then return end
        if not v or v == "any" then
            c.formGate = nil
        else
            local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(v)
            c.formGate = { spellID = v, name = nm }
        end
        applyStyle(P.selectedId)
    end)
    tip(P._formGate, "Only in form", "Show this widget only while you're in the chosen shapeshift form (e.g. combo points only in Cat Form). 'Any form' = no restriction.")

    -- Louder reminder (icon in "missing" mode): a pulsing attention effect + its colour. Named
    -- "Pulse" throughout to reserve "Glow" for the STEADY active/ready effect (they share a style).
    P._pulseChk = Check(ed, "Pulse while reminding", function(v)
        local c = curCfg(); if not c then return end
        if v then c.pulse = nil else c.pulse = false end   -- default (nil) = on
        applyStyle(P.selectedId)
    end)
    P._pulseColor = ColorSwatch(ed,
        function() return (curCfg() and curCfg().pulseColor) or { r = 1, g = 0.15, b = 0.15 } end,
        function(r, g, b, a) local c = curCfg(); if c then c.pulseColor = { r = r, g = g, b = b, a = a }; applyStyle(P.selectedId) end end)
    P._lblGlow = Label(ed, "Effect")
    P._glowStyle = Dropdown(ed, 170, function(v)
        local c = curCfg(); if c then c.glowStyle = v; applyStyle(P.selectedId); P._glowStyle:SetText(glowText(v)) end
    end)
    P._glowStyle:SetItems(GLOW_OPTS)

    -- Active/ready glow (icons, LOOK tab): a steady glow while the buff is up or the
    -- ability is off cooldown. Shares the glow-style dropdown; its own colour (green).
    P._activeGlow = Check(ed, "Glow while active / ready", function(v)
        local c = curCfg(); if c then c.activeGlow = v or nil; applyStyle(P.selectedId); OPT.RefreshEditor() end
    end)
    P._activeGlowColor = ColorSwatch(ed,
        function() return (curCfg() and curCfg().activeGlowColor) or { r = 0.25, g = 1, b = 0.35 } end,
        function(r, g, b, a) local c = curCfg(); if c then c.activeGlowColor = { r = r, g = g, b = b, a = a }; applyStyle(P.selectedId) end end)

    -- Glow when a value bar reaches its ceiling (DH Void Metamorphosis pool at cap, MSW at 10…).
    -- Only fires on a READABLE value, so it's offered only for bars that can actually read full.
    P._fullGlow = Check(ed, "Glow when full", function(v)
        local c = curCfg(); if c then c.fullGlow = v or nil; applyStyle(P.selectedId); OPT.RefreshEditor() end
    end)
    P._fullGlowColor = ColorSwatch(ed,
        function() return (curCfg() and curCfg().fullGlowColor) or { r = 1, g = 0.85, b = 0.2, a = 1 } end,
        function(r, g, b, a) local c = curCfg(); if c then c.fullGlowColor = { r = r, g = g, b = b, a = a }; applyStyle(P.selectedId) end end)

    -- Charge-icon mode (icon widget on a count tracker — Tip of the Spear): show ONE icon per
    -- charge in a row instead of a single icon + number. The pips DIVIDE the widget's Width × Height
    -- (so both Size sliders drive them), but a single icon is usually narrow, so on the way IN widen
    -- to a sensible N-across row; stash the single-icon width to put back on the way out.

    -- Colour-by-fill (power bars): engine-evaluated ColorCurve, secret-safe. The
    -- checkbox seeds a default ramp the first time; toggling off KEEPS your tuning
    -- (stashed) so re-enabling restores it. Reset restores the default ramp.
    P._curveChk = Check(ed, "Colour stops", function(v)
        local c = curCfg(); if not c then return end
        toggleCfg(c, "colorCurve", v, defaultCurve)
        applyStyle(P.selectedId); OPT.RefreshEditor()   -- show/hide the point editor
    end)
    P._curveReset = Button(ed, "Reset", 52, 20)
    P._curveReset:SetScript("OnClick", function()
        local c = curCfg(); if not c then return end
        c.colorCurve, c._kept_colorCurve = defaultCurve(), nil
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    -- Linear/Step ramp toggle + "add a colour stop" for the curve point editor.
    P._curveType = Button(ed, "Linear", 60, 20)
    P._curveType:SetScript("OnClick", function()
        local c = curCfg(); if not c or not c.colorCurve then return end
        c.colorCurve.type = (c.colorCurve.type == "Step") and "Linear" or "Step"
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    tip(P._curveType, "Colour ramp", "Linear fades the colour smoothly between stops as the bar fills; Step snaps to each stop's colour at its value.")
    P._addPoint = Button(ed, "+ Colour", 84, 20)
    P._addPoint:SetScript("OnClick", function()
        local c = curCfg(); if not c or not c.colorCurve then return end
        c.colorCurve.points = c.colorCurve.points or {}
        local pts = c.colorCurve.points
        pts[#pts + 1] = { pct = 0.5, color = { r = 1, g = 1, b = 1 } }
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    tip(P._addPoint, "Add a colour stop", "Add a colour at a fill level (a count on a count bar, a percent on a fill bar). The bar takes that colour as it passes the stop; set a sound to ping there too.")
    P._curveRows = {}

    -- Marker lines on a bar (at a value or a spell's cost). Rows are pooled, filled per widget
    -- in RefreshEditor. (Count thresholds merged into the colour-stop curve — see _addPoint.)
    P._mkRows = {}
    P._mkHint = Label(ed, "Lines on the bar at a value or a spell's cost. Use 'At spell cost' for a spender; 'Glow when able' lights the action button when you can afford it.", "GameFontDisableSmall")
    P._mkHint:SetJustifyH("LEFT")
    P._addMarker = Button(ed, "+ Add line", 92, 20)
    P._addMarker:SetScript("OnClick", function()
        local c = curCfg(); if not c then return end
        c.markers = c.markers or {}
        c.markers[#c.markers + 1] = { mode = "value", value = 50, color = { r = 1, g = 0.85, b = 0.30, a = 0.9 }, width = 2 }
        applyStyle(P.selectedId); OPT.RefreshEditor()
    end)

    -- Hover explanations on the controls whose purpose isn't obvious at a glance.
    -- (Spec toggles get their tooltip in P._ensureSpecBtn, so foreign-class ones are covered too.)
    tip(P._folder, "Folder", "Group widgets into collapsible folders in the list. Organization only — doesn't affect the HUD.")
    tip(P._glowStyle, "Effect", "The highlight's look — shared by the reminder pulse and the active/ready glow. Outline suits any icon art; Button border is the Blizzard look; Fill flashes the whole icon.")
    tip(P._pulseColor, "Pulse colour")
    tip(P._curveChk, "Colour stops", "Recolour the bar as it fills, and optionally ping you at a stop. On a count bar (Maelstrom Weapon, runes…) stops are set by count; on a fill bar (mana…) by percent. Colour works even on protected values; a ping needs a readable one.")
    tip(P._smooth, "Smooth fill", "Slide the bar to new values instead of snapping.")
    tip(P._spark, "Leading spark", "A bright spark that rides the fill's leading edge.")
    tip(P._pulseChk, "Pulse", "Pulse the icon while a missing reminder is on screen.")
    tip(P._anchor, "Text anchor", "Where the text sits on the widget — pick Center or a corner instead of nudging X/Y by hand. The X/Y offset still fine-tunes it from there.")
    tip(P._activeGlow, "Glow while active", "Steady glow on the icon while the aura is up. Its own colour; shares the effect style above.")
    tip(P._activeGlowColor, "Active glow colour")
    tip(P._segShow, "Segmented", "Draw one cell per point/charge: filled boxes on a bar (runes, combo points, stacks) or one icon per charge on an icon. The Width and Height sliders size the whole row.")
    tip(P._split, "5+5 split", "Draw the stacks past a divider — e.g. show 10 stacks as two rows of 5+5.")

    -- (The profile system is gone — sharing is via import/export strings instead; see the
    -- sidebar's Import button + the row/folder/class right-click Export. buildShareDialog
    -- makes the copy-paste overlay.)
    OPT.buildShareDialog()
    OPT.buildWizard()   -- guided "add widget" overlay (hidden until + Widget (guided))

    P:SetScript("OnHide", function()
        UI.CloseMenus()
        OPT.closeWizard()
    end)
    -- Soft fade-in whenever the panel opens.
    P:SetScript("OnShow", function() P:SetAlpha(0); tweenAlpha(P, 1, T.fx.fade) end)
end






-- ── Entry point ───────────────────────────────────────────────────────
function ns.OpenOptions()
    if not P then build() end
    -- Always open on the Home / start page rather than diving into the first widget's
    -- settings (which read as "why am I editing the Shaman Maelstrom bar?"). Pick a widget
    -- from the list to edit it.
    P.selectedId = nil
    OPT.RefreshList(); OPT.RefreshEditor()
    P:Show()
end

-- Toggle for the minimap button (and any other one-click entry point).
function ns.ToggleOptions()
    if P and P:IsShown() then P:Hide() else ns.OpenOptions() end
end

-- Open the panel focused on a specific widget — used when clicking a HUD widget in
-- move mode, so you jump straight to its settings.
function ns.SelectWidgetInOptions(id)
    if not P then build() end
    if id and ns.profile.widgets[id] then P.selectedId = id end
    OPT.RefreshList(); OPT.RefreshEditor()
    P:Show(); P:Raise()
end

-- Right-clicking a group's handle jumps to the Layout tab of its first member, where
-- the group's shared size / spacing live.
function ns.SelectGroupInOptions(gid)
    local order = ns.Groups and ns.Groups.Order(gid)
    local first = order and order[1]
    if not first then return end
    if not P then build() end
    P.selectedId = first; P._tab = "layout"
    OPT.RefreshList(); OPT.RefreshEditor()
    P:Show(); P:Raise()
end

-- Called after a profile switch/reset so the open panel reflects new data.
function ns.RefreshOptions()
    if P and P:IsShown() then
        if not P.selectedId or not ns.profile.widgets[P.selectedId] then
            P.selectedId = ns.profile.order[1]
        end
        OPT.RefreshList(); OPT.RefreshEditor()
    end
end
