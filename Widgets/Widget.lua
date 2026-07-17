-- Widgets/Widget.lua : base widget — frame, spec matching, and move mode.
--
-- Positioning is ABSOLUTE: every widget's frame is always anchored to the
-- screen (UIParent centre + offset). "Grouping" widgets is logical only
-- (cfg.anchor.group + profile.groups, see Core/Groups.lua) — packing is computed,
-- NOT a frame-to-frame anchor. This deliberately avoids the WoW pitfalls of
-- frame-anchored dragging (StartMoving blink, nil GetCenter).

local ADDON, ns = ...

local Widget = {}
Widget.__index = Widget
ns.Widget = Widget

-- Click-cue art, bundled as TGAs in the addon folder so it's ALWAYS present — no atlas-name
-- guessing, no 3rd-party dependence. Out of combat = a mouse glyph ("click to cast"); in
-- combat = a keyboard glyph ("use your keybind" — a generic press-your-own-key cue, NOT the
-- actual bound key). 64px 32-bit TGAs in Media\.
local CUE_MOUSE = "Interface\\AddOns\\Custodian\\Media\\cue-mouse.tga"
local CUE_KEY   = "Interface\\AddOns\\Custodian\\Media\\cue-key.tga"

-- ── Shared edge-box helpers ───────────────────────────────────────────
-- Every widget frames itself with four thin textures (a 1px border, the icon
-- outline, the move-mode role frame). Create + layout were copy-pasted in Bar,
-- Icon and here; these two helpers are the single source. (Icon's GLOW outline
-- sits OUTSIDE the frame, so it keeps its own offset layout — only its creation
-- shares MakeEdges.)

-- Four edge textures on `frame` at draw `layer`, optionally colour-filled.
-- Returns { TOP=, BOTTOM=, LEFT=, RIGHT= }.
function ns.MakeEdges(frame, layer, r, g, b, a)
    local edges = {}
    for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = frame:CreateTexture(nil, layer)
        if r then t:SetColorTexture(r, g, b, a or 1) end
        edges[k] = t
    end
    return edges
end

-- Position four edges flush around `frame`, `th` px thick (default 1).
function ns.LayoutEdges(edges, frame, th)
    th = th or 1
    local e = edges
    e.TOP:ClearAllPoints();    e.TOP:SetPoint("TOPLEFT", frame);       e.TOP:SetPoint("TOPRIGHT", frame);       e.TOP:SetHeight(th)
    e.BOTTOM:ClearAllPoints(); e.BOTTOM:SetPoint("BOTTOMLEFT", frame); e.BOTTOM:SetPoint("BOTTOMRIGHT", frame); e.BOTTOM:SetHeight(th)
    e.LEFT:ClearAllPoints();   e.LEFT:SetPoint("TOPLEFT", frame);      e.LEFT:SetPoint("BOTTOMLEFT", frame);    e.LEFT:SetWidth(th)
    e.RIGHT:ClearAllPoints();  e.RIGHT:SetPoint("TOPRIGHT", frame);    e.RIGHT:SetPoint("BOTTOMRIGHT", frame);  e.RIGHT:SetWidth(th)
end

-- Apply a widget's configurable resting border (thickness + colour) to its four edge
-- textures. `borderSize` 0 hides the frame entirely; the default is a 1px black outline.
-- Returns the thickness actually drawn (0 when hidden) so the caller can inset its content
-- to match, keeping the fill / icon art clear of the border.
local EDGE_KEYS = { "TOP", "BOTTOM", "LEFT", "RIGHT" }
function ns.ApplyBorder(edges, frame, cfg)
    local th = cfg.borderSize; if th == nil then th = 1 end
    if th <= 0 then
        for _, k in ipairs(EDGE_KEYS) do edges[k]:Hide() end
        return 0
    end
    local col = cfg.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    for _, k in ipairs(EDGE_KEYS) do
        edges[k]:SetColorTexture(col.r, col.g, col.b, col.a or 1); edges[k]:Show()
    end
    ns.LayoutEdges(edges, frame, th)
    return th
end

-- Resolve a text anchor (CENTER / LEFT / TOPRIGHT / …) into point + edge inset +
-- justify, so the panel's Anchor dropdown can place a widget's text without hand-
-- tuning X/Y. `inset` is the horizontal corner inset in px (bar 3, icon 2); the
-- vertical inset is a fixed 2. The user's textOffset is applied on top.
function ns.TextAnchor(a, default, inset)
    a = a or default or "CENTER"
    inset = inset or 3
    local x, y = 0, 0
    if a:find("LEFT") then x = inset elseif a:find("RIGHT") then x = -inset end
    if a:find("BOTTOM") then y = 2 elseif a:find("TOP") then y = -2 end
    local jh = a:find("LEFT") and "LEFT" or (a:find("RIGHT") and "RIGHT" or "CENTER")
    return a, x, y, jh
end

-- ── Shared manual-drag controller ─────────────────────────────────────
-- We drive dragging ourselves (cursor delta) rather than StartMoving, so it
-- works identically for every widget and never blinks.
local nearestStandalone   -- forward-declared: defined below, used by the drag updater's group hint
local drag = { active = nil }

-- A floating "+ Group" label pinned near the cursor while a standalone drag is over a pairable
-- target. At TOOLTIP strata so it sits above every icon glow/pulse — the reliable signal (the green
-- halo on the widgets is a bonus that a busy icon effect could otherwise drown out).
local pairHintFrame
local function showPairHint(on)
    if not on then if pairHintFrame then pairHintFrame:Hide() end return end
    if not pairHintFrame then
        local f = CreateFrame("Frame", nil, UIParent); f:SetFrameStrata("TOOLTIP")
        f._bg = f:CreateTexture(nil, "BACKGROUND"); f._bg:SetAllPoints(); f._bg:SetColorTexture(0.05, 0.18, 0.09, 0.94)
        f._e = ns.MakeEdges(f, "BORDER", 0.30, 1.0, 0.45, 1); ns.LayoutEdges(f._e, f, 1)
        f._t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); f._t:SetPoint("CENTER")
        f._t:SetText("|cff4dff7f+ Group|r")
        f:SetSize((f._t:GetStringWidth() or 60) + 18, 22)
        pairHintFrame = f
    end
    local mx, my = GetCursorPosition()
    local s = UIParent:GetEffectiveScale(); if not s or s <= 0 then s = 1 end
    pairHintFrame:ClearAllPoints()
    pairHintFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", mx / s + 18, my / s + 20)
    pairHintFrame:Show()
