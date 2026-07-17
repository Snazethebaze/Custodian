-- Core/Trackers.lua : the data engine.
--
-- Builds the set of trackers actually needed for the CURRENT spec (only the
-- trackers that visible widgets bind to), subscribes to exactly the union of
-- their events, and pushes normalized snapshots to the bound widgets when
-- those events fire. Purely event-driven — no idle polling.

local ADDON, ns = ...

local Trackers = {}
ns.Trackers = Trackers

local eventFrame = CreateFrame("Frame")

local activeTrackers  = {}   -- trackerId -> { cfg, reader, widgets = {…}, last }
local registeredEvents = {}  -- event     -> { trackerId, … }

local function pushSnapshot(entry, force)
    local snap = entry.reader.read(entry.cfg)
    -- Identity short-circuit: the throttled cached-table readers (EarthShield/Ally) hand back
    -- their SAME cached table while the coalesce window holds, and recompute a NEW table only
    -- when something actually changed. So at raid UNIT_AURA rates an unchanged read returns the
    -- identical table and we can skip the whole Update fan-out. Fresh-table readers (everything
    -- else) return a new table each time, so this never skips a real change. `force` (options
    -- path via Refresh) bypasses it, because a style/format change must repaint even when the
    -- snapshot table is identical.
    if not force and snap ~= nil and snap == entry.last then return end
    entry.last = snap
    for _, w in ipairs(entry.widgets) do
        if w.Update then w:Update(snap) end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, unit)
    local list = registeredEvents[event]
    if not list then return end
    -- The unit filter only applies to the UNIT_* family (arg1 = a unit token). Non-unit events
    -- like RUNE_POWER_UPDATE pass other args (a rune index) that must NOT be mistaken for a unit —
    -- they always push. Compute the family ONCE per fire, not once per tracker in the loop.
    local isUnitEvent = event:sub(1, 5) == "UNIT_"
    for _, trackerId in ipairs(list) do
        local entry = activeTrackers[trackerId]
        if entry then
            local otherUnit = isUnitEvent and entry.reader.unitEvent
                and unit and unit ~= (entry.cfg.unit or "player")
            if not otherUnit then  -- skip UNIT_* events aimed at a different unit
                pushSnapshot(entry)
            end
        end
    end
end)

function Trackers.Rebuild()
    activeTrackers  = {}
    registeredEvents = {}
    eventFrame:UnregisterAllEvents()

    local p = ns.profile
    if not p then return end
    local spec = ns.specID

    -- Group visible widgets by the tracker that feeds them.
    for _, w in pairs(ns.widgets) do
        if w:MatchesSpec(spec) then
            local tId    = w.cfg.trackerId
            local tCfg   = tId and p.trackers[tId]
            local reader = tCfg and ns.readers[tCfg.type]
            if reader then
                local entry = activeTrackers[tId]
                if not entry then
                    entry = { cfg = tCfg, reader = reader, widgets = {}, last = nil }
                    activeTrackers[tId] = entry
                end
                entry.widgets[#entry.widgets + 1] = w
            end
        end
    end

    -- Subscribe to the union of required events, once each.
    for tId, entry in pairs(activeTrackers) do
        local evs = entry.reader.events
        if type(evs) == "function" then evs = evs(entry.cfg) end
        for _, ev in ipairs(evs) do
            local l = registeredEvents[ev]
            if not l then
                l = {}
                registeredEvents[ev] = l
                eventFrame:RegisterEvent(ev)
            end
            l[#l + 1] = tId
        end
    end

    -- Prime so widgets show the current state immediately.
    for _, entry in pairs(activeTrackers) do
        pushSnapshot(entry)
    end

    Trackers.UpdateWarnTicker()
end

-- Re-read everything (used after a style/option change). While move-mode preview
-- is active, real reads are suppressed at the widget — re-push the synthetic preview
-- instead so an edited font/format/offset shows at once (StopPreview clears the flag
-- before its own Refresh, so locking still restores the real state).
function Trackers.Refresh()
    if ns.previewActive then
        if ns.RefreshPreview then ns.RefreshPreview() end
        return
    end
    for _, entry in pairs(activeTrackers) do
        pushSnapshot(entry, true)   -- force: an option/format change must repaint even an identical snapshot
    end
end

-- Re-read ONLY the active trackers of one type — used by the spec tickers (Stagger, DH fragments)
-- so a ~5-7 Hz poll re-reads just its own tracker instead of forcing the whole pipeline. No `force`:
-- those readers return a fresh table each tick, so a real change always fans out and an unchanged
-- read is naturally skipped (the identity short-circuit in pushSnapshot).
function Trackers.RefreshType(trackerType)
    if ns.previewActive then
        if ns.RefreshPreview then ns.RefreshPreview() end
        return
    end
    for _, entry in pairs(activeTrackers) do
        if entry.cfg and entry.cfg.type == trackerType then pushSnapshot(entry) end
    end
end

-- A low-duration warning ("expiring soon") needs a TIME trigger — the crossing
-- moment isn't an event, so while at least one visible reminder has a warn window
-- set we run a single coarse, self-cancelling ticker that just re-reads (cheap)
-- every 15s. It exists only when a warning is actually configured, so this isn't
-- the always-on polling the engine deliberately avoids.
local warnTicker
function Trackers.UpdateWarnTicker()
    local need = false
    for _, w in pairs(ns.widgets) do
        local c = w.cfg
        if c and c.warnLowSec and c.warnLowSec > 0 and ns.ReminderMode(c) == "missing"
           and w:MatchesSpec(ns.specID) then
            need = true
            break
        end
    end
    if need and not warnTicker then
        warnTicker = C_Timer.NewTicker(15, function() Trackers.Refresh() end)
    elseif not need and warnTicker then
        warnTicker:Cancel()
        warnTicker = nil
    end
end
