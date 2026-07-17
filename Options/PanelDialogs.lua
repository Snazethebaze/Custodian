-- Options/PanelDialogs.lua : the panel's modal dialogs — share import/export, the pre-combat
-- (secret buff) explainer, and the generic confirm gate.
--
-- Split out of Options/Panel.lua. These were forward-declared locals there; they are now entry
-- points on the shared ns.OPT table (see the seam note in Panel.lua). Each reads OPT.P — the
-- panel frame — at call time, so this file only needs ns.OPT to exist at load, and every dialog
-- is built lazily on first open.

local ADDON, ns = ...

local OPT = ns.OPT
local T  = ns.Theme
local UI = ns.UI
local border, bgTex = UI.border, UI.bgTex
local Label, Button, Check = UI.Label, UI.Button, UI.Check
local spellTip = UI.spellTip

-- Every modal here shares the same chrome: a click-eating dim over the panel, plus a centered
-- dialog frame that shows/hides the dim with it. Returns the dialog frame; the caller fills its
-- contents and stashes it (P._share / _pcw / _cfm) so the builder is a one-time no-op after.
local function makeDialog(w, h, dimAlpha)
    local P = OPT.P
    local dim = CreateFrame("Frame", nil, P); dim:SetAllPoints(P); dim:SetFrameStrata("FULLSCREEN")
    dim:EnableMouse(true); dim:Hide(); bgTex(dim, 0, 0, 0, dimAlpha)
    local dlg = CreateFrame("Frame", nil, P); dlg:SetSize(w, h); dlg:SetPoint("CENTER")
    dlg:SetFrameStrata("FULLSCREEN_DIALOG"); dlg:EnableMouse(true); dlg:Hide()
    bgTex(dlg, T.rgba(T.surface.panel)); border(dlg)
    dlg:SetScript("OnShow", function() dim:Show() end)
    dlg:SetScript("OnHide", function() dim:Hide() end)
    return dlg
end

-- ══ Import / export share dialog ══════════════════════════════════════
-- Replaces profiles: a copy-paste overlay. Export fills the box with the string (the
-- multi-line box soft-wraps it to full-width rows); Import reads a pasted string and
-- adds the widgets.