end
local dragUpdater = CreateFrame("Frame")
dragUpdater:Hide()
dragUpdater:SetScript("OnUpdate", function()
    local w = drag.active
    if not w then return end
    if not IsMouseButtonDown("LeftButton") then w:EndDrag(); return end
    local mx, my = GetCursorPosition()
    local dx = (mx - w._cx0) / w._scale
    local dy = (my - w._cy0) / w._scale
    -- Drag only THIS widget (groups move by their handle; a member drag means reorder /
    -- detach). Its slot is reserved as a gap in the layout (ns._dragActive), so the rest
    -- pack around the cursor.
    local px, py = w._x0 + dx, w._y0 + dy
    if px == w._lastPx and py == w._lastPy then return end   -- cursor still: skip redundant work
    w._lastPx, w._lastPy = px, py
    w.frame:ClearAllPoints()
    w.frame:SetPoint("CENTER", UIParent, "CENTER", px, py)

    -- Unified live feedback: whatever group the cursor is over (a member stays in its
    -- own group; a standalone can live-JOIN any group it's over) opens a slot where the
    -- widget will land and its members slide to make room — same behaviour for reorder
    -- AND for dropping an unconnected icon in. The target group is highlighted.
    local origGid = w._origGid
    local targetGid
    if origGid then
        if ns.Layout.InGroupBox(origGid, px, py, 24) then targetGid = origGid end
    elseif not IsAltKeyDown() then
        targetGid = ns.Layout.GroupAt(px, py, 20)
    end

    local changed = false
    local curGid = ns.Groups.GidOf(w.cfg)
    if targetGid then
        local idx = ns.Layout.InsertIndex(targetGid, px, py, w.id)
        if curGid ~= targetGid then
            ns.Groups.Add(targetGid, w.id, idx); w._lastInsertIdx = idx; changed = true
        elseif idx ~= w._lastInsertIdx then
            ns.Groups.Reorder(targetGid, w.id, idx); w._lastInsertIdx = idx; changed = true
        end
    elseif not origGid and curGid then
        ns.Groups.Remove(w.id, px, py); w._lastInsertIdx = nil; changed = true   -- live-joined, then left
    end
    if ns._dropTargetGid ~= targetGid then ns._dropTargetGid = targetGid; changed = true end

    -- New-group hint: a standalone dragged over another standalone will CONNECT them on drop, but
    -- there's no group box to highlight yet — so show a floating "+ Group" label at the cursor (plus
    -- a green halo on both widgets) so it's obvious it'll stick. (Alt = free move, no connect/hint.)
    local pair
    if not origGid and not targetGid and not IsAltKeyDown() then
        pair = nearestStandalone(w, px, py)
    end
    if ns._pairTarget ~= pair then
        if ns._pairTarget and ns._pairTarget.SetPairHint then ns._pairTarget:SetPairHint(false) end
        if pair and pair.SetPairHint then pair:SetPairHint(true) end
        ns._pairTarget = pair
        w:SetPairHint(pair ~= nil)   -- halo the dragged one too
    end
    showPairHint(pair ~= nil)        -- floating label follows the cursor each frame

    if changed then ns.Layout.Reposition() end
end)

-- ── Live preview (move mode) ──────────────────────────────────────────
-- Text, countdown and fill are normally only visible while the real buff/proc is
-- up — awkward for tuning font size or offset. So while unlocked we feed every
-- widget a synthetic, LOOPING snapshot: the countdown ticks and restarts, the
-- sweep runs, bars fill. Real pushes are suppressed meanwhile (Widget:Update
-- ignores non-preview snaps when unlocked), and StopPreview re-reads the real
-- state. Faithful to each widget: stacking buffs show a count, others a countdown.
local PREVIEW_CYCLE = 12
local previewTicker

local function spellTex(id)
    return id and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id) or nil
end

function ns.PreviewSnapshot(w)
    local cfg = w.cfg
    local tr  = ns.TrackerOf(cfg)
    local icon = cfg.icon or (tr and tr.icon) or spellTex(tr and tr.spellID)
    local exp  = GetTime() + PREVIEW_CYCLE
    if cfg.display == "bar" then
        local max = (tr and tr.max) or 100
        local val = math.max(1, math.floor(max * 0.65))
        return { _preview = true, active = true, present = true, ready = true,
                 value = val, max = max, count = val, icon = icon,
                 duration = PREVIEW_CYCLE, expiration = exp }
    end
    -- icon: a stacking buff shows a representative count (plus the sweep); anything
    -- else shows the looping countdown (which fully exercises the text render).
    if tr and tr.max and tr.max > 1 then
        local c = math.max(2, math.floor(tr.max * 0.6))
        return { _preview = true, active = true, present = true, ready = true,
                 count = c, value = c, max = tr.max, icon = icon,
                 duration = PREVIEW_CYCLE, expiration = exp }
    end
    return { _preview = true, active = true, present = true, ready = true,
             count = 0, value = 1, max = 1, noCount = true, icon = icon,
             duration = PREVIEW_CYCLE, expiration = exp }
end

local function previewAll()
    if not ns.previewActive then return end
    for _, w in pairs(ns.widgets) do
        if w.unlocked and w.frame and w:MatchesSpec(ns.specID) then
            w:Update(ns.PreviewSnapshot(w))
        end
    end
