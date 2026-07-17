-- Custodian — modular, cross-class resource & buff HUD.
-- Core/Custodian.lua : addon object, database, spec detection, orchestration.
--
-- Design: three separated layers connected by bindings —
--   trackers (data)  ->  widgets (display)  ->  layout (anchoring).
-- A tracker normalizes any source (power, aura, totem, cooldown, custom)
-- into one shape. A widget renders that shape as a bar / pips / icon. A
-- widget anchors to the screen OR to another widget. Nothing is hardcoded
-- to a spec or resource, so new things to track are just data.

local ADDON, ns = ...

local AceAddon = LibStub("AceAddon-3.0")
local A = AceAddon:NewAddon(ADDON, "AceEvent-3.0", "AceConsole-3.0")
ns.A     = A

-- ── Shared registries (filled by later files at load time) ────────────
ns.readers  = ns.readers  or {}   -- trackerType -> reader definition
ns.displays = ns.displays or {}   -- displayType -> display definition
ns.widgets  = ns.widgets  or {}   -- live widget objects, keyed by widget id

function ns.RegisterTracker(typeName, def) ns.readers[typeName]  = def end
function ns.RegisterDisplay(typeName, def) ns.displays[typeName] = def end

-- ── Class / spec ──────────────────────────────────────────────────────
ns.playerClass = select(2, UnitClass("player"))
ns.specID = nil   -- current spec ID (number) or nil

-- The class specs, in tree order: { {id, name, short, text}, ... }. With no argument it
-- returns the PLAYER's class specs (cached — class is fixed for the session). Pass a class
-- TOKEN ("SHAMAN", "PALADIN"…) to get that class's specs instead — used by the editor so a
-- foreign-class widget's "Show on" toggles are ITS specs, not the player's. Built from the
-- live API, so the whole addon stays class-agnostic (never hardcoded shaman specs).
local classSpecs
local classSpecsByToken = {}
local function buildSpecsForClassID(classID)
    local list = {}
    local n = classID and GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID)
    for i = 1, (n or 4) do
        local id, name = GetSpecializationInfoForClassID(classID, i)
        if id then list[#list + 1] = { id = id, name = name, short = name, text = name } end
    end
    return list
end
function ns.ClassSpecs(classToken)
    if classToken then
        local cached = classSpecsByToken[classToken]
        if cached then return cached end
        -- Resolve the token to a classID (GetClassInfo returns name, token, classID).
        local classID
        for cid = 1, ((GetNumClasses and GetNumClasses()) or 13) do
            local _, token = GetClassInfo(cid)
            if token == classToken then classID = cid; break end
        end
        local list = classID and buildSpecsForClassID(classID) or {}
        classSpecsByToken[classToken] = list
        return list
    end
    if classSpecs then return classSpecs end
    local _, _, classID = UnitClass("player")
    classSpecs = buildSpecsForClassID(classID)
    return classSpecs
end

-- Friendly name for a specID (labels). nil if it isn't one of this class's specs.
function ns.SpecName(specID)
    for _, s in ipairs(ns.ClassSpecs()) do if s.id == specID then return s.name end end
    return nil
end

function ns.GetSpecID()
    local idx = GetSpecialization()
    if not idx then return nil end
    return (GetSpecializationInfo(idx))
end

-- A widget config's spec restriction. cfg.specs is a SET of specIDs it shows on
-- ({ [262]=true, ... }); nil or empty = every spec. The legacy single cfg.spec
-- (a specID / "all" / nil) is folded into this set by MigrateProfile, so only
-- cfg.specs is read at runtime. Used by widgets, the layout, and /cust split.
function ns.CfgSpecActive(cfg, specID)
    local s = cfg and cfg.specs
    if not s or not next(s) then return true end   -- unrestricted -> every spec
    if not specID then return false end
    return s[specID] and true or false
end

-- ── Class ownership (cross-character sharing) ─────────────────────────
-- The profile is shared by every character, so a widget carries the CLASS it belongs
-- to. specId -> classToken and token -> localized name, built once from the live API
-- across all classes (so it's not hardcoded to any class).
local specClass, className, specName
local function buildClassMaps()
    if specClass then return end
    specClass, className, specName = {}, {}, {}
    local num = (GetNumClasses and GetNumClasses()) or 13
    for classID = 1, num do
        local name, token = GetClassInfo(classID)
        if token then
            className[token] = name or token
            local n = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID)
            for i = 1, (n or 0) do
                local sid, sName = GetSpecializationInfoForClassID(classID, i)
                if sid then specClass[sid] = token; specName[sid] = sName end
            end
        end
    end
end

-- Spec name for ANY class's specID (not just the player's) — so a foreign-class widget's marker
-- reads "Frost" instead of "Spec 262". ns.SpecName only knows the player's specs; this scans all.
function ns.SpecNameAny(sid)
    if not sid then return nil end
    buildClassMaps()
    return specName[sid]