function OPT.buildShareDialog()
    local P = OPT.P
    if P._share then return end
    local dlg = makeDialog(520, 340, 0.5)
    P._share = dlg

    dlg._title = Label(dlg, "", "GameFontNormalLarge"); dlg._title:SetPoint("TOPLEFT", 16, -14)
    dlg._hint = Label(dlg, "", "GameFontHighlightSmall")
    dlg._hint:SetPoint("TOPLEFT", 16, -40); dlg._hint:SetPoint("RIGHT", -16, 0)
    dlg._hint:SetJustifyH("LEFT"); dlg._hint:SetTextColor(T.rgba(T.text.info))

    -- A scroll viewport holding a multi-line EditBox scroll child, so a long export/import
    -- string scrolls (draggable scrollbar) and is fully clipped inside the box.
    local box = CreateFrame("Frame", nil, dlg); box:SetPoint("TOPLEFT", 16, -78); box:SetPoint("BOTTOMRIGHT", -16, 48)
    bgTex(box, T.rgba(T.surface.control)); border(box); box:EnableMouse(true)
    local view = CreateFrame("ScrollFrame", nil, box)
    view:SetPoint("TOPLEFT", 2, -2); view:SetPoint("BOTTOMRIGHT", -2, 2)
    view:SetClipsChildren(true)
    local eb = CreateFrame("EditBox", nil, view)
    eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(4, 4, 4, 4); eb:SetWidth(1)
    eb:SetScript("OnEscapePressed", function() dlg:Hide() end)
    view:SetScrollChild(eb)
    box:SetScript("OnMouseDown", function() eb:SetFocus() end)
    dlg._eb, dlg._view = eb, view

    -- Grow the editbox to its content so the viewport can scroll it; wrap width leaves a
    -- gutter clear of the scrollbar. Called on show + whenever the text changes.
    local vMax = function() return math.max(0, (eb:GetHeight() or 0) - (view:GetHeight() or 0)) end
    local function sizeEB()
        local vw = view:GetWidth() or 0
        if vw > 12 then eb:SetWidth(vw - 12) end
        local t = eb:GetText() or ""
        local lines = 1; for _ in t:gmatch("\n") do lines = lines + 1 end
        eb:SetHeight(math.max(view:GetHeight() or 1, lines * 14 + 10))
        if dlg._sbUpdate then dlg._sbUpdate() end
    end
    dlg._sizeEB = sizeEB
    eb:SetScript("OnTextChanged", function() sizeEB() end)

    dlg._sbUpdate = ns.UI.MakeScrollbar(box, view, {
        getMax = vMax,
        get    = function() return view:GetVerticalScroll() end,
        set    = function(v) view:SetVerticalScroll(math.max(0, math.min(vMax(), v))) end,
        frac   = function() local h = eb:GetHeight() or 1; return (h > 0) and ((view:GetHeight() or 1) / h) or 1 end,
    })
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(_, d)
        view:SetVerticalScroll(math.max(0, math.min(vMax(), view:GetVerticalScroll() - d * 28)))
        dlg._sbUpdate()
    end)

    -- Button bar: the primary action (Copy / Import) sits bottom-right, accent-lit;
    -- Close/Cancel to its left; the status message runs along the bottom-left.
    dlg._ok = Button(dlg, "", 110, 24); dlg._ok:SetPoint("BOTTOMRIGHT", -16, 14); dlg._ok:SetActive(true)
    dlg._cancel = Button(dlg, "Close", 92, 24); dlg._cancel:SetPoint("RIGHT", dlg._ok, "LEFT", -8, 0)
    dlg._cancel:SetScript("OnClick", function() dlg:Hide() end)
    dlg._status = Label(dlg, "", "GameFontDisableSmall"); dlg._status:SetPoint("BOTTOMLEFT", 16, 21)
    dlg._status:SetPoint("RIGHT", dlg._cancel, "LEFT", -12, 0); dlg._status:SetJustifyH("LEFT")
end

function OPT.openShareExport(str, label)
    local P = OPT.P
    if not str then ns.Print("Nothing to export."); return end
    OPT.buildShareDialog()
    local dlg = P._share
    dlg._title:SetText("Export" .. (label and (" \226\128\148 |cffffd100" .. label .. "|r") or ""))
    dlg._hint:SetText("Press |cffffd100Select all|r then |cffffd100Ctrl+C|r to copy, and share the string. The recipient pastes it into Import.")
    dlg._eb:SetText(str)
    dlg._status:SetText("")
    dlg._cancel._fs:SetText("Close")
    dlg._ok._fs:SetText("Select all"); dlg._ok:Show()
    dlg._ok:SetScript("OnClick", function()
        dlg._eb:SetFocus(); dlg._eb:HighlightText()
        dlg._status:SetText("|cffffd100Selected \226\128\148 press Ctrl+C to copy.|r")
    end)
    dlg:Show(); dlg:Raise()
    C_Timer.After(0.05, function()
        if not dlg:IsShown() then return end
        if dlg._sizeEB then dlg._sizeEB() end
        if dlg._view then dlg._view:SetVerticalScroll(0) end
        if dlg._sbUpdate then dlg._sbUpdate() end
        dlg._eb:SetCursorPosition(0); dlg._eb:SetFocus(); dlg._eb:HighlightText()
    end)
end

