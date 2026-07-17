-- Core/Layout.lua : builds widgets from the profile, shows only those that
-- match the current spec, and positions each one absolutely on the screen.
--
-- Every frame is anchored to UIParent centre + (anchor.x, anchor.y). Grouping
-- (cfg.anchor.group + profile.groups, see Core/Groups.lua) is logical only — group
-- packing is computed, never frame-to-frame anchored — so there are no cycles, no
-- StartMoving blink, and no nil-rect surprises.

local ADDON, ns = ...

local Layout = {}
ns.Layout = Layout

local T = ns.Theme

local function ensureWidget(id, cfg)
    local w = ns.widgets[id]
    -- Display type changed -> the frame's sub-parts differ, so rebuild it.
    if w and w.displayType ~= cfg.display then
        w:Destroy()
        ns.widgets[id] = nil
        w = nil
    end
    if not w then
        local disp = ns.displays[cfg.display] or ns.displays.bar
        w = ns.Widget.New(id, cfg, disp)
        ns.widgets[id] = w
    else
        w.cfg = cfg
        w:ApplyStyle()
    end
    return w
end

function Layout.Rebuild()
    local p = ns.profile
    if not p then return end

    for id, w in pairs(ns.widgets) do
        if not p.widgets[id] then
            w:Destroy()
            ns.widgets[id] = nil
        end
    end

    -- Load-on-demand by class: other classes' widgets stay in the profile (visible in
    -- options) but are never instantiated here — no frames, and since Trackers keys off
    -- ns.widgets, no tracker events either. Only our class's + shared widgets go live.
    for id, cfg in pairs(p.widgets) do
        if ns.CfgClassActive(cfg) then
            ensureWidget(id, cfg)
        elseif ns.widgets[id] then
            ns.widgets[id]:Destroy(); ns.widgets[id] = nil
        end
    end

    if ns.Groups and ns.Groups.Prune then ns.Groups.Prune() end   -- drop groups <2 members

    Layout.Resolve()

    -- Keep move-mode preview coherent with the (persisted) unlocked flag: a reload
    -- or spec change recreates widgets, so re-assert the preview engine for the fresh
    -- set (idempotent — it just re-pushes/tears down; no-op when already in sync).
    if p.unlocked and ns.StartPreview then ns.StartPreview()
    elseif not p.unlocked and ns.StopPreview and ns.previewActive then ns.StopPreview() end
end

local SLIDE = T.hud.slide   -- position-slide duration (live only)