end

-- The class a widget belongs to: explicit cfg.class, else inferred from its spec set,
-- else nil = SHARED (active on every character). Deliberately never guesses a class that
-- would HIDE a widget from where it belongs — an unknown stays shared (runs everywhere).
function ns.ClassOfCfg(cfg)
    if not cfg then return nil end
    if cfg.class then return cfg.class end
    local s = cfg.specs
    if s then
        buildClassMaps()
        for sid in pairs(s) do local t = specClass[sid]; if t then return t end end
    end
    return nil
end

-- Localized class name for a token (sidebar headers). nil token -> "Shared".
function ns.ClassName(token)
    if not token then return "Shared" end
    buildClassMaps()
    return className[token] or token
end

-- Is this widget ACTIVE on the current character? Shared (no class) or our own class.
-- Drives load-on-demand: other classes' widgets stay in the profile (visible/editable in
-- options) but create no frames and run no trackers here.
function ns.CfgClassActive(cfg)
    local c = ns.ClassOfCfg(cfg)
    return c == nil or c == ns.playerClass
end

-- ── Print helper ──────────────────────────────────────────────────────
local PREFIX = "|cff1784d1Custodian|r "
function ns.Print(msg) print(PREFIX .. tostring(msg)) end

-- ── Secret values (Midnight 12.0+) ────────────────────────────────────
-- In combat, data about non-player units is a "secret value": tainted addon
-- code may PASS it to widget setters but must NOT do arithmetic, comparison
-- or tostring on it (those error). The player's own data stays readable, so
-- our shaman trackers use the rich path — but custom trackers may point at a
-- target/enemy, so widgets guard every value with this before doing math.
local _issecretvalue = issecretvalue   -- global on 12.0+ clients; nil pre-Midnight
function ns.IsSecret(v)
    if _issecretvalue then return _issecretvalue(v) end
    return false
end

-- Set a font and FORCE the glyphs to re-flow immediately. WoW short-circuits
-- FontString:SetText() when the string is unchanged, so a font/size swap on a
-- bar that's sitting at a steady value (e.g. Maelstrom Weapon "0" out of
-- combat) wouldn't visibly update until the value next changed (in combat).
-- Re-setting the text breaks that short-circuit — but only when the current
-- text is a plain string: a secret power string can't be compared, and those
-- bars tick often enough to reflow on their own.
function ns.SetFontReflow(fs, path, size, flags)
    if not fs then return end
    if not fs:SetFont(path, size, flags) then fs:SetFontObject("GameFontHighlight") end
    -- IsSecret MUST be tested first: a secret power string can't be compared to
    -- nil/"" (that errors in combat), and those bars tick often enough to reflow
    -- on their own, so we simply skip the trick for them.
    local prev = fs:GetText()
    if not ns.IsSecret(prev) and prev ~= nil and prev ~= "" then
        fs:SetText("")
        fs:SetText(prev)
    end
end

