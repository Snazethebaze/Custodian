-- Core/Spells.lua : the spell-data layer — cached, secret-safe wrappers over the spell APIs.
--
-- Known/taken, name/icon, cost/usability, the aura-trackability oracle, the name-search index,
-- and the CooldownViewer-derived Browse list. Caches are invalidated together on talent/spell
-- change (the frame at the foot of the file).
--
-- Cost and usability are secret-SAFE: a spell's power cost and its usable/affordable state are
-- readable metadata (they drive the default action bars), so we can place a marker at "the Earth
-- Shock cost" or alert when a spender becomes castable WITHOUT ever reading the (secret) current
-- Maelstrom. Costs auto-reflect talents like Eye of the Storm, so nothing is hardcoded.
--
-- The /cust probes that used to live here (track / why / secrets / imbue / es / cdm / cats) moved
-- to Core/Probes.lua; they call back into these wrappers as ns.* at call time.

local ADDON, ns = ...

-- Is the spell actually in the player's spellbook? Respects talent choice
-- nodes — e.g. Earth Shock vs Elemental Blast: only the one you picked is
-- known, so only its marker shows.
function ns.SpellKnown(spellID)
    if not spellID then return false end
    local sb = C_SpellBook
    local checked = false
    if sb and sb.IsSpellKnownOrInSpellBook then
        checked = true
        if sb.IsSpellKnownOrInSpellBook(spellID) then return true end
    end
    if sb and sb.IsSpellKnown then
        checked = true
        if sb.IsSpellKnown(spellID) then return true end
    end
    if IsPlayerSpell then   -- legacy pre-12.0 fallback
        checked = true
        if IsPlayerSpell(spellID) then return true end
    end
    return not checked   -- no known-check API available at all -> fail open, don't blank markers
end

-- Strict "is this spell / talent TAKEN" for GATES — a rite require, a petless talent, a manual
-- tracker's requiredTalent. Same API chain as ns.SpellKnown but fails CLOSED (false when no API is
-- present), because a gate must not silently pass/hold when it can't tell. Tries C_SpellBook first
-- (12.0+; confirmed to answer for talents like Soul Glutton and the Lightsmith Rites) and keeps the
-- IsPlayerSpell global as a fallback, so it survives whichever of the two APIs the client exposes.
function ns.SpellTaken(spellID)
    if not spellID then return false end
    local sb = C_SpellBook
    if sb and sb.IsSpellKnown and sb.IsSpellKnown(spellID) then return true end
    if sb and sb.IsSpellKnownOrInSpellBook and sb.IsSpellKnownOrInSpellBook(spellID) then return true end
    if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    return false
end

-- A marker may BUNDLE several spell ids that are one logical spender — a choice
-- node (Earth Shock / Elemental Blast) or a spell's two cast forms (Earthquake:
-- ground 61882 + smart 462620). Resolve to the one you actually have: the first
-- KNOWN id, else the first listed (so it still shows a name). Accepts the legacy
-- single `m.spellID` too.
function ns.MarkerSpell(m)
    if not m then return nil end
    local ids = m.spellIDs
    if ids then
        for _, id in ipairs(ids) do if ns.SpellKnown(id) then return id end end
        return ids[1]
    end
    return m.spellID
end

-- Spell NAME / ICON metadata — readable (drives the default UI), never secret,
-- but the id is guarded defensively so a stray secret can't error a table index.
-- Shared by every tracker + the glow path (was copy-pasted four times).
function ns.SpellName(id)
    if not id or ns.IsSecret(id) then return nil end
    return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id) or nil
end

-- Icon cached per id so a display shows the right art even while the aura is down.
local iconCache = {}
function ns.SpellIcon(id)
    if not id or ns.IsSecret(id) then return nil end
    if iconCache[id] == nil then
        local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)
        iconCache[id] = tex or false
    end
    return iconCache[id] or nil
end