-- Shared slot geometry: walk a group's SHOWN members in stored order and hand each
-- one's packed CENTRE to fn(w, i, cx_i, cy_i, size). Members pack edge-to-edge along
-- the group axis, gapped, centred on the group's stored centre. computeTargets (which
-- PLACES widgets) and InsertIndex (which HIT-TESTS the cursor) both drive off this, so
-- the slot you drag over is exactly the slot a widget sits at — they can't drift apart.
-- Returns total (axis length incl. gaps), crossMax, horizontal, cx, cy.
local function iterGroupSlots(gid, fn)
    local grp = ns.Groups.Get(gid)
    if not grp then return 0, 0, true, 0, 0 end
    local horizontal = grp.axis ~= "v"
    local gap = grp.gap or 0
    local cx, cy = grp.x or 0, grp.y or 0

    local shown, total, crossMax = {}, 0, 0
    for _, wid in ipairs(ns.Groups.Order(gid)) do
        local w = ns.widgets[wid]
        if w and w.frame:IsShown() then   -- a hidden reminder gives up its slot so the rest re-center
            local size  = horizontal and (w.cfg.width or 0) or (w.cfg.height or 0)
            local cross = horizontal and (w.cfg.height or 0) or (w.cfg.width or 0)
            shown[#shown + 1] = { w = w, size = size }
            total = total + size
            if cross > crossMax then crossMax = cross end
        end
    end
    local n = #shown
    if n > 1 then total = total + gap * (n - 1) end

    local run = horizontal and (cx - total / 2) or (cy + total / 2)
    for i = 1, n do
        local size = shown[i].size
        local cxi = horizontal and (run + size / 2) or cx
        local cyi = horizontal and cy or (run - size / 2)
        if fn then fn(shown[i].w, i, cxi, cyi, size) end
        run = horizontal and (run + size + gap) or (run - size - gap)
    end
    return total, crossMax, horizontal, cx, cy
end

-- Target CENTRE offset (from UIParent centre) of every widget.
--
-- Each GROUP (profile.groups) has its OWN stored centre (grp.x/y), axis and gap. The
-- members currently shown pack edge-to-edge, in the group's explicit order, centred on
-- that fixed centre — so a hidden member contributes no width and the rest slide in to
-- fill, and the cluster never drifts when membership varies by spec. A standalone
-- widget sits at its own anchor. Every value is an absolute offset (never a frame-to-
-- frame anchor). Also records each group's bounding box in ns._groupBox for the move-
-- mode chrome (handle + drop zone) and for drag hit-testing.
local function computeTargets()
    local target = {}
    ns._groupBox = {}
    local groups = (ns.profile and ns.profile.groups) or {}
    local grouped = {}

    for gid, grp in pairs(groups) do
        local order = ns.Groups.Order(gid)
        -- Skip only groups OWNED BY ANOTHER CLASS (their members aren't loaded here, so they'd
        -- draw as an empty handle). A group whose members are all untagged/shared reads as
        -- ClassOf == nil — that belongs to THIS character and MUST still render. (Previously nil
        -- was skipped too, so removing a group's only class-tagged member — e.g. Earth Shield —
        -- made the whole group vanish.)
        local co = ns.Groups.ClassOf(gid)
        if #order > 0 and (co == nil or co == ns.playerClass) then
            for _, wid in ipairs(order) do grouped[wid] = true end   -- claim membership (shown or not)

            -- Pack the shown members. The actively-dragged member keeps its SLOT
            -- reserved (iterGroupSlots still advances past it) but isn't positioned — it
            -- follows the cursor while the rest pack around it, so a live reorder shows
            -- the others shifting in real time.
            local total, crossMax, horizontal, cx, cy = iterGroupSlots(gid, function(w, _, cxi, cyi)
                if w.id ~= ns._dragActive then target[w.id] = { cxi, cyi } end
            end)

            for _, wid in ipairs(order) do                     -- hidden members park at centre
                if not target[wid] then target[wid] = { cx, cy } end
            end

            ns._groupBox[gid] = {
                cx = cx, cy = cy,
                halfW = (horizontal and total or crossMax) / 2,
                halfH = (horizontal and crossMax or total) / 2,
                horizontal = horizontal,
            }
        end
    end

    -- Standalone widgets: their own anchor (the actively-dragged one follows the cursor).
    for id, w in pairs(ns.widgets) do
        if not grouped[id] and id ~= ns._dragActive then
            local a = w.cfg.anchor or {}
            target[id] = { a.x or 0, a.y or 0 }
        end
    end

    return target
end

-- Move each widget toward its target. LIVE (locked) it slides; in move mode
-- (unlocked) and for hidden frames it snaps, so dragging stays crisp and a
-- reminder is ready at its slot the instant it shows.
local function applyTargets(target)
    -- Normally snap while unlocked (crisp dragging) and slide while locked (live). But
    -- DURING a member drag, slide the OTHER members into their new slots so a live
    -- reorder reads fluidly instead of jumping. A snappier slide while dragging.
    local dragging = ns._dragActive
    local animate = ns.profile and (not ns.profile.unlocked or dragging ~= nil)
    local dur = dragging and 0.11 or SLIDE   -- gentle, fluid slide while rearranging
    for id, w in pairs(ns.widgets) do
        if id == dragging then
            -- the actively-dragged widget follows the cursor (positioned in Widget.lua);
            -- kill any leftover position slide so it can't fight that manual placement.
            ns.Animation.Cancel("px_" .. id); ns.Animation.Cancel("py_" .. id)
        else
            local t = target[id]
            if t then
                local tx, ty = t[1], t[2]
                if (w._px == nil) or (not animate) or (not w.frame:IsShown()) then
                    ns.Animation.Cancel("px_" .. id); ns.Animation.Cancel("py_" .. id)
                    w._px, w._py = tx, ty
                    w.frame:ClearAllPoints(); w.frame:SetPoint("CENTER", UIParent, "CENTER", tx, ty)
                else
                    local apply = function() w.frame:ClearAllPoints(); w.frame:SetPoint("CENTER", UIParent, "CENTER", w._px, w._py) end
                    ns.Animation.To("px_" .. id, w._px, tx, dur, function(v) w._px = v; apply() end)
                    ns.Animation.To("py_" .. id, w._py, ty, dur, function(v) w._py = v; apply() end)
                end
            end
        end
    end
end

-- Re-place everyone (linked chains reflow + slide). Does NOT touch shown-state, so
-- it's safe to call from a visibility flip without recursing.
function Layout.Reposition()
    applyTargets(computeTargets())
    Layout.UpdateLinks()
end

-- Show widgets for the current spec, then place them.
function Layout.Resolve()
    for _, w in pairs(ns.widgets) do
        w:UpdateShown()   -- spec match + content policy (e.g. "only when missing")
    end
    Layout.Reposition()
end

-- ── Group chrome: the draggable title tab + drop-zone outline (move mode) ──
-- Each group gets a handle (a small title bar sitting above it) you drag to move the
-- WHOLE group, and a faint outline around its extent so "inside vs outside" is obvious
-- for the drag-to-attach / drag-out-to-detach gestures. Handles are pooled per gid.
local handles = {}

-- Manual drag of a whole group by its handle (moves grp.x/y). Own controller so it's
-- independent of the per-widget drag in Widget.lua.
local gdrag = {}
local gdragUpdater = CreateFrame("Frame"); gdragUpdater:Hide()
gdragUpdater:SetScript("OnUpdate", function()
    local gid = gdrag.gid; if not gid then return end
    if not IsMouseButtonDown("LeftButton") then gdrag.gid = nil; gdragUpdater:Hide(); return end
    local grp = ns.Groups.Get(gid); if not grp then gdrag.gid = nil; gdragUpdater:Hide(); return end
    local mx, my = GetCursorPosition()
    grp.x = gdrag.x0 + (mx - gdrag.mx0) / gdrag.scale
    grp.y = gdrag.y0 + (my - gdrag.my0) / gdrag.scale
    Layout.Reposition()
end)

local function ensureHandle(gid)
    local h = CreateFrame("Frame", nil, UIParent)
    h:SetFrameStrata("HIGH"); h:SetSize(70, 15); h:EnableMouse(true); h:Hide()
    local bg = h:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
    bg:SetColorTexture(T.rgba(T.hud.main)); bg:SetAlpha(0.9); h._bg = bg
    local lbl = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("CENTER"); lbl:SetTextColor(1, 1, 1); h._lbl = lbl

    -- drop-zone: a faint fill (only shown when this group is the active drop target) +
    -- four outline edges, on their own frame drawn behind the icons.
    local z = CreateFrame("Frame", nil, UIParent); z:SetFrameStrata("MEDIUM"); z:Hide()
    z._fill = z:CreateTexture(nil, "BACKGROUND"); z._fill:SetAllPoints(); z._fill:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.14); z._fill:Hide()
    z._edges = {}
    for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = z:CreateTexture(nil, "OVERLAY")
        z._edges[k] = t
    end
    h._zone = z

    h:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        local grp = ns.Groups.Get(gid); if not grp then return end
        gdrag.gid = gid
        gdrag.scale = UIParent:GetEffectiveScale()
        gdrag.mx0, gdrag.my0 = GetCursorPosition()
        gdrag.x0, gdrag.y0 = grp.x or 0, grp.y or 0
        h._downX, h._downY = gdrag.mx0, gdrag.my0
        gdragUpdater:Show()
    end)
    h:SetScript("OnMouseUp", function(_, btn)
        gdrag.gid = nil; gdragUpdater:Hide()
        -- Right-click, OR a left CLICK on the group name (no real drag), jumps to its Group tab.
        local jump = (btn == "RightButton")
        if not jump and h._downX then
            local mx, my = GetCursorPosition()
            jump = math.abs(mx - h._downX) < 6 and math.abs(my - h._downY) < 6
        end
        if jump and ns.SelectGroupInOptions then ns.SelectGroupInOptions(gid) end
    end)
    handles[gid] = h
    return h