-- A "count" tracker exposes a fixed integer ceiling, so it can be drawn as discrete
-- segments / boxes: aura stacks (MSW, a config `max`) OR a DISCRETE point resource
-- (combo points, runes, holy power, chi, soul shards, arcane charges, essence — a live
-- UnitPowerMax). Continuous pools (Maelstrom, Mana, Rage, Runic Power…) have no such
-- ceiling, so the editor hides these options for them.
function ns.IsCountTracker(trackerId)
    local t = trackerId and ns.profile and ns.profile.trackers and ns.profile.trackers[trackerId]
    if not t then return false end
    if t.max ~= nil then return true end
    if t.type == "power" and ns.IsDiscretePower and ns.IsDiscretePower(t.power) then return true end
    return false
end

-- The reminder mode lives in cfg.reminder.mode. cfg.showWhen is the LEGACY field: nothing writes
-- it anymore, but a Share string from an older version (or a not-yet-migrated profile) can still
-- carry it — so this reads BOTH, permanently, as the safety net. One source of truth for every
-- "is this a missing/active/ready reminder?" test in the engine and editor.
function ns.ReminderMode(cfg)
    return (cfg and ((cfg.reminder and cfg.reminder.mode) or cfg.showWhen)) or "off"
end

-- Fold a widget's legacy showWhen onto cfg.reminder.mode and clear it. Called at BOTH boundaries
-- an old-format widget can enter the single account profile through: the login migration AND the
-- Share import (there are no AceDB profiles — everything arrives via import strings). A live
-- reminder.mode already wins over showWhen, so this never clobbers a newer setting.
function ns.NormalizeReminder(cfg)
    if not cfg or cfg.showWhen == nil then return end
    if cfg.reminder ~= nil and type(cfg.reminder) ~= "table" then cfg.reminder = nil end   -- hostile import guard
    local mode = (cfg.reminder and cfg.reminder.mode) or cfg.showWhen
    cfg.showWhen = nil
    if mode == nil or mode == "off" then cfg.reminder = nil
    else cfg.reminder = cfg.reminder or {}; cfg.reminder.mode = mode end
end

-- Re-read all active trackers and repaint their widgets, if the engine is up. Trackers and
-- watchers fire this after a state change no event covers (a cast, a timer, a probe). Guarded
-- because a tracker file can load and register a watcher before Core/Trackers.lua exists.
function ns.Refresh()
    if ns.Trackers and ns.Trackers.Refresh then ns.Trackers.Refresh() end
end

-- The tracker (data source) a widget cfg is bound to, or nil. Every "what does this widget
-- show" lookup goes through here — fully guarded so a cfg with no trackerId, or a profile that
-- isn't ready, returns nil instead of erroring. (Callers with their OWN profile table — e.g.
-- MigrateProfile's `p` — index it directly; this is only for the live ns.profile.)
function ns.TrackerOf(cfg)
    local id = cfg and cfg.trackerId
    return (id and ns.profile and ns.profile.trackers and ns.profile.trackers[id]) or nil
end