-- An ITEM's icon (weapon oil, augment rune…), for a reminder tied to a specific item. The id
-- and the returned texture are both IsSecret-guarded so a stray secret can't error a compare.
function ns.ItemIcon(itemID)
    if not itemID or ns.IsSecret(itemID) then return nil end
    if C_Item and C_Item.GetItemIconByID then
        local ic = C_Item.GetItemIconByID(itemID)
        if ic and not ns.IsSecret(ic) then return ic end
    end
    return nil
end

-- Power cost of a spell, optionally for a specific power type. Cached; the
-- cache is wiped on talent changes so Eye of the Storm etc. update the marker.
-- Returns nil for spells you haven't talented (choice-node aware).
local costCache = {}
function ns.SpellCost(spellID, powerType)
    if not spellID or not ns.SpellKnown(spellID) then return nil end
    local key = spellID .. ":" .. tostring(powerType or "any")
    local v = costCache[key]
    if v == nil then
        v = false
        local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(spellID)
        if type(costs) == "table" then
            -- Prefer the entry matching the requested power type (some spells,
            -- e.g. Elemental Blast, list a 0-cost entry first).
            if powerType then
                for _, c in ipairs(costs) do
                    if c.type == powerType then v = c.cost; break end
                end
            end
            if v == false then   -- no type match / none requested: first real (>0) cost
                for _, c in ipairs(costs) do
                    if c.cost and c.cost > 0 then v = c.cost; break end
                end
            end
            if v == false and costs[1] then v = costs[1].cost end
        end
        costCache[key] = v
    end
    return v or nil
end


-- ── The one player-aura read ──────────────────────────────────────────
-- EVERY GetPlayerAuraBySpellID call goes through here. On 12.0.7 a secret spell's aura simply
-- reads nil, so a bare `if a then` is safe today — but 12.1's wording says the UnitAura APIs
-- return "full secrets or nil" and that AuraData structs are "always fully secret", which
-- leaves it open that a secret aura starts coming back as a fully-secret STRUCT instead of nil.
-- If that lands, every raw `a ~= nil` / `not a` test on the result becomes a hard error. So:
-- pcall the call itself, then drop a secret or non-table result. IsSecret is tested BEFORE
-- type()/nil so a secret never reaches a comparison.
--
-- Returns a plain, indexable table, or nil (absent OR unreadable — callers that care about the
-- difference must decide OOC, where auras are readable). The FIELDS are still not guaranteed
-- readable: IsSecret-guard applications / charges / expirationTime before any arithmetic on
-- them. See ns.IsSecret (Core/Custodian.lua) and mem:midnight-secrets.
local GetPlayerAura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
function ns.PlayerAura(spellID)
    if not (spellID and GetPlayerAura) then return nil end
    local ok, a = pcall(GetPlayerAura, spellID)
    if not ok then return nil end
    if ns.IsSecret(a) then return nil end
    if type(a) ~= "table" then return nil end   -- also covers the nil (absent) case
    return a
end

