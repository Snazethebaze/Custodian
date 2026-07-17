-- Trackers/Aura.lua : reads a player aura's stacks / duration (MSW, shields…).
-- Config: { type = "aura", spellID = 344179, unit = "player", max = 10 }

local ADDON, ns = ...

local GetPlayerAura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
local ForEachAura   = AuraUtil and AuraUtil.ForEachAura

-- Shared spell metadata helpers (defined in Core/Spells.lua, loaded first).
local spellIcon, spellName = ns.SpellIcon, ns.SpellName

-- Item-backed aura (an augment rune / any consumable that grants the buff): show the ITEM's
-- icon so it reads as itself rather than its generic buff art — and matches the sidebar list.
local itemIcon = ns.ItemIcon

-- A buff's aura spellID often differs from the ABILITY's cast id the user typed,
-- so when the exact-id lookup misses, fall back to matching an active player
-- aura by NAME. Player aura names are readable; guard anyway.
local function findByName(name)
    if not name or not ForEachAura then return nil end
    local found
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        -- pcall: as of 12.1.0, index/slot aura enumeration Lua-errors while auras are
        -- secret (the spellID path stays fine). Catch it so a combat scan degrades to
        -- "not found" instead of throwing out of the tracker read.
        pcall(ForEachAura, "player", filter, nil, function(aura)
            if aura and not ns.IsSecret(aura.name) and aura.name == name then found = aura; return true end
        end, true)
        if found then break end
    end
    return found
end

-- ability spellID -> its buff's ACTUAL aura spellID, learned the first time the
-- buff is seen out of combat (names are readable then). In combat the name match
-- can't run (names are secret), so this cache lets a maintained buff keep
-- resolving via the combat-safe exact-id path.
local resolved = {}

-- Resolve a spellID to its active player aura: exact id, then the learned buff id, then by
-- readable name (so a set can list ABILITY ids — Crippling ability 3409 vs its buff 3408). nil
-- if not up. The one place both the single-aura and the match-set paths resolve auras.
local function resolveAura(id)
    if not id then return nil end
    local a = ns.PlayerAura(id)
    if not a and resolved[id] then a = ns.PlayerAura(resolved[id]) end
    if not a then
        local found = findByName(spellName(id))
        if found then a = found; if found.spellId and not ns.IsSecret(found.spellId) then resolved[id] = found.spellId end end
    end
    return a
end