-- The player's shapeshift forms as { spellID, name } (for the "only in form" widget gate's dropdown).
-- Reads the shapeshift bar — core UI state, never secret. Empty for classes/specs with no forms.
function ns.PlayerForms()
    local out = {}
    if not GetShapeshiftFormInfo then return out end
    local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    for i = 1, n do
        local _, _, _, sid = GetShapeshiftFormInfo(i)
        local nm = sid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
        if sid then out[#out + 1] = { spellID = sid, name = nm or ("Form " .. i) } end
    end
    return out
end

-- Is the player CURRENTLY in the given shapeshift form (matched by spellID, name fallback)? Reads
-- the shapeshift bar (never secret). False if not in it, or the form isn't on the bar at all — so a
-- "only in Cat Form" combo bar hides in Bear/Moonkin/no-form and for anyone without that form.
function ns.InForm(spellID, name)
    if not (spellID or name) or not GetShapeshiftFormInfo then return false end
    local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    for i = 1, n do
        local _, active, _, sid = GetShapeshiftFormInfo(i)
        local match = (spellID and sid == spellID) or false
        if not match and name and sid and C_Spell and C_Spell.GetSpellName then
            match = (C_Spell.GetSpellName(sid) == name)
        end
        if match then return active and true or false end
    end
    return false
end

-- How many discrete cells a "Segmented" widget draws (bar boxes OR icon charge-pips — same
-- question, one answer). Priority: MSW 5+5 split phase → the tracker's fixed max → a discrete
-- power's LIVE ceiling (combo 5/6/7, readable in combat) → a legacy numeric cfg.segments →
-- the caller's fallback. Returns nil when the widget isn't segmented. Secret-safe: never reads
-- a value, only config + UnitPowerMax. Shared by Bar.LayoutBoxes/Segments and Icon.LayoutPips.
function ns.SegmentCount(cfg, default)
    if not cfg or not cfg.segments then return nil end
    if cfg.split then return cfg.split.at or 5 end
    local t = ns.TrackerOf(cfg)
    if t then
        if type(t.max) == "number" and t.max >= 1 then return t.max end
        if t.type == "power" and ns.IsDiscretePower and ns.IsDiscretePower(t.power) and ns.PowerMax then
            local m = ns.PowerMax(t.power)
            if m and m > 0 then return m end
        end
    end
    if type(cfg.segments) == "number" then return cfg.segments end
    return default
end

-- Default transparent gap between segmented cells (bar boxes AND icon pips), so "Segmented"
-- looks pip-like out of the box instead of a solid strip. A user gap of 0 (boxes touching) is
-- honoured; only an unset gap falls back to this.
ns.SEG_GAP_DEFAULT = 4

-- The ONE remaining-time format, so a buff's countdown reads identically on a bar and an icon
-- (they used to disagree: bar showed decimals under 10s and rounded minutes, icon under 3s and
-- ceiled). Policy = never read LATE: floor whole seconds/minutes (so "11" means 11-12s left, never
-- more than you have), with one decimal in the tense last 3s. Used by Bar.fmtDur / Icon.fmtCountdown.
function ns.FormatRemaining(sec)
    if not sec or sec < 0 then sec = 0 end
    if sec < 3  then return string.format("%.1f", sec) end
    if sec < 60 then return tostring(math.floor(sec)) end
    return math.floor(sec / 60) .. "m"
end

-- Even cell width across `total`, with `gap` between the n cells, floored at 1px. The shared
-- geometry under bar boxes and icon pips; the Bar path then pixel-snaps each edge on top of this.
function ns.CellWidth(total, n, gap)
    if not n or n < 1 then n = 1 end
    local w = (total - (n - 1) * (gap or 0)) / n
    if w < 1 then w = 1 end
    return w
end

-- Is the player dead or a ghost? The presence trackers (pet / form / imbue / shields) all hold
-- SILENT while dead — you can't maintain a buff on a corpse — so they share this one gate.
function ns.PlayerDead()
    return UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and true or false
end

-- The normalized snapshot for a pure PRESENCE tracker (pet up? in the form? shield on?):
--   present=true  have it   · present=false missing (remind) · present=nil silent (held)
-- Shared by the trackers whose whole state is "is this one thing there or not".
function ns.PresenceSnap(present, icon)
    return { active = present ~= false, present = present,
             count = 0, value = present and 1 or 0, max = 1, icon = icon, noCount = true }
end

-- ── Lifecycle ─────────────────────────────────────────────────────────
function A:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("CustodianDB", ns.BuildDefaults(), true)
    ns.profile = self.db.profile

    ns.SeedDefaults(self.db.profile)   -- one-time starter layout
    ns.MigrateProfile(self.db.profile) -- fold legacy pips widgets into bars

    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied",  "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset",   "OnProfileChanged")

    self:RegisterChatCommand("custodian", "OnSlash")
    self:RegisterChatCommand("cust", "OnSlash")
end

function A:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshSpec")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "RefreshSpec")
    self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "RefreshSpec")
    self:RefreshSpec()
    if ns.SetupMinimap then ns.SetupMinimap() end