end
-- Public: re-push the preview now (e.g. a settings change while move mode is open,
-- so a new text format / size / offset is reflected immediately, not next cycle).
ns.RefreshPreview = previewAll

function ns.StartPreview()
    ns.previewActive = true
    previewAll()
    if not previewTicker then
        previewTicker = C_Timer.NewTicker(PREVIEW_CYCLE, previewAll)
    end
end

function ns.StopPreview()
    ns.previewActive = false
    if previewTicker then previewTicker:Cancel(); previewTicker = nil end
    ns.Refresh()
end

function Widget.New(id, cfg, disp)
    local self = setmetatable({}, Widget)
    self.id, self.cfg, self.disp = id, cfg, disp
    self.displayType = cfg.display   -- tracked so Layout can recreate on change

    local f = CreateFrame("Frame", "Custodian_" .. id, UIParent)
    f:SetSize(cfg.width or 240, cfg.height or 26)
    f:SetClampedToScreen(true)
    f.owner = self
    self.frame = f

    -- Move mode:
    --   drag a bar        -> move it; anything linked to it moves too
    --   drop near another -> connect (snaps/aligns) · Alt = place freely
    --   drag away         -> detaches it from its group
    --   right-click a bar -> disconnect it (or anything linked to it)
    f:SetScript("OnMouseDown", function(_, button)
        if self.unlocked and button == "LeftButton" then self:BeginDrag() end
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if not self.unlocked then return end
        if button == "LeftButton" then self:EndDrag()
        elseif button == "RightButton" then self:Disconnect() end
    end)

    -- Move-mode overlay on its own high-level frame so it paints above the fill.
    local mf = CreateFrame("Frame", nil, f)
    mf:SetAllPoints(f)
    mf:SetFrameLevel(f:GetFrameLevel() + 20)
    mf:Hide()
    local T = ns.Theme
    -- Faint wash so the widget clearly reads as "held" in move mode, but light enough
    -- that the live preview (text, countdown sweep, fill) still shows through it.
    local ov = mf:CreateTexture(nil, "BACKGROUND")
    ov:SetAllPoints(mf)
    ov:SetColorTexture(T.hud.overlay[1], T.hud.overlay[2], T.hud.overlay[3], T.hud.overlayAlpha)

    -- Role-coloured border framing the widget — the prominent "this is a Custodian
    -- widget you can move" marker. Coloured by Layout.UpdateLinks (main/attached/lone),
    -- an outline rather than a full-cover tint so it never hides the preview content.
    local th = T.hud.border or 2
    local edges = ns.MakeEdges(mf, "OVERLAY")   -- colour set later by Layout (role tint)
    ns.LayoutEdges(edges, mf, th)
    self.moveFrame, self.moveOverlay, self.moveEdges = mf, ov, edges

    -- "Click to cast" button. A reminder for a castable spell (missing shield, a ready
    -- ability) can be clicked to cast it OUT OF COMBAT. We use InsecureActionButtonTemplate,
    -- NOT the Secure one: the Secure template makes the whole widget frame a PROTECTED region
    -- (protection propagates to parents/anchors), which FORBIDS Hide()/SetPoint() in combat —
    -- so a reminder whose spell resolved (Skyfury) could never vanish or re-center mid-fight.
    -- The Insecure variant casts only out of combat (fine — in combat you use your keybind)
    -- and leaves the frame non-protected, so reminders Hide() and slide freely in combat.
    -- Same type/spell/unit attributes; still set OOC (RefreshCast). Mouse is on only while
    -- LOCKED, so move mode's drag still reaches the frame. See RefreshCast / CastSpellName.
    local cast = CreateFrame("Button", nil, f, "InsecureActionButtonTemplate")   -- unnamed: widgets can be recreated on display change
    cast:SetAllPoints(f)
    cast:RegisterForClicks("AnyUp", "AnyDown")
    cast:SetFrameLevel(f:GetFrameLevel() + 30)   -- above the display's cooldown / glow / text children
    cast:EnableMouse(false)
    cast:SetScript("OnEnter", function(b)
        if not self._castName then return end
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        if self._castSid and GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(self._castSid)
        elseif self._castItemId and GameTooltip.SetItemByID then GameTooltip:SetItemByID(self._castItemId)
        else GameTooltip:SetText(self._castName) end
        if InCombatLockdown() then
            GameTooltip:AddLine("Can't cast in combat — use your keybind", 0.9, 0.5, 0.5)
        else
            GameTooltip:AddLine("Click to cast", 0.55, 0.78, 1)
        end
        GameTooltip:Show()
    end)
    cast:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.castButton = cast

    -- Click-cue: a corner glyph on a castable reminder — a mouse "click to cast" glyph out of
    -- combat, a keyboard "use your keybind" glyph in combat. On the cast button (above the
    -- icon art); swapped by ApplyCastCue on the combat transitions.
    local cue = cast:CreateTexture(nil, "OVERLAY", nil, 7)
    cue:SetPoint("BOTTOMRIGHT", cast, "BOTTOMRIGHT", 2, -2)
    cue:Hide()
    self.castCue = cue

    if disp.Create then disp.Create(self) end
    self:ApplyStyle()
    self:SetUnlocked(ns.profile and ns.profile.unlocked)
    return self
end

function Widget:MatchesSpec(spec)
    return ns.CfgSpecActive(self.cfg, spec)
end

function Widget:ApplyStyle()
    self.frame:SetSize(self.cfg.width or 240, self.cfg.height or 26)
    if self.disp.ApplyStyle then self.disp.ApplyStyle(self) end
    self:SetupImbueHover()
    self:RefreshCast()
end