-- Public: which of these spellIDs are currently up on the player (used to auto-capture the
-- poisons you have applied, and to reflect checkbox state in the editor). Order preserved.
function ns.AurasUp(ids)
    local up = {}
    if type(ids) == "table" then for _, id in ipairs(ids) do if resolveAura(id) then up[#up + 1] = id end end end
    return up
end

-- spellID -> last-known { exp, dur, cnt, icon } while readable, so a HELD read (dead, or a
-- secret buff in combat) keeps the icon looking the same (lit + countdown) instead of blank.
local lastAura = {}
local dbgAt = {}   -- /cust auradbg throttle

-- ── Cast-timed buffs ──────────────────────────────────────────────────
-- Some defensives (Astral Shift, etc.) are SECRET auras: GetPlayerAuraBySpellID
-- returns nil in combat even while the buff is up, so we can't read the window.
-- But the CAST is observable (UNIT_SPELLCAST_SUCCEEDED). When cfg.castTimer is set,
-- we time the cast instead: show the buff active for castTimer seconds after use.
-- Reliable in and out of combat; the length is user-set (auras panel).
local GetTime = GetTime
local castAt = {}   -- ability spellID -> GetTime() of last successful cast
do
    local watch = CreateFrame("Frame")
    watch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")   -- player only (was raid-wide)
    watch:RegisterEvent("PLAYER_DEAD")   -- clear timed windows on death (see below)
    watch:SetScript("OnEvent", function(_, event, unit, _, spellID)
        if event == "PLAYER_DEAD" then
            -- A cast-timed buff (Astral Shift…) drops when you die — don't keep the
            -- fake window counting on a corpse. Wipe the stamps and re-read.
            wipe(castAt)
            ns.Refresh()
            return
        end
        if unit ~= "player" or not spellID then return end
        local trackers = ns.profile and ns.profile.trackers
        if not trackers then return end
        local castName, hit = spellName(spellID)
        for _, cfg in pairs(trackers) do
            if cfg.type == "aura" and cfg.spellID and (cfg.castTimer or 0) > 0 then
                -- match by exact id OR name (the cast id can differ from the stored one)
                if cfg.spellID == spellID or (castName and spellName(cfg.spellID) == castName) then
                    -- Anchor to the cooldown's START (the authoritative cast moment) so a
                    -- late-delivered event doesn't push the window out; fall back to now.
                    local start = GetTime()
                    local cdi = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(cfg.spellID)
                    -- IsSecret MUST be checked before any compare: in combat startTime goes
                    -- secret, and `> 0` on a secret value throws (aborting this handler).
                    if cdi and cdi.startTime and not ns.IsSecret(cdi.startTime) and cdi.startTime > 0 then
                        start = cdi.startTime
                    end
                    castAt[cfg.spellID] = start; hit = true
                    -- re-read right when the window ends so it flips to inactive on time
                    C_Timer.After(math.max(0, (start + cfg.castTimer) - GetTime()) + 0.05, function()
                        ns.Refresh()
                    end)
                end
            end
        end
        if hit then ns.Refresh() end
    end)
end

-- ── Group-buff via Blizzard's action-bar glow ─────────────────────────
-- A raid-wide buff (Skyfury…) is hard to track by scanning everyone's auras (secret
-- in combat, expensive out of it). But the game GLOWS the ability on the action bar
-- when it should be cast — i.e. someone in range lacks it — and fires a public event
-- for that. So a "group buff" reminder just mirrors that glow: shown while the spell
-- is glowing (someone needs it), hidden when it isn't. No aura scan, secret-safe.
local glowSet = {}   -- spellID -> true while Blizzard glows it on the action bar
do
    local gw = CreateFrame("Frame")
    gw:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
    gw:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
    gw:SetScript("OnEvent", function(_, event, spellID)
        if not spellID then return end
        glowSet[spellID] = (event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW") and true or nil
        if ns._glowDbg then
            ns.Print(("|cffffd100glow|r %s %s (%s)"):format(
                (event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW") and "|cff40ff40SHOW|r" or "|cffff4040HIDE|r",
                tostring(spellID), tostring(spellName(spellID))))
        end
        ns.Refresh()
    end)
end

-- Is the ability currently glowing? Match by exact id OR name (the glowed action id
-- can differ from the stored one for ranked / override variants).
local function abilityGlowing(wantId)
    if not wantId then return false end
    if glowSet[wantId] then return true end
    local wantName = spellName(wantId)
    if wantName then
        for sid in pairs(glowSet) do if spellName(sid) == wantName then return true end end
    end
    return false
end

ns.RegisterTracker("aura", {
    -- combat transitions matter: whether "not found" means missing vs unknown depends on
    -- InCombatLockdown, so re-read when it flips. Death/resurrect (a wipe) also flip the
    -- "silent while dead" gate, so re-read on those too.
    events    = { "UNIT_AURA", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
                  "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" },
    unitEvent = true,
    read = function(cfg)
        -- Match-SET mode: a category buff (rogue poisons) tracked over a list, since you pick
        -- WHICH poison. Two shapes:
        --   cfg.matchAll (non-empty) — you pinned exact poisons; ALL of them must be up.
        --   cfg.matchAny             — the category pool; you need `need` DISTINCT members up,
        --                              where `need` is cfg.requireCount (default 1) bumped by a
        --                              talent: Dragon-Tempered Blades lets a Rogue run 2 of a
        --                              category, so require 2 ONLY when it's actually taken (fail-
        --                              closed ns.SpellTaken) — spec out of it and it drops back to
        --                              1, so it never nags for a slot you can't fill.
        -- The icon shows the FIRST MISSING member when reminding, so it tells you what to reapply.
        -- Poisons are pre-combat maintenance (secret in combat), so a shortfall IN COMBAT HOLDS
        -- (present=nil) instead of false-nagging.
        local useAll = cfg.matchAll and #cfg.matchAll > 0
        if (useAll or cfg.matchAny) and GetPlayerAura then
            local list = useAll and cfg.matchAll or cfg.matchAny
            local need
            if useAll then
                need = #list
            else
                need = cfg.requireCount or 1
                local g = cfg.requireCountTalent
                if g and g.talent and ns.SpellTaken(g.talent) then need = g.count or need end
                if need > #list then need = #list end
            end
            local up, firstMissing, sample = 0, nil, nil
            for _, id in ipairs(list) do
                local au = resolveAura(id)
                if au then up = up + 1; sample = sample or au
                elseif not firstMissing then firstMissing = id end
            end
            local ok = up >= need
            if ok then
                return { active = true, present = true, count = up, value = up, max = need, noCount = true,
                         icon = cfg.icon or (sample and sample.icon) or spellIcon(list[1]),
                         duration = sample and sample.duration, expiration = sample and sample.expirationTime }
            end
            -- What CLICK-TO-CAST applies (and the reminder icon): the reminder counts "any of the
            -- category", so it can't know which poison YOU run — cfg.castPref (+ cfg.castPref2, the
            -- Dragon-Tempered Blades 2nd slot) name your poisons. Apply the FIRST of them that's
            -- currently missing, so each click reapplies a specific poison you run rather than an
            -- arbitrary pool member. No preference set → first missing member.
            local castId = firstMissing or list[1]
            local prefs = {}
            if cfg.castPref  then prefs[#prefs + 1] = cfg.castPref  end
            if cfg.castPref2 then prefs[#prefs + 1] = cfg.castPref2 end
            for _, pref in ipairs(prefs) do
                if not resolveAura(pref) then castId = pref; break end
            end
            local missIcon = cfg.icon or spellIcon(castId)
            local present
            local hidden = ns.AuraTrackability and ns.AuraTrackability(list[1]) == "hidden"
            if ns.PlayerDead() then present = nil
            elseif hidden and ns.AurasSecretNow() then present = nil
            else present = false end
            return { active = present == nil, present = present, count = up, value = up, max = need,
                     noCount = true, icon = missIcon, castId = castId }
        end

        -- Group-buff mode: nag even if YOU have it when the action-bar glow says a GROUP
        -- member lacks it. Gated on IsInGroup so the glow can't false-fire solo.
        local glowNeeded = cfg.groupGlow and IsInGroup() and cfg.spellID and abilityGlowing(cfg.spellID)

        -- Cast-timed buff (e.g. Astral Shift): within the window after a witnessed cast, report
        -- active with a countdown. Works even when the real aura is secret in combat.
        if (cfg.castTimer or 0) > 0 and cfg.spellID and not ns.PlayerDead() then
            local t = castAt[cfg.spellID]
            local expiry = t and (t + cfg.castTimer)
            if expiry and GetTime() < expiry then
                return { active = true, present = true, count = 0, value = 1, max = 1, noCount = true,
                         icon = cfg.icon or itemIcon(cfg.itemID) or spellIcon(cfg.spellID), duration = cfg.castTimer, expiration = expiry }
            end
        end

        -- Read the aura: exact id first, then its learned aura id, then by readable name.
        local a = cfg.spellID and resolveAura(cfg.spellID)

        -- Is this buff READABLE in combat? The reliable, out-of-combat-cached oracle answers it.
        local track = (cfg.spellID and ns.AuraTrackability and ns.AuraTrackability(resolved[cfg.spellID] or cfg.spellID)) or "unknown"
        local staticIcon = cfg.icon or itemIcon(cfg.itemID) or spellIcon(cfg.spellID)

        -- FOUND — you have it. Cache its timer/stacks so a later held read keeps the icon looking
        -- the same. present=false only if group-glow says a member still needs it.
        if a then
            local count = a.applications or a.charges or 0
            if cfg.spellID then lastAura[cfg.spellID] = { exp = a.expirationTime, dur = a.duration, cnt = count, icon = a.icon } end
            return { active = true, present = not glowNeeded, count = count, value = count,
                     max = cfg.max or a.maxCharges or 10, icon = staticIcon or a.icon,
                     duration = a.duration, expiration = a.expirationTime }
        end

        -- NOT FOUND — the ENTIRE decision, three plain cases:
        --   dead                          -> nil  (can't maintain buffs on a corpse -> silent)
        --   secret aura, secrecy engaged  -> nil  (unreadable -> HIDE the reminder; no false nag)
        --   otherwise (readable, or OOC)  -> false (genuinely MISSING -> show the reminder)
        -- Gate the hidden case on ns.AurasSecretNow(), NOT InCombatLockdown(): the secrecy
        -- restriction engages a beat before the lockdown flag at a pull, and a UNIT_AURA landing
        -- in that gap would otherwise read nil-while-"not in combat" and flash the reminder.
        local present
        if ns.PlayerDead() then
            present = nil
        elseif track == "hidden" and ns.AurasSecretNow() then
            present = nil
        else
            present = false
        end
        if glowNeeded then present = false end   -- a group member needs it -> definitely missing

        if ns._auraDbg and cfg.spellID and ns.AurasSecretNow() then
            local now = GetTime()
            if (now - (dbgAt[cfg.spellID] or 0)) > 1 then
                dbgAt[cfg.spellID] = now
                ns.Print(("|cffffd100aura|r %s present=%s track=%s a=%s glow=%s"):format(
                    tostring(cfg.spellID), tostring(present), tostring(track), a and "found" or "nil", tostring(glowNeeded)))
            end
        end

        -- present==nil = held (dead, or secret-in-combat): report ACTIVE with the last-known
        -- timer, so a plain buff icon stays lit and a "missing" reminder stays hidden.
        local snap = { active = present == nil, present = present, count = 0, value = 0, max = cfg.max or 10, icon = staticIcon }
        local la = present == nil and cfg.spellID and lastAura[cfg.spellID]
        if la then
            snap.count, snap.value = la.cnt or 0, la.cnt or 0
            snap.duration, snap.expiration = la.dur, la.exp
            snap.icon = staticIcon or la.icon
        end
        return snap
    end,
})

-- ── Diagnostic (/cust aura <id|name>) ──────────────────────────────────
-- Dump exactly what the aura read sees for a spell, in the current combat state, plus the
-- tracker's cached internals. Run it OOC and IN combat (dummy) to see WHY a reminder fires.
function ns.AuraProbe(spellID)
    if not spellID then ns.Print("usage: /cust aura <spellID or name>"); return end
    local nm = spellName(spellID)
    ns.Print(("|cffffd100aura probe|r id=%s (%s) combat=%s dead=%s"):format(
        tostring(spellID), tostring(nm), tostring(InCombatLockdown()),
        tostring(ns.PlayerDead())))

    local direct = ns.PlayerAura(spellID)
    ns.Print(("  GetPlayerAuraBySpellID(%s) -> %s"):format(tostring(spellID), direct and "FOUND" or "nil/secret"))
    local rid = resolved[spellID]
    if rid then
        local ra = ns.PlayerAura(rid)
        ns.Print(("  resolved id=%s -> %s"):format(tostring(rid), ra and "FOUND" or "nil/secret"))
    end
    local byname = findByName(nm)
    ns.Print(("  findByName(%s) -> %s"):format(tostring(nm), byname and ("FOUND id=" .. tostring(byname.spellId)) or "nil"))

    -- The NEW model's decision, mirrored exactly: found -> have it (hide); else dead or
    -- secret-in-combat -> held (nil, reminder hidden); else -> missing (show).
    local track = ns.AuraTrackability and ns.AuraTrackability(rid or spellID)
    local verdict
    if direct or byname then verdict = "|cff40ff40have it -> hide|r"
    elseif ns.PlayerDead() then verdict = "|cffffd100dead -> held (silent)|r"
    elseif track == "hidden" and ns.AurasSecretNow() then verdict = "|cffffd100secret in combat -> held (hidden)|r"
    else verdict = "|cffff5555missing -> SHOW|r" end
    ns.Print(("  track(read=%s)=%s | ShouldSpellAuraBeSecret=%s  =>  %s"):format(
        tostring(rid or spellID), tostring(track),
        tostring(ns.AuraSecretInCombat and ns.AuraSecretInCombat(spellID)), verdict))

    -- Raw enumeration: how many HELPFUL auras are visible, and whether ANY has a readable
    -- name matching (tells us if the name path can work in this state).
    if ForEachAura then
        local n, named, match = 0, 0, false
        pcall(ForEachAura, "player", "HELPFUL", nil, function(au)
            if au then
                n = n + 1
                if au.name and not ns.IsSecret(au.name) then
                    named = named + 1
                    if nm and au.name == nm then match = true end
                end
            end
        end, true)
        ns.Print(("  ForEachAura HELPFUL: %d auras, %d with readable name, nameMatch=%s"):format(n, named, tostring(match)))
    end
end
