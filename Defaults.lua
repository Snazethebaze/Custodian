-- Defaults.lua : AceDB defaults + one-time shaman starter layout.
--
-- Static AceDB defaults are intentionally empty containers. The starter
-- trackers/widgets are written into the profile by SeedDefaults so the user
-- fully OWNS them (can rename, restyle, delete) — unlike static defaults,
-- which can't be individually removed.

local ADDON, ns = ...

function ns.BuildDefaults()
    return {
        profile = {
            version  = 1,
            unlocked = false,
            trackers = {},   -- id -> tracker config
            widgets  = {},   -- id -> widget config
            order    = {},   -- array of widget ids, creation order
        },
    }
end

-- Spec IDs (shaman)
local ELEMENTAL, ENHANCEMENT, RESTORATION = 262, 263, 264

-- Elemental spender spell ids, grouped by logical spender (a choice node, or a
-- spell's two cast forms). ONE source of truth for the seed markers, the
-- affordability-alert seed, and the marker-bundling migration below.
local ELE_SPENDERS = {
    { 61882, 462620 },   -- Earthquake: ground + smart cast (node 80985)
    { 8042, 117014 },    -- Earth Shock / Elemental Blast (choice node 80984)
}
-- A fresh copy of a spender group's ids (the "+" bundle editor mutates spellIDs,
-- so seeded markers must NOT share the constant's table).
local function spenderIds(i)
    local out = {}
    for _, id in ipairs(ELE_SPENDERS[i]) do out[#out + 1] = id end
    return out
end

-- Resto mana "colour by fill" curve (red when low -> green when full). A FACTORY so
-- the seed and the older-profile migration each get their own table (never shared).
local function manaColorCurve()
    return { type = "Linear", points = {
        { pct = 0.0, color = { r = 0.85, g = 0.20, b = 0.20 } },
        { pct = 0.5, color = { r = 0.95, g = 0.85, b = 0.25 } },
        { pct = 1.0, color = { r = 0.30, g = 0.85, b = 0.40 } },
    } }
end

function ns.SeedDefaults(p)
    if p._seeded then return end
    p._seeded = true
    if ns.playerClass ~= "SHAMAN" then return end

    -- ── Trackers (data sources) ───────────────────────────────────────
    p.trackers.maelstrom = p.trackers.maelstrom or { type = "power", power = "MAELSTROM" }
    p.trackers.msw       = p.trackers.msw       or { type = "aura",  spellID = 344179, unit = "player", max = 10 }
    p.trackers.mana      = p.trackers.mana      or { type = "power", power = "MANA" }

    -- ── Widgets (display) ─────────────────────────────────────────────
    local function add(id, cfg)
        if not p.widgets[id] then
            p.widgets[id] = cfg
            table.insert(p.order, id)
        end
    end

    -- Shared bar template; `over` supplies the per-widget bits.
    local function bar(over)
        local t = {
            display    = "bar",
            width      = 240, height = 26,
            texture    = "Blizzard",
            font       = "Friz Quadrata TT", fontSize = 13,
            showText   = true, textFormat = "valuemax",
            anchor     = { x = 0, y = -170 },   -- screen offset from centre; anchor.group added on connect
        }
        for k, v in pairs(over) do t[k] = v end
        return t
    end

    add("ele_maelstrom", bar{
        name = "Maelstrom", specs = { [ELEMENTAL] = true }, trackerId = "maelstrom",
        color = { r = 0.10, g = 0.55, b = 0.95, a = 1 },
        -- Dynamic spender markers: position = the spell's live power cost, so they
        -- auto-shift with Eye of the Storm. Secret-safe. Each is ONE line that
        -- BUNDLES the ids of a single logical spender, resolving to the one you have
        -- (ns.MarkerSpell): Earthquake's two cast forms, and the Earth Shock /
        -- Elemental Blast choice node. alert = true -> the line lights up when
        -- you can actually afford the cast.
        markers = {
            { mode = "spell", spellIDs = spenderIds(1), color = { r = 1.0, g = 0.82, b = 0.25, a = 0.9 }, width = 2, alert = true }, -- Earthquake (ground + smart cast, node 80985)
            { mode = "spell", spellIDs = spenderIds(2), color = { r = 1.0, g = 0.55, b = 0.20, a = 0.9 }, width = 2, alert = true }, -- Earth Shock / Elemental Blast (choice node 80984)
        },
    })
    add("enh_msw", bar{
        name = "Maelstrom Weapon", specs = { [ENHANCEMENT] = true }, trackerId = "msw",
        color = { r = 1.00, g = 0.55, b = 0.05, a = 1 }, textFormat = "value",
        -- MSW stacks are readable, so classic colour+sound thresholds work.
        thresholds = {
            { count = 5,  color = { r = 1.00, g = 0.90, b = 0.20, a = 1 } },              -- yellow at 5
            { count = 10, color = { r = 0.30, g = 1.00, b = 0.35, a = 1 }, sound = 8959 }, -- green + ping at 10 (capped)
        },
    })
    add("res_mana", bar{
        name = "Mana", specs = { [RESTORATION] = true }, trackerId = "mana",
        color = { r = 0.20, g = 0.80, b = 0.45, a = 1 },
        -- Colour by fill (secret-safe, engine-evaluated): red when low -> green
        -- when full. No-ops gracefully if the 12.0 curve API isn't present.
        colorCurve = manaColorCurve(),
    })
end

-- ── Migration ─────────────────────────────────────────────────────────
-- "pips" is no longer a separate display — it's a Bar with segment dividers.
-- Fold any existing pips widget into a bar so old layouts keep their look.
-- Runs on every load (outside the one-time SeedDefaults guard).
function ns.MigrateProfile(p)
    if not p or not p.widgets then return end

    -- User-defined folders live here (ordered; each { name, collapsed }). Ensure a
    -- profile-OWNED table exists before anyone inserts into it (a shared AceDB
    -- default table would be mutated across profiles).
    p.folders = p.folders or {}

    for _, c in pairs(p.widgets) do
        if c.display == "pips" then
            c.display = "bar"
            if c.segments == nil then c.segments = true end   -- keep the dividers
        end
        -- Legacy single spec (cfg.spec: a specID / "all" / nil) -> multi-spec SET
        -- cfg.specs (see ns.CfgSpecActive). Idempotent: only where specs is absent,
        -- and the old field is cleared so the two can never drift apart.
        if c.specs == nil and c.spec ~= nil then
            if type(c.spec) == "number" then c.specs = { [c.spec] = true } end
            c.spec = nil   -- "all"/nil -> no restriction (specs stays nil)
        end
        -- Legacy showWhen -> reminder.mode. Idempotent: NormalizeReminder is a no-op once cleared.
        ns.NormalizeReminder(c)
        -- Icon "charge pips" (cfg.chargeIcons/chargeGap) merged into the shared "Segmented" model
        -- (cfg.segments/segmentGap) so bar boxes and icon pips are one feature. Idempotent: once
        -- folded the legacy fields are gone. On an icon, segments now means "one pip per charge".
        if c.chargeIcons then
            c.segments = true
            if c.segmentGap == nil and c.chargeGap ~= nil then c.segmentGap = c.chargeGap end
        end
        c.chargeIcons, c.chargeGap = nil, nil
        -- U20: fold legacy count thresholds into the unified colour-stop curve. Each {count,color,
        -- sound} becomes a Step stop at count/max; a stop at 0 with the bar's BASE colour is prepended
        -- so "below the first threshold = base colour" (the old ns.ThresholdColor behaviour) is kept
        -- exactly. Idempotent (thresholds cleared after). max = tracker max / discrete power max /
        -- the largest stop count, so a pct is always derivable even without a live reading.
        ns.MigrateThresholds(c)
    end

    -- Legacy linkedTo chains -> explicit groups (Core/Groups.lua). One-way; after this
    -- runs the profile uses cfg.anchor.group + p.groups, and linkedTo/linkSide are gone.
    if ns.Groups and ns.Groups.Migrate then ns.Groups.Migrate(p) end

    -- One-time repair: the seeded "maelstrom" resource tracker could be flipped to an
    -- empty aura by a stray source-kind click (before kind-switches preserved fields),
    -- silently killing the Elemental Maelstrom bar. Restore it to the resource bar iff
    -- it's in that clearly-clobbered state (aura, no spell). Guarded so it runs once and
    -- never overrides a later intentional change.
    if not p._maelstromRepair then
        p._maelstromRepair = true
        local mtr = p.trackers and p.trackers.maelstrom
        if mtr and mtr.type == "aura" and not mtr.spellID then
            mtr.type, mtr.power, mtr.spellID, mtr.slot = "power", "MAELSTROM", nil, nil
        end
    end

    -- The old "combat-hidden" aura mechanism was deleted in the Aura-tracker rewrite;
    -- nothing reads or writes p._combatHidden anymore, so drop it from saved profiles.
    -- Idempotent, so no one-time guard flag is needed.
    p._combatHidden = nil

    -- The "cooldown" tracker type is retired (no reliable standalone in-combat readout in
    -- Midnight — see mem:midnight-secrets). Its reader no longer loads, so any legacy cooldown
    -- tracker + the widgets bound to it would render against a missing reader (go blank). Drop
    -- both. Idempotent: once cleared there are no cooldown trackers left, so this is a no-op.
    -- Rogue poison categories now track a talent-aware COUNT (1 of the category, 2 with Dragon-
    -- Tempered Blades), not a pinned member list. The old wizard auto-captured the poisons you had
    -- up into matchAll, which then nagged for slots you couldn't fill after a respec. Drop those
    -- pins so every category tracker uses the count model. Idempotent (once cleared, no matchAll).
    if p.trackers then
        for _, t in pairs(p.trackers) do
            if t and t.matchAny and t.matchAll then t.matchAll = nil end
        end
    end

    if p.trackers then
        local cdIds = {}
        for tid, t in pairs(p.trackers) do
            if t and t.type == "cooldown" then cdIds[tid] = true end
        end
        if next(cdIds) then
            for wid, c in pairs(p.widgets) do
                if c.trackerId and cdIds[c.trackerId] then p.widgets[wid] = nil end
            end
            for tid in pairs(cdIds) do p.trackers[tid] = nil end
        end
    end

    -- One-time: turn on affordability alerts for the seeded Elemental spenders in
    -- profiles created before the feature existed. Guarded so a later user toggle
    -- (which stores an explicit true/false) is never overwritten.
    if not p._alertSeed then
        p._alertSeed = true
        local spenders = {}
        for _, g in ipairs(ELE_SPENDERS) do for _, id in ipairs(g) do spenders[id] = true end end
        local w = p.widgets.ele_maelstrom
        if w and w.markers then
            for _, m in ipairs(w.markers) do
                if m.mode == "spell" and spenders[m.spellID] and m.alert == nil then m.alert = true end
            end
        end
    end

    -- One-time: fold same-spender spell markers into a single BUNDLED line per
    -- group (a choice node / a spell's two cast forms), across every widget. The
    -- first marker of a group keeps its colour/alert/width and gains spellIDs; the
    -- rest are dropped. New markers made by the user later are untouched.
    if not p._markerGroupSeed then
        p._markerGroupSeed = true
        local groupOf = {}
        for gi, g in ipairs(ELE_SPENDERS) do for _, id in ipairs(g) do groupOf[id] = gi end end
        for _, wc in pairs(p.widgets) do
            local mk = wc.markers
            if mk then
                local primary, drop = {}, {}
                for _, m in ipairs(mk) do
                    local gi = (m.mode == "spell") and m.spellID and groupOf[m.spellID]
                    if gi then
                        if primary[gi] then
                            local list = primary[gi].spellIDs
                            list[#list + 1] = m.spellID
                            drop[m] = true
                        else
                            primary[gi] = m
                            m.spellIDs = { m.spellID }
                            m.spellID = nil
                        end
                    end
                end
                if next(drop) then
                    local keep = {}
                    for _, m in ipairs(mk) do if not drop[m] then keep[#keep + 1] = m end end
                    wc.markers = keep
                end
            end
        end
    end

    -- One-time: Earth Shield is a Shaman spell, so stamp existing Earth Shield widgets
    -- (tracker type "earthshield") with class = SHAMAN. Without a class they'd count as
    -- "Shared" and run/show on every character; this is safe to run from ANY class since
    -- the spell is unambiguously Shaman. New ES widgets already get tagged at creation.
    if not p._esClassSeed then
        p._esClassSeed = true
        for _, c in pairs(p.widgets) do
            if not c.class then
                local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
                if tr and tr.type == "earthshield" then c.class = "SHAMAN" end
            end
        end
    end

    -- One-time: backfill spellID = 974 (Earth Shield) onto existing earthshield trackers so the
    -- widget has an icon (sidebar / move mode) and the hub sees it as already-added. Separate flag
    -- so it also runs for users who already passed the _esClassSeed migration above.
    if not p._esIconSeed then
        p._esIconSeed = true
        for _, c in pairs(p.widgets) do
            local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
            if tr and tr.type == "earthshield" and not tr.spellID then tr.spellID = 974 end
        end
    end

    -- One-time: give resource widgets whose name is still the raw power key (e.g.
    -- "RUNIC_POWER") the friendly name ("Runic Power"). Only exact raw-key matches, so a
    -- user's own rename is never touched.
    if not p._powerNameSeed then
        p._powerNameSeed = true
        for _, c in pairs(p.widgets) do
            local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
            if tr and tr.type == "power" and tr.power and c.name == tr.power and ns.PrettyPowerName then
                c.name = ns.PrettyPowerName(tr.power) or c.name
            end
        end
    end

    -- One-time: turn the segment (boxes) display ON for existing discrete-resource bars
    -- (runes, combo points…) made before it defaulted on. Only where `segments` was never
    -- set, so a deliberate off is preserved.
    if not p._segDefaultSeed then
        p._segDefaultSeed = true
        for _, c in pairs(p.widgets) do
            if c.segments == nil and (c.display == nil or c.display == "bar") then
                local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
                if tr and tr.type == "power" and ns.IsDiscretePower and ns.IsDiscretePower(tr.power) then
                    c.segments = true
                end
            end
        end
    end

    -- One-time: colour existing resource widgets that are still on the generic grey
    -- default with their in-game hue (Rage red, Mana blue…). Only exact grey matches are
    -- touched — a deliberate colour (or a colour-curve bar) is never overwritten.
    if not p._powerColorSeed then
        p._powerColorSeed = true
        local function isGrey(col)
            return col and math.abs((col.r or 0) - 0.55) < 0.01
                       and math.abs((col.g or 0) - 0.55) < 0.01
                       and math.abs((col.b or 0) - 0.62) < 0.01
        end
        for _, c in pairs(p.widgets) do
            local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
            if tr and tr.type == "power" and not c.colorCurve and isGrey(c.color) and ns.PowerColor then
                local r, g, b, a = ns.PowerColor(tr.power)
                if r then c.color = { r = r, g = g, b = b, a = a or 1 } end
            end
        end
    end

    -- One-time: opt existing DK rune bars into spec-dynamic colour (Blood red / Frost blue /
    -- Unholy green) unless the user gave them a colour curve or a deliberate non-default colour.
    -- Grey (the old RUNES default) or the flat curated RUNES hue both count as "untouched".
    if not p._runeSpecColorSeed then
        p._runeSpecColorSeed = true
        for _, c in pairs(p.widgets) do
            local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
            if tr and tr.type == "power" and tr.power == "RUNES" and not c.colorCurve and not c.autoPowerColor
               and ns.PowerColorForSpec then
                c.autoPowerColor = true   -- the bar now follows the current spec's rune colour
            end
        end
    end

    -- One-time (v2): upgrade existing Lightsmith Rite imbue trackers to the ID-driven choice-node
    -- gate. Earlier attempts used a single-spell gate or a name lookup that failed (these hero-talent
    -- abilities aren't in the spellbook enumeration), so the OTHER rite never reminded. Detected by a
    -- prior rites/riteNames field or a "Rite"-named widget; converted to riteIds { Sanctification,
    -- Adjuration } so gate + icon + cast resolve live by ns.SpellTaken.
    if p._riteNamesSeed ~= 2 then
        p._riteNamesSeed = 2
        for _, c in pairs(p.widgets or {}) do
            local tr = c.trackerId and p.trackers and p.trackers[c.trackerId]
            if tr and tr.type == "imbue" and not tr.riteIds
               and (tr.rites or tr.riteNames or (type(c.name) == "string" and c.name:find("Rite"))) then
                tr.riteIds = { 433568, 433583 }
                tr.rites, tr.riteNames = nil, nil
                tr.talentGate = { mode = (tr.talentGate and tr.talentGate.mode) or "require" }
            end
        end
    end

    -- Refresh MANUAL trackers' mechanic data (gen/spend lists, aura id, duration…) from the
    -- current seed whenever it changes — a widget added before a fix (e.g. before the OOC aura
    -- sync existed, or with the old wrong spender list) picks up the corrected data, keeping the
    -- user's widget (name / position / display) untouched. Versioned so it only runs on a change.
    if p._manualSeedVer ~= ns.MANUAL_SEED_VER and ns.RefreshManualTrackers then
        p._manualSeedVer = ns.MANUAL_SEED_VER
        ns.RefreshManualTrackers()
    end

    -- One-time: give the seeded Resto mana bar its colour-by-fill curve in
    -- profiles created before that feature existed.
    if not p._curveSeed then
        p._curveSeed = true
        local mana = p.widgets.res_mana
        if mana and not mana.colorCurve then
            mana.colorCurve = manaColorCurve()
        end
    end
end

-- ── Runtime helpers (used by slash cmds now, the settings panel later) ──

-- Create a custom tracker (data source) and return its id. `def` is the tracker
-- config, e.g. { type="aura", spellID=974, unit="player" } for Earth Shield,
-- { type="imbue", slot="main" } for a weapon imbue, { type="power", power="MANA" }.
function ns.AddTracker(def)
    local p = ns.profile
    if not def or not def.type then return nil end
    local n, id = 1
    repeat id = "trk_" .. n; n = n + 1 until not p.trackers[id]
    p.trackers[id] = def
    return id
end

-- Add a new widget, of the given display type (bar/icon). `spec` may be a specID
-- number, a ready-made specs SET, or nil/"all" (= every spec) — it is normalized
-- into cfg.specs. Reuses a tracker already active on that spec if none is given.
function ns.AddWidget(spec, trackerId, display)
    local p = ns.profile
    display = display or "bar"
    if display == "pips" then display = "bar" end   -- pips folded into bar

    -- Normalize the spec arg into an owned specs SET (nil = all specs). Copy any
    -- passed table so the widget never aliases a caller's live set.
    local specs
    if type(spec) == "table" then
        if next(spec) then specs = {}; for k in pairs(spec) do specs[k] = true end end
    elseif type(spec) == "number" then
        specs = { [spec] = true }
    end

    if not trackerId and type(spec) == "number" then
        for _, cfg in pairs(p.widgets) do
            if cfg.trackerId and ns.CfgSpecActive(cfg, spec) then trackerId = cfg.trackerId; break end
        end
    end

    local n, id = 1
    repeat id = "user_" .. n; n = n + 1 until not p.widgets[id]

    -- Spawn ABOVE centre (the centre-bottom is crowded with the player frame, personal
    -- resource + cast bars, etc., where a new widget would hide), and cascade each add along a
    -- small diagonal so consecutive ones don't stack on top of each other.
    local casc = n % 6
    local cfg = {
        name = display:gsub("^%l", string.upper) .. " " .. (n - 1),
        class = ns.playerClass,   -- owning class (cross-char sharing + load-on-demand)
        specs = specs, trackerId = trackerId, display = display,
        texture = "Blizzard", font = "Friz Quadrata TT", fontSize = 13,
        showText = true, textFormat = "valuemax",
        color = { r = 0.55, g = 0.55, b = 0.62, a = 1 },
        anchor = { x = casc * 12, y = 180 - casc * 28 },
    }
    if display == "icon" then
        cfg.width, cfg.height = 40, 40
    else
        cfg.width, cfg.height = 240, 26
    end

    -- Point resources (runes, combo points, chi…) read best as boxes — default the
    -- segment display on so it looks right immediately.
    local dtr = trackerId and p.trackers[trackerId]
    if dtr and dtr.type == "power" and ns.IsDiscretePower and ns.IsDiscretePower(dtr.power) then
        cfg.segments = true
    end

    -- Druid combo points only mean anything in Cat Form, so default the "only in form" gate to Cat
    -- (768). A user can clear/change it in the WHEN tab. Only for a Druid's combo-point bar.
    if dtr and dtr.type == "power" and dtr.power == "COMBO_POINTS" and ns.playerClass == "DRUID" then
        cfg.formGate = { spellID = 768, name = "Cat Form" }
    end

    -- Resource widgets default to their in-game colour (Rage red, Mana blue…) so they
    -- read correctly without a trip to the colour picker.
    if dtr and dtr.type == "power" and ns.PowerColor then
        local r, g, b, a = ns.PowerColor(dtr.power)
        if r then cfg.color = { r = r, g = g, b = b, a = a or 1 } end
    end
    -- Dynamic colour bars follow live state via autoPowerColor (a manual colour pick clears it,
    -- so an override sticks): DK runes recolour by SPEC, and a PRIMARY bar recolours by the
    -- current FORM's power. Seed the colour that applies right now so it looks right immediately.
    if dtr and dtr.type == "power" then
        local r, g, b, a
        if dtr.power == "PRIMARY" and ns.CurrentPowerColor then r, g, b, a = ns.CurrentPowerColor(dtr.unit or "player")
        elseif ns.PowerColorForSpec then r, g, b, a = ns.PowerColorForSpec(dtr.power, ns.specID) end
        if r then cfg.autoPowerColor = true; cfg.color = { r = r, g = g, b = b, a = a or 1 } end
    end

    p.widgets[id] = cfg
    table.insert(p.order, id)
    ns.Layout.Rebuild()
    ns.Trackers.Rebuild()
    return id
end

-- One-shot "add a tracker + its widget" used by every special spawn (Stagger, Shatter, the two
-- DH bars, Earth Shield, and the /cust test* commands). Creates the tracker, attaches a widget
-- of the given kind, copies `props` onto the new widget config, then rebuilds. Returns the widget
-- id (nil if the profile/tracker couldn't be made).
--   trackerDef : table for ns.AddTracker
--   props      : widget fields to copy onto the new config (name, colours, size, reminder, …)
--   opts       : { kind = "bar"|"icon" (default "bar"), specs = specID|set|nil (nil = all specs),
--                  unlock = true to enter move mode, print = chat notice to show after }
function ns.SpawnWidget(trackerDef, props, opts)
    opts = opts or {}
    local p = ns.profile
    if not p then return nil end
    local tid = ns.AddTracker(trackerDef)
    if not tid then return nil end
    local wid = ns.AddWidget(opts.specs, tid, opts.kind or "bar")
    local w = wid and p.widgets[wid]
    if w then
        if props then for k, v in pairs(props) do w[k] = v end end
        ns.Layout.Rebuild(); ns.Trackers.Rebuild()
    end
    if opts.unlock and ns.Layout.SetUnlocked then ns.Layout.SetUnlocked(true) end
    if opts.print then ns.Print(opts.print) end
    return wid
end

-- Add the "keep 2 Earth Shields out" reminder: an icon that appears in a group when
-- you're missing a shield (self or ally). Self-gating tracker (group + ES known), so
-- it's spec-agnostic — leave specs = all and it simply stays silent when irrelevant.
function ns.AddEarthShieldWidget()
    -- spellID = 974 (Earth Shield) is metadata only — the tracker SCANS via its own 974/383648
    -- constants, but a spellID gives the widget an icon (sidebar / move mode / HUD) and lets the
    -- hub detect it as already-added. It's NOT the aura path (type stays "earthshield").
    return ns.SpawnWidget(
        { type = "earthshield", name = "Earth Shield", spellID = 974 },
        {
            name     = "Earth Shield 2/2",
            reminder = { mode = "missing" },   -- appear only when a shield is down (and in a group)
            showText = false,
            anchor   = { x = 0, y = -150 },
        },
        { kind = "icon" })   -- specs nil = all specs (self-gating tracker)
end

-- Wipe all widgets/trackers and re-seed the shaman defaults.
function ns.ResetLayout()
    local p = ns.profile
    wipe(p.widgets); wipe(p.trackers); wipe(p.order)
    -- Groups/folders reference widget ids; a wiped widget would leave them
    -- dangling, so clear them too (a full reset re-seeds standalone bars).
    if p.groups  then wipe(p.groups)  end
    if p.folders then wipe(p.folders) end
    p._seeded = nil
    ns.SeedDefaults(p)
    ns.Layout.Rebuild()
    ns.Trackers.Rebuild()
end