-- ── Click-to-cast (secure) ────────────────────────────────────────────
-- The castable spell behind a reminder, or nil if this widget shouldn't cast. Only
-- "press this now" reminders cast: MISSING (recast the dropped shield/imbue) and READY
-- (fire the off-cooldown ability). Earth Shield's tracker has no spellID of its own, so
-- map it to the castable Earth Shield (974) — casting on the player refreshes the self
-- shield, exactly the "self missing" case. Off when the user unticks cfg.clickToCast.
--   Pet: cast the CHOSEN summon (tr.spellID — a Call Pet slot / a Warlock demon). When the
--   current pet is DEAD and the tracker has reviveWhenDead (Hunter Revive Pet 982), cast that
--   instead. Click-to-cast is OOC-only, which is exactly when you Revive Pet — so it lines up.
function Widget:CastSpellName()
    if self.cfg.clickToCast == false then return nil end
    local cfg  = self.cfg
    local mode = (cfg.reminder and cfg.reminder.mode) or cfg.showWhen
    if mode ~= "missing" and mode ~= "ready" then return nil end
    local tr = ns.TrackerOf(cfg)
    if not tr then return nil end
    local sid
    if tr.type == "earthshield" then
        sid = 974
    elseif tr.type == "imbue" and tr.riteIds then
        -- Choice-node rite: cast whichever Rite you actually have (matched by spell id, live).
        for _, id in ipairs(tr.riteIds) do
            if ns.SpellTaken(id) then sid = id; break end
        end
        sid = sid or tr.spellID   -- none known → fall back to the seeded id
    elseif tr.type == "pet" then
        sid = tr.spellID
        if tr.reviveWhenDead and ns.PetNeedsRevive and ns.PetNeedsRevive() then
            sid = tr.reviveWhenDead   -- a dead pet needs reviving, not resummoning (latched)
        end
    elseif (tr.matchAny or tr.matchAll) and self.snap and self.snap.castId then
        sid = self.snap.castId   -- category (poisons): reapply the MISSING member, not the pool's first
    else
        sid = tr.spellID
    end
    if not sid then return nil end
    if not (C_Spell and C_Spell.GetSpellName) then return nil end
    local nm = C_Spell.GetSpellName(sid)
    if nm then self._castSid = sid end
    return nm
end

-- The ITEM/enchant action behind a reminder, or nil. Same gating as CastSpellName.
--   · A SPELL-based weapon imbue (a Lightsmith Rite, Windfury…) casts the enchant and then USES
--     its weapon slot in one macro — casting alone just opens a "click your weapon" cursor, so the
--     /use 16|17 auto-applies it to the hand the reminder watches (no manual weapon click).
--   · An imbue with an ITEM (weapon oil) does the same with /use item + /use slot.
--   · Any other item (an augment rune) just uses the item (it buffs you). Only when you carry it.
function Widget:CastItemAction()
    if self.cfg.clickToCast == false then return nil end
    local mode = (self.cfg.reminder and self.cfg.reminder.mode) or self.cfg.showWhen
    if mode ~= "missing" and mode ~= "ready" then return nil end
    local tr = ns.TrackerOf(self.cfg)
    if not tr then return nil end
    -- Spell-based weapon imbue: cast + apply-to-slot macro (see the note above).
    if tr.type == "imbue" and not tr.itemID then
        local name = self:CastSpellName()
        if not name then return nil end
        local slotId = (tr.slot == "off") and 17 or 16
        return { attrType = "macro", macrotext = ("/cast %s\n/use %d"):format(name, slotId),
                 name = name, spellID = self._castSid }
    end
    if not tr.itemID then return nil end
    if C_Item and C_Item.GetItemCount and (C_Item.GetItemCount(tr.itemID) or 0) <= 0 then return nil end
    local nm = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(tr.itemID))
            or (GetItemInfo and GetItemInfo(tr.itemID)) or ("item:" .. tr.itemID)
    if tr.type == "imbue" then
        local slotId = (tr.slot == "off") and 17 or 16
        return { attrType = "macro", macrotext = ("/use item:%d\n/use %d"):format(tr.itemID, slotId),
                 name = nm, itemID = tr.itemID }
    end
    return { attrType = "item", item = ("item:%d"):format(tr.itemID), name = nm, itemID = tr.itemID }
end

-- Push the current cast target onto the secure button. Secure attributes are OOC-only,
-- so in combat we just flag it dirty and re-apply on PLAYER_REGEN_ENABLED (below). Mouse
-- is enabled only while LOCKED and castable — move mode needs clicks to reach the frame.
function Widget:RefreshCast()
    local cast = self.castButton
    if not cast then return end
    if InCombatLockdown() then self._castDirty = true; return end
    self._castDirty = nil
    cast:SetFrameLevel(self.frame:GetFrameLevel() + 30)   -- re-assert on top (drag/Raise churn levels)

    -- Item action (weapon oil / augment rune) takes precedence over a spell — a tracker with an
    -- itemID uses/applies the item instead of casting.
    local item = self:CastItemAction()
    if item then
        cast:SetAttribute("type", item.attrType)
        cast:SetAttribute("unit", nil)
        cast:SetAttribute("spell", nil)
        cast:SetAttribute("macrotext", (item.attrType == "macro") and item.macrotext or nil)
        cast:SetAttribute("item", (item.attrType == "item") and item.item or nil)
        -- spellID (a spell-based imbue macro) → spell tooltip; else itemID → item tooltip.
        self._castSid, self._castItemId, self._castName = item.spellID, item.itemID, item.name
        cast:EnableMouse((not self.unlocked) and not InCombatLockdown())
        self:UpdateCastCue()
        return
    end

    local name = self:CastSpellName()
    if name then
        cast:SetAttribute("type", "spell")
        cast:SetAttribute("unit", "player")
        cast:SetAttribute("spell", name)
        cast:SetAttribute("macrotext", nil); cast:SetAttribute("item", nil)
    else
        cast:SetAttribute("type", nil)
        cast:SetAttribute("spell", nil); cast:SetAttribute("macrotext", nil); cast:SetAttribute("item", nil)
        self._castSid = nil
    end
    self._castItemId = nil
    self._castName = name
    cast:EnableMouse((not self.unlocked) and name ~= nil and not InCombatLockdown())
    self:UpdateCastCue()