end

function A:OnProfileChanged()
    ns.profile = self.db.profile
    ns.SeedDefaults(self.db.profile)
    ns.MigrateProfile(self.db.profile)
    ns.Layout.Rebuild()
    ns.Trackers.Rebuild()
    if ns.RefreshOptions then ns.RefreshOptions() end
end

-- Register a callback fired on every spec change (and once at first build) — used to spec-gate the
-- always-on tickers (Stagger/DH) so their OnUpdate only runs on the spec that needs it. Registered
-- at file load (tracker files load after this Core file); fired from RefreshSpec below.
ns._specHooks = ns._specHooks or {}
function ns.OnSpecChange(fn) if fn then ns._specHooks[#ns._specHooks + 1] = fn end end

-- Spec change: rebuild visible widgets + re-subscribe to needed events.
function A:RefreshSpec()
    local newSpec = ns.GetSpecID()
    if newSpec == ns.specID and ns._built then return end
    ns.specID = newSpec
    ns._built = true
    ns.Layout.Rebuild()
    ns.Trackers.Rebuild()
    for _, fn in ipairs(ns._specHooks) do pcall(fn) end   -- spec-gate the tickers, etc.
end

-- ── Slash commands ────────────────────────────────────────────────────
-- The first word dispatches; everything after it is handed to the handler as a plain argument
-- string. Registering by exact word (instead of a chain of input:match patterns) removes the
-- old ordering traps — "^testally" used to have to be tested before "^ally" or it matched the
-- wrong branch. Player commands register HERE; developer probes register in Core/Probes.lua.
ns.SlashCmds = ns.SlashCmds or {}
function ns.RegisterSlash(word, fn) ns.SlashCmds[word] = fn end

-- A live-log toggle: flip ns[flag] and print `msg` with the ON/OFF state substituted in.
function ns.SlashToggle(flag, msg)
    return function()
        ns[flag] = not ns[flag]
        ns.Print(msg:format(ns[flag] and "|cff40ff40ON|r" or "|cffff4040OFF|r"))
    end
end

-- A probe guard: run ns[fnName](arg) if that module loaded, else say it isn't there.
function ns.SlashProbe(fnName, label)
    return function(rest)
        if ns[fnName] then ns[fnName](rest ~= "" and rest or nil)
        else ns.Print(label .. " not loaded.") end
    end
end

function ns.SlashHelp()
    ns.Print("|cff1784d1Custodian|r — commands:")
    ns.Print("  |cffffd100/cust|r  open settings  ·  |cffffd100config|r  same")
    ns.Print("  |cffffd100unlock|r / |cffffd100lock|r  move the HUD  ·  |cffffd100add [bar|icon]|r  quick-add a widget  ·  |cffffd100reset|r  clear the layout")
    ns.Print("  |cffffd100minimap|r  toggle the minimap button")
    ns.Print("  |cff808080/cust debug|r  developer probes (for troubleshooting)")
end

function A:OnSlash(input)
    input = (input or ""):lower():match("^%s*(.-)%s*$")
    local word, rest = input:match("^(%S*)%s*(.-)$")
    local fn = ns.SlashCmds[word]
    if fn then fn(rest) else ns.SlashHelp() end
end

ns.RegisterSlash("unlock", function()
    ns.Layout.SetUnlocked(true)
    ns.Print("Move HUD |cff40ff40on|r.")
    ns.Print("  Drag a widget |cffffd100onto|r another to group them.")
    ns.Print("  Drag one |cffffd100out|r (or right-click it) to detach.")
    ns.Print("  Drag a group's |cffffd100title tab|r to move the whole group.")
    ns.Print("  |cffffd100Alt+drag|r places freely · |cffaaaaaa/cust lock|r when done.")
end)

ns.RegisterSlash("lock", function()
    ns.Layout.SetUnlocked(false)
    ns.Print("Move HUD |cffff4040off|r.")
end)

ns.RegisterSlash("add", function(rest)
    if not ns.specID then ns.Print("Can't add — no spec detected yet."); return end
    local disp = rest:match("^(%a+)") or "bar"
    if disp ~= "bar" and disp ~= "icon" then disp = "bar" end
    ns.AddWidget(ns.specID, nil, disp)
    ns.Layout.SetUnlocked(true)
    ns.Print(("Added a |cff40ff40%s|r widget — Move HUD on. |cffffd100/cust lock|r when happy · |cffffd100/cust reset|r to clear."):format(disp))
end)

ns.RegisterSlash("reset", function()
    ns.ResetLayout()
    ns.Print("Layout reset to defaults.")
end)

ns.RegisterSlash("minimap", function()
    local on = ns.ToggleMinimap and ns.ToggleMinimap()
    ns.Print(("Minimap button %s."):format(on and "|cff40ff40shown|r" or "|cffff4040hidden|r"))
end)

ns.RegisterSlash("earthshield", function()
    if ns.AddEarthShieldWidget and ns.AddEarthShieldWidget() then
        if ns.Layout and ns.Layout.SetUnlocked then ns.Layout.SetUnlocked(true) end
        ns.Print("Added the |cff40ff40Earth Shield 2/2|r reminder — Move HUD on.")
        ns.Print("  Shows |cffffd100in a group|r when you're missing a shield (self or ally); silent solo. |cffffd100/cust lock|r when placed.")
    else
        ns.Print("Couldn't add the Earth Shield reminder.")
    end
end)

-- The four Tracked-Bar icon commands all need CDMBars loaded — guard once.
local function withCDM(fn)
    return function(rest)
        if not ns.CDMBars then ns.Print("CDMBars not loaded."); return end
        fn(rest)
    end
end

ns.RegisterSlash("cdmicon", withCDM(function()
    local on = ns.CDMBars.Toggle()
    ns.Print(("Tracked Bars → centered icons %s (size %d, %s). |cffffd100/cust cdmdir|r h/v · |cffffd100/cust cdmsize|r · |cffffd100/cust cdmgap|r"):format(
        on and "|cff40ff40ON|r" or "|cffff4040OFF|r", ns.CDMBars.size,
        ns.CDMBars.dir == "h" and "horizontal" or "vertical"))
    if on then ns.Print("  |cff808080Position the cluster in Edit Mode → Tracked Bars. Icons center on it. Need a tracked buff up to see them.|r") end
end))

ns.RegisterSlash("cdmsize", withCDM(function(rest)
    local px = tonumber(rest:match("^(%d+)"))
    if px then ns.Print(("Icon size = |cffffd100%d|r"):format(ns.CDMBars.SetSize(px)))
    else ns.Print(("Icon size = |cffffd100%d|r (usage: /cust cdmsize 40)"):format(ns.CDMBars.size)) end
end))

ns.RegisterSlash("cdmdir", withCDM(function(rest)
    local d = rest:match("^(%a)")
    d = (d == "h" or d == "v") and d or nil
    local dir = ns.CDMBars.SetDir(d)
    ns.Print(("Tracked-Bar icons = |cffffd100%s|r layout."):format(dir == "h" and "horizontal row" or "vertical column"))
end))

ns.RegisterSlash("cdmgap", withCDM(function(rest)
    local px = tonumber(rest:match("^(%-?%d+)"))
    if px then ns.Print(("Icon spacing = |cffffd100%d|r"):format(ns.CDMBars.SetGap(px)))
    else ns.Print(("Icon spacing = |cffffd100%d|r (usage: /cust cdmgap 6)"):format(ns.CDMBars.gap)) end
end))

local function openConfig()
    if ns.OpenOptions then
        ns.OpenOptions()
    else
        ns.Print("Settings panel is on the way. For now:  |cffffd100/cust unlock|r · |cffffd100/cust add [bar|icon]|r · |cffffd100/cust lock|r · |cffffd100/cust reset|r")
    end
end
ns.RegisterSlash("config", openConfig)
ns.RegisterSlash("", openConfig)   -- bare /cust

