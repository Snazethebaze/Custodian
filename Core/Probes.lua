-- Core/Probes.lua : developer / support probes and their slash commands.
--
-- Everything here is diagnostic — nothing in the addon's runtime path depends on it, and the
-- whole file can be dropped from the .toc without breaking anything (the commands simply stop
-- registering, so `/cust <probe>` falls through to the normal help). Player-facing commands
-- live in Core/Custodian.lua; this file owns the `/cust debug` index and every probe it lists.
--
-- Probe bodies resolve their targets as ns.* at CALL time, so load order never matters.

local ADDON, ns = ...

-- ── Read-outs (thin guards over a module's own probe) ─────────────────
ns.RegisterSlash("secrets",    ns.SlashProbe("SecretScan",       "secrets probe"))
ns.RegisterSlash("why",        ns.SlashProbe("WhyReminders",     "why probe"))
ns.RegisterSlash("track",      ns.SlashProbe("TrackerDebug",     "track debug"))
ns.RegisterSlash("imbue",      ns.SlashProbe("ImbueDebug",       "imbue debug"))
ns.RegisterSlash("cdm",        ns.SlashProbe("CDMDebug",         "cdm debug"))
ns.RegisterSlash("cats",       ns.SlashProbe("CDMCats",          "cats probe"))
ns.RegisterSlash("pet",        ns.SlashProbe("PetProbe",         "pet probe"))
ns.RegisterSlash("pets",       ns.SlashProbe("CallPetProbe",     "pets probe"))
ns.RegisterSlash("manualaura", ns.SlashProbe("ManualAuraProbe",  "manual aura probe"))
ns.RegisterSlash("imbuegate",  ns.SlashProbe("ImbueGateProbe",   "imbue gate probe"))
ns.RegisterSlash("shatter",    ns.SlashProbe("ShatterProbe",     "shatter probe"))
ns.RegisterSlash("es",         ns.SlashProbe("EarthShieldProbe", "es probe"))

ns.RegisterSlash("glow", function()
    if ns.Glow and ns.Glow.Debug then ns.Glow.Debug() else ns.Print("glow module not loaded.") end
end)

ns.RegisterSlash("curve", function()
    if ns.ColorCurve and ns.ColorCurve.Probe then ns.ColorCurve.Probe() else ns.Print("colorcurve module not loaded.") end
end)

-- ── Live logs (toggles) ───────────────────────────────────────────────
ns.RegisterSlash("log", ns.SlashToggle("_reminderLog",
    "reminder push log %s — do the action (enter combat / rebuff / remove), then /cust log to stop."))
ns.RegisterSlash("glowdbg", ns.SlashToggle("_glowDbg",
    "action-bar glow debug %s — cast/watch a raid-wide group buff and see if it prints |cff40ff40glow SHOW|r / |cffff4040HIDE|r lines. If it does, a 'Group buff' reminder can use it."))
ns.RegisterSlash("auradbg", ns.SlashToggle("_auraDbg",
    "aura live-log %s — prints each in-combat aura read (present + inputs). Watch it while the reminder is wrongly showing."))
ns.RegisterSlash("casts", ns.SlashToggle("_castLog",
    "cast log %s — cast your abilities; each prints its spell name + id. Use it to fill a manual tracker's builder/spender list."))
ns.RegisterSlash("manuallog", ns.SlashToggle("_manualLog",
    "manual log %s — prints each manual tracker's count as it changes."))

-- ── Aura probe (resolves a name to an id first) ───────────────────────
ns.RegisterSlash("aura", function(rest)
    local arg = (rest ~= "" and rest) or nil
    local id = tonumber(arg)
    if not id and arg and ns.SearchSpells then local m = ns.SearchSpells(arg, 1); if m and m[1] then id = m[1].id end end
    if ns.AuraProbe then ns.AuraProbe(id) else ns.Print("aura probe not loaded.") end
end)

-- ── browse : what the wizard's Browse screen will actually offer ──────
-- ns.BrowseSpells() grouped, with the RESOLVED aura id (not the ability id) and each item's
-- live/pre-combat verdict. Run OOC — the trackability oracle only classifies out of combat. Use
-- it to confirm the aura-id resolution (selfAura / linkedSpellIDs) points at the real buff, and
-- that the live-first filter isn't wrongly hiding a maintenance buff.
ns.RegisterSlash("browse", function()
    local groups = ns.BrowseSpells and ns.BrowseSpells() or {}
    if #groups == 0 then ns.Print("|cffffd100browse|r no aura-bearing CooldownViewer entries (or API unavailable).")
    else
        ns.Print("|cffffd100browse|r — what the wizard's Browse screen offers:")
        for _, g in ipairs(groups) do
            local live = 0; for _, it in ipairs(g.items) do if not it.hidden then live = live + 1 end end
            ns.Print(("|cff8fb8e0%s|r (%d, %d live)"):format(g.cat, #g.items, live))
            for _, it in ipairs(g.items) do
                local col = it.hidden and "|cffe6a53cpre-combat" or "|cff5ec888live"
                ns.Print(("   %s |cffffffff%s|r  %s|r"):format(tostring(it.id), tostring(it.name), col))
            end
        end
    end
end)

-- ── dbg : power/marker wiring for the Elemental Maelstrom bar + every power widget ──
ns.RegisterSlash("dbg", function()
    local MS = (ns.PowerTypes and ns.PowerTypes.MAELSTROM) or 11
    local mx = UnitPowerMax("player", MS)
    ns.Print(("|cffffd100dbg|r MAELSTROM=%s spec=%s max=%s secret=%s"):format(
        tostring(MS), tostring(ns.specID), tostring(mx), tostring(ns.IsSecret(mx))))
    for _, id in ipairs({ 462620, 8042, 117014 }) do
        ns.Print(("  spell %d: known=%s cost=%s costMS=%s"):format(
            id, tostring(ns.SpellKnown(id)), tostring(ns.SpellCost(id)), tostring(ns.SpellCost(id, MS))))
        local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(id)
        if type(costs) == "table" then
            if #costs == 0 then ns.Print("     (empty cost table)") end
            for j, c in ipairs(costs) do
                ns.Print(("     [%d] type=%s cost=%s"):format(j, tostring(c.type), tostring(c.cost)))
            end
        else
            ns.Print("     GetSpellPowerCost=" .. type(costs))
        end
    end
    local pw = ns.profile.widgets.ele_maelstrom
    local lw = ns.widgets.ele_maelstrom
    local shown = 0
    if lw and lw.markers then for _, t in ipairs(lw.markers) do if t:IsShown() then shown = shown + 1 end end end
    ns.Print(("  ele: cfgMarkers=%s liveWidget=%s markersShown=%s"):format(
        tostring(pw and pw.markers and #pw.markers), tostring(lw ~= nil), tostring(shown)))
    -- What is the maelstrom bar's SOURCE right now? (a stray kind-change clears power)
    local mtr = ns.TrackerOf(pw)
    ns.Print(("  |cffffd100ele-src|r trackerId=%s type=%s power=%s spellID=%s"):format(
        tostring(pw and pw.trackerId), tostring(mtr and mtr.type), tostring(mtr and mtr.power), tostring(mtr and mtr.spellID)))
    -- Every power-bound widget: its power type + the live read, so a broken fill
    -- (bar stuck at 0) shows whether it's the CONFIG (power=nil) or the VALUE.
    for id, c in pairs(ns.profile.widgets) do
        local tr = ns.TrackerOf(c)
        if tr and tr.type == "power" then
            local pt  = ns.PowerTypes and ns.PowerTypes[tr.power]
            local val = pt and UnitPower("player", pt)
            local w2  = ns.widgets[id]
            ns.Print(("  |cffffd100pwr|r %s power=%s pt=%s value=%s max=%s live=%s shown=%s spec=%s"):format(
                tostring(id), tostring(tr.power), tostring(pt),
                (ns.IsSecret(val) and "<secret>" or tostring(val)),
                tostring(pt and UnitPowerMax("player", pt)),
                tostring(w2 ~= nil),
                tostring(w2 and w2.frame and w2.frame:IsShown()),
                tostring(w2 and w2:MatchesSpec(ns.specID))))
        end
    end
end)

-- ── buffs : dump every HELPFUL aura on you (name + id) ────────────────
-- To find a buff whose name we don't know, e.g. the Grimoire of Sacrifice petless buff
-- (sacrifice your pet FIRST, then run this).
ns.RegisterSlash("buffs", function()
    if AuraUtil and AuraUtil.ForEachAura then
        ns.Print("|cffffd100buffs|r on you (HELPFUL):")
        local n = 0
        pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(a)
            if not a then return end
            n = n + 1
            local nm = a.name
            if ns.IsSecret and ns.IsSecret(nm) then nm = "<secret>" end
            ns.Print(("   %s |cff808080#%s|r"):format(tostring(nm), tostring(a.spellId)))
        end, true)
        if n == 0 then ns.Print("   (none)") end
    else
        ns.Print("AuraUtil.ForEachAura unavailable.")
    end
end)

-- ── poison : are Rogue poisons weapon ENCHANTS (imbue) or self-BUFFS (aura)? ──
-- Apply a lethal + non-lethal poison, then run this. Reports both so the mechanic is unambiguous.
ns.RegisterSlash("poison", function()
    if GetWeaponEnchantInfo then
        local mhHas, mhMs, _, mhId, ohHas, ohMs, _, ohId = GetWeaponEnchantInfo()
        ns.Print(("|cffffd100poison|r weapon-enchant read — MH has=%s (id=%s, %sms) · OH has=%s (id=%s, %sms)"):format(
            tostring(mhHas), tostring(mhId), tostring(mhMs), tostring(ohHas), tostring(ohId), tostring(ohMs)))
    else
        ns.Print("|cffffd100poison|r GetWeaponEnchantInfo unavailable.")
    end
    if AuraUtil and AuraUtil.ForEachAura then
        ns.Print("  HELPFUL buffs with 'poison' in the name:")
        local n = 0
        pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(a)
            if not a then return end
            local nm = a.name
            if nm and not (ns.IsSecret and ns.IsSecret(nm)) and nm:lower():find("poison") then
                n = n + 1
                ns.Print(("     |cff5ec888%s|r |cff808080#%s|r"):format(tostring(nm), tostring(a.spellId)))
            end
        end, true)
        if n == 0 then ns.Print("     (none found — apply a poison first, or they aren't auras → check the enchant line above)") end
    end
end)

-- ── ally : can we READ a given buff on an ALLY (and is the source readable as ours)? ──
-- The research gate for ally trackers — run in a group with the buff placed on someone.
ns.RegisterSlash("ally", function(rest)
    local sid = tonumber(rest:match("(%d+)"))
    if not sid then ns.Print("|cffffd100ally|r usage: |cffffd100/cust ally <spellID>|r — scan party/raid for YOUR buff (be in a group, ideally in combat)."); return end
    local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or ("#" .. sid)
    if not IsInGroup() then ns.Print(("|cffffd100ally|r %s (#%d): not in a group — join one and place the buff on an ally."):format(nm, sid)); return end
    ns.Print(("|cffffd100ally|r scanning for |cffffffff%s|r (#%d) — in combat=%s:"):format(nm, sid, tostring(InCombatLockdown())))
    local units = {}
    if IsInRaid() then for i = 1, 40 do units[#units + 1] = "raid" .. i end else for i = 1, 4 do units[#units + 1] = "party" .. i end end
    local anyReadable, anyMine, anySecretSrc = false, false, false
    for _, u in ipairs(units) do
        if UnitExists(u) and not UnitIsUnit(u, "player") then
            local mineHere, secretHere = false, false
            pcall(AuraUtil.ForEachAura, u, "HELPFUL", nil, function(a)
                if a and a.spellId == sid then
                    anyReadable = true
                    if ns.IsSecret and ns.IsSecret(a.sourceUnit) then secretHere = true; anySecretSrc = true
                    elseif a.sourceUnit == "player" then mineHere = true; anyMine = true end
                end
            end, true)
            if mineHere then ns.Print(("   |cff5ec888%s|r has YOUR %s"):format(UnitName(u) or u, nm))
            elseif secretHere then ns.Print(("   |cffe6a53c%s|r has it — source SECRET"):format(UnitName(u) or u)) end
        end
    end
    ns.Print(("  → readable on an ally: %s · confirmed yours: %s%s%s"):format(
        anyReadable and "|cff5ec888yes|r" or "|cffff4040no|r",
        anyMine and "|cff5ec888yes|r" or "|cffff4040no|r",
        anySecretSrc and " |cffe6a53c(source secret on some)|r" or "",
        (ns.AllyBuffUp and (" · tracker reads: " .. (ns.AllyBuffUp(sid) and "|cff5ec888up|r" or "|cffff4040down|r"))) or ""))
end)

-- ── grpdbg : every display group's order + each member's shown/size ───
-- Reveals hidden members or odd sizes that can make reordering to an end fail.
ns.RegisterSlash("grpdbg", function()
    local groups = ns.profile and ns.profile.groups
    if not (groups and next(groups)) then ns.Print("No display groups."); return end
    for gid, grp in pairs(groups) do
        ns.Print(("|cffffd100%s|r (%s) axis=%s gap=%d"):format(grp.name or gid, gid, grp.axis or "h", grp.gap or 0))
        for i, wid in ipairs(ns.Groups.Order(gid)) do
            local c = ns.profile.widgets[wid]
            local w = ns.widgets and ns.widgets[wid]
            ns.Print(("   %d. %s [%s] shown=%s size=%sx%s"):format(
                i, tostring(c and c.name or wid), tostring(c and c.display),
                tostring(w and w.frame and w.frame:IsShown()),
                tostring(c and c.width), tostring(c and c.height)))
        end
    end
end)

-- ── castdbg : for every reminder widget, print its cast-button state ──
ns.RegisterSlash("castdbg", function()
    ns.Print("|cffffd100Click-to-cast state:|r")
    local any = false
    for id, w in pairs(ns.widgets or {}) do
        local cb = w.castButton
        if cb then
            local name = w.CastSpellName and w:CastSpellName()
            if name or w.cfg.showWhen or (w.cfg.reminder and w.cfg.reminder.mode) then
                any = true
                ns.Print(("  %s: name=%s mouse=%s shown=%s lvl=%d type=%s spell=%s"):format(
                    tostring(w.cfg.name or id),
                    tostring(name),
                    tostring(cb:IsMouseEnabled()),
                    tostring(w.frame and w.frame:IsShown()),
                    cb:GetFrameLevel(),
                    tostring(cb:GetAttribute("type")),
                    tostring(cb:GetAttribute("spell"))))
            end
        end
    end
    if not any then ns.Print("  (no reminder widgets found — make one show, HUD locked)") end
end)

-- ── sounds : the sounds that SURVIVE the junk filter, with their source path ──
-- So a straggler can be traced to its addon and filtered precisely.
ns.RegisterSlash("sounds", function()
    local hash = ns.Media and ns.Media.SoundList and ns.Media.SoundList()
    local opts = ns.Sound and ns.Sound.Options and ns.Sound.Options() or {}
    local n = 0
    for _, o in ipairs(opts) do
        if type(o.value) == "string" and o.value ~= "" and o.value ~= "__tts__" then
            n = n + 1
            ns.Print(("  %s  |cff808080%s|r"):format(o.text, tostring(hash and hash[o.value])))
        end
    end
    ns.Print(("|cffffd100sounds|r %d SharedMedia sound(s) kept after filtering."):format(n))
end)

ns.RegisterSlash("tts", function(rest)
    local msg = (rest ~= "" and rest) or "Custodian text to speech test"
    local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    local vid = ns.Sound and ns.Sound.Voice and ns.Sound.Voice()
    ns.Print(("|cffffd100tts|r toc=%s voices=%s voiceID=%s — speaking \"%s\""):format(
        tostring(select(4, GetBuildInfo())), tostring(voices and #voices or "?"), tostring(vid), msg))
    if ns.Sound and ns.Sound.Speak then ns.Sound.Speak(msg) end
end)

-- ── Fixers ────────────────────────────────────────────────────────────
ns.RegisterSlash("fixmanual", function()
    local n = ns.RefreshManualTrackers and ns.RefreshManualTrackers() or 0
    if ns.Trackers and ns.Trackers.Rebuild then ns.Trackers.Rebuild() end
    ns.Print(("refreshed |cff40ff40%d|r manual tracker(s) from the current seed (gen/spend lists, aura, duration)."):format(n))
end)

-- ── Spawn a test widget ───────────────────────────────────────────────
ns.RegisterSlash("split", function()
    local target
    for _, id in ipairs(ns.profile.order) do
        local c = ns.profile.widgets[id]
        if c and c.display == "bar" and ns.CfgSpecActive(c, ns.specID) then target = id; break end
    end
    if not target then ns.Print("No bar on this spec to split."); return end
    local c = ns.profile.widgets[target]
    if c.split then c.split = nil else c.split = { at = 5, color = { r = 0.60, g = 0.20, b = 1, a = 1 } } end
    ns.Layout.Rebuild(); ns.Trackers.Rebuild()
    ns.Print(("5+5 split %s on |cffffd100%s|r."):format(c.split and "|cff40ff40on|r" or "|cffff4040off|r", c.name or target))
end)

-- Spawn a "missing pet" reminder for the current spec so the pet tracker can be tested
-- end-to-end (summon/dismiss + the summon-known gate). Mirrors AddEarthShieldWidget. The
-- summon spellID drives both the icon and the "does this build use a pet" gate.
ns.RegisterSlash("testpet", function()
    local PET = {
        HUNTER  = { spellID = 883,   petlessTalent = 466867, reviveWhenDead = 982 },  -- Call Pet; Avian=petless; Revive Pet
        WARLOCK = { spellID = 688,   petlessTalent = 108503 },    -- Summon Imp icon; Grimoire of Sacrifice = petless
        MAGE    = { spellID = 31687,  petlessTalent = 205024 },   -- Water Elemental; Lonely Winter = petless
    }
    local pd = PET[ns.playerClass] or {}
    ns.SpawnWidget(
        { type = "pet", name = "Pet", spellID = pd.spellID,
          petlessTalent = pd.petlessTalent, reviveWhenDead = pd.reviveWhenDead },
        { name = "Pet", reminder = { mode = "missing" }, showText = false, anchor = { x = 0, y = -150 } },
        { kind = "icon", specs = ns.specID, unlock = true,
          print = "Added a |cff40ff40Pet|r reminder — dismiss your pet to see it appear, resummon to clear. On MM Avian Spec it should stay silent. |cffffd100/cust lock|r when done; delete it in the panel afterwards." })
end)

-- Spawn a form reminder for the shapeshift form you're CURRENTLY in (or the first on the
-- bar), so leaving it shows the reminder and shifting back clears it. Self-contained test.
ns.RegisterSlash("testform", function()
    if not GetShapeshiftFormInfo then ns.Print("No shapeshift API on this class."); return end
    local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    if n == 0 then ns.Print("No shapeshift forms on your bar (form trackers are Druid / Shadow Priest / Prot Warrior)."); return end
    local pick = 1
    for i = 1, n do local _, act = GetShapeshiftFormInfo(i); if act then pick = i; break end end
    local _, _, _, sid = GetShapeshiftFormInfo(pick)
    local nm = (sid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or "Form"
    ns.SpawnWidget(
        { type = "form", name = nm, spellID = sid },
        { name = nm, reminder = { mode = "missing" }, showText = false, anchor = { x = 0, y = -150 } },
        { kind = "icon", specs = ns.specID, unlock = true,
          print = ("Added a |cff40ff40%s|r reminder — leave the form to see it, shift back to clear (click it OOC to shift in). |cffffd100/cust lock|r when done."):format(nm) })
end)

-- Spawn an "ally buff missing" reminder for a given spellID so the ally tracker can be
-- tested end-to-end (put the buff on a group member -> clears; out on nobody -> shows).
ns.RegisterSlash("testally", function(rest)
    local sid = tonumber(rest:match("(%d+)"))
    if not sid then ns.Print("usage: |cffffd100/cust testally <spellID>|r"); return end
    local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or "Ally buff"
    ns.SpawnWidget(
        { type = "ally", spellID = sid, name = nm },
        { name = nm, reminder = { mode = "missing" }, showText = false, anchor = { x = 0, y = -150 } },
        { kind = "icon", specs = ns.specID, unlock = true,
          print = ("Added a |cff40ff40%s (on ally)|r reminder — put the buff on a group member to clear it; it shows when it's out on nobody. |cffffd100/cust lock|r when done."):format(nm) })
end)

-- ── The index ─────────────────────────────────────────────────────────
-- Developer / support probes — listed here (not in the main help) so they stay out of a normal
-- player's way but remain discoverable when diagnosing something. They all still run directly
-- (e.g. /cust shatter); this is just the index. Grouped by what they do.
function ns.DebugHelp()
    ns.Print("|cff1784d1Custodian|r developer probes  |cff808080(/cust <name>)|r")
    ns.Print("  |cff8fb8e0read-outs|r  secrets · why · track [id] · aura <id|name> · imbue · imbuegate · shatter · es [off] · voidmeta [id] · poison · pet · pets · manualaura · cats · browse · glow · curve · grpdbg · castdbg · dbg · buffs · sounds · tts [msg]")
    ns.Print("  |cff8fb8e0live logs (toggle)|r  log · auradbg · glowdbg · casts · manuallog")
    ns.Print("  |cff8fb8e0spawn a test widget|r  testpet · testform · testally <id> · earthshield · split")
    ns.Print("  |cff8fb8e0fixers|r  fixmanual  (re-seed manual trackers)")
    ns.Print("  |cff8fb8e0Tracked-Bar icons|r  cdmicon · cdmsize <n> · cdmdir <h|v> · cdmgap <n>")
end
ns.RegisterSlash("debug", ns.DebugHelp)
ns.RegisterSlash("dev",   ns.DebugHelp)

-- ══ Probe implementations (moved out of Core/Spells.lua) ════════════
-- These were interleaved with Spells.lua's load-bearing wrappers; the wrappers they
-- call (ns.SpellKnown / ns.AuraSecretInCombat / ns.AuraTrackability / ns.CooldownViewerInfo /
-- ns.SearchSpells / ns.BrowseSpells) stay there and resolve as ns.* at call time.

-- Diagnostics for `/cust track <id>`: what an aura / cooldown lookup returns for
-- a spell, and which fields are secret — run it in AND out of combat to compare.
function ns.TrackerDebug(input)
    local id = tonumber(input)
    if not id then ns.Print("usage: |cffffd100/cust track <spellID>|r"); return end
    local function sv(v) return ns.IsSecret(v) and "<secret>" or tostring(v) end
    ns.Print(("|cffffd100track|r %d (%s) known=%s combat=%s"):format(
        id, tostring(C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)),
        tostring(ns.SpellKnown(id)), tostring(InCombatLockdown())))

    local a = ns.PlayerAura(id)
    if a then
        ns.Print(("  aura FOUND by exact id: name=%s stacks=%s expiration=%s"):format(sv(a.name), sv(a.applications), sv(a.expirationTime)))
    else
        ns.Print("  aura: none by that exact id (a buff's aura id often differs from the ability id)")
    end

    -- Name-scan: what the aura tracker's fallback does — reveals the buff's REAL
    -- aura spellId (and whether even that is secret) so we know the right id.
    local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    if nm and AuraUtil and AuraUtil.ForEachAura then
        local hit
        for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
            pcall(AuraUtil.ForEachAura, "player", filter, nil, function(au)   -- 12.1.0: errors when secret
                if au and not ns.IsSecret(au.name) and au.name == nm then hit = au; return true end
            end, true)
            if hit then break end
        end
        if hit then
            ns.Print(("  name-scan: FOUND '%s' -> aura spellId=%s"):format(nm, sv(hit.spellId)))
        else
            ns.Print(("  name-scan: no active player aura named '%s'"):format(tostring(nm)))
        end
    end

    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
    if cd then
        ns.Print(("  cd: isActive=%s isEnabled=%s start=%s dur=%s"):format(
            sv(cd.isActive), sv(cd.isEnabled), sv(cd.startTime), sv(cd.duration)))
    else
        ns.Print("  cd: GetSpellCooldown = nil")
    end

    -- Cooldown-Manager data: dump EVERY field so we can see which one (if any) carries
    -- readable start/duration IN COMBAT. Run this right after casting, in combat.
    local cvi = ns.CooldownViewerInfo(id)
    if cvi then
        ns.Print("  cd-viewer fields:")
        for k, v in pairs(cvi) do
            ns.Print(("    |cff9fd6ff%s|r = %s"):format(tostring(k), sv(v)))
        end
    else
        ns.Print("  cd-viewer: |cffff8080not in the tracked set|r (falls back to isActive heuristic)")
    end

    local secret = ns.AuraSecretInCombat(id)
    ns.Print(("  aura-secret-in-combat=%s%s"):format(tostring(secret),
        secret == true and "  |cffffcc00(aura tracker won't see it in combat -> use a Cooldown tracker)|r" or ""))
end

-- /cust why : dump every reminder widget's LIVE snapshot + visibility verdict, so we can
-- see exactly why a reminder is/isn't showing (present wrong? vis wrong? frame not hiding?
-- move mode forcing it on?). Run it IN combat with the buffs up.
function ns.WhyReminders()
    local sv = function(v) return ns.IsSecret(v) and "<secret>" or tostring(v) end
    ns.Print(("|cffffd100why|r combat=%s moveMode=%s"):format(tostring(InCombatLockdown()), tostring(ns.previewActive and true or false)))
    local n = 0
    for id, w in pairs(ns.widgets or {}) do
        local cfg = w.cfg or {}
        local mode = (cfg.reminder and cfg.reminder.mode) or cfg.showWhen
        if mode then
            n = n + 1
            local snap = w.snap
            local vis  = w.ReminderVisible and w:ReminderVisible(snap)
            local shown = w.frame and w.frame:IsShown()
            local specOK = w.MatchesSpec and w:MatchesSpec(ns.specID)
            local tr = ns.TrackerOf(cfg)
            local trk = (tr and tr.spellID and ns.AuraTrackability and ns.AuraTrackability(tr.spellID)) or "-"
            ns.Print(("  %s [%s]: present=%s active=%s vis=%s shown=%s spec=%s track=%s exp=%s"):format(
                tostring(cfg.name or id), tostring(mode),
                snap and sv(snap.present) or "NO-SNAP", snap and sv(snap.active) or "-",
                tostring(vis), tostring(shown), tostring(specOK), tostring(trk),
                snap and sv(snap.expiration) or "-"))
        end
    end
    if n == 0 then ns.Print("  (no reminder widgets active on this spec)") end
end

-- ── /cust secrets : batch trackability probe ──────────────────────────
-- Calibration for the "will this actually track in combat?" classifier. For each of
-- this class's aura picks, and every active buff, it reports (secret-safely) what
-- ShouldSpellAuraBeSecret claims vs what the LIVE aura read returns. Run it OUT of
-- combat, then AGAIN in combat (on a target dummy), and paste both — the difference
-- between the two states is exactly what we need to tell trustworthy picks from traps.
-- Correct AURA ids (not ability ids) for calibration — the KEY question is whether
-- GetSpellAuraSecrecy returns a stable classification OUT of combat (an add-time oracle),
-- since ShouldSpellAuraBeSecret only tells the truth once you're already in combat.
local SECRET_CALIB = {
    { 192106, "Lightning Shield (secret in combat)" },
    { 383648, "Earth Shield self (readable in combat)" },
    { 344179, "Maelstrom Weapon (readable in combat)" },
    { 52127,  "Water Shield" },
    { 462854, "Skyfury (readable in combat)" },
    { 108271, "Astral Shift (defensive)" },
}

function ns.SecretScan()
    local sv = function(v) return ns.IsSecret(v) and "<secret>" or tostring(v) end
    ns.Print(("|cffffd100secret scan|r  combat=%s  — run OOC first (tests the add-time oracle), then in combat."):format(tostring(InCombatLockdown())))

    -- Global secrecy state + the full C_Secrets query surface.
    local function flag(fn)
        if not (C_Secrets and C_Secrets[fn]) then return fn .. "=?" end
        local ok, v = pcall(C_Secrets[fn])
        return fn .. "=" .. (ok and tostring(v) or "err")
    end
    ns.Print("  state: " .. flag("HasSecretRestrictions") .. "  " .. flag("ShouldAurasBeSecret") .. "  " .. flag("ShouldCooldownsBeSecret"))

    -- Secrecy getter (candidate oracle) — pcall-guarded, may not exist / may error.
    local function secrecyOf(id)
        if not (C_Secrets and C_Secrets.GetSpellAuraSecrecy) then return "?" end
        local ok, v = pcall(C_Secrets.GetSpellAuraSecrecy, id)
        return ok and tostring(v) or "err"
    end

    local function probe(id, label)
        if not id then return end
        local known  = ns.SpellKnown and ns.SpellKnown(id)
        local should = ns.AuraSecretInCombat and ns.AuraSecretInCombat(id)
        local live, stacks = "nil", "-"
        local data = ns.PlayerAura(id)
        if data then live, stacks = "FOUND", sv(data.applications) end
        ns.Print(("  %s (%s): known=%s should=%s secrecy=%s live=%s stacks=%s"):format(
            tostring(label or id), tostring(id), tostring(known), tostring(should), secrecyOf(id), live, stacks))
    end

    -- Known correct-id calibration (the important test — read this OOC).
    ns.Print("  — known aura ids (calibration) —")
    for _, e in ipairs(SECRET_CALIB) do probe(e[1], e[2]) end

    -- Every active buff: id + its secrecy getter (only when the id is readable, i.e. OOC).
    ns.Print("  — active HELPFUL auras —")
    if AuraUtil and AuraUtil.ForEachAura then
        local n = 0
        pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(au)
            if au then
                n = n + 1
                local sid = au.spellId
                local sec = (not ns.IsSecret(sid)) and secrecyOf(sid) or "-"
                ns.Print(("    %s (id=%s) secrecy=%s stacks=%s"):format(sv(au.name), sv(sid), sec, sv(au.applications)))
            end
        end, true)
        if n == 0 then ns.Print("    (none visible — all secret, or no buffs up)") end
    end
end

-- Diagnostics for `/cust imbue`: dump the temporary WEAPON ENCHANT state for both
-- hands, flagging which fields are secret. Windfury / Flametongue Weapon are
-- imbues (not auras), so this is how the "imbue missing" reminder sees them —
-- run it in AND out of combat to learn whether presence/expiry go secret there.
function ns.ImbueDebug()
    if not GetWeaponEnchantInfo then ns.Print("GetWeaponEnchantInfo unavailable on this client."); return end
    local function sv(v) return ns.IsSecret(v) and "<secret>" or tostring(v) end
    local mhHas, mhMs, mhCh, mhId, ohHas, ohMs, ohCh, ohId = GetWeaponEnchantInfo()
    ns.Print(("|cffffd100imbue|r combat=%s"):format(tostring(InCombatLockdown())))
    ns.Print(("  main-hand: has=%s msLeft=%s charges=%s enchantID=%s"):format(sv(mhHas), sv(mhMs), sv(mhCh), sv(mhId)))
    ns.Print(("  off-hand : has=%s msLeft=%s charges=%s enchantID=%s"):format(sv(ohHas), sv(ohMs), sv(ohCh), sv(ohId)))
    ns.Print("  (note: imbues usually read live in combat, duration included; Windfury MH has been seen to read has=false while still up in the odd fight, so the reminder trusts a live 'true' and only falls back to the out-of-combat state on a 'false')")
end

-- ── /cust es : probe Earth Shield tracking (self + ally presence, readability) ──
-- With Therazane's Resilience, Earth Shield has no charges + 60min → a pure presence
-- maintenance tracker for 2 shields (self + an ally, via Elemental Orbit). This probe
-- answers the load-bearing unknown: can we READ self/ally ES presence in combat, or is
-- it secret? Plus a cast logger to see how to capture WHICH ally we shielded.
local ES_ID = 974
local esWatch
function ns.EarthShieldProbe(arg)
    -- The cast logger below stays armed for the rest of the session once the probe runs, so
    -- `/cust es off` tears it down again — a dev logger shouldn't outlive the probe session.
    if arg == "off" then
        if esWatch then
            esWatch:UnregisterAllEvents(); esWatch:SetScript("OnEvent", nil); esWatch = nil
            ns.Print("|cffffd100es|r cast logging |cffff4040OFF|r.")
        else
            ns.Print("|cffffd100es|r cast logging wasn't running.")
        end
        return
    end
    ns.Print(("|cffffd100es|r Earth Shield (%d) — self + ally probe (run OOC and in COMBAT)"):format(ES_ID))
    local function fld(v)
        if ns.IsSecret and ns.IsSecret(v) then return "|cffff4040<secret>|r" end
        local ok, str = pcall(tostring, v); return ok and str or "?"
    end

    -- SELF
    local a = ns.PlayerAura(ES_ID)
    if type(a) == "table" then
        ns.Print(("  |cff40ff40SELF: present|r  stacks=%s dur=%s exp=%s"):format(
            fld(a.applications), fld(a.duration), fld(a.expirationTime)))
    else
        ns.Print("  |cffff8040SELF: not present|r (or hidden in combat)")
    end
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, sec = pcall(C_Secrets.ShouldSpellAuraBeSecret, ES_ID)
        ns.Print(("  ShouldSpellAuraBeSecret(%d) = %s"):format(ES_ID, ok and tostring(sec) or "?"))
    end

    -- Unified scan by NAME (self ES may be a different spellID than the ally's 974,
    -- so match the localized name + source=player to catch BOTH slots at once).
    local ES_NAME = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(ES_ID)) or "Earth Shield"
    ns.Print(("  scanning group for a player-sourced \"%s\" aura:"):format(ES_NAME))
    local units = { "player" }
    if IsInRaid() then for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else for i = 1, 4 do units[#units + 1] = "party" .. i end end
    local selfHit, allyHits = false, 0
    for _, u in ipairs(units) do
        if UnitExists(u) and AuraUtil and AuraUtil.ForEachAura then
            local found
            pcall(AuraUtil.ForEachAura, u, "HELPFUL", nil, function(aura)
                if aura and (aura.spellId == ES_ID or aura.name == ES_NAME) then found = aura; return true end
            end, true)
            if found and found.sourceUnit == "player" then
                if u == "player" then selfHit = true else allyHits = allyHits + 1 end
                ns.Print(("    |cff40ff40%s|r %s (%s): spellId=%s name=%q"):format(
                    u == "player" and "SELF" or "ALLY", UnitName(u) or u, u, fld(found.spellId), tostring(found.name)))
            end
        end
    end
    ns.Print(("  |cffffd100shields out: %d/2|r  (self=%s, ally=%d)"):format(
        (selfHit and 1 or 0) + math.min(allyHits, 1), tostring(selfHit), allyHits))
    if not selfHit then ns.Print("  |cffff8040self not found — note the SELF spellId above once it appears (it differs from 974).|r") end

    -- Cast logger: reveals the target NAME captured at cast time (for the ally slot).
    if not esWatch then
        esWatch = CreateFrame("Frame")
        esWatch:RegisterEvent("UNIT_SPELLCAST_SENT")
        esWatch:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        esWatch:SetScript("OnEvent", function(_, ev, ...)
            if ev == "UNIT_SPELLCAST_SENT" then
                local unit, target, _, spellID = ...
                if unit == "player" and spellID == ES_ID then
                    ns.Print(("  |cffffd100SENT|r ES → target=|cff40ff40%s|r"):format(tostring(target)))
                end
            else
                local unit, _, spellID = ...
                if unit == "player" and spellID == ES_ID then
                    ns.Print("  |cffffd100SUCCEEDED|r ES cast landed")
                end
            end
        end)
        ns.Print("  |cff808080cast logging ON — cast Earth Shield to see the captured target name. /cust es off to stop.|r")
    end
end

-- ── /cust cdm : dump the Tracked Bars viewer's live frame structure ────────
-- Read-only probe so we can design a "bar -> movable icon" restyle against the
-- real regions instead of guessing. Prints the container, how it stores items,
-- and one item's regions + Lua-side fields (Icon / Cooldown swipe / text / the
-- cooldownID + auraInstanceID data hooks). Run with at least one Tracked Bar
-- active. See mem:custodian-project CDM research + mem:midnight-secrets.
-- combat-safe accessor: nil if it errors OR yields a secret value (so reading a
-- hidden spell icon / name in combat degrades gracefully instead of aborting).
local function accS(fn, o)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, o)
    if not ok then return nil end
    if ns.IsSecret and ns.IsSecret(v) then return nil end
    return v
end

local function objDesc(o)
    if type(o) ~= "table" or not o.GetObjectType then
        if ns.IsSecret and ns.IsSecret(o) then return "|cffff4040<secret>|r" end
        return tostring(o)
    end
    local ot = accS(o.GetObjectType, o) or "?"
    local extra = ""
    if ot == "FontString" then
        local t = accS(o.GetText, o)
        if t and t ~= "" then extra = (" text=%q"):format(tostring(t))
        elseif t == nil then extra = " |cffff4040<text hidden>|r" end
    elseif ot == "Texture" then
        local atlas = accS(o.GetAtlas, o)
        local tex = (not atlas) and accS(o.GetTextureFilePath, o)
        if atlas then extra = " atlas=" .. tostring(atlas)
        elseif tex then extra = " tex=" .. tostring(tex)
        else extra = " |cffff4040<art hidden>|r" end
    end
    local w, h = accS(o.GetSize, o) or 0, 0
    local sz = { pcall(o.GetSize, o) }
    if sz[1] then w, h = sz[2] or 0, sz[3] or 0 end
    return ("%s [%dx%d shown=%s]%s"):format(ot, math.floor((w or 0) + 0.5), math.floor((h or 0) + 0.5), tostring(accS(o.IsShown, o)), extra)
end

local function dumpItem(item, label)
    ns.Print(("  |cffffd100%s|r %s"):format(label, objDesc(item)))
    -- Lua-side named fields Blizzard sets on the item (regions + data hooks)
    local named = {}
    for k, v in pairs(item) do
        if type(k) == "string" and type(v) ~= "function" then named[#named + 1] = k end
    end
    table.sort(named)
    for _, k in ipairs(named) do
        local v = item[k]
        if ns.IsSecret and ns.IsSecret(v) then
            ns.Print(("      .%s = |cffff4040<secret in combat>|r"):format(k))
        elseif type(v) == "table" and v.GetObjectType then
            ns.Print(("      .%s = %s"):format(k, objDesc(v)))
        else
            ns.Print(("      .%s = %s"):format(k, tostring(v)))
        end
    end
    -- Anonymous regions (unnamed textures/fontstrings) + child frames
    if item.GetRegions then
        local regs = { item:GetRegions() }
        for i, r in ipairs(regs) do ns.Print(("      region[%d] %s"):format(i, objDesc(r))) end
    end
    if item.GetChildren then
        local kids = { item:GetChildren() }
        for i, c in ipairs(kids) do ns.Print(("      child[%d] %s"):format(i, objDesc(c))) end
    end
end

function ns.CDMDebug()
    local v = _G.BuffBarCooldownViewer
    ns.Print("|cffffd100cdm|r Tracked Bars = |cffffd100BuffBarCooldownViewer|r")
    if not v then
        ns.Print("  frame does NOT exist. Enable it: Edit Mode → check |cff40ff40Tracked Bars|r, and add at least one bar in the Cooldown Manager settings.")
        return
    end
    local w, h = v:GetSize()
    ns.Print(("  container: shown=%s %dx%d scale=%.2f strata=%s"):format(
        tostring(v:IsShown()), math.floor(w + 0.5), math.floor(h + 0.5), v:GetScale() or 1, tostring(v:GetFrameStrata())))

    -- How does it STORE its item frames? Probe common patterns + dump table keys.
    local storeKeys = {}
    for k, val in pairs(v) do
        if type(k) == "string" and type(val) ~= "function" then
            storeKeys[#storeKeys + 1] = ("%s=%s"):format(k, type(val) == "table" and "table" or tostring(val))
        end
    end
    table.sort(storeKeys)
    ns.Print("  container fields: " .. (next(storeKeys) and table.concat(storeKeys, ", ") or "(none)"))

    -- Collect item frames: prefer the mixin's own accessor, else scan children.
    local items = {}
    if v.GetItemFrames then
        local ok, list = pcall(v.GetItemFrames, v)
        if ok and type(list) == "table" then for _, it in ipairs(list) do items[#items + 1] = it end end
    end
    if #items == 0 then
        for _, c in ipairs({ v:GetChildren() }) do
            -- an item looks like a frame carrying an Icon or a cooldownID
            if type(c) == "table" and (c.Icon or c.cooldownID or c.GetCooldownID) then items[#items + 1] = c end
        end
    end
    ns.Print(("  found |cff40ff40%d|r item frame(s)%s"):format(#items,
        v.GetItemFrames and " (via GetItemFrames)" or " (via child scan)"))

    if #items == 0 then
        ns.Print("  no items — add a tracked bar (e.g. a buff you have up) so an item exists to inspect, then rerun.")
        -- still show the raw children so we can see the layout scaffolding
        for i, c in ipairs({ v:GetChildren() }) do ns.Print(("  rawchild[%d] %s"):format(i, objDesc(c))) end
        return
    end

    -- Prefer an ACTIVE item (buff currently up): inactive items have a blank icon
    -- and no timer, so an active one reveals the swipe + timer text we'd reuse.
    local pick, pickIdx = items[1], 1
    for i, it in ipairs(items) do if it.isActive then pick, pickIdx = it, i; break end end
    if not pick.isActive then
        ns.Print("  |cffff8040NOTE: no active bar right now — icon/timer are blank. Rerun with a tracked buff UP for the swipe + timer picture.|r")
    end
    dumpItem(pick, ("item[%d]"):format(pickIdx))

    -- One level deeper into the composite subframes: this is where the actual icon
    -- texture, the Cooldown SWIPE, and the timer FontString actually live.
    for _, key in ipairs({ "Icon", "Bar", "DebuffBorder" }) do
        local sf = pick[key]
        if type(sf) == "table" and sf.GetObjectType then
            ns.Print(("    |cff29b3ff.%s|r contents:"):format(key))
            local named = {}
            for k, val in pairs(sf) do
                if type(k) == "string" and type(val) == "table" and val.GetObjectType then named[#named + 1] = k end
            end
            table.sort(named)
            for _, k in ipairs(named) do ns.Print(("        .%s = %s"):format(k, objDesc(sf[k]))) end
            if sf.GetRegions then for i, r in ipairs({ sf:GetRegions() }) do ns.Print(("        region[%d] %s"):format(i, objDesc(r))) end end
            if sf.GetChildren then for i, c in ipairs({ sf:GetChildren() }) do ns.Print(("        child[%d] %s"):format(i, objDesc(c))) end end
        end
    end

    -- What does the item expose READABLY? (decides sweep via readable vs. secret SetCooldown.)
    local ci = pick.cooldownInfo
    if type(ci) == "table" then
        ns.Print("    |cff29b3ff.cooldownInfo|r:")
        local keys = {}
        for k in pairs(ci) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = ci[k]
            if ns.IsSecret and ns.IsSecret(val) then
                ns.Print(("        %s = |cffff4040<secret in combat>|r"):format(tostring(k)))
            else
                local okv, sv = pcall(function() return tostring(val) end)
                ns.Print(("        %s = %s"):format(tostring(k), okv and sv or "|cffff4040<blocked>|r"))
            end
        end
    end

    for i = 1, #items do
        if i ~= pickIdx then ns.Print(("  |cff808080item[%d]|r %s active=%s"):format(i, objDesc(items[i]), tostring(items[i].isActive))) end
    end
end

-- ── /cust cats : dump C_CooldownViewer category sets (the data-driven wizard's source) ──
-- Ground-truth probe: for the CURRENT spec, list every spell Blizzard groups under each
-- category (Essential / Utility / TrackedBuff / TrackedBar), with its flags and OUR
-- trackability verdict. This tells us whether a data-driven guided wizard can replace the
-- hand-curated ClassKit picks — and exactly what it would auto-offer. Run OUT OF COMBAT
-- (the trackability oracle only classifies OOC). NOTE: trackability is queried with the
-- cooldown's spellID, which for some buffs differs from the real AURA id (ability≠aura) —
-- those read "unknown" here but resolve once the wizard learns the aura id. The one-time
-- schema dump below shows the full info shape so we can spot an aura-id field if one exists.
local function cdmName(sid)
    if not sid then return "?" end
    if C_Spell and C_Spell.GetSpellName then
        local ok, nm = pcall(C_Spell.GetSpellName, sid)
        if ok and nm then return nm end
    end
    return "?"
end

function ns.CDMCats()
    local C = C_CooldownViewer
    if not (C and C.GetCooldownViewerCategorySet and C.GetCooldownViewerCooldownInfo) then
        ns.Print("|cffff4040cdm cats|r C_CooldownViewer not available on this build."); return
    end
    local cats = Enum and Enum.CooldownViewerCategory
    if type(cats) ~= "table" then ns.Print("|cffff4040cdm cats|r Enum.CooldownViewerCategory missing."); return end

    -- category value -> name, in stable numeric order
    local order = {}
    for name, val in pairs(cats) do order[#order + 1] = { name = name, val = val } end
    table.sort(order, function(a, b) return a.val < b.val end)

    local specName = "?"
    if GetSpecialization and GetSpecializationInfo then
        local i = GetSpecialization()
        if i then local _, nm = GetSpecializationInfo(i); specName = nm or "?" end
    end
    ns.Print(("|cffffd100cdm cats|r — |cff40c0ff%s|r"):format(specName))
    if InCombatLockdown() then ns.Print("  |cffe6a53c⚠ in combat — trackability shows 'unknown'; re-run out of combat.|r") end

    local sampleInfo   -- first info table seen, for a one-time full-schema dump
    for _, c in ipairs(order) do
        local ok, ids = pcall(C.GetCooldownViewerCategorySet, c.val)
        local list = (ok and type(ids) == "table") and ids or {}
        ns.Print(("|cff40c0ff%s|r (%d)"):format(c.name, #list))
        for _, cdID in ipairs(list) do
            local ok2, info = pcall(C.GetCooldownViewerCooldownInfo, cdID)
            if ok2 and type(info) == "table" then
                sampleInfo = sampleInfo or info
                local sid = info.overrideSpellID or info.spellID
                local flags = ("self=%s aura=%s known=%s ch=%s"):format(
                    info.selfAura and "Y" or "n", info.hasAura and "Y" or "n",
                    info.isKnown and "Y" or "n", info.charges and "Y" or "n")
                local track = (sid and ns.AuraTrackability and ns.AuraTrackability(sid)) or "-"
                local tcol = (track == "live") and "|cff5ec888" or (track == "hidden") and "|cffe6a53c" or "|cff808080"
                ns.Print(("   %s |cffffffff%s|r  %s  %s%s|r"):format(tostring(sid or "?"), cdmName(sid), flags, tcol, track))
            else
                ns.Print(("   cdID %s → |cffff4040<no info>|r"):format(tostring(cdID)))
            end
        end
    end

    if sampleInfo then
        local keys = {}
        for k in pairs(sampleInfo) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = ("%s=%s"):format(k, tostring(sampleInfo[k])) end
        ns.Print("|cff808080info schema:|r " .. table.concat(parts, "  "))
    end
    ns.Print("|cff808080TrackedBuff/TrackedBar with self=Y = maintenance-buff candidates. Imbues + resources come from elsewhere (weapon slots / power types).|r")
end
