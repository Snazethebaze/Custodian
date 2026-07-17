-- Options/PanelList.lua : the left sidebar — the widget list, its folder/class grouping, the
-- row right-click menus, and the move-mode group pips.
--
-- Split out of Options/Panel.lua. RefreshList is the one entry point the rest of the panel
-- needs, so it lives on the shared ns.OPT table; the menus, folder view-state and pip colours
-- are private to this file. Panel.lua helpers (folder CRUD, widgetIcon, applyStructural,
-- RefreshEditor) come in via OPT, resolved at call time.

local ADDON, ns = ...

local OPT = ns.OPT
local UI = ns.UI
local ACCENT = UI.ACCENT
local bgTex, tweenAlpha = UI.bgTex, UI.tweenAlpha

local P
OPT.OnBind(function(panel) P = panel end)

-- The top menu and its "Move to" drill open each other, so forward-declare both as
-- file-scoped locals — never globals.
local showWidgetMenu, showMoveMenu

-- ── list / editor refresh ─────────────────────────────────────────────
-- The sidebar groups widgets into the USER'S folders (cfg.folder). Widgets with
-- no folder sit loose at the top; folders (order + collapse) come from
-- profile.folders. With no folders at all it's just a flat list — you only get
-- structure when you ask for it. Right-click a folder header to rename / delete.
local ungroupedCollapsed = false
local classCollapsed = {}   -- classToken -> collapsed? (session view state; others default collapsed)
local SHARED_TOKEN = "\0shared"   -- sentinel bucket for class-agnostic widgets

-- Pop a small context menu at `anchor` from a list of { text, func, header?, checked? }
-- items. Rows are pooled; a header is a non-clickable caption. Dismissed by the
-- click-eater (built in build()) on any outside click.
local CTX_ROW_H = 20
local function showContextMenu(anchor, items)
    local cm = P and P._ctxMenu
    if not cm then return end
    for _, r in ipairs(P._ctxRows) do r:Hide() end
    local yy = 4
    for i, it in ipairs(items) do
        local r = P._ctxRows[i]
        if not r then
            r = CreateFrame("Button", nil, cm); r:SetHeight(CTX_ROW_H)
            r._h = bgTex(r, ACCENT[1], ACCENT[2], ACCENT[3], 0)
            r._f = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r._f:SetPoint("LEFT", 8, 0); r._f:SetPoint("RIGHT", -8, 0); r._f:SetJustifyH("LEFT"); r._f:SetWordWrap(false)
            r:SetScript("OnEnter", function() if r._on then r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.25) end end)
            r:SetScript("OnLeave", function() r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0) end)
            P._ctxRows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", cm, "TOPLEFT", 1, -yy); r:SetPoint("TOPRIGHT", cm, "TOPRIGHT", -1, -yy)
        if it.header then
            r._on = false; r:EnableMouse(false)
            r._f:SetText("|cff8fbfe0" .. it.text .. "|r")
            r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.10)
            r:SetScript("OnClick", nil)
        else
            r._on = true; r:EnableMouse(true)
            r._f:SetText((it.checked and "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t " or "") .. it.text)
            r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0)
            r:SetScript("OnClick", function() cm:Hide(); if it.func then it.func() end end)
        end
        r:Show()
        yy = yy + CTX_ROW_H
    end
    cm:SetSize(150, yy + 4)
    cm:ClearAllPoints(); cm:SetPoint("TOPLEFT", anchor, "TOPRIGHT", -8, 0)
    cm:Show(); cm:Raise()
    if P._menuEater then P._menuEater:Show() end
end

-- ── Widget row right-click menu ───────────────────────────────────────
-- Duplicate · Delete · Move to folder ▶ (a drill submenu). The Move-to list is scoped to
-- the widget's OWN class — folders that already hold a same-class widget (plus the
-- current one and + New folder) — so you never drop a DK widget into a Shaman-only folder.
local function duplicateWidget(id)
    local c = ns.profile.widgets[id]; if not c then return end
    local copy = CopyTable(c)
    copy.anchor = { x = (c.anchor and c.anchor.x or 0) + 16, y = (c.anchor and c.anchor.y or 0) - 16 }  -- standalone, nudged
    local n, nid = 1; repeat nid = "user_" .. n; n = n + 1 until not ns.profile.widgets[nid]
    copy.name = (c.name or id) .. " copy"
    ns.profile.widgets[nid] = copy; table.insert(ns.profile.order, nid)
    OPT.applyStructural(); P.selectedId = nid; OPT.RefreshList(); OPT.RefreshEditor()