function OPT.openShareImport()
    local P = OPT.P
    OPT.buildShareDialog()
    local dlg = P._share
    dlg._title:SetText("Import")
    dlg._hint:SetText("Paste a shared Custodian string, then |cffffd100Import|r. It ADDS the widgets to your setup — nothing is overwritten.")
    dlg._eb:SetText("")
    dlg._status:SetText("")
    dlg._cancel._fs:SetText("Cancel")
    dlg._ok._fs:SetText("Import"); dlg._ok:Show()
    dlg._ok:SetScript("OnClick", function()
        local ok, res = ns.Share.Import(dlg._eb:GetText())
        if ok then
            dlg._status:SetText(("|cff40ff40Imported %d widget(s).|r"):format(tonumber(res) or 0))
            C_Timer.After(0.9, function() if dlg:IsShown() then dlg:Hide() end end)
        else
            dlg._status:SetText("|cffff5555Couldn't import: " .. tostring(res) .. "|r")
        end
    end)
    if dlg._sizeEB then dlg._sizeEB() end
    if dlg._view then dlg._view:SetVerticalScroll(0) end
    if dlg._sbUpdate then dlg._sbUpdate() end
    dlg:Show(); dlg:Raise()
    C_Timer.After(0.05, function() if dlg:IsShown() then dlg._eb:SetFocus() end end)
end

-- ══ Pre-combat (secret buff) explainer modal ══════════════════════════
-- Fires the first time a user adds a buff that Midnight hides from addons in combat, so a
-- "pre-combat" reminder is a deliberate choice, not a surprise when it stops updating mid-fight.
-- Suppressible via a "don't warn again" checkbox (ns.profile._noPreCombatWarn, cross-char).
function OPT.buildPreCombatDialog()
    local P = OPT.P
    if P._pcw then return end
    local dlg = makeDialog(470, 320, 0.55)
    P._pcw = dlg

    dlg._title = Label(dlg, "|cffe6a53cHeads up|r — this buff hides in combat", "GameFontNormalLarge")
    dlg._title:SetPoint("TOPLEFT", 18, -16)

    dlg._body = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dlg._body:SetPoint("TOPLEFT", 18, -46); dlg._body:SetWidth(434)
    dlg._body:SetJustifyH("LEFT"); dlg._body:SetJustifyV("TOP"); dlg._body:SetWordWrap(true)
    dlg._body:SetSpacing(3)
    dlg._body:SetText(
        "In the Midnight update (patch 12.0), Blizzard made buff and resource timers |cffffd100secret|r to addons while you're in combat.\n\n"
        .. "Custodian can't read a hidden buff's timer mid-fight, so a widget for it works as a |cffffd100pre-combat check|r: set it up before you pull and it shows whether the buff is |cffffffffmissing|r. Once the fight starts it stops live-updating until you leave combat.\n\n"
        .. "It's still useful — it catches a missing buff before the pull. Buffs, imbues and resources marked |cff5ec888live|r read fine in combat; only |cffe6a53cpre-combat|r ones are affected.")

    dlg._chk = Check(dlg, "Don't warn me about pre-combat buffs again", function() end)
    dlg._chk:SetPoint("BOTTOMLEFT", 18, 50)

    dlg._ok = Button(dlg, "Add it anyway", 128, 24); dlg._ok:SetPoint("BOTTOMRIGHT", -16, 14); dlg._ok:SetActive(true)
    dlg._cancel = Button(dlg, "Cancel", 92, 24); dlg._cancel:SetPoint("RIGHT", dlg._ok, "LEFT", -8, 0)

    local function dismiss(proceed)
        if dlg._chk:GetChecked() and ns.profile then ns.profile._noPreCombatWarn = true end
        dlg:Hide()
        local fn = dlg._onProceed; dlg._onProceed = nil
        if proceed and fn then fn() end
    end
    dlg._ok:SetScript("OnClick", function() dismiss(true) end)
    dlg._cancel:SetScript("OnClick", function() dismiss(false) end)
end

-- Show the explainer before running onProceed (the actual add). If the user has suppressed it,
-- run onProceed straight away — no modal.
function OPT.openPreCombatWarning(onProceed)
    local P = OPT.P
    if ns.profile and ns.profile._noPreCombatWarn then if onProceed then onProceed() end; return end
    OPT.buildPreCombatDialog()
    local dlg = P._pcw
    dlg._onProceed = onProceed
    dlg._chk:SetChecked(false)
    dlg:Show(); dlg:Raise()