end

-- Show the click-cue on a castable reminder and pick the art for the given state: a MOUSE
-- glyph out of combat ("click to cast") or a KEYBOARD glyph in combat ("use your keybind").
-- Hidden entirely in move mode (clicks drag there) and on non-castable widgets. Combat state
-- is passed in EXPLICITLY by the transition events (castWatch), so the swap can't hang on a
-- mid-flip InCombatLockdown() — the exact reason the old hide-on-combat cue stayed stuck on.
function Widget:ApplyCastCue(inCombat)
    -- Keep the cast button's MOUSE in lockstep with the cue: clickable only when castable, locked,
    -- and OUT OF COMBAT. Our button is insecure (so the widget can Hide/move in combat), and an
    -- insecure click that reaches CastSpellByName/UseItem IN COMBAT throws ADDON_ACTION_FORBIDDEN.
    -- OOC it's a normal hardware-event cast; in combat we hard-disable it (the keybind cue says so).
    -- Combat state is passed in EXPLICITLY by the transition events — InCombatLockdown() can read
    -- stale mid-flip. This is why every prior test passed: item/macro casts clicked out of combat.
    local castable = (self._castName ~= nil) and (not self.unlocked)
    if self.castButton then self.castButton:EnableMouse(castable and not inCombat) end
    local cue = self.castCue
    if not cue then return end
    -- Not castable, or in move mode (clicks drag): no cue at all.
    if not castable then cue:Hide(); return end
    -- Mouse "click to cast" out of combat; keyboard "use your keybind" in combat.
    cue:SetTexture(inCombat and CUE_KEY or CUE_MOUSE)
    cue:SetSize(18, 18)
    cue:Show()
end

-- Reconcile from the live combat flag (config/lock changes go through here, which are OOC).
function Widget:UpdateCastCue()
    self:ApplyCastCue(InCombatLockdown() and true or false)
end

