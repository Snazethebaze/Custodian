-- Trackers/Manual.lua : a MANUAL (estimated) stack counter, with out-of-combat aura sync.
--
-- Some class mechanics are a small stack pool that certain spells GENERATE and others CONSUME
-- — Survival Hunter's Tip of the Spear, Fury Warrior's Improved Whirlwind. Their real aura
-- exists and is READABLE out of combat, but the Midnight lockdown (12.0) makes the stack count
-- SECRET while you're IN combat. So this is a HYBRID:
--   · out of combat → read the real aura and trust it (ground truth). This self-corrects any
--     drift the moment a fight ends, and means an out-of-combat Whirlwind that generates nothing
--     shows nothing (the aura says 0), instead of a bogus full bar.
--   · in combat → ESTIMATE by watching your own casts (UNIT_SPELLCAST_SUCCEEDED is an event,
--     readable in combat): a generator adds, a consumer spends, seeded from the pre-pull aura.
--
-- The in-combat estimate is still inherently approximate and WILL sometimes be wrong:
--   · a cast that's dodged / parried / missed / made you immune still fires the event
--   · a spell whose stack is consumed only when its animation finishes (Rampage) reads early
--   · lag or a dropped event skips a change; talents change which spells count
-- It self-corrects to the real aura the instant you drop combat, and every manual widget is
-- loudly flagged "MANUAL" in the UI.
--
-- Config: { type = "manual", name = <label>, spellID = <icon>, max = N,
--           aura = <buffSpellID>|nil,          -- optional: the real buff, read OOC for ground truth
--           gen = { [spellID] = amount, … },   -- casts that ADD stacks (amount ≥ max = "set to full")
--           aoeGen = { [spellID] = true, … },  -- generators that only build when a hostile is in
--                                              --   reach (AoE: Whirlwind/Thunder Clap). Others self-confirm.
--           con = { [spellID] = amount, … },   -- casts that SPEND a stack (default 1)
--           duration = <sec>|nil,              -- optional: auto-clear this long after the last gen
--           resetOnCombatEnd = <bool>|nil,     -- default TRUE: zero when you leave combat (no aura only)
--           requiredTalent = <spellID>|nil }   -- if set and NOT taken, the mechanic is off (shows empty)
--
-- A gen/con amount may be a plain number OR a talent-conditional table
--   { base = N, talent = <talentSpellID>, boost = M }
-- so e.g. Survival's Kill Command grants 1 stack, or 2 with Primal Surge. A single cast may be
-- in BOTH gen and con (applied gen-then-con) — Survival's Takedown with Twin Fangs grants 3 and
-- self-consumes 1 for a net +2, and is a plain spender without it.

local ADDON, ns = ...

local GetTime       = GetTime
local spellIcon     = ns.SpellIcon

-- Transient per-tracker state, keyed by the cfg TABLE (a stable instance in
-- ns.profile.trackers). Weak keys so a deleted tracker's state is collected.
local state = setmetatable({}, { __mode = "k" })
local function getState(cfg)
    local s = state[cfg]
    if not s then s = { count = 0, exp = nil }; state[cfg] = s end
    return s
end

local function clamp(cfg, s)
    local mx = cfg.max or 3
    if s.count < 0 then s.count = 0 elseif s.count > mx then s.count = mx end
end

-- Resolve a gen/con value to a number. A plain number is used as-is; a talent-conditional
-- table { base, talent, boost } adds `boost` when that talent is taken (Survival's Primal
-- Surge makes Kill Command grant an extra Tip of the Spear stack).
local function amountOf(v)
    if type(v) == "number" then return v end
    if type(v) == "table" then
        local n = v.base or 1
        if v.talent and ns.SpellTaken(v.talent) then n = n + (v.boost or 0) end
        return n
    end
    return 0
end

-- True when the mechanic is gated behind a talent the player hasn't taken (Improved Whirlwind).
local function mechanicOff(cfg)
    return cfg.requiredTalent and not ns.SpellTaken(cfg.requiredTalent) and true or false
end