end

-- ══ Generic confirm modal ═════════════════════════════════════════════
-- A reusable Yes/Cancel gate before an add. cfg = { title, body, yes(button label), onYes,
-- linkSpell }. linkSpell shows a hoverable spell/talent row (icon + name + game tooltip) — used
-- to link the required talent (e.g. Elemental Orbit) so the user can check it before committing.
function OPT.buildConfirmDialog()
    local P = OPT.P
    if P._cfm then return end
    local dlg = makeDialog(456, 250, 0.55)
    P._cfm = dlg

    dlg._title = Label(dlg, "", "GameFontNormalLarge"); dlg._title:SetPoint("TOPLEFT", 18, -16)
    dlg._body = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dlg._body:SetPoint("TOPLEFT", 18, -46); dlg._body:SetWidth(420)
    dlg._body:SetJustifyH("LEFT"); dlg._body:SetJustifyV("TOP"); dlg._body:SetWordWrap(true); dlg._body:SetSpacing(3)

    dlg._link = CreateFrame("Button", nil, dlg); dlg._link:SetSize(420, 26)
    dlg._link._bg = bgTex(dlg._link, T.rgba(T.surface.controlAlt)); border(dlg._link)
    dlg._link._icon = dlg._link:CreateTexture(nil, "ARTWORK"); dlg._link._icon:SetPoint("LEFT", 5, 0); dlg._link._icon:SetSize(18, 18); dlg._link._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dlg._link._t = dlg._link:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); dlg._link._t:SetPoint("LEFT", dlg._link._icon, "RIGHT", 8, 0)
    dlg._link:SetScript("OnEnter", function() dlg._link._bg:SetColorTexture(T.rgba(T.surface.controlHot)) end)
    dlg._link:SetScript("OnLeave", function() dlg._link._bg:SetColorTexture(T.rgba(T.surface.controlAlt)) end)
    spellTip(dlg._link, function() return dlg._link._sid end)
    dlg._link:Hide()

    dlg._ok = Button(dlg, "", 128, 24); dlg._ok:SetPoint("BOTTOMRIGHT", -16, 14); dlg._ok:SetActive(true)
    dlg._cancel = Button(dlg, "Cancel", 92, 24); dlg._cancel:SetPoint("RIGHT", dlg._ok, "LEFT", -8, 0)
    dlg._cancel:SetScript("OnClick", function() dlg:Hide() end)
    dlg._ok:SetScript("OnClick", function()
        dlg:Hide()
        local fn = dlg._onYes; dlg._onYes = nil
        if fn then fn() end
    end)
end

function OPT.openWizConfirm(cfg)
    local P = OPT.P
    cfg = cfg or {}
    OPT.buildConfirmDialog()
    local dlg = P._cfm
    dlg._title:SetText(cfg.title or "Before you add this")
    dlg._body:SetText(cfg.body or "")
    dlg._onYes = cfg.onYes
    dlg._ok._fs:SetText(cfg.yes or "Continue")
    local bodyH = dlg._body:GetStringHeight() or 40
    local linkH = 0
    if cfg.linkSpell then
        dlg._link._sid = cfg.linkSpell
        dlg._link._icon:SetTexture((C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(cfg.linkSpell)) or 134400)
        dlg._link._t:SetText((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(cfg.linkSpell)) or ("Spell " .. tostring(cfg.linkSpell)))
        dlg._link:ClearAllPoints(); dlg._link:SetPoint("TOPLEFT", 18, -(46 + bodyH + 12))
        dlg._link:Show()
        linkH = 26 + 12
    else
        dlg._link:Hide()
    end
    -- Grow the modal to fit the WRAPPED body (+ optional link) so a long explainer can't overflow the
    -- frame's bottom edge; the buttons are anchored to BOTTOM, so they follow. 46 = body top inset,
    -- ~58 = the button strip + margins.
    dlg:SetHeight(46 + bodyH + linkH + 58)
    dlg:Show(); dlg:Raise()
end