end
local function deleteWidget(id)
    if not (id and ns.profile.widgets[id]) then return end
    ns.profile.widgets[id] = nil
    for i, wid in ipairs(ns.profile.order) do if wid == id then table.remove(ns.profile.order, i); break end end
    if P.selectedId == id then P.selectedId = ns.profile.order[1] end
    OPT.applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
end
-- Folders that belong to this widget's class (hold ≥1 same-class widget), so Move-to
-- stays within the class. Plus the widget's current folder, always.
local function classFolderNames(id)
    local c = ns.profile.widgets[id]
    local myClass = ns.ClassOfCfg(c)
    local used = {}
    for _, w in pairs(ns.profile.widgets) do
        if w.folder and w.folder ~= "" and ns.ClassOfCfg(w) == myClass then used[w.folder] = true end
    end
    if c.folder and c.folder ~= "" then used[c.folder] = true end
    local out = {}
    for _, f in ipairs(OPT.foldersList()) do if used[f.name] then out[#out + 1] = f.name end end
    return out
end


function showMoveMenu(anchor, id)
    local c = ns.profile.widgets[id]
    local function moveTo(name) c.folder = name; OPT.applyStructural(); OPT.RefreshList(); OPT.RefreshEditor() end
    local items = {
        { text = "\194\171 Back", func = function() showWidgetMenu(anchor, id) end },   -- « Back (Latin-1; font-safe)
        { text = "Move to folder", header = true },
        { text = "(No folder)", checked = not (c.folder and c.folder ~= ""), func = function() moveTo(nil) end },
    }
    for _, name in ipairs(classFolderNames(id)) do
        items[#items + 1] = { text = name, checked = (c.folder == name), func = function() moveTo(name) end }
    end
    items[#items + 1] = { text = "+ New folder", func = function()
        OPT.promptFolderName("", function(nm) nm = OPT.ensureFolder(nm); if nm then moveTo(nm) end end)
    end }
    showContextMenu(anchor, items)
end
function showWidgetMenu(anchor, id)
    local c = ns.profile.widgets[id]
    showContextMenu(anchor, {
        { text = c and (c.name or id) or id, header = true },
        { text = "Duplicate", func = function() duplicateWidget(id) end },
        { text = "Delete",    func = function() deleteWidget(id) end },
        { text = "Move to folder  \194\187", func = function() showMoveMenu(anchor, id) end },   -- » drill (Latin-1; font-safe)
        { text = "Export", func = function() OPT.openShareExport(ns.Share.EncodeWidgets({ id }, "widget", c and c.name), c and c.name) end },
    })
end

-- A stable, distinct colour per DISPLAY group (widgets connected on the HUD), so the
-- sidebar can pip each grouped row — same colour = same on-screen cluster. Keyed by gid,
-- ordered by the numeric id suffix so colours don't shuffle between refreshes.
local GROUP_PIPS = {
    { 0.40, 0.75, 1.00 }, { 1.00, 0.62, 0.35 }, { 0.55, 0.90, 0.45 }, { 0.80, 0.58, 1.00 },
    { 1.00, 0.85, 0.35 }, { 1.00, 0.48, 0.58 }, { 0.40, 0.90, 0.85 }, { 0.70, 0.72, 0.78 },
}
local function groupColorMap()
    local groups = ns.profile and ns.profile.groups
    if not groups then return {} end
    local gids = {}
    for gid in pairs(groups) do gids[#gids + 1] = gid end
    table.sort(gids, function(a, b) return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0) end)
    local map = {}
    for i, gid in ipairs(gids) do
        local c = GROUP_PIPS[((i - 1) % #GROUP_PIPS) + 1]
        map[gid] = { c[1], c[2], c[3], n = i }   -- colour + a stable ordinal for the badge number
    end
    return map
end

function OPT.RefreshList()
    if not P then return end
    for _, r in ipairs(P._listRows) do r:Hide() end
    local grpColors = groupColorMap()

    -- Bucket ids by CLASS (the profile is shared across characters), preserving
    -- profile.order within each. A class-agnostic widget lands in the SHARED bucket.
    local byClass = {}
    for _, id in ipairs(ns.profile.order) do
        local c = ns.profile.widgets[id]
        if c then
            local token = ns.ClassOfCfg(c) or SHARED_TOKEN
            local b = byClass[token]; if not b then b = {}; byClass[token] = b end
            b[#b + 1] = id
        end
    end
    -- Surface the class layer whenever the profile holds any widget that ISN'T this
    -- character's (a foreign class) — that's exactly when the list would otherwise be
    -- cluttered with other classes' things. A char whose profile is all its own class
    -- (+ shared) keeps the clean flat/folder list it had.
    local useClassLayer = false
    for token in pairs(byClass) do
        if token ~= SHARED_TOKEN and token ~= ns.playerClass then useClassLayer = true; break end
    end

    -- Class display order: your current class first, then Shared, then the rest by name.
    local classOrder = {}
    if byClass[ns.playerClass] then classOrder[#classOrder + 1] = ns.playerClass end
    if byClass[SHARED_TOKEN] then classOrder[#classOrder + 1] = SHARED_TOKEN end
    do
        local rest = {}
        for token in pairs(byClass) do
            if token ~= ns.playerClass and token ~= SHARED_TOKEN then rest[#rest + 1] = token end
        end
        table.sort(rest, function(a, b) return ns.ClassName(a) < ns.ClassName(b) end)
        for _, t in ipairs(rest) do classOrder[#classOrder + 1] = t end
    end
    local function classLabel(token) return (token == SHARED_TOKEN) and "Shared" or ns.ClassName(token) end
    local function classHex(token)
        local cc = (token ~= SHARED_TOKEN) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if cc and cc.colorStr then return cc.colorStr:sub(3) end   -- "ffRRGGBB" -> "RRGGBB"
        return "cbe2ff"
    end
    local function classIsCollapsed(token)
        local v = classCollapsed[token]
        if v == nil then v = not (token == ns.playerClass or token == SHARED_TOKEN); classCollapsed[token] = v end
        return v
    end

    local i = 0
    local function row()
        i = i + 1
        local r = P._listRows[i]
        if not r then
            r = CreateFrame("Button", nil, P._list); r:SetHeight(22)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r._h = bgTex(r, ACCENT[1], ACCENT[2], ACCENT[3], 1); r._h:SetAlpha(0)   -- accent, alpha-driven so it can fade
            r._bar = r:CreateTexture(nil, "OVERLAY"); r._bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
            r._bar:SetPoint("TOPLEFT"); r._bar:SetPoint("BOTTOMLEFT"); r._bar:SetWidth(3); r._bar:Hide()   -- selected-row accent stripe
            r._f = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r._f:SetJustifyH("LEFT")
            r._icon = r:CreateTexture(nil, "ARTWORK"); r._icon:SetSize(16, 16)
            r._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); r._icon:Hide()   -- trim the default icon border
            -- Display-group badge on the right edge: a colour chip with the group's NUMBER on it, so
            -- membership reads by number (colour-blind safe) as well as colour — same number = same
            -- on-screen cluster. Compact (no wrapping); the full group name is in the row tooltip.
            r._grpPip = r:CreateTexture(nil, "OVERLAY")
            r._grpPip:SetSize(15, 13); r._grpPip:SetPoint("RIGHT", -6, 0)
            r._grpPip:Hide()
            r._grpNum = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r._grpNum:SetPoint("CENTER", r._grpPip, "CENTER", 0, 0); r._grpNum:SetTextColor(0.08, 0.08, 0.08)
            r._grpNum:Hide()
            r:SetScript("OnEnter", function()
                if r._hoverable then tweenAlpha(r._h, (r._baseA or 0) + 0.13, 0.10) end
                if r._grpTip then
                    GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                    GameTooltip:SetText(r._grpTip, 1, 1, 1); GameTooltip:Show()
                end
            end)
            r:SetScript("OnLeave", function()
                if r._hoverable then tweenAlpha(r._h, r._baseA or 0, 0.13) end
                GameTooltip:Hide()
            end)
            P._listRows[i] = r
        end
        local yy = -((i - 1) * 22 + 2)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", P._list, "TOPLEFT", 1, yy)
        r:SetPoint("TOPRIGHT", P._list, "TOPRIGHT", -1, yy)
        r._f:ClearAllPoints()
        r._ctxOpen = nil   -- reset each acquisition; menu-bearing rows below set their own opener
        return r
    end

    local function widgetRow(id, indent)
        local c = ns.profile.widgets[id]
        local r = row()
        r._id = id
        local ic, unlearned = OPT.widgetIcon(c)
        if ic then
            r._icon:ClearAllPoints(); r._icon:SetPoint("LEFT", indent, 0)
            r._icon:SetTexture(ic); r._icon:SetDesaturated(unlearned and true or false); r._icon:Show()
            r._f:SetPoint("LEFT", indent + 20, 0)
        else
            r._icon:Hide()
            r._f:SetPoint("LEFT", indent, 0)
        end
        r._f:SetText(c.name or id)
        -- Mark display-group membership: a colour-coded pip (shared per on-screen cluster).
        local gid = ns.Groups and ns.Groups.GidOf(c)
        local col = gid and grpColors[gid]
        if col then
            r._grpPip:SetColorTexture(col[1], col[2], col[3], 1); r._grpPip:Show()
            local num = ns.Groups.DisplayNumber(gid) or col.n   -- SAME number the move-mode handle shows
            r._grpNum:SetText(tostring(num or "")); r._grpNum:Show()
            r._f:SetPoint("RIGHT", r._grpPip, "LEFT", -4, 0)   -- name clears the badge (compact — no wrap)
            local grp = ns.Groups.Get(gid)
            local n = ns.Groups.Count(gid)
            local axis = (grp and grp.axis == "v") and "vertical" or "horizontal"
            r._grpTip = ("%s — %d widget%s, %s"):format(ns.Groups.DisplayName(gid), n, n == 1 and "" or "s", axis)
        else
            r._grpPip:Hide(); r._grpNum:Hide(); r._grpTip = nil
            r._f:SetPoint("RIGHT", -8, 0)   -- reset: this pooled row may have been a grouped one
        end
        r._hoverable = true
        local sel = (id == P.selectedId)
        r._baseA = sel and 0.26 or 0
        tweenAlpha(r._h, r._baseA, 0)   -- snap to resting state (cancels any stale fade)
        r._bar:SetShown(sel)
        r._f:SetTextColor(1, 1, 1)
        r._ctxOpen = function() showWidgetMenu(r, id) end   -- so a right-click while another menu is open re-targets here
        r:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                showWidgetMenu(r, id)
            else
                P.selectedId = id; OPT.RefreshList(); OPT.RefreshEditor()
            end
        end)
        r:Show()
    end

    -- `onExport` (optional): a function that exports this header's widgets. `isReal` marks
    -- a real (renamable/deletable) folder. Right-click builds Export + Rename/Delete.
    local function headerRow(name, collapsed, count, isReal, onToggle, indent, hex, onExport)
        local hr = row()
        hr._icon:Hide()
        hr._grpPip:Hide(); hr._grpNum:Hide(); hr._grpTip = nil
        local pm = collapsed and "UI-PlusButton-Up" or "UI-MinusButton-Up"
        hr._f:SetPoint("LEFT", indent or 4, 0)
        hr._f:SetText(("|TInterface\\Buttons\\%s:14|t |cff%s%s|r |cff6a6a6a(%d)|r"):format(pm, hex or "cbe2ff", name, count))
        hr._hoverable, hr._baseA = true, 0.10        -- clickable band, subtle hover lift
        tweenAlpha(hr._h, 0.10, 0)
        hr._bar:Hide()
        local function openHeaderMenu()
            local items = {}
            if onExport then items[#items + 1] = { text = "Export", func = onExport } end
            if isReal then
                items[#items + 1] = { text = "Rename", func = function()
                    OPT.promptFolderName(name, function(nn) OPT.renameFolder(name, nn); OPT.applyStructural(); OPT.RefreshList(); OPT.RefreshEditor() end)
                end }
                items[#items + 1] = { text = "Delete", func = function()
                    OPT.deleteFolder(name); OPT.applyStructural(); OPT.RefreshList(); OPT.RefreshEditor()
                end }
            end
            if #items > 0 then
                table.insert(items, 1, { text = name, header = true })
                showContextMenu(hr, items)
            end
        end
        if onExport or isReal then hr._ctxOpen = openHeaderMenu end   -- re-target on right-click while a menu is open
        hr:SetScript("OnClick", function(_, button)
            if button == "RightButton" then openHeaderMenu() else onToggle() end
        end)
        hr:Show()
    end

    -- Render a set of widget ids grouped by FOLDER (+ an Ungrouped bucket), indented by
    -- `base` so it can nest under a class header. Folders are the persisted list first,
    -- then any a widget names that isn't listed yet.
    local function renderFolders(ids, base)
        local byFolder, ungrouped = {}, {}
        for _, id in ipairs(ids) do
            local c = ns.profile.widgets[id]
            local fld = c and c.folder
            if fld and fld ~= "" then byFolder[fld] = byFolder[fld] or {}; table.insert(byFolder[fld], id)
            else ungrouped[#ungrouped + 1] = id end
        end
        local order, seen = {}, {}
        for _, f in ipairs(OPT.foldersList()) do
            if byFolder[f.name] and not seen[f.name] then order[#order + 1] = f.name; seen[f.name] = true end
        end
        for name in pairs(byFolder) do if not seen[name] then order[#order + 1] = name; seen[name] = true end end

        if #order == 0 then   -- no folders in this set -> flat rows
            for _, id in ipairs(ungrouped) do widgetRow(id, base + 8) end
            return
        end
        for _, name in ipairs(order) do
            local f = OPT.findFolder(name)
            local collapsed = f and f.collapsed
            local fids = byFolder[name] or {}
            headerRow(name, collapsed, #fids, true, function()
                local ff = OPT.findFolder(name) or (OPT.ensureFolder(name) and OPT.findFolder(name))
                if ff then ff.collapsed = not ff.collapsed end
                OPT.RefreshList()
            end, base + 4, nil,
            function() OPT.openShareExport(ns.Share.EncodeWidgets(fids, "folder", name), name) end)
            if not collapsed then for _, id in ipairs(fids) do widgetRow(id, base + 22) end end
        end
        if #ungrouped > 0 then
            headerRow("Ungrouped", ungroupedCollapsed, #ungrouped, false, function()
                ungroupedCollapsed = not ungroupedCollapsed; OPT.RefreshList()
            end, base + 4, nil,
            function() OPT.openShareExport(ns.Share.EncodeWidgets(ungrouped, "folder", "Ungrouped"), "Ungrouped") end)
            if not ungroupedCollapsed then for _, id in ipairs(ungrouped) do widgetRow(id, base + 22) end end
        end
    end

    -- Single class in the profile -> the familiar flat/folder list. Multiple classes ->
    -- a class header layer (your class + Shared expanded, other classes collapsed) so a
    -- character isn't buried under other classes' widgets.
    if not useClassLayer then
        renderFolders(ns.profile.order, 0)
    else
        for _, token in ipairs(classOrder) do
            local ids = byClass[token]
            local collapsed = classIsCollapsed(token)
            headerRow(classLabel(token), collapsed, #ids, false, function()
                classCollapsed[token] = not collapsed; OPT.RefreshList()
            end, 4, classHex(token),
            function() OPT.openShareExport(ns.Share.EncodeWidgets(ids, "class", classLabel(token)), classLabel(token)) end)
            if not collapsed then renderFolders(ids, 12) end
        end
    end

    -- Empty state: a fresh character (Defaults only seeds Shaman) otherwise shows a bare dark box.
    if not P._listEmpty then
        P._listEmpty = P._list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        P._listEmpty:SetPoint("TOPLEFT", 10, -10); P._listEmpty:SetPoint("RIGHT", -10, 0)
        P._listEmpty:SetJustifyH("LEFT"); P._listEmpty:SetText("Your widgets will appear here.")
    end
    P._listEmpty:SetShown(i == 0)

    -- Size the scroll child to the rows drawn (i = row count), so it can scroll.
    P._list:SetHeight(math.max(i * 22 + 4, 1))
    if P._listUpdateScrollbar then P._listUpdateScrollbar() end
end

-- Let the HUD refresh the sidebar (group pips / "Group N" names) after a move-mode change —
-- otherwise the list only caught up on close+reopen. No-op unless the panel is open.
ns.RefreshOptionsList = function() if P and P:IsShown() then OPT.RefreshList() end end