-- The tracked buff's real state, out of combat:
--   nil          → UNREADABLE (in combat, where the count is secret) → caller keeps the estimate
--   0            → out of combat and genuinely ABSENT (expired / spent / cancelled) → caller zeros
--   apps, exp    → present, with its real stack count + expiration
-- The absent case is only ever reported OUT of combat, and callers drive it from UNIT_AURA (which
-- fires precisely when an aura changes) or a settled post-combat read, so a 0 here is real, not a
-- transition blip.
local function auraRead(cfg)
    if not cfg.aura then return nil end
    -- Gate on the aura-secrecy RESTRICTION, not InCombatLockdown(): they engage slightly out of
    -- step at a pull, and in that gap a secret read returns nil while the lockdown flag still says
    -- false — which would sync the estimate to a spurious 0. AurasSecretNow() flips with the reads.
    if ns.AurasSecretNow() then return nil end
    -- ns.PlayerAura returns nil for absent OR unreadable; that conflation is safe here because
    -- we only reach this when auras are NOT secret, i.e. the aura reads live by definition.
    local a = ns.PlayerAura(cfg.aura)
    if not a then return 0 end                          -- OOC and absent → genuinely 0
    local apps = a.applications or a.charges or 1
    if ns.IsSecret and ns.IsSecret(apps) then return nil end
    local mx = cfg.max or 3
    if apps > mx then apps = mx end
    local exp = a.expirationTime
    if (ns.IsSecret and ns.IsSecret(exp)) or type(exp) ~= "number" or exp <= 0 then exp = nil end
    return apps, exp
end

-- Zero the count at `when` (an absolute GetTime timestamp) so a stack window expires on its own
-- even with no further events. Reschedules are self-cancelling — an early timer sees the pushed
-- expiry and no-ops, so no cancel bookkeeping is needed.
local function scheduleExpiryAt(s, when)
    if not (when and C_Timer) then return end
    local delay = when - GetTime() + 0.05
    if delay < 0 then delay = 0 end
    C_Timer.After(delay, function()
        if s.exp and GetTime() >= s.exp and s.count > 0 then
            s.count = 0; s.exp = nil
            ns.Refresh()
        end
    end)
end

-- Sync the estimate to the real buff when READABLE (out of combat) — present syncs to its real
-- count + expiration; absent zeros it (so cancelling / dispelling the buff OOC updates at once).
-- In combat the read is nil, so the in-combat estimate is left untouched. Returns true if changed.
local function syncFromAura(cfg, s)
    local real, exp = auraRead(cfg)
    if real == nil then return false end
    if s.count ~= real or s.exp ~= exp then
        s.count = real; s.exp = exp
        if real > 0 then scheduleExpiryAt(s, exp) end
        return true
    end
    return false
end

-- Will a generator cast actually BUILD stacks? Only if it connects with an enemy: you're in
-- combat, or a hostile is within melee/AoE RANGE (your target or a nearby nameplate). This
-- separates "opened the fight with Whirlwind → 4 stacks" from "jumped around out of combat
-- pressing Whirlwind → nothing". The range gate matters because casting Whirlwind / Thunder Clap
-- auto-targets an attackable NPC far in front of you — without it, that fakes a stack when
-- nothing's actually in reach. CheckInteractDistance index 2 ≈ 11 yd (covers the 8 yd hit radius
-- with a little slack) and is only reached out of combat, where it's safe to call.
local function hostileInReach(u)
    return UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u)
        and CheckInteractDistance and CheckInteractDistance(u, 2)
end
local function generatorConnects()
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then return true end
    if not CheckInteractDistance then   -- no range API: fall back to a plain hostile-target check
        return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") or false
    end
    if hostileInReach("target") then return true end
    for i = 1, 40 do
        if hostileInReach("nameplate" .. i) then return true end
    end
    return false
end

-- Reader: hand back the current count. State is mutated by the watcher below (OOC aura sync +
-- in-combat cast estimate); read() only ages out an expired in-combat window.
ns.RegisterTracker("manual", {
    events = { "PLAYER_ENTERING_WORLD" },   -- prime on login / zone; live updates arrive via Refresh()
    read = function(cfg)
        local s = getState(cfg)
        local mx = cfg.max or 3
        local icon = cfg.icon or spellIcon(cfg.spellID)
        -- Talent-gated mechanic that isn't taken → it can't build; show empty.
        if mechanicOff(cfg) then
            if s.count ~= 0 or s.exp then s.count = 0; s.exp = nil end
            return { active = false, present = false, count = 0, value = 0, max = mx, icon = icon }
        end
        -- (No aura read here — that would clobber a just-estimated opener with a not-yet-applied
        -- buff. OOC truth arrives via UNIT_AURA / the combat-exit settle-sync in the watcher.)
        if s.exp and GetTime() >= s.exp then s.count = 0; s.exp = nil end
        return { active = s.count > 0, present = s.count > 0, count = s.count, value = s.count, max = mx, icon = icon }
    end,
})

