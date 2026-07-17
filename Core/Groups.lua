-- Core/Groups.lua : explicit widget GROUPS.
--
-- A group is a first-class object with its OWN stored centre (x/y), axis, gap and
-- member order. The shown members pack edge-to-edge centred on that fixed centre —
-- so the cluster never drifts when membership changes across specs, and you move the
-- whole thing by its handle (see Layout's group chrome) rather than a "main" icon.
--
-- Storage: profile.groups[gid] = { x, y, axis = "h"|"v", gap, order = { widgetId… }, name }
-- A member widget carries cfg.anchor.group = gid. A widget with no group is standalone
-- and uses cfg.anchor.x / y. (Replaces the old cfg.anchor.linkedTo chain graph.)

local ADDON, ns = ...

local Groups = {}
ns.Groups = Groups

local function widgets() return ns.profile and ns.profile.widgets end
local function tbl()
    local p = ns.profile
    if not p then return nil end
    p.groups = p.groups or {}
    return p.groups
end

local function newId()
    local p = ns.profile
    p._groupSeq = (p._groupSeq or 0) + 1
    return "g" .. p._groupSeq
end

function Groups.Get(gid) local g = tbl(); return gid and g and g[gid] or nil end

-- The valid group id a config belongs to (nil if standalone / dangling).
function Groups.GidOf(cfg)
    local gid = cfg and cfg.anchor and cfg.anchor.group
    return (gid and Groups.Get(gid)) and gid or nil
end

-- Member widget ids of a group, in order. Also self-heals: drops ids whose config no
-- longer points here, and appends any member missing from the order list.
function Groups.Order(gid)
    local grp = Groups.Get(gid); local W = widgets()
    if not (grp and W) then return {} end
    grp.order = grp.order or {}
    local out, seen = {}, {}
    for _, wid in ipairs(grp.order) do
        local c = W[wid]
        if c and c.anchor and c.anchor.group == gid and not seen[wid] then
            out[#out + 1] = wid; seen[wid] = true
        end
    end
    for wid, c in pairs(W) do
        if c.anchor and c.anchor.group == gid and not seen[wid] then
            out[#out + 1] = wid; seen[wid] = true
        end
    end
    grp.order = out
    return out
end

function Groups.Count(gid) return #Groups.Order(gid) end

-- The owning class of a group (from its members' cfg.class). Groups live in the shared cross-
-- char profile, so a character must show only its OWN class's groups — an other-class group's
-- members aren't loaded here and would otherwise draw as an empty, unlabelled handle. nil if
-- the group has no class-tagged member.
function Groups.ClassOf(gid)
    local grp = Groups.Get(gid); local W = widgets()
    if not (grp and W) then return nil end
    for _, wid in ipairs(grp.order or {}) do
        local c = W[wid]
        if c and c.class then return c.class end
    end
    return nil
end

-- Stable per-character display name: the user's own name, else "Group N" where N is this group's
-- position (sorted by id) among THIS character's groups — so the move-mode handle and the options
-- sidebar always show the SAME number for the same group.
-- The stable per-character group NUMBER: position among THIS character's non-empty groups, sorted
-- by id. The ONE source of that ordinal so the move-mode handle (DisplayName) and the sidebar badge
-- always agree. Returns nil if the group isn't in that set.
function Groups.DisplayNumber(gid)
    local g = tbl() or {}
    local mine = {}
    for id in pairs(g) do
        local co = Groups.ClassOf(id)
        if Groups.Count(id) > 0 and (co == nil or co == ns.playerClass) then mine[#mine + 1] = id end
    end
    table.sort(mine)
    for i, id in ipairs(mine) do if id == gid then return i end end
    return nil
end

function Groups.DisplayName(gid)
    local grp = Groups.Get(gid); if not grp then return "Group" end
    if grp.name and grp.name ~= "" and grp.name ~= "Group" then return grp.name end
    local n = Groups.DisplayNumber(gid)
    return n and ("Group " .. n) or "Group"
end

-- Create an empty group at a centre; caller then Adds members.
function Groups.Create(cx, cy, axis)
    local g = tbl(); if not g then return nil end
    local gid = newId()
    g[gid] = { x = cx or 0, y = cy or 0, axis = axis or "h", gap = 0, order = {}, name = "Group" }
    return gid
end

-- Detach a widget from whatever group it's in (silent — dissolve handled by callers
-- that need it, so Add can move a widget between groups without a spurious dissolve).
local function detachOnly(wid)
    local W = widgets(); local c = W and W[wid]
    if not (c and c.anchor and c.anchor.group) then return nil end
    local gid = c.anchor.group
    c.anchor.group = nil
    local grp = Groups.Get(gid)
    if grp and grp.order then
        for i = #grp.order, 1, -1 do if grp.order[i] == wid then table.remove(grp.order, i) end end
    end
    return gid
end

-- Add a widget to a group at `index` (1-based; nil = end). Clears any prior group.
function Groups.Add(gid, wid, index)
    local grp = Groups.Get(gid); local W = widgets()
    if not (grp and W and W[wid]) then return end
    local oldGid = detachOnly(wid)
    local c = W[wid]; c.anchor = c.anchor or {}
    c.anchor.group = gid
    c.anchor.linkedTo, c.anchor.linkSide = nil, nil   -- legacy fields never coexist with a group
    grp.order = grp.order or {}
    index = math.max(1, math.min(index or (#grp.order + 1), #grp.order + 1))
    table.insert(grp.order, index, wid)
    Groups.InheritSize(gid, wid)
    if oldGid and oldGid ~= gid and Groups.Count(oldGid) < 2 then Groups.Dissolve(oldGid) end
end

-- A joining ICON takes on the cluster's icon size, so a new member matches the rest
-- instead of standing out at its own size. (Gap/spacing is a group property that already
-- applies to every member via the layout, so only per-widget size needs copying.) Uses
-- the first existing icon member's size as the group's canonical size; restyles the live
-- widget so the change shows immediately.
function Groups.InheritSize(gid, wid)
    local grp = Groups.Get(gid); local W = widgets()
    if not (grp and W) then return end
    local c = W[wid]
    if not (c and c.display == "icon") then return end
    for _, other in ipairs(grp.order or {}) do
        if other ~= wid then
            local oc = W[other]
            if oc and oc.display == "icon" and oc.width then
                if c.width == oc.width and c.height == oc.height then return end
                c.width, c.height = oc.width, oc.height
                c._sizeByDisplay = c._sizeByDisplay or {}
                c._sizeByDisplay.icon = { oc.width, oc.height }   -- keep per-display memory in sync
                if ns.widgets and ns.widgets[wid] then ns.widgets[wid]:ApplyStyle() end
                return
            end
        end
    end
end

-- Move a member to a new position within its group's order.
function Groups.Reorder(gid, wid, index)
    local grp = Groups.Get(gid); if not (grp and grp.order) then return end
    for i = #grp.order, 1, -1 do if grp.order[i] == wid then table.remove(grp.order, i) end end
    index = math.max(1, math.min(index or (#grp.order + 1), #grp.order + 1))
    table.insert(grp.order, index, wid)
end

-- Dissolve a group: every remaining member becomes standalone, frozen at its current
-- on-screen spot so nothing jumps.
function Groups.Dissolve(gid)
    local grp = Groups.Get(gid); local W = widgets()
    if not (grp and W) then return end
    for wid, c in pairs(W) do
        if c.anchor and c.anchor.group == gid then
            local w = ns.widgets and ns.widgets[wid]
            c.anchor.x = (w and w._px) or c.anchor.x or grp.x
            c.anchor.y = (w and w._py) or c.anchor.y or grp.y
            c.anchor.group = nil
        end
    end
    tbl()[gid] = nil
end

-- Remove a widget from its group (becomes standalone at drop x/y if given, else its
-- current spot). Auto-dissolves a group that drops below 2 members.
function Groups.Remove(wid, x, y)
    local W = widgets(); local c = W and W[wid]
    if not (c and c.anchor and c.anchor.group) then return end
    local gid = c.anchor.group
    detachOnly(wid)
    if x then c.anchor.x = x end
    if y then c.anchor.y = y end
    if Groups.Count(gid) < 2 then Groups.Dissolve(gid) end
end

-- Dissolve any group left with fewer than 2 members (e.g. a member was deleted
-- outright rather than detached). Called from Layout.Rebuild after structural changes.
function Groups.Prune()
    local g = tbl(); if not g then return end
    local dead = {}
    for gid in pairs(g) do if Groups.Count(gid) < 2 then dead[#dead + 1] = gid end end
    for _, gid in ipairs(dead) do Groups.Dissolve(gid) end
end

-- ── Migration: legacy linkedTo chains -> explicit groups ───────────────
-- Self-contained (runs before ns.profile is guaranteed set): operates on the passed
-- profile p directly. Each connected component of the old anchor.linkedTo graph with
-- 2+ members becomes a group; centre = centroid, axis = the larger span, gap = the
-- root's old linkGap, order = the same left→right / top→bottom sort the layout used.
function Groups.Migrate(p)
    if not (p and p.widgets) then return end
    p.groups = p.groups or {}
    local W = p.widgets

    local function root(id)
        local seen, cur = {}, id
        while cur and W[cur] and not seen[cur] do
            seen[cur] = true
            local a = W[cur].anchor
            local par = a and a.linkedTo
            if not par or not W[par] or par == cur then break end
            cur = par
        end
        return cur
    end

    -- Bucket every LINKED widget (and its root) by component root.
    local byRoot = {}
    for id, c in pairs(W) do
        if c.anchor and c.anchor.linkedTo and W[c.anchor.linkedTo] then
            local r = root(id)
            local set = byRoot[r]; if not set then set = {}; byRoot[r] = set end
            set[id] = true; set[r] = true
        end
    end

    for _, set in pairs(byRoot) do
        local ids = {}
        for id in pairs(set) do ids[#ids + 1] = id end
        if #ids >= 2 then
            local sx, sy, minx, maxx, miny, maxy = 0, 0, math.huge, -math.huge, math.huge, -math.huge
            local gap = 0
            for _, id in ipairs(ids) do
                local a = W[id].anchor or {}
                local x, y = a.x or 0, a.y or 0
                sx, sy = sx + x, sy + y
                if x < minx then minx = x end; if x > maxx then maxx = x end
                if y < miny then miny = y end; if y > maxy then maxy = y end
                if W[id].linkGap and W[id].linkGap > gap then gap = W[id].linkGap end
            end
            local cx, cy = sx / #ids, sy / #ids
            local horizontal = (maxx - minx) >= (maxy - miny)
            table.sort(ids, function(a, b)
                local aa, ab = W[a].anchor or {}, W[b].anchor or {}
                if horizontal then return (aa.x or 0) < (ab.x or 0) else return (aa.y or 0) > (ab.y or 0) end
            end)
            p._groupSeq = (p._groupSeq or 0) + 1
            local gid = "g" .. p._groupSeq
            p.groups[gid] = { x = cx, y = cy, axis = horizontal and "h" or "v", gap = gap, order = ids, name = "Group" }
            for _, id in ipairs(ids) do
                local a = W[id].anchor; a.group = gid; a.linkedTo, a.linkSide = nil, nil
                W[id].linkGap = nil
            end
        end
    end
end
