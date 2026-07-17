-- Options/PanelEditor.lua : the right-hand editor — the stacker that lays out the selected
-- widget's rows, the pooled marker / threshold / colour-curve rows, and the floating spell picker.
--
-- Split out of Options/Panel.lua. RefreshEditor is the one entry point the rest of the panel
-- needs, so it lives on the shared ns.OPT table. build() still CREATES the editor controls (they
-- hang off P); this file only decides which ones show, where, and with what values. The statics,
-- label resolvers and helpers it reads (SUBDESC, GLOW_OPTS, curCfg, applyStyle, …) stay in
-- Panel.lua and come in via OPT, resolved at call time.

local ADDON, ns = ...

local OPT = ns.OPT
local T  = ns.Theme
local UI = ns.UI
local ACCENT = UI.ACCENT
local border, bgTex, tweenAlpha = UI.border, UI.bgTex, UI.tweenAlpha
local Label, Button, Check, EditBox, Dropdown = UI.Label, UI.Button, UI.Check, UI.EditBox, UI.Dropdown
local ColorSwatch, tip, spellTip = UI.ColorSwatch, UI.tip, UI.spellTip

local P
OPT.OnBind(function(panel) P = panel end)

-- Every simple editor element, so the stacker can hide the lot and re-show only
-- what the selected widget needs. (Marker/threshold rows are pooled separately.)
local EDITOR_KEYS = {
    "_edTitle", "_lblName", "_name", "_lblTracks", "_lblOn", "_specAll", "_lblFolder", "_folder", "_lblDisplay",
    "_lblColour", "_col", "_lblTexture", "_tex", "_lblWidth", "_w", "_lblHeight", "_h",
    "_lblBorder", "_borderSize", "_lblBorderCol", "_borderColor", "_lblSegGap", "_segGap",
    "_grpInfo", "_lblGrpSize", "_grpSize", "_grpWMatch", "_grpHMatch", "_lblGrpWidth", "_grpWidth", "_lblGrpHeight", "_grpHeight", "_lblGrpAxis", "_lblGrpGap", "_grpGap", "_grpHelp",
    "_lblFont", "_font", "_lblSize", "_fontSize", "_lblText", "_showText", "_fmt",
    "_lblPos", "_offX", "_lblOffY", "_offY", "_posAdv", "_lblAnchor", "_anchor", "_segShow", "_split", "_splitColor", "_splitLbl",
    "_smooth", "_spark", "_curveChk", "_curveReset", "_curveType", "_addPoint", "_pulseChk", "_pulseColor", "_lblGlow", "_glowStyle",
    "_activeGlow", "_activeGlowColor", "_fullGlow", "_fullGlowColor",
    "_lblReminder", "_reminder", "_lblRemVal", "_remVal", "_learned", "_clickCast", "_combatOnly", "_combatOnlyNote", "_lblFormGate", "_formGate", "_lblWarn", "_warn", "_mkHint", "_addMarker", "_esNote",
    "_ntPower", "_ntSpellLbl", "_ntSpell", "_ntSpellIcon", "_ntSpellId", "_lblSlot", "_lblCastTimer", "_castTimer", "_groupGlow", "_auraAdv",
    "_ntSummonLbl", "_ntPetSummon", "_ntChooseLbl", "_ntChoose", "_setLbl", "_setHint", "_poisonCastLbl", "_poisonCast", "_poisonCast2Lbl", "_poisonCast2", "_poisonCast2Note", "_manualWarn",
    "_lblItem", "_ntItem", "_lblGate", "_imbGate", "_lblGateSpell", "_imbGateSpell", "_gateHint",
    "_shatterNote", "_shatterHide", "_riteNote",
}

-- ── ALERTS list-editor rows (markers / thresholds) ────────────────────
-- The sound picker's items / labels come from Core/Sound.lua: a curated library
-- of NAMED sounds, the user's SharedMedia sounds, and a custom TTS option.
local function soundText(s) return ns.Sound.Text(s) end
local function soundOpts() return ns.Sound.Options() end
local function removeEntry(list, e)
    if not list then return end
    for i, x in ipairs(list) do if x == e then table.remove(list, i); return end end
end