-- Every manual tracker currently in the profile (few; scanned per relevant event).
local function manualTrackers(out)
    out = out or {}
    local trs = ns.profile and ns.profile.trackers
    if trs then for _, cfg in pairs(trs) do if cfg.type == "manual" then out[#out + 1] = cfg end end end
    return out
end

-- Watcher: player casts (in-combat estimate) + aura changes / combat transitions (OOC sync).
-- All events are player-scoped. On any count change, re-push snapshots so bound widgets update
-- even mid-fight (the count is a plain Lua integer — never a secret value).
local watch = CreateFrame("Frame")
watch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
watch:RegisterUnitEvent("UNIT_AURA", "player")           -- OOC: the real buff appeared / changed / dropped
watch:RegisterEvent("PLAYER_REGEN_ENABLED")              -- left combat → sync to the (now readable) aura
watch:RegisterEvent("PLAYER_REGEN_DISABLED")             -- entered combat → seed the estimate from it
watch:RegisterEvent("PLAYER_ENTERING_WORLD")
local scratch = {}

local function refresh() ns.Refresh() end

-- Sync every AURA-backed manual tracker to its real buff (a no-op in combat, where auraRead
-- returns nil). This is the OOC ground-truth corrector, driven by UNIT_AURA (the buff actually
-- changing) and a short settle-sync after combat. Returns true if anything changed.
local function syncAllAura()
    local changed = false
    for i = #scratch, 1, -1 do scratch[i] = nil end
    for _, cfg in ipairs(manualTrackers(scratch)) do
        if not mechanicOff(cfg) and cfg.aura and syncFromAura(cfg, getState(cfg)) then changed = true end
    end
    return changed
end

watch:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat. Non-aura trackers reset now (their buffs drop). Aura trackers get a
        -- SETTLED sync a beat later — reading the buff at the raw transition can catch a transient
        -- 0 and wrongly drop stacks that are still up. UNIT_AURA covers a genuine drop immediately.
        local changed = false
        for i = #scratch, 1, -1 do scratch[i] = nil end
        for _, cfg in ipairs(manualTrackers(scratch)) do
            if not mechanicOff(cfg) and not cfg.aura and cfg.resetOnCombatEnd ~= false then
                local s = getState(cfg)
                if s.count ~= 0 or s.exp then s.count = 0; s.exp = nil; changed = true end
            end
        end
        if changed then refresh() end
        if C_Timer then C_Timer.After(0.3, function() if syncAllAura() then refresh() end end) end
        return
    end

    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then
        -- UNIT_AURA / PLAYER_REGEN_DISABLED / PLAYER_ENTERING_WORLD → sync to the real buff (OOC).
        if syncAllAura() then refresh() end
        return
    end

    -- UNIT_SPELLCAST_SUCCEEDED (player): args are (unit, castGUID, spellID).
    if unit ~= "player" or not spellID then return end
    if ns._castLog then
        ns.Print(("|cff9fd6ffcast|r %s |cff808080#%d|r"):format(
            (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or "?", spellID))
    end
    -- "Did an AoE generator connect?" is decided at most ONCE per cast (a hostile in reach / in
    -- combat) and only when actually needed — most casts aren't AoE generators, and the check
    -- scans nameplates, so compute it lazily and share it across trackers.
    local connects   -- nil = not yet evaluated this cast
    local changed = false
    for i = #scratch, 1, -1 do scratch[i] = nil end
    for _, cfg in ipairs(manualTrackers(scratch)) do
      if not mechanicOff(cfg) then
        local s = getState(cfg)
        local before = s.count
        -- A cast can BOTH generate and consume (Takedown + Twin Fangs: grant 3, spend 1 for a net
        -- +2). Generate first, then consume, each clamped. AoE generators (Whirlwind / Thunder Clap,
        -- listed in cfg.aoeGen) only build when a hostile is actually in reach — they cast into thin
        -- air otherwise. Single-target generators (Kill Command, Takedown) SELF-CONFIRM: a successful
        -- cast means the target was valid and in range, so they always build (never range-gated).
        local ga = 0
        if cfg.gen and cfg.gen[spellID] ~= nil then
            if cfg.aoeGen and cfg.aoeGen[spellID] then
                if connects == nil then connects = generatorConnects() end
                if connects then ga = amountOf(cfg.gen[spellID]) end
            else
                ga = amountOf(cfg.gen[spellID])
            end
        end
        local ca = (cfg.con and cfg.con[spellID] ~= nil) and amountOf(cfg.con[spellID]) or 0
        if ga ~= 0 then
            s.count = s.count + ga; clamp(cfg, s)
            if ga > 0 and cfg.duration then s.exp = GetTime() + cfg.duration; scheduleExpiryAt(s, s.exp) end
        end
        if ca ~= 0 then
            s.count = s.count - ca; clamp(cfg, s)
            if s.count == 0 then s.exp = nil end
        end
        if s.count ~= before then
            changed = true
            if ns._manualLog then
                ns.Print(("|cffffd100manual|r %s: %s -> %d/%d"):format(
                    cfg.name or "?",
                    (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or ("#" .. spellID),
                    s.count, cfg.max or 3))
            end
        end
      end   -- not mechanicOff
    end
    if changed then refresh() end
end)

-- Icon-spellID -> the manual seed def, scanned from ns.Maintenance ([specID] lists only). Used
-- by the migration to REFRESH an existing manual tracker's mechanic data (gen/con/aura/…) when
-- the seed changes — so a widget added before a fix picks up the corrected lists / new fields.
function ns.ManualSeedByIcon()
    local map = {}
    for _, cls in pairs(ns.Maintenance or {}) do
        if type(cls) == "table" then
            for k, v in pairs(cls) do
                if type(k) == "number" and type(v) == "table" then   -- [specID] = maintenance list
                    for _, e in ipairs(v) do
                        if type(e) == "table" and e.m == "manual" and e.spellID then map[e.spellID] = e end
                    end
                end
            end
        end
    end
    return map
end

-- Copy the current seed's mechanic fields onto matching manual trackers (by icon spellID),
-- leaving the user's widget (name / position / display) alone. Returns how many were refreshed.
function ns.RefreshManualTrackers()
    local p = ns.profile
    if not (p and p.trackers) then return 0 end
    local seed = ns.ManualSeedByIcon()
    local n = 0
    for _, c in pairs(p.trackers) do
        if c.type == "manual" and c.spellID and seed[c.spellID] then
            local e = seed[c.spellID]
            c.aura, c.gen, c.con, c.aoeGen = e.aura, e.gen, e.con, e.aoeGen
            c.max, c.duration, c.requiredTalent, c.resetOnCombatEnd = e.max, e.duration, e.requiredTalent, e.resetOnCombatEnd
            n = n + 1
        end
    end
    return n
end

-- ── /cust manualaura : can we actually READ the tracked buff? ──
-- Prints, for every manual tracker in the profile (and the known Tip / Whirlwind buff ids),
-- whether cfg.aura is set and whether GetPlayerAuraBySpellID finds it live (stacks + expiry,
-- flagged SECRET in combat). Run it OOC with stacks up to confirm the OOC read works.
local function probeAura(id)
    if not id then ns.Print(("  #%s: no aura id"):format(tostring(id))); return end
    local a = ns.PlayerAura(id)
    if not a then ns.Print(("  #%s: |cffff6060NOT FOUND|r (GetPlayerAuraBySpellID → nil/secret)"):format(tostring(id))); return end
    local apps = a.applications or a.charges
    local appsStr = (ns.IsSecret and ns.IsSecret(apps)) and "|cffffd100SECRET|r" or tostring(apps)
    local expStr  = (ns.IsSecret and ns.IsSecret(a.expirationTime)) and "|cffffd100SECRET|r" or tostring(a.expirationTime)
    ns.Print(("  #%s: |cff40ff40FOUND|r name=%s stacks=%s expiry=%s"):format(
        tostring(id), tostring(a.name), appsStr, expStr))
end

function ns.ManualAuraProbe()
    ns.Print(("|cffffd100manual aura probe|r (in combat = %s):"):format(InCombatLockdown() and "|cffff6060YES — reads will be SECRET|r" or "no"))
    local trs = ns.profile and ns.profile.trackers
    local any = false
    if trs then
        for id, cfg in pairs(trs) do
            if cfg.type == "manual" then
                any = true
                ns.Print(("%s (tracker %s): spellID=%s  |cff%saura=%s|r"):format(
                    cfg.name or "?", id, tostring(cfg.spellID),
                    cfg.aura and "40ff40" or "ff4040", tostring(cfg.aura)))
                probeAura(cfg.aura or cfg.spellID)
            end
        end
    end
    if not any then ns.Print("  (no manual trackers in your profile yet)") end
    ns.Print("|cffffd100direct reads of the known buff ids:|r")
    probeAura(260286)   -- Tip of the Spear buff
    probeAura(85739)    -- Whirlwind buff
    ns.Print("If |cffff6060aura=nil|r above, your widget predates the aura sync — run |cffffd100/cust fixmanual|r to refresh it.")
end