-- Weapon-imbue widgets show the equipped weapon's tooltip on hover, so you can see
-- what's on the weapon (and which enchant) without opening your bags. Mouse stays
-- enabled for these even when locked (SetUnlocked honours _imbueHover); the drag
-- handlers are no-ops while locked, so a hover just shows the tooltip.
function Widget:SetupImbueHover()
    local tr = ns.TrackerOf(self.cfg)
    local isImbue = tr and tr.type == "imbue"
    if not isImbue then
        if self._imbueHover then
            self.frame:SetScript("OnEnter", nil); self.frame:SetScript("OnLeave", nil)
            self._imbueHover = false
            self.frame:EnableMouse(self.unlocked)
        end
        return
    end
    local slotId = (tr.slot == "off") and 17 or 16   -- either / main -> main-hand (16), off-hand (17)
    self.frame:SetScript("OnEnter", function(fr)
        if not GameTooltip.SetInventoryItem then return end
        GameTooltip:SetOwner(fr, "ANCHOR_RIGHT")
        local hasItem = GameTooltip:SetInventoryItem("player", slotId)
        if not hasItem then GameTooltip:SetText((tr.slot == "off") and "No off-hand weapon" or "No main-hand weapon") end
        GameTooltip:Show()
        -- Show only the weapon's own tooltip — never the equipped-comparison shopping
        -- tooltips (they bloat the screen depending on what's equipped).
        if GameTooltip_HideShoppingTooltips then GameTooltip_HideShoppingTooltips(GameTooltip) end
    end)
    self.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self._imbueHover = true
    self.frame:EnableMouse(true)
end

function Widget:Update(snap)
    -- In move mode we feed synthetic PREVIEW snapshots (see the preview engine below);
    -- real tracker pushes must not clobber them, so while previewing only preview snaps
    -- get through. Preview is purely visual — skip the show/hide + reflow policy for it.
    if ns.previewActive and self.unlocked and not (snap and snap._preview) then return end
    self.snap = snap
    -- Click-to-cast target can move (a category reminder points at whichever member is missing) —
    -- re-point the secure button when it changes. No-op for widgets with no castId (most).
    if snap and not snap._preview and self._lastCastId ~= snap.castId then
        self._lastCastId = snap.castId
        if self.RefreshCast then self:RefreshCast() end
    end
    if self.disp.Update then self.disp.Update(self, snap) end
    if snap and snap._preview then return end
    local vis = self:ReminderVisible(snap)
    local changed = vis ~= self._contentVisible
    self._contentVisible = vis
    self:UpdateShown()   -- reconcile the frame EVERY push so it can't desync (vis=true, shown=false)
    if ns._reminderLog and ((self.cfg.reminder and self.cfg.reminder.mode) or self.cfg.showWhen) then
        ns.Print(("|cffff88ffpush|r %s: present=%s src=%s vis=%s cv=%s SHOWN=%s"):format(
            tostring(self.cfg.name or "?"),
            snap and (ns.IsSecret(snap.present) and "<s>" or tostring(snap.present)) or "nosnap",
            snap and (snap._preview and "PREVIEW" or "real") or "-",
            tostring(vis), tostring(self._contentVisible), tostring(self.frame and self.frame:IsShown())))
    end
    -- Appearing / disappearing changes a linked chain's shape — reflow so the rest slides
    -- in/out to fill (no static gap where a hidden reminder sat). Only on an actual change.
    if changed and ns.Layout and ns.Layout.Reposition then ns.Layout.Reposition() end
end

-- Source-AGNOSTIC reminder visibility. A widget is a REMINDER when it has a condition
-- (cfg.reminder.mode, or the legacy cfg.showWhen); otherwise it's always visible. The
-- condition reads the NORMALIZED snapshot, so ANY tracker can drive a reminder:
--   missing  -> buff/imbue confirmed absent (present == false) [+ low-duration warn]
--   active   -> buff/shield confirmed up (present == true)
--   ready    -> ability off cooldown / usable (snap.ready == true)
--   notready -> on cooldown (snap.ready == false)
--   atLeast / atMost -> a READABLE count/value crosses a threshold
-- Everything is secret-safe: an unknown value (secret in combat) yields "don't show"
-- rather than a false reminder — same policy as the aura "missing" path.
function Widget:ReminderVisible(snap, inCombat)
    local r    = self.cfg.reminder
    local mode = (r and r.mode) or self.cfg.showWhen
    if not mode then return true end          -- not a reminder: always visible
    if not snap then return false end
    -- "Only warn in combat": suppress the reminder while OOC (forms/stances). Can't help a
    -- pre-combat reminder (its aura goes secret in combat and already holds) — noted in the editor.
    -- `inCombat` is passed EXPLICITLY on a combat transition (PLAYER_REGEN_*) because
    -- InCombatLockdown() reads stale for a beat there — otherwise a combat-only reminder lags 1-3s
    -- into a pull. Elsewhere it's nil and we read the (reliable) live flag.
    if inCombat == nil then inCombat = InCombatLockdown() and true or false end
    if r and r.combatOnly and not inCombat then return false end

    if mode == "missing" then
        return ((snap.present == false) or self:ExpiringSoon(snap)) and self:AbilityLearned()
    elseif mode == "active" then
        return snap.present == true
    elseif mode == "ready" then
        return snap.ready == true and self:AbilityLearned()
    elseif mode == "notready" then
        return snap.ready == false
    elseif mode == "atLeast" or mode == "atMost" then
        return self:ThresholdMet(snap, r) and self:AbilityLearned()
    end
    return true
end

-- Secret-safe threshold on a readable count/value (or value/max % when r.pct). A
-- secret/unknown value => false, so a threshold reminder never fires on something it
-- can't read (e.g. a power value in combat) instead of nagging wrongly.
function Widget:ThresholdMet(snap, r)
    if not (snap and r and r.value) then return false end
    local v = snap.count or snap.value
    if v == nil or ns.IsSecret(v) then return false end
    if r.pct then
        local mx = snap.max
        if not mx or ns.IsSecret(mx) or mx <= 0 then return false end
        v = v / mx * 100
    end
    if r.mode == "atLeast" then return v >= r.value else return v <= r.value end
end

-- For a "missing" reminder: is the tracked ability actually learned/talented? A
-- talent you didn't take (e.g. Flametongue Weapon on an Elemental build) shouldn't
-- nag you to cast it. Gates ONLY when the tracker names a real spell that the
-- spellbook says you don't have — item enhancements (weapon oils carry no spellID)
-- and the "off" toggle are never gated. ns.SpellKnown fails open, so an absent
-- known-check API shows rather than wrongly hides.
function Widget:AbilityLearned()
    if self.cfg.onlyWhenLearned == false then return true end   -- user opted out
    local tr = ns.TrackerOf(self.cfg)
    local sid = tr and tr.spellID
    if not sid then return true end
    return ns.SpellKnown(sid)
end

-- True when the tracked buff/imbue is present but inside its low-duration warn
-- window (cfg.warnLowSec seconds). Secret-safe: only a READABLE expiration is
-- compared — a secret one (an aura's expiration in combat) is skipped, which is
-- correct since the time can't be read then anyway.
function Widget:ExpiringSoon(snap)
    local warn = self.cfg.warnLowSec
    if not (warn and warn > 0) then return false end
    if not (snap and snap.present == true and snap.expiration) then return false end
    if ns.IsSecret(snap.expiration) then return false end
    if snap.expiration <= 0 then return false end   -- permanent / no-duration buff: never "expiring"
    local left = snap.expiration - GetTime()
    -- Only a REAL, positive remaining time under the threshold counts. A zero/past/now
    -- expiration (a permanent buff, or a just-applied imbue whose ms hasn't populated)
    -- must NOT read as "expiring soon" — that was pinning the reminder open forever so a
    -- rebuffed buff never cleared.
    return left > 0 and left < warn
end

-- Actual frame visibility = spec matches AND content wants to show — except in
-- move mode, where everything shows so you can position hidden reminders.
function Widget:UpdateShown()
    local content = self._contentVisible
    if content == nil then content = true end
    if self.unlocked then content = true end
    local spec = self:MatchesSpec(ns.specID)
    -- "Only in form" gate (e.g. Druid combo points only in Cat Form): hide entirely off-form. Move
    -- mode shows everything so a hidden widget can still be positioned. Live-read (never secret).
    local g = self.cfg.formGate
    local formOK = self.unlocked or not g or ns.InForm(g.spellID or g, g.name)
    local visible = (spec and content and formOK) and true or false
    -- The widget frame is non-protected (its click-to-cast button uses InsecureActionButton-
    -- Template), so a plain Hide()/Show() works in combat: a reminder can vanish and the group
    -- can re-center mid-fight. Layout reads the shown state directly via frame:IsShown().
    self.frame:SetShown(visible)
    self.frame:SetAlpha(1)   -- clear any leftover alpha from the old protected-frame workaround
    -- The click-to-cast button is INSECURE, so a click that reaches CastSpellByName in combat
    -- throws ADDON_ACTION_FORBIDDEN. A reminder can APPEAR mid-combat (a poison drops) AFTER the
    -- combat-transition cue already disabled everything, so re-assert the combat gate on show:
    -- an insecure cast button must never be mouse-enabled while in combat. It's re-enabled OOC by
    -- ApplyCastCue on PLAYER_REGEN_ENABLED.
    if visible and self.castButton and InCombatLockdown() then
        self.castButton:EnableMouse(false)
    end
    if ns._reminderLog and ((self.cfg.reminder and self.cfg.reminder.mode) or self.cfg.showWhen) then
        ns.Print(("|cff88ffffshown|r %s: cv=%s spec=%s visible=%s shown=%s"):format(
            tostring(self.cfg.name or "?"), tostring(self._contentVisible), tostring(spec),
            tostring(visible), tostring(self.frame:IsShown())))
    end
end

-- Re-evaluate reminder visibility from the LAST snapshot (no fresh tracker push) — used on a combat
-- transition so an "only warn in combat" reminder (and any InCombatLockdown-gated visibility)
-- appears/vanishes the moment combat starts/ends, not on the next unrelated tracker event.
function Widget:RefreshVisibility(inCombat)
    local vis = self:ReminderVisible(self.snap, inCombat)
    local changed = vis ~= self._contentVisible
    self._contentVisible = vis
    self:UpdateShown()
    if changed and ns.Layout and ns.Layout.Reposition then ns.Layout.Reposition() end
end

function Widget:SetUnlocked(state)
    self.unlocked = state and true or false
    -- imbue widgets keep mouse on even when locked (for the weapon tooltip); others
    -- only capture in move mode.
    self.frame:EnableMouse(self.unlocked or self._imbueHover == true)
    self.moveFrame:SetShown(self.unlocked)
    -- Directly gate the click-to-cast button's mouse HERE (EnableMouse works on the Insecure
    -- button in any state), so move-mode drag ALWAYS reaches the frame beneath it. RefreshCast
    -- also does this, but it DEFERS in combat and can lag behind — and the cast button sits
    -- above the frame, so if it stays mouse-enabled it eats the drag mousedown and the widget
    -- can't be moved (hit on the pet reminder, whose Call Pet button is always castable).
    if self.castButton then self.castButton:EnableMouse((not self.unlocked) and self._castName ~= nil and not InCombatLockdown()) end
    self:RefreshCast()   -- click-to-cast is live only when LOCKED (drag needs clicks in move mode)
    self:UpdateShown()   -- re-evaluate: "missing" reminders show in move mode
end

-- Secure cast attributes can't be set in combat, so RefreshCast defers (marks _castDirty)
-- while locked down. Re-apply the deferred ones the moment combat ends. UNIT_PET re-points a
-- pet reminder's cast (Call Pet <-> Revive Pet) when the pet is summoned / dismissed / dies.
local function isPetWidget(w)
    local tr = ns.TrackerOf(w.cfg)
    return tr and tr.type == "pet"
end
local castWatch = CreateFrame("Frame")
castWatch:RegisterEvent("PLAYER_REGEN_ENABLED")            -- combat end: re-apply deferred casts, cues back on
castWatch:RegisterEvent("PLAYER_REGEN_DISABLED")           -- combat start: flip every clickable cue off
castWatch:RegisterUnitEvent("UNIT_PET", "player")          -- pet change: re-point pet-reminder click-to-cast (player only)
castWatch:RegisterEvent("UPDATE_SHAPESHIFT_FORM")          -- form change: re-gate "only in form" widgets (combo in Cat, etc.)
castWatch:SetScript("OnEvent", function(_, event, unit)
    if not ns.widgets then return end
    if event == "UNIT_PET" then
        if unit ~= "player" then return end
        for _, w in pairs(ns.widgets) do if isPetWidget(w) and w.RefreshCast then w:RefreshCast() end end
        return
    end
    if event == "UPDATE_SHAPESHIFT_FORM" then
        for _, w in pairs(ns.widgets) do if w.UpdateShown then w:UpdateShown() end end   -- re-read the form gate live
        if ns.Layout and ns.Layout.Reposition then ns.Layout.Reposition() end            -- reflow so groups re-center
        return
    end
    local inCombat = (event == "PLAYER_REGEN_DISABLED")
    for _, w in pairs(ns.widgets) do
        if (not inCombat) and w._castDirty and w.RefreshCast then w:RefreshCast() end
        if w.ApplyCastCue then w:ApplyCastCue(inCombat) end   -- explicit state: swaps mouse<->keyboard reliably
        if w.RefreshVisibility then w:RefreshVisibility(inCombat) end -- explicit state: combat-only reminders react at once (InCombatLockdown is stale mid-flip)
    end
end)

-- ── Drag (group model) ────────────────────────────────────────────────
-- Dragging a widget moves only IT. On drop:
--   · a grouped member dropped INSIDE its group  -> reorder
--   · a grouped member dropped OUTSIDE its group -> detach (standalone)
--   · a standalone dropped INTO a group          -> attach
--   · a standalone dropped ONTO another standalone-> form a new group
--   · else                                        -> just move
-- The whole group is moved separately, by its handle (Core/Layout.lua).
function Widget:BeginDrag()
    self._scale = UIParent:GetEffectiveScale()
    self._cx0, self._cy0 = GetCursorPosition()
    local a = self.cfg.anchor or {}
    self._x0, self._y0 = self._px or a.x or 0, self._py or a.y or 0   -- ACTUAL on-screen spot
    self._origGid = ns.Groups.GidOf(self.cfg)   -- the group it started in (nil = standalone)
    self._lastInsertIdx = nil
    self._lastPx, self._lastPy = nil, nil
    ns.Animation.Cancel("px_" .. self.id); ns.Animation.Cancel("py_" .. self.id)   -- no fight with the cursor
    self.frame:Raise()   -- ride above siblings while dragging (never hidden behind one)
    drag.active = self
    ns._dragActive = self.id            -- layout reserves this widget's slot as a gap
    ns._dropTargetGid = self._origGid   -- start highlighting its own group if it has one
    dragUpdater:Show()
    if ns.Layout and ns.Layout.Reposition then ns.Layout.Reposition() end   -- open the gap now
end

-- A standalone widget near a screen point (offset from UIParent centre), for the
-- drag-onto-another-to-connect gesture. Within the target's box + a small margin.
function nearestStandalone(self, x, y)
    local best, bestD
    for _, o in pairs(ns.widgets) do
        if o ~= self and o.frame:IsShown() and not ns.Groups.GidOf(o.cfg) then
            local ox, oy = o._px or 0, o._py or 0
            local hw = (o.cfg.width or 40) / 2 + 16
            local hh = (o.cfg.height or 40) / 2 + 16
            if math.abs(x - ox) <= hw and math.abs(y - oy) <= hh then
                local d = (x - ox) ^ 2 + (y - oy) ^ 2
                if not bestD or d < bestD then best, bestD = o, d end
            end
        end
    end
    return best
end

-- Make a fresh group from two standalone widgets, centred between them, ordered along
-- the drag axis.
local function formGroup(self, other, dropX, dropY)
    local ox = other._px or 0
    -- Default axis by widget shape (change it later in the Group tab): a row of ICONS reads best
    -- horizontally, but BARS (wide) stack vertically — so a group is horizontal only when BOTH
    -- members are icons, otherwise vertical.
    local bothIcons = (self.cfg and self.cfg.display == "icon")
        and (other.cfg and other.cfg.display == "icon")
    local axis = bothIcons and "h" or "v"
    local gid = ns.Groups.Create((ox + dropX) / 2, ((other._py or 0) + dropY) / 2, axis)
    if axis == "v" then
        -- Order top→bottom along the vertical drop direction.
        if dropY > (other._py or 0) then ns.Groups.Add(gid, self.id); ns.Groups.Add(gid, other.id)
        else ns.Groups.Add(gid, other.id); ns.Groups.Add(gid, self.id) end
    else
        if dropX < ox then ns.Groups.Add(gid, self.id); ns.Groups.Add(gid, other.id)
        else ns.Groups.Add(gid, other.id); ns.Groups.Add(gid, self.id) end
    end
end

-- "Drop here to group" hint: a bright-green halo drawn a few px OUTSIDE the widget (like the glow
-- edges), shown on the target AND the dragged widget while a standalone hovers another standalone.
-- Outset so it reads even when the dragged widget (raised to the cursor) overlaps the target.
function Widget:SetPairHint(on)
    if not on then
        if self._pairHL then for _, t in pairs(self._pairHL) do t:Hide() end end
        return
    end
    if not self._pairHL then
        local f, o, th = self.frame, 3, 3
        local e = {}
        for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            local t = f:CreateTexture(nil, "OVERLAY", nil, 7); t:SetColorTexture(0.30, 1.0, 0.45, 1); e[k] = t
        end
        e.TOP:SetPoint("BOTTOMLEFT", f, "TOPLEFT", -o, o);      e.TOP:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", o, o);      e.TOP:SetHeight(th)
        e.BOTTOM:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -o, -o);  e.BOTTOM:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", o, -o);  e.BOTTOM:SetHeight(th)
        e.LEFT:SetPoint("TOPRIGHT", f, "TOPLEFT", -o, o);       e.LEFT:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", -o, -o); e.LEFT:SetWidth(th)
        e.RIGHT:SetPoint("TOPLEFT", f, "TOPRIGHT", o, o);       e.RIGHT:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", o, -o); e.RIGHT:SetWidth(th)
        self._pairHL = e
    end
    for _, t in pairs(self._pairHL) do t:Show() end
end

function Widget:EndDrag()
    if drag.active ~= self then return end
    drag.active = nil
    ns._dragActive = nil
    ns._dropTargetGid = nil
    -- Clear the "will group" hint (halo on the target + this widget, and the floating label).
    if ns._pairTarget and ns._pairTarget.SetPairHint then ns._pairTarget:SetPairHint(false) end
    ns._pairTarget = nil
    self:SetPairHint(false)
    showPairHint(false)
    dragUpdater:Hide()

    local mx, my = GetCursorPosition()
    local dx = (mx - self._cx0) / self._scale
    local dy = (my - self._cy0) / self._scale

    -- A click (no real drag) opens the options panel focused on this widget.
    if math.abs(dx) < 3 and math.abs(dy) < 3 then
        if ns.SelectWidgetInOptions then ns.SelectWidgetInOptions(self.id) end
        ns.Layout.Resolve()   -- close the reserved gap
        return
    end

    -- The live drag already reflects reorder / attach; here we just finalise. curGid is
    -- the live membership (a standalone that hovered into a group is already in it).
    local dropX, dropY = self._x0 + dx, self._y0 + dy
    local curGid = ns.Groups.GidOf(self.cfg)

    if curGid then
        if not ns.Layout.InGroupBox(curGid, dropX, dropY, 24) then
            ns.Groups.Remove(self.id, dropX, dropY)                    -- dropped out -> detach
            local into = (not IsAltKeyDown()) and ns.Layout.GroupAt(dropX, dropY, 20)
            if into then ns.Groups.Add(into, self.id, ns.Layout.InsertIndex(into, dropX, dropY, nil)) end
        end
        -- inside its group: already reordered / attached live
    else
        local other = (not IsAltKeyDown()) and nearestStandalone(self, dropX, dropY) or nil
        if other then formGroup(self, other, dropX, dropY)
        else
            self.cfg.anchor = self.cfg.anchor or {}
            self.cfg.anchor.x, self.cfg.anchor.y = dropX, dropY
        end
    end
    ns.Layout.Resolve()
    if ns.RefreshOptionsList then ns.RefreshOptionsList() end   -- keep the sidebar pips/names in sync
end

-- Right-click a member -> detach it from its group (a quick alternative to dragging
-- it out). Standalone widgets have nothing to disconnect.
function Widget:Disconnect()
    local gid = ns.Groups.GidOf(self.cfg)
    if not gid then return end
    ns.Groups.Remove(self.id, self._px, self._py)
    ns.Layout.Resolve()
    if ns.RefreshOptionsList then ns.RefreshOptionsList() end
    ns.Print(("|cffffd100%s|r detached."):format(self.cfg.name or self.id))
end

function Widget:Destroy()
    if drag.active == self then drag.active = nil; ns._dragActive = nil; dragUpdater:Hide() end
    ns.Animation.Cancel(self.id)
    if self.disp.Destroy then self.disp.Destroy(self) end
    self.frame:Hide()
    self.frame:SetParent(nil)
    self.frame = nil
end