-- ── Reusable spell picker ─────────────────────────────────────────────
-- A floating search (edit box + icon/name results) any control can pop to choose a
-- spell — so markers show a real spell instead of a raw id you had to know. Parented
-- to UIParent (floats above the scroll clip); dismissed by a click-eater. openSpell-
-- Picker(anchor, onPick) → onPick(id, name).
local function ensureSpellPicker()
    if P._sp then return P._sp end
    local eater = CreateFrame("Button", nil, UIParent); eater:SetFrameStrata("FULLSCREEN"); eater:SetAllPoints(UIParent); eater:Hide()
    P._spEater = eater
    local sp = CreateFrame("Frame", nil, UIParent); sp:SetFrameStrata("FULLSCREEN_DIALOG"); sp:SetSize(240, 44); sp:Hide()
    bgTex(sp, T.rgba(T.surface.dialog)); border(sp)
    eater:SetScript("OnClick", function() sp:Hide() end)
    sp:SetScript("OnHide", function() eater:Hide() end)
    local box = EditBox(sp, 222, nil); box:SetPoint("TOPLEFT", 8, -8)
    local rows = {}
    sp._box, sp._rows = box, rows
    local function render(matches)
        for _, r in ipairs(rows) do r:Hide() end
        local n = matches and math.min(#matches, 8) or 0
        sp:SetHeight(34 + n * 22 + (n > 0 and 6 or 0))
        for i = 1, n do
            local m = matches[i]
            local r = rows[i]
            if not r then
                r = OPT.spellRow(sp, { iconX = 2, textX = 24 })
                r:SetPoint("TOPLEFT", 6, -(32 + (i - 1) * 22)); r:SetPoint("TOPRIGHT", -6, -(32 + (i - 1) * 22))
                rows[i] = r
            end
            OPT.fillSpellRow(r, m)
            -- Commit on mouse-DOWN, not click: clicking a row drops the edit box's
            -- focus, whose commit resolves the typed text to the FIRST match and would
            -- otherwise race ahead of an OnClick and override the row you picked. Down
            -- fires first + sets a guard so any trailing commit is a no-op, so the
            -- picked row always wins (same fix as the source field's _ntJustPicked).
            r:SetScript("OnMouseDown", function()
                sp._picked = true
                if sp._onPick then sp._onPick(m.id, m.name) end
                sp:Hide()
            end)
            r:Show()
        end
    end
    local function commit()
        if sp._picked then sp._picked = nil; return end   -- a row was just clicked; don't override with the first match
        local id = ns.ResolveSpellText(box:GetText())
        if id and sp._onPick then sp._onPick(id, C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) end
        sp:Hide()
    end
    box:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local t = self:GetText()
        if t == "" or tonumber(t) then render(nil) else render(ns.SearchSpells(t, 8)) end
    end)
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEscapePressed", function() sp:Hide() end)
    P._sp = sp
    return sp
end
local function openSpellPicker(anchor, onPick)
    local sp = ensureSpellPicker()
    sp._onPick = onPick
    sp._picked = nil
    for _, r in ipairs(sp._rows) do r:Hide() end
    sp._box:SetText(""); sp:SetHeight(44)
    sp:ClearAllPoints(); sp:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    sp:Show(); sp:Raise()
    if P._spEater then P._spEater:Show() end
    sp._box:SetFocus()
end

-- A marker = a labelled line on the bar. Row reads left→right: a MODE dropdown
-- ("At value / At % / At spell cost"), then the value (a number, or — for spell
-- mode — a spell shown by icon+name, picked from search, never a raw id), a colour
-- and a delete. Spell mode adds a second line: a clearly-labelled affordability
-- glow toggle. Row grows to 2 lines only in spell mode.
local MARK_MODES = { { value = "value", text = "At value" }, { value = "percent", text = "At %" }, { value = "spell", text = "At spell cost" } }
local function markMode(m) for _, o in ipairs(MARK_MODES) do if o.value == m then return o.text end end return "At value" end
-- Which spec(s) a marker is gated to (nil/empty = all). Label for the per-row spec dropdown.
local function markerSpecText(m)
    if not (m and m.specs and next(m.specs)) then return "All specs" end
    local ids = {}; for id in pairs(m.specs) do ids[#ids + 1] = id end
    if #ids == 1 then return ns.SpecName(ids[1]) or ns.SpecNameAny(ids[1]) or ("Spec " .. ids[1]) end
    return #ids .. " specs"
end
local function markerRow(i)
    local rowF = CreateFrame("Frame", nil, P._ed); rowF:SetSize(344, 48)

    local mode = Dropdown(rowF, 104, function(v)
        local e = rowF._entry; if not e then return end
        e.mode = v; if v ~= "spell" then e.spellID = nil; e.spellIDs = nil end
        OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
    end, { menuWidth = 120 })
    mode:SetItems(MARK_MODES)
    mode:SetPoint("TOPLEFT", 0, 0)
    tip(mode, "Where the line sits", "A flat value, a percent of the bar, or a spell's live cost (the line then tracks that spell's real cost).")

    -- value / percent input
    local num = EditBox(rowF, 54, function(t)
        local e = rowF._entry; if e then e.value = tonumber(t); OPT.applyStyle(P.selectedId) end
    end)
    num:SetPoint("LEFT", mode, "RIGHT", 8, 0)
    local numHint = Label(rowF, ""); numHint:SetPoint("LEFT", num, "RIGHT", 5, 0)

    -- spell mode: an icon+name button (click = set) + a small "+" that BUNDLES a
    -- variant / choice-node sibling into the same line (Earth Shock / Elemental Blast).
    local spell = Button(rowF, "", 120, 22); spell:SetPoint("LEFT", mode, "RIGHT", 8, 0)
    spell._ic = spell:CreateTexture(nil, "ARTWORK"); spell._ic:SetPoint("LEFT", 3, 0); spell._ic:SetSize(16, 16); spell._ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    spell._fs:ClearAllPoints(); spell._fs:SetPoint("LEFT", 23, 0); spell._fs:SetPoint("RIGHT", -6, 0); spell._fs:SetJustifyH("LEFT"); spell._fs:SetWordWrap(false)
    spell:SetScript("OnClick", function()
        openSpellPicker(spell, function(id)
            local e = rowF._entry; if not e then return end
            e.spellIDs = { id }; e.spellID = nil            -- set (replaces the bundle)
            OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
        end)
    end)
    tip(spell, "Pick the spell", "Click to search the spell whose cost sets this line. Use + to bundle a choice-node sibling.")
    spellTip(spell, function() local e = rowF._entry; return e and ns.MarkerSpell(e) end, function() local e = rowF._entry; return e and e.spellIDs end)

    local addv = Button(rowF, "+", 20, 22); addv:SetPoint("LEFT", spell, "RIGHT", 3, 0)
    addv:SetScript("OnClick", function()
        openSpellPicker(addv, function(id)
            local e = rowF._entry; if not e then return end
            local list = e.spellIDs or (e.spellID and { e.spellID }) or {}
            list[#list + 1] = id; e.spellIDs = list; e.spellID = nil   -- bundle another id
            OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
        end)
    end)
    tip(addv, "Bundle a variant", "Add a choice-node sibling or cast form to this one line — it uses whichever you have (e.g. " .. OPT.classEx("spender") .. ").")

    local sw = ColorSwatch(rowF, function() return (rowF._entry and rowF._entry.color) or { r = 1, g = 1, b = 1, a = 1 } end,
        function(r, g, b, a) local e = rowF._entry; if e then e.color = { r = r, g = g, b = b, a = a }; OPT.applyStyle(P.selectedId) end end)
    sw:SetPoint("TOPRIGHT", -26, -1)

    local del = Button(rowF, "X", 20, 20); del:SetPoint("TOPRIGHT", 0, 0)
    tip(del, "Remove", "Delete this line.")
    del:SetScript("OnClick", function()
        local c = OPT.curCfg(); if c then removeEntry(c.markers, rowF._entry) end
        OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
    end)

    -- line 2 (spell mode): pick what this marker does — draw the line, glow the action
    -- button when affordable, or both. Two toggles cover all three combinations.
    -- Spec gate (line 2, ALL modes): draw this marker only on the chosen spec, so one shared
    -- resource bar can carry different lines/glows per spec (Blood's Death Strike, Unholy's other).
    local specDD = Dropdown(rowF, 92, function(v)
        local e = rowF._entry; if not e then return end
        if v == "all" then e.specs = nil else e.specs = { [v] = true } end
        OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
    end, { menuWidth = 128 })
    specDD:SetPoint("TOPLEFT", 2, -24)
    tip(specDD, "Show on spec", "Draw this marker only on the chosen spec — one shared resource bar can then carry different lines per spec. 'All specs' shows it everywhere.")

    local line = Check(rowF, "Line", function(v)
        -- nil (default) = draw the line; false = don't. (Must be an if/else: the old
        -- `(v and nil) or false` collapsed to false for BOTH states, so re-checking never
        -- restored the line.)
        local e = rowF._entry
        if e then if v then e.line = nil else e.line = false end; OPT.applyStyle(P.selectedId) end
    end)
    line:SetPoint("LEFT", specDD, "RIGHT", 12, 0)
    tip(line, "Marker line", "Draw the reference line on the bar at this spell's cost.")
    local glow = Check(rowF, "Glow when able", function(v)
        local e = rowF._entry; if e then e.alert = v or nil; OPT.applyStyle(P.selectedId) end
    end)
    glow:SetPoint("LEFT", line._fs, "RIGHT", 14, 0)
    tip(glow, "Glow when able", "Glow the bar's action button the moment you can afford this spell.")

    rowF._mode, rowF._num, rowF._numHint, rowF._spell, rowF._add, rowF._sw, rowF._glow, rowF._line, rowF._spec = mode, num, numHint, spell, addv, sw, glow, line, specDD
    P._mkRows[i] = rowF
    return rowF
end


-- A ColorCurve point row: [colour] at [pct] % fill [sound] [play] [X]. Editing colours/stops here
-- is how you retune the fill gradient (e.g. flip Maelstrom to run hot toward cap). The sound picker
-- is shown only on READABLE bars (a ping needs a value we can compare in Lua — see the render loop);
-- on a secret power bar it's hidden and the row is the plain [colour] at [pct] % fill [X].
local function curvePointRow(i)
    local rowF = CreateFrame("Frame", nil, P._ed); rowF:SetSize(360, 22)
    local sw = ColorSwatch(rowF, function() return (rowF._entry and rowF._entry.color) or { r = 1, g = 1, b = 1, a = 1 } end,
        function(r, g, b, a) local e = rowF._entry; if e then e.color = { r = r, g = g, b = b, a = a }; OPT.applyStyle(P.selectedId) end end)
    sw:SetPoint("LEFT", 0, 0)
    local at = Label(rowF, "at"); at:SetPoint("LEFT", sw, "RIGHT", 10, 4)
    local pct = EditBox(rowF, 42, function(t)
        local e = rowF._entry; if not e then return end
        local n = tonumber(t)
        if n then
            if rowF._countMode and rowF._max and rowF._max > 0 then
                e.pct = math.max(0, math.min(1, n / rowF._max))   -- count -> fraction
            else
                e.pct = math.max(0, math.min(100, n)) / 100        -- percent -> fraction
            end
        end
        OPT.applyStyle(P.selectedId)
    end)
    pct:SetPoint("LEFT", at, "RIGHT", 6, -4)
    local pctLbl = Label(rowF, "% fill"); pctLbl:SetPoint("LEFT", pct, "RIGHT", 4, 4)
    local snd = Dropdown(rowF, 116, function(v)
        local e = rowF._entry; if not e then return end
        ns.Sound.StopPreview()
        if v == "__tts__" then   -- pick TTS -> type the message to speak
            local cur = (type(e.sound) == "table" and e.sound.tts) or ""
            OPT.promptTTS(cur, function(text)
                e.sound = (text and text ~= "") and { tts = text } or nil
                OPT.applyStyle(P.selectedId); rowF._snd:SetText(soundText(e.sound))
            end)
            return
        end
        e.sound = (v ~= "" and v) or nil
        OPT.applyStyle(P.selectedId); rowF._snd:SetText(soundText(e.sound))
    end, { onHover = function(v) ns.Sound.Preview(v) end })
    snd:SetPoint("LEFT", pctLbl, "RIGHT", 12, -4)
    snd._menu:HookScript("OnHide", function() ns.Sound.StopPreview() end)
    local play = Button(rowF, ">", 20, 20); play:SetPoint("LEFT", snd, "RIGHT", 6, 0)
    play:SetScript("OnClick", function() local e = rowF._entry; if e then ns.Sound.StopPreview(); ns.PlaySound(e.sound) end end)
    tip(play, "Preview", "Play this sound now.")
    local del = Button(rowF, "X", 20, 20)
    tip(del, "Remove", "Delete this colour stop.")
    del:SetScript("OnClick", function()
        local c = OPT.curCfg(); if c and c.colorCurve then removeEntry(c.colorCurve.points, rowF._entry) end
        OPT.applyStyle(P.selectedId); OPT.RefreshEditor()
    end)
    rowF._sw, rowF._pct, rowF._snd, rowF._play, rowF._del, rowF._pctLbl = sw, pct, snd, play, del, pctLbl
    P._curveRows[i] = rowF
    return rowF
end

-- Light in-tab SUB-CAPTION (accent tick + small-caps label + hairline). Groups a
-- tab's rows into scannable clusters so a screen doesn't read as one dense wall.
-- Pooled; RefreshEditor hides all then shows the ones it uses.
local function makeSubCap(i)
    local ed = P._ed
    local cap = {}
    cap.bar = ed:CreateTexture(nil, "ARTWORK"); cap.bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9); cap.bar:SetSize(3, 9)
    cap.lbl = ed:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); cap.lbl:SetTextColor(T.rgba(T.text.header))
    cap.ln  = ed:CreateTexture(nil, "ARTWORK"); cap.ln:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.12); cap.ln:SetHeight(1)
    cap.desc = ed:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cap.desc:SetTextColor(T.rgba(T.text.muted)); cap.desc:SetJustifyH("LEFT"); cap.desc:SetWidth(440)
    P._subCaps[i] = cap
    return cap