end

local function layoutZone(z, box)
    local pad, th = 5, 1
    local w, hh = box.halfW * 2 + pad * 2, box.halfH * 2 + pad * 2
    z:ClearAllPoints(); z:SetSize(w, hh)
    z:SetPoint("CENTER", UIParent, "CENTER", box.cx, box.cy)
    local e = z._edges
    e.TOP:ClearAllPoints();    e.TOP:SetPoint("TOPLEFT");    e.TOP:SetPoint("TOPRIGHT");    e.TOP:SetHeight(th)
    e.BOTTOM:ClearAllPoints(); e.BOTTOM:SetPoint("BOTTOMLEFT"); e.BOTTOM:SetPoint("BOTTOMRIGHT"); e.BOTTOM:SetHeight(th)
    e.LEFT:ClearAllPoints();   e.LEFT:SetPoint("TOPLEFT");   e.LEFT:SetPoint("BOTTOMLEFT");  e.LEFT:SetWidth(th)
    e.RIGHT:ClearAllPoints();  e.RIGHT:SetPoint("TOPRIGHT"); e.RIGHT:SetPoint("BOTTOMRIGHT"); e.RIGHT:SetWidth(th)
end

-- Move-mode chrome: per-group handle + zone, and a per-widget border tint (grouped vs
-- standalone). Called by Reposition (so it tracks live positions during a group drag).
function Layout.UpdateChrome()
    local show = ns.profile and ns.profile.unlocked
    local boxes = ns._groupBox or {}

    for gid, h in pairs(handles) do
        if not (show and boxes[gid]) then h:Hide(); h._zone:Hide() end
    end
    if show then
        for gid, box in pairs(boxes) do
            local grp = ns.Groups.Get(gid)
            if grp then
                local h = handles[gid] or ensureHandle(gid)
                h._lbl:SetText(ns.Groups.DisplayName(gid))   -- shared "Group N" numbering (matches the sidebar)
                h:SetWidth(math.max(48, (h._lbl:GetStringWidth() or 30) + 18))
                h:ClearAllPoints()
                -- Sit above the group; flip BELOW if that'd clip off the top of the screen.
                local uh = UIParent:GetHeight() / 2
                if box.cy + box.halfH + 22 > uh then
                    h:SetPoint("TOP", UIParent, "CENTER", box.cx, box.cy - box.halfH - 5)
                else
                    h:SetPoint("BOTTOM", UIParent, "CENTER", box.cx, box.cy + box.halfH + 5)
                end
                h:Show()
                layoutZone(h._zone, box)
                -- Highlight the group the dragged widget will drop INTO (accent, brighter).
                local hot = (gid == ns._dropTargetGid)
                for _, t in pairs(h._zone._edges) do
                    if hot then t:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.95)
                    else t:SetColorTexture(T.hud.main[1], T.hud.main[2], T.hud.main[3], 0.5) end
                end
                h._zone._fill:SetShown(hot)
                h._bg:SetColorTexture(hot and T.accent[1] or T.hud.main[1], hot and T.accent[2] or T.hud.main[2], hot and T.accent[3] or T.hud.main[3])
                h._zone:Show()
            end
        end
    end

    for _, w in pairs(ns.widgets) do
        -- The widget currently SELECTED in the options panel gets a bright accent outline so you
        -- can tell which one you're editing; others keep their role tint (grouped vs standalone).
        local isSel = (w.id == ns._selectedId)
        local r, g, b
        if isSel then r, g, b = T.accent[1], T.accent[2], T.accent[3]
        elseif ns.Groups.GidOf(w.cfg) then r, g, b = T.rgba(T.hud.attached)
        else r, g, b = T.rgba(T.hud.lone) end
        if w.moveOverlay then w.moveOverlay:SetColorTexture(r, g, b, T.hud.overlayAlpha) end
        if w.moveEdges then for _, t in pairs(w.moveEdges) do t:SetColorTexture(r, g, b, isSel and 1 or T.hud.borderAlpha) end end
    end
