-- Core/Share.lua : import / export widget setups as shareable strings.
--
-- Replaces the profile system. You export a single widget, a folder, or a whole class
-- (from the sidebar's right-click menus) to a string, and import that string to add the
-- same widgets — with their trackers, groups and folder intact — into your own setup.
--
-- The string is a SAFE, data-only encoding (no loadstring / code execution on import):
-- a tiny length-prefixed serializer, deflated + printable-encoded (LibDeflate), tagged CUST1!.

local ADDON, ns = ...

local LibDeflate = LibStub("LibDeflate")

local Share = {}
ns.Share = Share

-- Brand tag on every shared string. (Was ANC1/ANC2 under the old name; CUST1 marks the
-- Custodian format: deflate + printable encoding.)
local PREFIX = "CUST1!"

-- Deep copy of plain data (configs are tables of string/number/boolean/nested).
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = copy(val) end
    return t
end

-- ── serializer ────────────────────────────────────────────────────────
-- Grammar: T/F boolean · N<num>; number · S<len>:<bytes> string · Z nil ·
-- M<count>; (key value)* table (keys + values are themselves values). Length-prefixed
-- strings need no escaping; parsing is a plain cursor walk (no executable content).
local function ser(v, out)
    local tp = type(v)
    if tp == "boolean" then out[#out + 1] = v and "T" or "F"
    elseif tp == "number" then out[#out + 1] = "N"; out[#out + 1] = tostring(v); out[#out + 1] = ";"
    elseif tp == "string" then out[#out + 1] = "S"; out[#out + 1] = tostring(#v); out[#out + 1] = ":"; out[#out + 1] = v
    elseif tp == "table" then
        local n = 0; for _ in pairs(v) do n = n + 1 end
        out[#out + 1] = "M"; out[#out + 1] = tostring(n); out[#out + 1] = ";"
        for k, val in pairs(v) do ser(k, out); ser(val, out) end
    else out[#out + 1] = "Z" end
end
local function serialize(v) local out = {}; ser(v, out); return table.concat(out) end

-- Hard limits so a tiny hostile string can't blow the C stack (deeply nested maps)
-- or balloon memory (a huge declared count). Tripping either aborts the parse, which
-- pcall below turns into a clean "unreadable" — never a client crash.
local MAX_DEPTH = 64
local MAX_NODES = 100000

local function deser(s, i, depth, ctx)
    if depth > MAX_DEPTH then error("depth") end
    ctx.n = ctx.n + 1; if ctx.n > MAX_NODES then error("nodes") end
    local tag = s:sub(i, i); i = i + 1
    if tag == "T" then return true, i
    elseif tag == "F" then return false, i
    elseif tag == "Z" then return nil, i
    elseif tag == "N" then
        local e = s:find(";", i, true); if not e then error("num") end
        return tonumber(s:sub(i, e - 1)), e + 1
    elseif tag == "S" then
        local c = s:find(":", i, true); if not c then error("str") end
        local len = tonumber(s:sub(i, c - 1))
        if not len or len < 0 or c + len > #s + 1 then error("str len") end
        return s:sub(c + 1, c + len), c + 1 + len
    elseif tag == "M" then
        local c = s:find(";", i, true); if not c then error("map") end
        local cnt = tonumber(s:sub(i, c - 1))
        if not cnt or cnt < 0 then error("map count") end
        i = c + 1
        local t = {}
        for _ = 1, cnt do
            local k; k, i = deser(s, i, depth + 1, ctx)
            local val; val, i = deser(s, i, depth + 1, ctx)
            if k ~= nil then t[k] = val end
        end
        return t, i
    end
    error("tag")
end
local function deserialize(s)
    local ok, v = pcall(deser, s, 1, 0, { n = 0 })
    if not ok then return nil end
    return v
end

-- ── wire encoding: deflate + printable (LibDeflate) ───────────────────
-- Compress the serialized blob (configs are very repetitive, so deflate wins big),
-- then EncodeForPrint into a compact copy-paste-safe alphabet. Still data-only —
-- deflate is not executable content.
local function encode(data)
    return LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(data))
end
local function decode(text)
    local packed = LibDeflate:DecodeForPrint(text); if not packed then return nil end
    return LibDeflate:DecompressDeflate(packed)   -- nil on malformed input
end

-- ── export ────────────────────────────────────────────────────────────
-- Bundle the given widget ids (+ their trackers, any fully-contained groups, and folder
-- metadata) into a shareable string. `scope`/`label` are carried for display only.
function Share.EncodeWidgets(ids, scope, label)
    local p = ns.profile; if not p then return nil end
    local set = {}; for _, id in ipairs(ids) do set[id] = true end
    local payload = { v = 1, scope = scope, name = label, widgets = {}, trackers = {}, groups = {}, folders = {} }

    for _, id in ipairs(ids) do
        local c = p.widgets[id]
        if c then
            payload.widgets[id] = copy(c)
            local tid = c.trackerId
            if tid and p.trackers[tid] and not payload.trackers[tid] then
                payload.trackers[tid] = copy(p.trackers[tid])
            end
            if c.folder and c.folder ~= "" and not payload.folders[c.folder] then
                local col
                for _, ff in ipairs(p.folders or {}) do if ff.name == c.folder then col = ff.collapsed; break end end
                payload.folders[c.folder] = { collapsed = col }
            end
        end
    end

    -- Keep only groups whose every shown member is in the export; otherwise the members
    -- come across as standalone (no dangling group reference).
    for gid, g in pairs(p.groups or {}) do
        local order = ns.Groups and ns.Groups.Order(gid) or {}
        local members, allIn = {}, (#order > 0)
        for _, wid in ipairs(order) do
            if set[wid] then members[#members + 1] = wid else allIn = false end
        end
        if allIn and #members >= 2 then
            payload.groups[gid] = { x = g.x, y = g.y, axis = g.axis, gap = g.gap, name = g.name, share = copy(g.share), order = members }
        end
    end
    for _, cc in pairs(payload.widgets) do
        if cc.anchor and cc.anchor.group and not payload.groups[cc.anchor.group] then cc.anchor.group = nil end
    end

    return PREFIX .. encode(serialize(payload))
end

-- ── import ────────────────────────────────────────────────────────────
-- Parse a string and add its widgets (new ids throughout, remapping trackers + groups),
-- preserving each widget's class so shared setups land in the right sidebar section.
-- Returns ok, countOrError.
-- Coerce helpers for untrusted numeric / string fields (reject nan/inf).
local function numOr(v, d)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return d end
    return v
end
local function strOr(v, d) return type(v) == "string" and v or d end

function Share.Import(str)
    if type(str) ~= "string" then return false, "no string" end
    str = str:gsub("%s", "")
    if str == "" then return false, "empty" end
    if str:sub(1, #PREFIX) ~= PREFIX then return false, "not a Custodian string" end
    local blob = decode(str:sub(#PREFIX + 1))
    if not blob then return false, "unreadable" end
    local payload = deserialize(blob)
    if type(payload) ~= "table" or type(payload.widgets) ~= "table" then return false, "unreadable" end

    local p = ns.profile; if not p then return false, "no profile" end

    -- PLAN (pure): every read of the untrusted payload happens here, inside pcall, and
    -- is normalized into clean local tables. Because ALL hostile-data traversal is in
    -- this phase — before the profile is touched — a malformed string fails here and
    -- leaves the profile completely untouched (no half-written import).
    local ok, plan = pcall(function()
        local pl = { trackers = {}, folders = {}, widgets = {}, groups = {} }
        for otid, def in pairs(payload.trackers or {}) do
            if type(def) == "table" then pl.trackers[#pl.trackers + 1] = { oid = otid, def = copy(def) } end
        end
        for name, meta in pairs(payload.folders or {}) do
            if type(name) == "string" then
                pl.folders[#pl.folders + 1] = { name = name, collapsed = (type(meta) == "table") and meta.collapsed or nil }
            end
        end
        for owid, cfg in pairs(payload.widgets) do
            if type(cfg) == "table" then
                local nc = copy(cfg)
                if nc.anchor ~= nil and type(nc.anchor) ~= "table" then nc.anchor = nil end
                pl.widgets[#pl.widgets + 1] = { oid = owid, cfg = nc, otid = nc.trackerId }
            end
        end
        for _, g in pairs(payload.groups or {}) do
            if type(g) == "table" then
                pl.groups[#pl.groups + 1] = {
                    x = numOr(g.x, 0), y = numOr(g.y, 0),
                    axis = (g.axis == "v") and "v" or "h",
                    gap = numOr(g.gap, 0), name = strOr(g.name, "Group"),
                    share = (type(g.share) == "table") and copy(g.share) or nil,
                    order = (type(g.order) == "table") and g.order or {},
                }
            end
        end
        return pl
    end)
    if not ok or type(plan) ~= "table" then return false, "corrupt data" end

    -- COMMIT: operates only on the normalized plan (well-typed), so hostile input can't
    -- make it throw. Everything added is NEW (fresh ids); existing widgets are untouched.
    p.folders = p.folders or {}
    local trkMap = {}
    for _, t in ipairs(plan.trackers) do trkMap[t.oid] = ns.AddTracker(t.def) end
    for _, f in ipairs(plan.folders) do
        local exists = false
        for _, ef in ipairs(p.folders) do if ef.name == f.name then exists = true; break end end
        if not exists then table.insert(p.folders, { name = f.name, collapsed = f.collapsed }) end
    end
    local widMap, count = {}, 0
    for _, w in ipairs(plan.widgets) do
        local nc = w.cfg
        ns.NormalizeReminder(nc)   -- an older exporter may carry legacy showWhen — fold it here too
        if nc.chargeIcons then      -- legacy icon charge-pips -> shared "Segmented" model (mirrors MigrateProfile)
            nc.segments = true
            if nc.segmentGap == nil and nc.chargeGap ~= nil then nc.segmentGap = nc.chargeGap end
        end
        nc.chargeIcons, nc.chargeGap = nil, nil
        if ns.MigrateThresholds then ns.MigrateThresholds(nc) end   -- legacy thresholds -> colour-stop curve
        if w.otid then nc.trackerId = trkMap[w.otid] end
        if nc.anchor then nc.anchor.group = nil end   -- (re)assigned below
        local n, nid = 1; repeat nid = "user_" .. n; n = n + 1 until not p.widgets[nid]
        p.widgets[nid] = nc; table.insert(p.order, nid)
        widMap[w.oid] = nid; count = count + 1
    end
    for _, g in ipairs(plan.groups) do
        if ns.Groups then
            local ngid = ns.Groups.Create(g.x, g.y, g.axis)
            local grp = ns.Groups.Get(ngid)
            if grp then grp.gap = g.gap; grp.name = g.name; grp.share = g.share end
            for _, owid in ipairs(g.order) do
                local nwid = widMap[owid]
                if nwid then ns.Groups.Add(ngid, nwid) end
            end
        end
    end

    if ns.Layout then ns.Layout.Rebuild() end
    if ns.Trackers then ns.Trackers.Rebuild() end
    if ns.RefreshOptions then ns.RefreshOptions() end
    return true, count
end