-- Are player auras secret RIGHT NOW? This is NOT the same question as "am I in combat", and
-- the difference is load-bearing: the aura-secrecy restriction engages at the pull slightly
-- OUT OF STEP with InCombatLockdown(). In that gap a hidden buff already reads nil while the
-- lockdown flag still says false — so anything that gates a "can't read -> hold" decision on
-- InCombatLockdown() briefly decides "genuinely missing" and flashes a reminder (~0.2s at
-- every pull; seen on Resto's Water Shield). ShouldAurasBeSecret reports the RESTRICTION, so
-- it flips exactly when the reads do. Degrades to the lockdown flag if the API isn't there.
function ns.AurasSecretNow()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and v ~= nil then return v and true or false end
    end
    return InCombatLockdown() and true or false
end

-- Will this spell's aura be hidden from addons in combat? Defensives/utility
-- buffs (e.g. Astral Shift) are "secret auras": in combat GetPlayerAuraBySpellID
-- returns nil and the aura can't be enumerated — so an aura tracker can't see it
-- there (use a cooldown tracker instead). Returns true / false / nil (unknown).
function ns.AuraSecretInCombat(spellID)
    if not (spellID and C_Secrets and C_Secrets.ShouldSpellAuraBeSecret) then return nil end
    local ok, res = pcall(C_Secrets.ShouldSpellAuraBeSecret, spellID)
    if ok then return res end
    return nil
end


-- Static (combat-independent) trackability of a spell's AURA, from C_Secrets — the
-- add-time oracle. Query the real AURA id (some abilities apply a differently-ided buff;
-- pass that when known). GetSpellAuraSecrecy is stable OUT of combat and matches the
-- in-combat reality, so we can warn the moment a spell is picked. Returns:
--   "live"    — stays readable in combat (secrecy 0): full live tracking works.
--   "hidden"  — goes secret in combat (>0): OOC display / 'missing' reminder / cast-timer.
--   "unknown" — the getter isn't exposed (pre-12.0) or errored.
local trackCache = {}   -- spellID -> "live"/"hidden", cached from an OUT-of-combat query
function ns.AuraTrackability(spellID)
    if not spellID then return "unknown" end
    local cached = trackCache[spellID]
    if cached then return cached end
    if not (C_Secrets and C_Secrets.GetSpellAuraSecrecy) then return "unknown" end
    -- GetSpellAuraSecrecy proved context-dependent (it flips in combat, e.g. Lightning
    -- Shield reads 2 out of combat but 0 in it), so ONLY trust an out-of-combat query and
    -- cache it forever (secrecy is a game-global fact). In combat before it's cached we
    -- return "unknown" so the aura read falls back to its empirical path, never a wrong value.
    if InCombatLockdown and InCombatLockdown() then return "unknown" end
    local ok, v = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
    if not ok or v == nil then return "unknown" end
    local r = (v == 0) and "live" or "hidden"
    trackCache[spellID] = r
    return r
end


-- Live spell-name search over the player's spellbook, so the tracker picker lets
-- you type "Lightning Shield" instead of hunting id 192106. Built once, cached,
-- invalidated on SPELLS_CHANGED. Heavily pcall-guarded (spellbook API varies).
local spellList
local function buildSpellList()
    spellList = {}
    local sb = C_SpellBook
    if not (sb and sb.GetNumSpellBookSkillLines and sb.GetSpellBookItemInfo and sb.GetSpellBookSkillLineInfo) then return end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    local seen = {}
    local ok, nLines = pcall(sb.GetNumSpellBookSkillLines)
    if not ok then return end
    for line = 1, (nLines or 0) do
        local _, li = pcall(sb.GetSpellBookSkillLineInfo, line)
        if type(li) == "table" then
            local off, num = li.itemIndexOffset or 0, li.numSpellBookItems or 0
            for i = off + 1, off + num do
                local _, it = pcall(sb.GetSpellBookItemInfo, i, bank)
                if type(it) == "table" and it.spellID and it.name and not seen[it.spellID] then
                    seen[it.spellID] = true
                    spellList[#spellList + 1] = { id = it.spellID, name = it.name, icon = it.iconID, lower = it.name:lower() }
                end
            end
        end
    end
end

function ns.SearchSpells(query, maxResults)
    if not query or query == "" then return {} end
    if not spellList then buildSpellList() end
    local q = query:lower()
    local out = {}
    for _, s in ipairs(spellList or {}) do
        if s.lower:find(q, 1, true) then
            out[#out + 1] = s
            if #out >= (maxResults or 8) then break end
        end
    end
    return out
end

-- Resolve typed spell-field text to an id: a raw number wins; else the top name-search hit;
-- else nil. Every spell input box commits through this, so "Lightning Shield" and "192106"
-- both land on the same id.
function ns.ResolveSpellText(text)
    if not text or text == "" then return nil end
    local id = tonumber(text)
    if id then return id end
    local m = ns.SearchSpells(text, 1)
    return (m and m[1] and m[1].id) or nil
end

-- Best-effort buff length (seconds) parsed from a spell's description — used to
-- SUGGEST a cast-timer length for combat-hidden defensives (Astral Shift). It's
-- locale-dependent and approximate (grabs the first "<n> sec"), so it's only a
-- default the user can override. Returns a number or nil.
function ns.SpellBuffDuration(spellID)
    if not (spellID and C_Spell and C_Spell.GetSpellDescription) then return nil end
    local desc = C_Spell.GetSpellDescription(spellID)
    if type(desc) ~= "string" then return nil end
    local n = desc:match("(%d+)%s*sec")
    return n and tonumber(n) or nil
end

-- ── Cooldown Manager timing (READABLE in combat) ──────────────────────
-- C_Spell.GetSpellCooldown returns SECRET start/duration in combat and its isActive
-- flag lags the real end by up to ~1s — so a cooldown icon trails the action bar.
-- The Cooldown VIEWER (Blizzard's cooldown manager data) reports READABLE start/
-- duration for the spells it tracks by default, no CDM *display* setup needed — we
-- only READ it. We map each tracked spellID -> its cooldownID once so a cooldown
-- tracker can compute the exact ready moment and match the action bar. Returns nil
-- for spells not in the tracked set (caller falls back to the isActive heuristic).
local cdvMap   -- spellID -> cooldownID (nil until built; wiped on spec/spell change)
local function buildCdvMap()
    cdvMap = {}
    local C = C_CooldownViewer
    if not (C and C.GetCooldownViewerCategorySet and C.GetCooldownViewerCooldownInfo) then return end
    local cats = Enum and Enum.CooldownViewerCategory
    if type(cats) ~= "table" then return end
    for _, cat in pairs(cats) do
        local ok, ids = pcall(C.GetCooldownViewerCategorySet, cat)
        if ok and type(ids) == "table" then
            for _, cdID in ipairs(ids) do
                local ok2, info = pcall(C.GetCooldownViewerCooldownInfo, cdID)
                if ok2 and type(info) == "table" then
                    -- map BOTH the base id and any override (talent-swapped) id
                    if info.spellID then cdvMap[info.spellID] = cdID end
                    if info.overrideSpellID then cdvMap[info.overrideSpellID] = cdID end
                end
            end
        end
    end
end

function ns.CooldownViewerInfo(spellID)
    if not spellID then return nil end
    if not cdvMap then buildCdvMap() end
    local cdID = cdvMap and cdvMap[spellID]
    if not cdID then return nil end
    local C = C_CooldownViewer
    if not (C and C.GetCooldownViewerCooldownInfo) then return nil end
    local ok, info = pcall(C.GetCooldownViewerCooldownInfo, cdID)
    if ok and type(info) == "table" then return info end
    return nil
end

-- ── Browse: the data-driven "track any buff on your spec" list ─────────
-- Feeds the wizard's Browse screen — the escape hatch beyond the curated Recommended
-- seed. Walks the CooldownViewer category sets (the same source /cust cats dumps) and
-- returns the KNOWN, aura-bearing entries for the current spec, grouped by a friendly
-- category label. Cooldown-only abilities (no aura) are skipped: every wizard widget
-- tracks a buff/resource/imbue/form/pet — there is no cooldown widget — so a bare
-- cooldown would just make a reminder that never fires. Each item carries its resolved
-- AURA id (the ability id often differs from the buff it applies — see the trackability-
-- column note in CDMCats) plus a live/hidden verdict, so the UI can default to live-only
-- (Browse is live-first) yet reveal the combat-hidden ones on request.
-- Returns { { cat = <label>, items = { { id = <auraId>, castId, name, icon, hidden } … } } … }.
local BROWSE_META = {
    -- friendly label + display order, keyed by the STABLE Enum field NAME (values can
    -- shift across patches). HiddenAura / HiddenSpell are Blizzard-hidden by default → omitted.
    TrackedBuff = { label = "Buffs", order = 1 },
    TrackedBar  = { label = "Tracked bars", order = 2 },
    Essential   = { label = "Cooldown buffs", order = 3 },
    Utility     = { label = "Cooldown buffs", order = 3 },
}
local browseCats   -- lazily-built { { val, label, order } … } for the current build's Enum
local function buildBrowseCats()
    browseCats = {}
    local cats = Enum and Enum.CooldownViewerCategory
    if type(cats) ~= "table" then return end
    for name, val in pairs(cats) do
        local m = BROWSE_META[name]
        if m then browseCats[#browseCats + 1] = { val = val, label = m.label, order = m.order } end
    end
    table.sort(browseCats, function(a, b) return a.order < b.order end)
end

-- The aura id a CDM entry actually applies (ability id ≠ buff id for many spells). Prefer a
-- numeric selfAura, else a linkedSpellID that differs from the cast id, else the cast id itself.
local function browseAuraId(info, castId)
    if type(info.selfAura) == "number" and info.selfAura > 0 then return info.selfAura end
    if type(info.linkedSpellIDs) == "table" then
        for _, lid in ipairs(info.linkedSpellIDs) do
            if type(lid) == "number" and lid ~= castId then return lid end
        end
    end
    return castId
end

function ns.BrowseSpells()
    local C = C_CooldownViewer
    if not (C and C.GetCooldownViewerCategorySet and C.GetCooldownViewerCooldownInfo) then return {} end
    if not browseCats then buildBrowseCats() end
    local groups, byLabel, seen = {}, {}, {}
    for _, c in ipairs(browseCats or {}) do
        local g = byLabel[c.label]
        if not g then g = { cat = c.label, items = {} }; byLabel[c.label] = g; groups[#groups + 1] = g end
        local ok, ids = pcall(C.GetCooldownViewerCategorySet, c.val)
        if ok and type(ids) == "table" then
            for _, cdID in ipairs(ids) do
                local ok2, info = pcall(C.GetCooldownViewerCooldownInfo, cdID)
                if ok2 and type(info) == "table" and info.hasAura and info.isKnown then
                    local castId = info.overrideSpellID or info.spellID
                    local auraId = castId and browseAuraId(info, castId)
                    if auraId and not seen[auraId] then
                        seen[auraId] = true
                        local track = ns.AuraTrackability and ns.AuraTrackability(auraId)
                        g.items[#g.items + 1] = {
                            id     = auraId,
                            castId = castId,
                            name   = ns.SpellName(auraId) or ns.SpellName(castId) or "?",
                            icon   = ns.SpellIcon(auraId) or ns.SpellIcon(castId),
                            hidden = (track == "hidden"),
                        }
                    end
                end
            end
        end
    end
    -- Drop groups emptied by the filter; sort each surviving group by name.
    local out = {}
    for _, g in ipairs(groups) do
        if #g.items > 0 then
            table.sort(g.items, function(a, b) return (a.name or "") < (b.name or "") end)
            out[#out + 1] = g
        end
    end
    return out
end

-- isUsable, insufficientPower — both readable booleans (AllowedWhenTainted).
function ns.SpellUsable(spellID)
    if not spellID then return false, false end
    if C_Spell and C_Spell.IsSpellUsable then
        return C_Spell.IsSpellUsable(spellID)
    end
    return false, false
end

local f = CreateFrame("Frame")
f:RegisterEvent("TRAIT_CONFIG_UPDATED")
f:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
f:RegisterEvent("SPELLS_CHANGED")
f:SetScript("OnEvent", function()
    wipe(costCache)
    spellList = nil   -- rebuild the name-search index on next use
    cdvMap = nil      -- rebuild the spellID -> cooldownID map (talents change the set)
    ns.Refresh()
end)