end
Layout.UpdateLinks = Layout.UpdateChrome   -- back-compat alias (Reposition still calls UpdateLinks)

-- Which group's box contains the point (offset from UIParent centre), within margin —
-- the drop-target test for drag-to-attach / drag-out-to-detach. nil = outside all.
function Layout.GroupAt(x, y, margin)
    margin = margin or 20
    for gid, box in pairs(ns._groupBox or {}) do
        if math.abs(x - box.cx) <= box.halfW + margin and math.abs(y - box.cy) <= box.halfH + margin then
            return gid
        end
    end
    return nil
end

-- Is the point within a SPECIFIC group's box (+margin)? Used to tell reorder (inside
-- my own group) from detach (outside it), independent of any overlapping group.
function Layout.InGroupBox(gid, x, y, margin)
    local box = (ns._groupBox or {})[gid]; if not box then return false end
    margin = margin or 20
    return math.abs(x - box.cx) <= box.halfW + margin and math.abs(y - box.cy) <= box.halfH + margin
end

-- Where in a group's order the dragged widget should sit, given the cursor. Computed
-- against the ACTUAL displayed slots (the packing that already reserves the dragged's
-- gap), so the item you drag over slides aside exactly when your cursor reaches it —
-- no offset between the trigger and what's on screen.
--   · reorder (dragId already in the order): pick the SLOT nearest the cursor (1..N),
--     which is the position Reorder places it at.
--   · attach (dragId not yet in the order):  the insertion point among the members.
function Layout.InsertIndex(gid, x, y, dragId)
    local order = ns.Groups.Order(gid)
    local n = #order
    if n == 0 then return 1 end

    -- Only SHOWN members have a slot, but Groups.Reorder/Add index into the FULL order
    -- (which can also hold members hidden on another spec). So tag each slot with its
    -- FULL-ORDER index and RETURN THAT — otherwise a trailing hidden member makes the last
    -- real position unreachable (you "can't drag to the far end"). With nothing hidden the
    -- slot index equals the order index, so this is identical to the old behaviour.
    local orderIdx = {}
    for i, wid in ipairs(order) do orderIdx[wid] = i end

    local slots, inOrder = {}, false
    local _, _, horizontal = iterGroupSlots(gid, function(w, _, cxi, cyi)
        slots[#slots + 1] = { oi = orderIdx[w.id] or n, cx = cxi, cy = cyi }
        if w.id == dragId then inOrder = true end
    end)
    local m = #slots
    if m == 0 then return 1 end
    local cursor = horizontal and x or y
    local function pos(s) return horizontal and s.cx or s.cy end

    if inOrder then
        -- reorder: the shown SLOT nearest the cursor, mapped to its full-order index.
        local bestK, bestD = 1, math.huge
        for k = 1, m do
            local d = math.abs(cursor - pos(slots[k]))
            if d < bestD then bestD = d; bestK = k end
        end
        return slots[bestK].oi
    end
    -- attach: how many shown slots the cursor is past (h: to the right; v: above) — insert
    -- just before the next shown member, or at the very end.
    local past = 0
    for k = 1, m do
        local c = pos(slots[k])
        if (horizontal and cursor > c) or ((not horizontal) and cursor < c) then past = past + 1 end
    end
    if past >= m then return n + 1 end
    return slots[past + 1].oi
end

function Layout.SetUnlocked(state)
    if ns.profile then ns.profile.unlocked = state and true or false end
    for _, w in pairs(ns.widgets) do
        w:SetUnlocked(state)
    end
    -- Toggling move mode changes which members are shown (all reminders reveal when
    -- unlocked, hide again when locked), so re-pack every group. Without this the
    -- just-revealed reminders stay parked at their group centre and pile up. Reposition
    -- also refreshes the link visuals (it calls UpdateLinks).
    Layout.Reposition()
    -- Drive (or tear down) the live preview so tuning text/countdown/fill is possible
    -- without the real buff being up.
    if state then
        if ns.StartPreview then ns.StartPreview() end
    else
        if ns.StopPreview then ns.StopPreview() end
    end
end