end

function OPT.RefreshEditor()
    if not P then return end
    local c = OPT.curCfg()
    local ed, X = P._ed, 14

    -- On switching to a different widget: reset the scroll to the top and fade the
    -- pane in so the change reads as a fresh screen.
    if P._edScrollFor ~= P.selectedId then
        P._edScrollFor = P.selectedId
        ns._selectedId = P.selectedId   -- so the HUD marks the selected widget in move mode
        if P._edView then P._edView:SetVerticalScroll(0) end
        ed:SetAlpha(0.3); tweenAlpha(ed, 1, T.fx.editorFade)
        if ns.profile.unlocked and ns.Layout and ns.Layout.UpdateLinks then ns.Layout.UpdateLinks() end
    end

    local mb = P._moveBtn
    mb:SetActive(ns.profile.unlocked); mb._fs:SetText(ns.profile.unlocked and "Lock HUD" or "Move HUD")

    for _, k in ipairs(EDITOR_KEYS) do local e = P[k]; if e and e.Hide then e:Hide() end end
    for _, b in pairs(P._disp) do b:Hide() end
    if P._grpAxis then for _, b in pairs(P._grpAxis) do b:Hide() end end
    for _, b in pairs(P._ntType) do b:Hide() end
    if P._specBtns then for _, b in pairs(P._specBtns) do b:Hide() end end
    if P._ntSlot then for _, b in pairs(P._ntSlot) do b:Hide() end end
    for _, r in ipairs(P._mkRows) do r:Hide() end
    if P._curveRows then for _, r in ipairs(P._curveRows) do r:Hide() end end
    if P._ntResults then P._ntResults:Hide() end
    for _, cp in ipairs(P._subCaps) do cp.bar:Hide(); cp.lbl:Hide(); cp.ln:Hide(); if cp.desc then cp.desc:Hide() end end

    if not c then
        -- Home / start page: no widget selected. Hide the editor chrome and show the landing.
        for _, b in pairs(P._tabBtns) do b:Hide() end
        P._edTitle:Hide()
        if P._home then
            P._home:Show()
            if P._homeMove then
                P._homeMove:SetActive(ns.profile.unlocked)
                P._homeMove._fs:SetText(ns.profile.unlocked and "Lock HUD" or "Move HUD")
            end
            -- "What you have" summary: this character's widgets (its class + shared), plus a nudge.
            local mine = 0
            for _, id in ipairs(ns.profile.order) do
                local w = ns.profile.widgets[id]
                if w then local cls = ns.ClassOfCfg(w); if cls == nil or cls == ns.playerClass then mine = mine + 1 end end
            end
            local clsName = ns.ClassName and ns.ClassName(ns.playerClass) or ""
            local stat
            if mine == 0 then
                stat = "No widgets yet on this character.\nHit |cff4aa8ff+ Add widget|r to set up your first resource bar or reminder."
            else
                stat = ("You have |cffffffff%d|r widget%s on your %s.\nPick one from the list to edit it. |cff808080Right-click a row for duplicate / delete / move / export.|r"):format(
                    mine, mine == 1 and "" or "s", clsName)
            end
            P._homeStat:SetText(stat)
        end
        ed:SetHeight(60); if P._edUpdateScrollbar then P._edUpdateScrollbar() end
        return
    end
    if P._home then P._home:Hide() end

    -- Grid: a muted field label at the label column, its control at the control
    -- column, one field per row on a uniform pitch (ROW). Checkboxes sit flush at
    -- the label column with their own text. Everything lines up, so a row scans as
    -- "label -> value" instead of a wall of same-weight controls.
    local GUT, ROW = 80, 31
    local function L(lbl, y, ch) lbl:ClearAllPoints(); lbl:SetPoint("LEFT", ed, "TOPLEFT", X, -(y + (ch or 22) / 2)); lbl:SetTextColor(T.rgba(T.text.label)); lbl:Show() end
    local function put(ctrl, y, xoff) ctrl:ClearAllPoints(); ctrl:SetPoint("TOPLEFT", ed, "TOPLEFT", X + (xoff or GUT), -y); ctrl:Show() end
    local function chk(box, y) box:ClearAllPoints(); box:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); box:Show() end

    -- In-tab group caption (see makeSubCap). Adds a little space above, draws the
    -- caption, and returns the y to start the group's rows at. Pass the FIRST group's
    -- y as-is (no leading gap) by calling with top=true.
    local capN = 0
    local function sub(text, yy, top)
        if not top then yy = yy + 9 end
        capN = capN + 1
        local cap = P._subCaps[capN] or makeSubCap(capN)
        cap.bar:ClearAllPoints(); cap.bar:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -(yy + 3)); cap.bar:Show()
        cap.lbl:ClearAllPoints(); cap.lbl:SetPoint("LEFT", cap.bar, "RIGHT", 6, -1); cap.lbl:SetText(text); cap.lbl:Show()
        cap.ln:ClearAllPoints(); cap.ln:SetPoint("LEFT", cap.lbl, "RIGHT", 8, 0); cap.ln:SetPoint("RIGHT", ed, "RIGHT", -10, 0); cap.ln:Show()
        local d = OPT.SUBDESC[text]
        if d then
            cap.desc:ClearAllPoints(); cap.desc:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -(yy + 19))
            cap.desc:SetText(d); cap.desc:Show()
            -- Advance by the description's ACTUAL height, so a desc that wraps to two lines doesn't
            -- bleed into the first control below it (SetWidth(440) can wrap a long one).
            return yy + 19 + math.max(12, cap.desc:GetStringHeight() or 12) + 4
        end
        cap.desc:Hide()
        return yy + 20
    end

    local isBar = (c.display == "bar")
    local disc  = ns.IsCountTracker(c.trackerId)   -- fixed stack ceiling (MSW)?
    local tr    = ns.TrackerOf(c)
    local isAura = tr and tr.type == "aura"
    local isImbue = tr and tr.type == "imbue"
    local isCooldown = tr and tr.type == "cooldown"
    local isEarthShield = tr and tr.type == "earthshield"

    -- Fixed title + tab bar: only the active tab's controls render below.
    P._edTitle:SetText("|cffffffffEdit:|r " .. (c.name or P.selectedId)); P._edTitle:Show()
    local tab = P._tab or "trigger"
    for k, b in pairs(P._tabBtns) do b:SetActive(k == tab); b:Show() end
    local y = 8

    if tab == "trigger" then
    y = sub("BASICS", y, true)
    L(P._lblName, y, 20); put(P._name, y); P._name:SetText(c.name or ""); y = y + ROW

    -- Trigger: the widget's OWN source. Pick a kind, then type the spell — edited live,
    -- so it's always THIS widget's thing (no shared list to mis-pick from).
    y = sub("TRIGGER", y)
    L(P._lblTracks, y, 20)   -- "Trigger"
    local kx = GUT
    for _, k in ipairs({ "aura", "power", "imbue" }) do
        put(P._ntType[k], y, kx); P._ntType[k]:SetActive(tr and tr.type == k and true or false); kx = kx + 78
    end
    y = y + ROW
    local function showSpell(lbl)
        P._ntSpellLbl:SetText(lbl); L(P._ntSpellLbl, y, 16); put(P._ntSpell, y)
        local nm = tr.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.spellID)
        P._ntSpell:SetText(nm or (tr.spellID and tostring(tr.spellID)) or "")
        -- Once a real spell is resolved, show its art inside the box (name inset past it)
        -- and the muted id just outside to the right.
        if tr.spellID then
            local ic = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(tr.spellID)
            P._ntSpellIcon:SetTexture(ic or 134400); P._ntSpellIcon:Show()
            P._ntSpell:SetTextInsets(24, 6, 0, 0)   -- clear the icon
            P._ntSpellId:ClearAllPoints()
            P._ntSpellId:SetPoint("TOPLEFT", ed, "TOPLEFT", X + GUT + 196, -(y + 6))
            P._ntSpellId:SetText(("|cff808080#%d|r"):format(tr.spellID)); P._ntSpellId:Show()
        else
            P._ntSpellIcon:Hide(); P._ntSpellId:Hide()
            P._ntSpell:SetTextInsets(6, 6, 0, 0)
        end
        y = y + ROW
    end
    -- Item source (oil / augment rune): its icon overrides the default, and click-to-cast uses it.
    local function showItem()
        L(P._lblItem, y, 16); put(P._ntItem, y)
        local id = tr and tr.itemID
        local nm = id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
        P._ntItem:SetText(nm or (id and ("item:" .. id)) or "")
        if id then
            local ic = ns.ItemIcon(id)
            P._ntItemIcon:SetTexture(ic or 134400); P._ntItemIcon:Show()
            P._ntItem:SetTextInsets(24, 6, 0, 0)
        else
            P._ntItemIcon:Hide()
            P._ntItem:SetTextInsets(6, 6, 0, 0)
        end
        y = y + ROW
    end
    if not tr then
        P._ntSpellLbl:SetText("|cff888888pick what to show above|r"); L(P._ntSpellLbl, y, 16); y = y + ROW
    elseif tr.type == "power" then
        P._ntSpellLbl:SetText("Resource"); L(P._ntSpellLbl, y, 16); put(P._ntPower, y)
        P._ntPower:SetItems(OPT.powerOpts()); P._ntPower:SetText(tr.power and OPT.prettyPower(tr.power) or "Choose a resource")
        y = y + ROW
    elseif tr.type == "imbue" then
        L(P._lblSlot, y, 16)
        local sx = GUT
        for _, sl in ipairs({ "main", "off", "either" }) do
            put(P._ntSlot[sl], y, sx); P._ntSlot[sl]:SetActive((tr.slot or "main") == sl); sx = sx + 84
        end
        y = y + ROW
        showSpell("Spell")
        showItem()   -- optional oil/rune item → its icon + click-to-cast (applies to the slot above)
        if tr.riteIds then
            -- Lightsmith Rite (choice node): the gate is id-driven, not the manual talent picker —
            -- show a note instead so it's clear ONE widget follows whichever Rite you've talented.
            P._riteNote:SetText("|cff9fe6a0One widget for both Rites.|r It tracks whichever |cffffffffRite of Sanctification / Adjuration|r "
                .. "you've talented (Lightsmith) and follows a talent swap — name, icon and click-to-cast update automatically. "
                .. "You never need a second one.")
            P._riteNote:ClearAllPoints(); P._riteNote:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._riteNote:Show()
            y = y + (P._riteNote:GetStringHeight() or 40) + 10
        else
        -- Talent gate: only-when / hide-when a talent is taken (mutually-exclusive slot reminders).
        local gm = (tr.talentGate and tr.talentGate.mode) or "off"
        L(P._lblGate, y, 16); put(P._imbGate, y); P._imbGate:SetItems(OPT.GATE_OPTS); P._imbGate:SetText(OPT.gateModeText(gm)); y = y + ROW
        if gm ~= "off" then
            L(P._lblGateSpell, y, 16); put(P._imbGateSpell, y)
            local gid = tr.talentGate and tr.talentGate.spell
            local gnm = gid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(gid)
            P._imbGateSpell:SetText(gnm or (gid and tostring(gid)) or "")
            if gid then
                local ic = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(gid)
                P._imbGateSpellIcon:SetTexture(ic or 134400); P._imbGateSpellIcon:Show(); P._imbGateSpell:SetTextInsets(24, 6, 0, 0)
            else
                P._imbGateSpellIcon:Hide(); P._imbGateSpell:SetTextInsets(6, 6, 0, 0)
            end
            y = y + ROW
            if not gid then   -- loud reminder: an empty talent makes the gate do nothing
                P._gateHint:SetText("|cffe58a4bPick a talent above — the gate does nothing until you do.|r")
                L(P._gateHint, y, 14); y = y + 20
            end
        end
        end   -- rite-note vs talent-gate
    elseif tr.type == "pet" then
        -- Which pet to summon on click (Hunter Call Pet slot / Warlock demon). Other classes
        -- have a single summon, so no picker — just note the tracked pet.
        local opts = OPT.petSummonOpts(ns.ClassOfCfg and ns.ClassOfCfg(c) or ns.playerClass)
        if opts and #opts > 0 then
            L(P._ntSummonLbl, y, 16); put(P._ntPetSummon, y)
            P._ntPetSummon:SetItems(opts)
            local cur = tr.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.spellID)
            P._ntPetSummon:SetText(cur or "Choose a pet")
            y = y + ROW
        else
            P._ntSpellLbl:SetText("|cff888888tracks your pet — summon it to clear|r"); L(P._ntSpellLbl, y, 16); y = y + ROW
        end
    elseif tr.type == "form" then
        P._ntSpellLbl:SetText("|cff888888tracks " .. (tr.name or "your form") .. " — leave it to be reminded, click to shift in|r")
        L(P._ntSpellLbl, y, 16); y = y + ROW
    elseif tr.type == "earthshield" then
        P._ntSpellLbl:SetText("|cff888888tracks 2 Earth Shields — yours + an ally's (needs Elemental Orbit)|r")
        L(P._ntSpellLbl, y, 16); y = y + ROW
    elseif tr.type == "manual" then
        -- Estimated stack counter: no editable spell, just a loud caution banner so it's always
        -- clear this value is inferred from your casts, not read from the game.
        local nGen = 0; if tr.gen then for _ in pairs(tr.gen) do nGen = nGen + 1 end end
        local nCon = 0; if tr.con then for _ in pairs(tr.con) do nCon = nCon + 1 end end
        P._manualWarn:SetText(("|cffe58a4b\226\154\160 Manual tracker (estimated)|r\n"
            .. "Counts |cffffffff%d|r builder%s / |cffffffff%d|r spender%s of |cffffffff%s|r from your casts (up to |cffffffff%d|r); can drift on a missed cast or lag, and resets out of combat.")
            :format(nGen, nGen == 1 and "" or "s", nCon, nCon == 1 and "" or "s", tr.name or "stacks", tr.max or 3))
        P._manualWarn:ClearAllPoints(); P._manualWarn:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._manualWarn:Show()
        y = y + (P._manualWarn:GetStringHeight() or 40) + 10
    elseif tr.type == "shatter" then
        -- Reads the target's Shatter debuff from the Cooldown Manager (it's a secret target aura).
        P._shatterNote:SetText("Reads your |cfffffffftarget's Shatter|r from the |cffffffffCooldown Manager|r — so Shatter must be a tracked aura there, or this stays empty.")
        P._shatterNote:ClearAllPoints(); P._shatterNote:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._shatterNote:Show()
        y = y + (P._shatterNote:GetStringHeight() or 30) + 10
        chk(P._shatterHide, y); P._shatterHide:SetChecked(tr.hideCdmIcon and true or false); y = y + ROW
    elseif tr.type == "ally" then
        -- A buff YOU keep on someone else (Source of Magic). Editable buff + a note that it
        -- scans the group for your copy (present if on any ally, reminds when out on nobody).
        showSpell("Aura on ally")
    else   -- aura / cooldown
        if tr.matchAny then
            -- Category (poisons): tracks a talent-aware COUNT of the pool, not pinned members —
            -- keep 1 of the category up, or the talent count (2) while requireCountTalent is taken.
            -- ANY member counts, so a respec adapts and there's nothing to misconfigure (no per-
            -- poison checklist). The pool is listed read-only so it's clear what qualifies.
            local g = tr.requireCountTalent
            local base = tr.requireCount or 1
            local talName = g and g.talent and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(g.talent)
            if g and talName then
                -- State BOTH cases so it's clear what's tracked with and without the talent.
                P._setLbl:SetText(("Keep |cffffd100%d|r up — |cffffd100%d|r with %s:"):format(base, g.count or base, talName))
            else
                P._setLbl:SetText(("Keep |cffffd100%d|r up (any of the pool):"):format(base))
            end
            L(P._setLbl, y, 16); y = y + ROW
            local names = {}
            for _, id in ipairs(tr.matchAny) do
                names[#names + 1] = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("#" .. id)
            end
            P._setHint:SetWidth(430); P._setHint:SetJustifyH("LEFT"); P._setHint:SetWordWrap(true)
            P._setHint:SetText("|cff888888Counts any of: " .. table.concat(names, ", ") .. "|r")
            L(P._setHint, y, 16)
            y = y + math.max(ROW - 2, (P._setHint:GetStringHeight() or 14) + 8)

            -- Which poison CLICK-TO-CAST applies. "Auto" = the first one that's missing; or pin your
            -- own so the click always reapplies the poison you actually run.
            local items = { { value = "", text = "Auto (first missing)" } }
            for i, id in ipairs(tr.matchAny) do items[i + 1] = { value = id, text = names[i] } end
            P._poisonCast:SetItems(items)
            local curName = tr.castPref and ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.castPref)) or ("#" .. tr.castPref))
            P._poisonCast:SetText(curName or "Auto (first missing)")
            L(P._poisonCastLbl, y, 16); put(P._poisonCast, y); y = y + ROW

            -- Second poison — only meaningful with a talent that runs 2 of the category (DTB), so
            -- it's shown for those widgets only, with a note that it does nothing without the talent.
            if g and talName then
                P._poisonCast2:SetItems(items)
                local cur2 = tr.castPref2 and ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.castPref2)) or ("#" .. tr.castPref2))
                P._poisonCast2:SetText(cur2 or "Auto (first missing)")
                L(P._poisonCast2Lbl, y, 16); put(P._poisonCast2, y); y = y + ROW
                P._poisonCast2Note:SetText(("|cff888888Only used while %s is taken.|r"):format(talName))
                L(P._poisonCast2Note, y, 16); y = y + ROW - 4
            end
        elseif tr.chooseFrom then
            -- Interchangeable variants (Paladin Devotion / Concentration): a picker, not a free
            -- spell field — you track ONE specific intended aura.
            L(P._ntChooseLbl, y, 16); put(P._ntChoose, y)
            local items = {}
            for _, nm in ipairs(tr.chooseFrom) do items[#items + 1] = { value = nm, text = nm } end
            P._ntChoose:SetItems(items)
            local curName = tr.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tr.spellID)
            P._ntChoose:SetText(curName or tr.chooseFrom[1] or "Choose an aura")
            y = y + ROW
        else
            showSpell("Spell")
            showItem()   -- optional: the item whose buff this tracks (an augment rune) → click uses it
        end
        -- Cast-timer: for a buff we can't read in combat (Astral Shift etc.), time it
        -- from the cast. Shown for any single (non-stack) Buff source so it's always
        -- findable; auto-fills the detected length only when we're SURE it's hidden.
        if tr.type == "aura" and tr.spellID and not tr.matchAny and not disc then
            -- Relevant (auto-reveal) when the aura is combat-hidden (needs the cast-timer), or when
            -- either advanced option is already set. Otherwise offer them behind "Advanced…".
            local hidden = ns.AuraSecretInCombat and ns.AuraSecretInCombat(tr.spellID) == true
            if tr.castTimer == nil and hidden then tr.castTimer = ns.SpellBuffDuration(tr.spellID) or 0 end
            local relevant = hidden or (tr.castTimer or 0) > 0 or tr.groupGlow
            chk(P._auraAdv, y); P._auraAdv:SetChecked(P._auraAdvOpen or relevant and true or false); y = y + ROW
            if P._auraAdvOpen or relevant then
                L(P._lblCastTimer, y, 16); put(P._castTimer, y); P._castTimer:Set(tr.castTimer or 0); y = y + ROW
                -- Group-buff (Skyfury): react to the action-bar glow instead of your aura.
                chk(P._groupGlow, y); P._groupGlow:SetChecked(tr.groupGlow and true or false); y = y + ROW
            end
        end
    end

    -- Folder (organization only; independent of spec). Scoped to this widget's class so
    -- you can't file it under another class's folder.
    L(P._lblFolder, y); put(P._folder, y)
    P._folder:SetItems(OPT.folderOptsFor(ns.ClassOfCfg(c), c.folder)); P._folder:SetText(c.folder or "(No folder)")
    y = y + ROW

    elseif tab == "display" then
    y = sub("DISPLAY", y, true)
    L(P._lblDisplay, y, 20)
    local dx = GUT
    for _, dt in ipairs({ "bar", "icon" }) do
        put(P._disp[dt], y, dx); P._disp[dt]:SetActive(c.display == dt); dx = dx + 52
    end
    y = y + ROW
    -- Size lives right under the bar/icon choice — one place for "what + how big".
    L(P._lblWidth, y, 16);  put(P._w, y); P._w:Set(c.width or 240);  y = y + ROW
    L(P._lblHeight, y, 16); put(P._h, y); P._h:Set(c.height or 26);  y = y + ROW
    -- Border: thickness (0 = none) + colour.
    L(P._lblBorder, y, 16); put(P._borderSize, y); P._borderSize:Set(c.borderSize == nil and 1 or c.borderSize); y = y + ROW
    L(P._lblBorderCol, y, 22); put(P._borderColor, y); P._borderColor:Refresh(); y = y + ROW

    -- "Segmented" (one field, both display types): a count/discrete-power tracker can draw as
    -- N discrete cells — filled boxes on a bar (runes, combo points, MSW stacks) or one icon per
    -- charge on an icon (Tip of the Spear). Gap tunes the spacing; the 5+5 split is bar+MSW only.
    if disc then
        chk(P._segShow, y); P._segShow:SetChecked(c.segments and true or false); y = y + ROW
        if c.segments then
            L(P._lblSegGap, y, 16); put(P._segGap, y); P._segGap:Set(c.segmentGap or ns.SEG_GAP_DEFAULT); y = y + ROW
            local isStackAura = isBar and tr and tr.type == "aura" and tr.spellID == 344179   -- Enh MSW only
            if isStackAura then
                chk(P._split, y); P._split:SetChecked(c.split ~= nil)
                if c.split then
                    P._splitColor:ClearAllPoints(); P._splitColor:SetPoint("LEFT", P._split._fs, "RIGHT", 12, 0); P._splitColor:Show(); P._splitColor:Refresh()
                    P._splitLbl:ClearAllPoints(); P._splitLbl:SetPoint("LEFT", P._splitColor, "RIGHT", 6, 0); P._splitLbl:Show()
                end
                y = y + ROW
            end
        end
    end
    if isBar then   -- colour + texture only matter for a fill bar (icon uses spell art)
        y = sub("FILL", y)
        L(P._lblColour, y, 22); put(P._col, y); P._col:Refresh(); y = y + ROW
        L(P._lblTexture, y); put(P._tex, y)
        P._tex:SetItems(OPT.mediaOpts(ns.Media.BarList())); P._tex:SetText(c.texture or "Blizzard"); y = y + ROW
    end
    -- Colour stops: the bar recolours as it fills, and can ping you at a stop. One editor for every
    -- fill bar — a COUNT bar (MSW/runes/combo) enters stops as counts, a continuous bar as % fill;
    -- both store a 0..1 pct under the hood. Sound needs a readable value, so it's hidden on a secret
    -- power fill (Mana/Maelstrom). Count bars are readable, so they keep their pings.
    if isBar then
        y = sub("COLOUR STOPS", y)
        chk(P._curveChk, y); P._curveChk:SetChecked(c.colorCurve ~= nil); y = y + ROW
        if c.colorCurve then
            P._curveType._fs:SetText((c.colorCurve.type == "Step") and "Step" or "Linear")
            put(P._curveType, y, 16)
            P._curveReset:ClearAllPoints(); P._curveReset:SetPoint("LEFT", P._curveType, "RIGHT", 8, 0); P._curveReset:Show()
            y = y + 28
            local secretPower = tr and tr.type == "power" and not (ns.IsDiscretePower and ns.IsDiscretePower(tr.power))
            local canSound = not secretPower
            -- Count bars show/edit stops as a count; convert via the tracker's max (fixed max, live
            -- discrete-power ceiling, or a sane default) so 5/10 read as 5/10, not 50%/100%.
            local countMode = disc
            local mx = countMode and ((tr and type(tr.max) == "number" and tr.max)
                or (tr and tr.type == "power" and ns.PowerMax and ns.PowerMax(tr.power)) or 10) or nil
            for i, pnt in ipairs(c.colorCurve.points or {}) do
                local rowF = P._curveRows[i] or curvePointRow(i)
                rowF._entry = pnt; rowF._sw:Refresh()
                rowF._countMode, rowF._max = countMode, mx
                if countMode then
                    rowF._pct:SetText(tostring(math.floor((pnt.pct or 0) * mx + 0.5)))
                    rowF._pctLbl:SetText("")
                else
                    rowF._pct:SetText(tostring(math.floor((pnt.pct or 0) * 100 + 0.5)))
                    rowF._pctLbl:SetText("% fill")
                end
                if canSound then
                    rowF._snd:Show(); rowF._play:Show()
                    rowF._snd:SetItems(soundOpts()); rowF._snd:SetText(soundText(pnt.sound))
                    rowF._del:ClearAllPoints(); rowF._del:SetPoint("LEFT", rowF._play, "RIGHT", 6, 0)
                else
                    rowF._snd:Hide(); rowF._play:Hide()
                    rowF._del:ClearAllPoints(); rowF._del:SetPoint("LEFT", rowF._pctLbl, "RIGHT", 14, -4)
                end
                put(rowF, y, 16); y = y + 26
            end
            put(P._addPoint, y, 16); y = y + 30
        end
    end
    y = sub("TEXT", y)
    L(P._lblFont, y); put(P._font, y)
    P._font:SetItems(OPT.mediaOpts(ns.Media.FontList())); P._font:SetText(c.font or "Friz Quadrata TT"); y = y + ROW
    P._lblSize:SetText("Size")
    L(P._lblSize, y, 16); put(P._fontSize, y); P._fontSize:Set(c.fontSize or 13); y = y + ROW
    -- Text: a show toggle; then (bars) format and the position offsets on their own rows.
    P._showText._fs:SetText("Show text")
    chk(P._showText, y); P._showText:SetChecked(c.showText ~= false); y = y + ROW
    if isBar then
        P._lblText:SetText("Format")
        L(P._lblText, y); put(P._fmt, y); P._fmt:SetText(OPT.fmtText(c.textFormat)); y = y + ROW
    end
    L(P._lblAnchor, y, 16); put(P._anchor, y)
    P._anchor:SetText(OPT.anchorText(c.textAnchor or (isBar and "CENTER" or "BOTTOMRIGHT"))); y = y + ROW
    -- Anchor is the drag-first placement; the X/Y nudges hide behind "Fine-tune position" until
    -- opened, or auto-reveal when an offset is already set (so a nudged widget still shows them).
    local posSet = (c.textOffsetX or 0) ~= 0 or (c.textOffsetY or 0) ~= 0
    chk(P._posAdv, y); P._posAdv:SetChecked(P._posAdvOpen or posSet); y = y + ROW
    if P._posAdvOpen or posSet then
        -- X and Y on their own rows: the slider's editable value sits to its right, so a
        -- shared row would bury the Y label behind the X value (and now its edit field).
        P._lblPos:SetText("Text X")
        L(P._lblPos, y, 16); put(P._offX, y); P._offX:Set(c.textOffsetX or 0); y = y + ROW
        P._lblOffY:SetText("Text Y")
        L(P._lblOffY, y, 16); put(P._offY, y); P._offY:Set(c.textOffsetY or 0); y = y + ROW
    end
    -- HIGHLIGHT (icons): one place for the icon's glow, with its two trigger states — a steady
    -- glow while the buff is active/ready, and a pulse while a "missing" reminder is on screen.
    -- They're mode-exclusive (a missing reminder is hidden while the buff is up, so only its pulse
    -- applies; everything else uses the steady glow), and share one Effect style shown once.
    if c.display == "icon" then
        local mode = OPT.reminderMode(c)
        local canActive = mode ~= "missing"   -- steady glow is pointless in missing mode (icon hidden while up)
        local canPulse  = mode ~= "off"       -- pulse only matters when a reminder shows the icon
        if canActive or canPulse then
            y = sub("HIGHLIGHT", y)
            if canActive then
                chk(P._activeGlow, y); P._activeGlow:SetChecked(c.activeGlow and true or false)
                if c.activeGlow then
                    P._activeGlowColor:ClearAllPoints(); P._activeGlowColor:SetPoint("LEFT", P._activeGlow._fs, "RIGHT", 12, 0); P._activeGlowColor:Show(); P._activeGlowColor:Refresh()
                end
                y = y + ROW
            end
            if canPulse then
                chk(P._pulseChk, y); P._pulseChk:SetChecked(c.pulse ~= false)
                if c.pulse ~= false then
                    P._pulseColor:ClearAllPoints(); P._pulseColor:SetPoint("LEFT", P._pulseChk._fs, "RIGHT", 12, 0); P._pulseColor:Show(); P._pulseColor:Refresh()
                end
                y = y + ROW
            end
            -- Shared Effect style, shown when either trigger is on.
            if (canActive and c.activeGlow) or (canPulse and c.pulse ~= false) then
                L(P._lblGlow, y); put(P._glowStyle, y)
                P._glowStyle:SetItems(OPT.GLOW_OPTS); P._glowStyle:SetText(OPT.glowText(c.glowStyle))
                y = y + ROW
            end
        end
    end
    -- (The "Segmented" toggle + gap + 5+5 split now render up top, right after Border, for both
    -- bar and icon — see the `if disc then` block above.)
    if isBar then y = sub("BAR OPTIONS", y) end
    if isBar then   -- fill motion is meaningless for an icon (no fill)
        chk(P._smooth, y); P._smooth:SetChecked(c.smooth ~= false)
        P._spark:ClearAllPoints(); P._spark:SetPoint("LEFT", P._smooth._fs, "RIGHT", 18, 0); P._spark:Show()
        P._spark:SetChecked(c.spark and true or false)
        y = y + ROW
    end
    -- "Glow when full" — only where the value can actually READ full: a continuous power bar
    -- (Mana/Maelstrom…) is secret, so its value never compares to max and the glow could never
    -- fire; hide it there rather than offer a dead toggle. Count/aura/value bars keep it.
    local contPower = tr and tr.type == "power" and not (ns.IsDiscretePower and ns.IsDiscretePower(tr.power))
    if isBar and not contPower then
        chk(P._fullGlow, y); P._fullGlow:SetChecked(c.fullGlow and true or false)
        if c.fullGlow then
            P._fullGlowColor:ClearAllPoints(); P._fullGlowColor:SetPoint("LEFT", P._fullGlow._fs, "RIGHT", 12, 0)
            P._fullGlowColor:Show(); P._fullGlowColor:Refresh()
        end
        y = y + ROW
    end

    -- Markers are value cues drawn on a bar → they live under Display. (Thresholds merged into the
    -- COLOUR STOPS section above — one place for "recolour as it fills, maybe ping me".)
    local isMana         = tr and tr.power == "MANA"
    local showMarkers    = isBar and not disc and not isMana
    if showMarkers then
        y = sub("MARKERS", y, y == 8)
        P._mkHint:ClearAllPoints(); P._mkHint:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._mkHint:SetWidth(440); P._mkHint:Show()
        y = y + 30
        local mk = c.markers or {}
        for i, m in ipairs(mk) do
            local rowF = P._mkRows[i] or markerRow(i)
            rowF._entry = m
            local mode = m.mode or "value"
            rowF._mode:SetText(markMode(mode)); rowF._sw:Refresh()
            -- Per-marker spec gate (all modes): this class's specs + "All specs".
            local mSpecItems = { { value = "all", text = "All specs" } }
            for _, s in ipairs(ns.ClassSpecs(ns.ClassOfCfg(c)) or {}) do mSpecItems[#mSpecItems + 1] = { value = s.id, text = s.name } end
            rowF._spec:SetItems(mSpecItems); rowF._spec:SetText(markerSpecText(m)); rowF._spec:Show()
            if mode == "spell" then
                rowF._num:Hide(); rowF._numHint:Hide()
                local sid = ns.MarkerSpell(m)   -- the id you actually have (bundles resolve to it)
                local nm = sid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                local ic = sid and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
                -- "+N" only when the bundle holds other DISTINCT spells (so Earthquake's
                -- two same-named cast forms don't read as "+1").
                local extra = ""
                if m.spellIDs and #m.spellIDs > 1 and C_Spell and C_Spell.GetSpellName then
                    local names = {}
                    for _, id in ipairs(m.spellIDs) do local n = C_Spell.GetSpellName(id); if n then names[n] = true end end
                    local distinct = 0; for _ in pairs(names) do distinct = distinct + 1 end
                    if distinct > 1 then extra = " |cff7fb0d0(+" .. (distinct - 1) .. ")|r" end
                end
                rowF._spell._ic:SetTexture(ic or 134400)
                rowF._spell._fs:SetText((nm and (nm .. extra)) or (sid and ("|cffff8080id " .. sid .. "|r")) or "|cff9fd6ffchoose a spell…|r")
                rowF._spell:Show(); rowF._add:Show()
                rowF._line:Show(); rowF._line:SetChecked(m.line ~= false)
                rowF._glow:Show(); rowF._glow:SetChecked(m.alert and true or false)
                rowF:SetHeight(48)
            else
                rowF._spell:Hide(); rowF._add:Hide(); rowF._glow:Hide(); rowF._line:Hide()
                rowF._num:Show(); rowF._num:SetText(m.value and tostring(m.value) or "")
                rowF._numHint:Show(); rowF._numHint:SetText(mode == "percent" and "% of bar" or "")
                rowF:SetHeight(48)   -- line 1 (value) + line 2 (spec gate)
            end
            rowF:ClearAllPoints(); rowF:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); rowF:Show()
            y = y + rowF:GetHeight() + 6
        end
        P._addMarker:ClearAllPoints(); P._addMarker:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._addMarker:Show()
        y = y + 30
    end
    elseif tab == "when" then
    -- Show-on specs: which specs this widget appears on (none lit = all specs). For a
    -- foreign-class widget these are ITS class's specs, so you edit the right ones (and
    -- can't overwrite it with your own specs).
    y = sub("WHERE IT SHOWS", y, true)
    L(P._lblOn, y, 20)
    local sx = GUT
    local wClass = ns.ClassOfCfg(c)
    local specList = (wClass and wClass ~= ns.playerClass) and ns.ClassSpecs(wClass) or OPT.SPEC_LIST()
    for _, sp in ipairs(specList) do
        local b = P._ensureSpecBtn(sp)
        put(b, y, sx)
        b:SetActive(c.specs and c.specs[sp.id] and true or false)
        sx = sx + 32
    end
    if not (c.specs and next(c.specs)) then
        P._specAll:ClearAllPoints(); P._specAll:SetPoint("LEFT", ed, "TOPLEFT", X + sx + 6, -(y + 10)); P._specAll:Show()
    end
    y = y + ROW

    -- "Only in form": offered when the player's own class has shapeshift forms (the gate reads the
    -- live shapeshift bar, so it's meaningless for a foreign-class widget).
    local forms = ns.PlayerForms()
    if #forms > 0 and (not wClass or wClass == ns.playerClass) then
        local items = { { value = "any", text = "Any form" } }
        for _, f in ipairs(forms) do items[#items + 1] = { value = f.spellID, text = f.name } end
        L(P._lblFormGate, y, 16); put(P._formGate, y)
        P._formGate:SetItems(items)
        P._formGate:SetText((c.formGate and (c.formGate.name
            or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c.formGate.spellID)))) or "Any form")
        y = y + ROW
    end

    -- Reminder: when this widget appears (source-agnostic — aura missing/active, cooldown
    -- ready, or a readable value over/under a threshold).
    local isThresholdable = isAura
    if isAura or isImbue or isCooldown or isEarthShield then
        y = sub("REMINDER", y)
        local mode
        if isEarthShield then
            -- Earth Shield is inherently a "missing" reminder (shows when a shield is
            -- down, in a group) — no mode to pick, but the glow IS adjustable below.
            mode = "missing"
            P._esNote:SetText("|cff888888Shows in a group when a shield is missing (self or ally); silent solo.|r")
            P._esNote:ClearAllPoints(); P._esNote:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._esNote:Show()
            y = y + 22
        else
            mode = OPT.reminderMode(c)
            L(P._lblReminder, y, 16); put(P._reminder, y)
            P._reminder:SetItems(OPT.reminderOpts(isAura, isImbue, isCooldown, isThresholdable))
            P._reminder:SetText(OPT.reminderText(mode)); y = y + ROW
        end

        if mode ~= "off" then
            if mode == "atLeast" or mode == "atMost" then
                P._lblRemVal:SetText("Stacks")
                L(P._lblRemVal, y, 16); put(P._remVal, y)
                P._remVal:SetText(tostring((c.reminder and c.reminder.value) or 1)); y = y + ROW
            end
            if tr and tr.spellID then
                chk(P._learned, y); P._learned:SetChecked(c.onlyWhenLearned ~= false); y = y + ROW
            end
            -- Click-to-cast: only the "press this now" reminders (missing / ready) with a
            -- castable spell behind them (Earth Shield's tracker has no spellID but casts 974).
            if (mode == "missing" or mode == "ready") and ((tr and tr.spellID) or isEarthShield) then
                chk(P._clickCast, y); P._clickCast:SetChecked(c.clickToCast ~= false); y = y + ROW
            end
            if mode == "missing" and not isEarthShield then
                P._lblWarn:SetText("Warn under (min)")
                L(P._lblWarn, y, 16); put(P._warn, y, 116); P._warn:Set((c.warnLowSec or 0) / 60); y = y + ROW   -- wider gutter: the label is longer than the default 80
            end
            -- Only warn in combat (any reminder mode): suppress OOC, for forms/stances. Show the
            -- pre-combat caveat only when it's on (that's when it matters).
            chk(P._combatOnly, y); P._combatOnly:SetChecked((c.reminder and c.reminder.combatOnly) and true or false); y = y + ROW
            if c.reminder and c.reminder.combatOnly then
                P._combatOnlyNote:ClearAllPoints(); P._combatOnlyNote:SetPoint("TOPLEFT", ed, "TOPLEFT", X + 24, -y); P._combatOnlyNote:SetWidth(400); P._combatOnlyNote:Show()
                y = y + 20
            end
            -- (The pulse-while-reminding toggle moved to the HIGHLIGHT group on the Display tab,
            -- alongside the steady active/ready glow — one "highlight" concept, one shared style.)
        end
    end

    -- Form / pet / ally reminders are inherently "missing" and don't use the reminder editor above,
    -- but "Only warn in combat" is exactly for them (druid forms/stances) — so surface it here too.
    if not (isAura or isImbue or isCooldown or isEarthShield) and ns.ReminderMode(c) ~= "off" then
        y = sub("REMINDER", y)
        chk(P._combatOnly, y); P._combatOnly:SetChecked((c.reminder and c.reminder.combatOnly) and true or false); y = y + ROW
        if c.reminder and c.reminder.combatOnly then
            P._combatOnlyNote:ClearAllPoints(); P._combatOnlyNote:SetPoint("TOPLEFT", ed, "TOPLEFT", X + 24, -y); P._combatOnlyNote:SetWidth(400); P._combatOnlyNote:Show()
            y = y + 20
        end
    end

    elseif tab == "layout" then
    -- GROUP — one place to resize / space every member, so you don't open each icon to
    -- change a shared property. Only when this widget is in a group.
    local groupIds, gid = OPT.groupMemberIds(P.selectedId)
    local grp = gid and ns.Groups.Get(gid)
    if grp then
        y = sub("GROUP", y, true)
        P._grpInfo:ClearAllPoints(); P._grpInfo:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y)
        P._grpInfo:SetText(("|cff9fd6ff%d|r in this group — changes here apply to all"):format(#groupIds)); P._grpInfo:Show()
        y = y + 22
        local nIcons, nBars = 0, 0
        for _, wid in ipairs(groupIds) do
            local d = ns.profile.widgets[wid].display
            if d == "icon" then nIcons = nIcons + 1 elseif d == "bar" then nBars = nBars + 1 end
        end
        if nIcons > 0 then
            L(P._lblGrpSize, y, 16); put(P._grpSize, y)
            P._grpSize:Set((c.display == "icon" and c.width) or 40)
            y = y + ROW
        end
        -- Bars: share width and/or height across the group (each an opt-in, so you can do
        -- width-only, both, or neither). When on, its slider governs every bar member.
        if nBars > 0 then
            local shW, shH = OPT.groupShare(grp)
            chk(P._grpWMatch, y); P._grpWMatch:SetChecked(shW); y = y + ROW
            if shW then
                L(P._lblGrpWidth, y, 16); put(P._grpWidth, y)
                P._grpWidth:Set((c.display == "bar" and c.width) or OPT.firstBarDim(groupIds, "w"))
                y = y + ROW
            end
            chk(P._grpHMatch, y); P._grpHMatch:SetChecked(shH); y = y + ROW
            if shH then
                L(P._lblGrpHeight, y, 16); put(P._grpHeight, y)
                P._grpHeight:Set((c.display == "bar" and c.height) or OPT.firstBarDim(groupIds, "h"))
                y = y + ROW
            end
        end
        -- Direction: new groups are horizontal; switch to vertical to stack them.
        L(P._lblGrpAxis, y, 16)
        local ax = (grp.axis == "v") and "v" or "h"
        local axx = GUT
        for _, k in ipairs({ "h", "v" }) do
            local b = P._grpAxis[k]; b:ClearAllPoints(); b:SetPoint("TOPLEFT", ed, "TOPLEFT", axx, -y); b:Show()
            b:SetActive(ax == k); axx = axx + 98
        end
        y = y + ROW
        L(P._lblGrpGap, y, 16); put(P._grpGap, y)
        P._grpGap:Set(grp.gap or 0)
        y = y + ROW
    end
    y = sub("ARRANGING", y, not grp)
    P._grpHelp:ClearAllPoints(); P._grpHelp:SetPoint("TOPLEFT", ed, "TOPLEFT", X, -y); P._grpHelp:Show()
    y = y + 58
    end

    ed:SetHeight(y + 12)
    if P._edUpdateScrollbar then P._edUpdateScrollbar() end
end
