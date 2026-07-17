-- Core/Maintenance.lua — the curated per-class SEED for the guided wizard.
--
-- This is the ONLY hand-maintained per-class data in Custodian (ClassKit is retired — its
-- resources / specials moved here). Everything else the wizard offers is data-driven: the
-- "Browse your spec" list comes from C_CooldownViewer. This table lists what the game data
-- CANNOT tell us — the buffs / imbues / forms / pets a spec actively MAINTAINS (proven: the
-- Cooldown Manager omits Skyfury and Blessing of the Bronze while listing 30+ procs), plus the
-- resource bars a spec uses and any ready-made "special" widgets. Source: class research sheet.
--
-- Per class:
--   raid            — the class-wide buff (all specs), if any.
--   [specID]        — that spec's own maintenance list (a spec's Recommended = raid + this).
--   resources       — power-type KEYS this class can use (Trackers/Power.lua POWER map). Filters
--                     the Resource chips + the editor's Resource dropdown to what's relevant.
--   resourcesBySpec — [specID] -> resource list, when a class's bars differ per spec (UnitPowerMax
--                     isn't spec-aware for some secondary bars, e.g. Maelstrom on all Shaman specs).
--                     An entry is a power KEY (string) or an aura-stack DESCRIPTOR
--                     { name, auraId, max, segments } for a "resource" that's really an aura.
--   specials        — ready-made class widgets that ride a dedicated tracker (not the pick→spell
--                     flow). Each = { name, sub, icon, tab, confirm?, add = function() -> widgetId }.
--
-- Keyed by class token (UnitClassBase) then by numeric specID (localization-safe — the old
-- English spec-NAME keys broke on non-English clients; the spec name is kept as a comment).
--
-- Entry mechanics:
--   aura   — a self / raid buff (aura tracker; `name` resolves the spellID at runtime).
--            `cast`/`aura` optional when the CAST id differs from the AURA id (Earth Shield).
--   imbue  — a temporary weapon enchant (`slot` = "main" | "off" | "either").
--   form   — a shapeshift / stance you should be in.
--   pet    — a pet / guardian that should be up. `spellID` = the summon (icon only). Petless-
--            by-design builds are gated so they never nag: `petlessTalent` (a talent that LOCKS
--            pets out — the summon stays KNOWN when locked, so we check the talent, not the
--            summon) or `petlessAura` (a buff that converts the pet away — Warlock Grim. of Sac.).
--            Click-to-cast (OOC): the user picks WHICH summon — Hunter Call Pet SLOT 1-5 (static
--            ids 883 / 83242-83245; the beast in each slot is dynamic), or a Warlock demon by
--            name. `reviveWhenDead` (Hunter Revive Pet 982) is cast instead when the pet is dead.
--   ally   — a buff kept on someone ELSE (`unit = "ally"`).
--   research = true — trackability unconfirmed; stubbed until probed (ally cases).
--
-- Optional on an `aura` entry — mutually-exclusive variants the USER picks:
--   choose  — list of interchangeable auras (e.g. Paladin Devotion vs Concentration);
--             the entry's `name` is the initial pick, the user can switch to any other.
-- We track the CHOSEN aura specifically, so being on the WRONG one (a Paladin still on
-- Crusader Aura after mounting) reads as "missing" and reminds — no special-case logic.
--
-- IDs are omitted on `aura`/`imbue` entries on purpose — names are authoritative (from the
-- sheet) and the trackers resolve name -> spellID -> aura at runtime.

local ADDON, ns = ...

-- Bump whenever a MANUAL tracker's mechanic data below changes (gen/con lists, aura, duration…),
-- so the migration in Defaults.lua re-applies the current seed onto widgets added earlier.
ns.MANUAL_SEED_VER = 4

-- Rogue poisons are AURAS, not weapon enchants (confirmed via /cust poison — GetWeaponEnchantInfo
-- reads has=false). Tracked as "any lethal / any non-lethal" (matchAny) so the reminder works
-- whichever poison you apply; the aura tracker resolves each id to its buff by name, so listing
-- the ability id is fine (ability≠buff, e.g. Crippling 3409/buff 3408). Leeching Poison (108211)
-- is a PASSIVE talent that's ALWAYS up → deliberately EXCLUDED (matching by id sidesteps the
-- name-match false positive). All ids below are the actual applied-BUFF ids (confirmed via
-- /cust poison reading aura.spellId) — the COMPLETE set of retail rogue poisons.
local ROGUE_LETHAL    = { 315584, 2823, 8679, 381664 }   -- Instant, Deadly, Wound, Amplifying
local ROGUE_NONLETHAL = { 3408, 381637, 5761 }            -- Crippling, Atrophic, Numbing
-- Dragon-Tempered Blades: lets you run a 2nd lethal AND 2nd non-lethal at once. The category
-- trackers require 1 of each normally, 2 of each while it's taken (fail-closed, so a respec out
-- of it drops back to 1 — never nags for a slot you can't fill). Applied via requireCountTalent.
local ROGUE_DTB       = 381801
local ROGUE_2X        = { talent = ROGUE_DTB, count = 2 }

-- MANUAL (estimated) stack counters — see Trackers/Manual.lua for how they work and why
-- they're inherently approximate. Spell lists cross-checked against the TIPSRedux (Tip of the
-- Spear) and SenseiClassResourceBar (Improved Whirlwind) addons for the current 12.0 rework,
-- then adapted to our engine. Re-verify live with |cffffd100/cust casts|r (logs each cast's
-- id+name) and |cffffd100/cust manuallog|r (logs count changes) if a patch shifts them.
--   gen = casts that ADD stacks (a talent table { base, talent, boost } is conditional)
--   con = casts that SPEND a stack (default 1). A spell in BOTH gen+con nets the difference.
--
-- Tip of the Spear (Survival Hunter) — 3 stacks, 10s window:
--   Kill Command grants 1 (2 with Primal Surge 1272154). Takedown is normally a spender, but
--   with Twin Fangs (1272139) it grants 3 and self-consumes 1 (net +2). Everything else spends 1.
local TIP_OF_THE_SPEAR = { m = "manual", name = "Tip of the Spear", spellID = 260285, max = 3, duration = 10,
    aura = 260286,   -- VERIFY the Tip of the Spear BUFF id via /cust buffs (OOC ground-truth sync)
    gen = {
        [259489]  = { base = 1, talent = 1272154, boost = 1 },   -- Kill Command (+1, or +2 w/ Primal Surge)
        [1253859] = { base = 0, talent = 1272139, boost = 3 },   -- Takedown (base): +3 only w/ Twin Fangs
        [1250646] = { base = 0, talent = 1272139, boost = 3 },   -- Takedown (Twin Fangs variant)
    },
    con = {
        [186270]  = 1,  -- Raptor Strike
        [1262293] = 1,  -- Raptor Swipe
        [1261193] = 1,  -- Boomstick
        [259495]  = 1,  -- Wildfire Bomb
        [193265]  = 1,  -- Hatchet Toss
        [1264949] = 1,  -- Chakram
        [1262343] = 1,  -- Ranged Raptor Swipe
        [265189]  = 1,  -- Ranged Raptor Strike
        [1251592] = 1,  -- Flamefang Pitch
        [1253859] = 1,  -- Takedown (base): the self-consume that nets +2 with Twin Fangs, or a plain spend without
        [1250646] = 1,  -- Takedown (Twin Fangs variant)
    },
    note = "estimated from your casts (Kill Command / Takedown build; melee & bomb finishers spend)" }
-- Improved Whirlwind (Fury Warrior) — needs the Improved Whirlwind talent (12950); 4 stacks, 20s:
--   Whirlwind refreshes to full. Thunder Clap / Thunder Blast also fill it, but only with the
--   Crashing Thunder talent (436707). Single-target strikes spend one each.
local IMPROVED_WHIRLWIND = { m = "manual", name = "Improved Whirlwind", spellID = 190411, max = 4, duration = 20,
    requiredTalent = 12950,
    aura = 85739,   -- VERIFY the Whirlwind BUFF id via /cust buffs (OOC ground-truth sync)
    gen = {
        [190411] = 4,                                            -- Whirlwind → full
        [6343]   = { base = 0, talent = 436707, boost = 4 },     -- Thunder Clap (only w/ Crashing Thunder)
        [435222] = { base = 0, talent = 436707, boost = 4 },     -- Thunder Blast (only w/ Crashing Thunder)
    },
    aoeGen = { [190411] = true, [6343] = true, [435222] = true },  -- all AoE → range-gate (auto-target can be far)
    con = {
        [23881]  = 1,  -- Bloodthirst
        [85288]  = 1,  -- Raging Blow
        [280735] = 1,  -- Execute
        [5308]   = 1,  -- Execute (base)
        [202168] = 1,  -- Impending Victory
        [184367] = 1,  -- Rampage
        [335096] = 1,  -- Bloodbath
        [335097] = 1,  -- Crushing Blow
    },
    note = "estimated from your casts — needs the Improved Whirlwind talent" }

ns.Maintenance = {

  DEATHKNIGHT = {
    -- No raid buff — utility only (Death Grip, Gorefiend's Grasp). Runeforging is a PERMANENT
    -- weapon enchant, not a temporary imbue, so it isn't tracked. Nothing to maintain.
    resources = { "RUNIC_POWER", "RUNES" },
    [250] = {},   -- Blood
    [251] = {},   -- Frost
    -- Unholy's ghoul (Raise Dead) is a PERMANENT pet that fills the pet slot, so the pet tracker
    -- reads it like the Frost Water Elemental. Resummon with Raise Dead when it dies (no revive
    -- spell). (VERIFY 46585 is the Unholy permanent-ghoul summon.)
    [252] = { { m = "pet", name = "Ghoul", spellID = 46585, note = "Raise Dead — keep your ghoul up" } },   -- Unholy
  },

  DEMONHUNTER = {
    -- No raid buff, no out-of-combat maintenance.
    resources = { "FURY", "PAIN" },
    specials = {
      -- Vengeance Soul Fragments: a 6-box bar of the fragments you hold. No aura/power exposes the
      -- count — read via Soul Cleave's cast count (secret in combat, shown secret-safe). Veng-only.
      { name = "Soul Fragments", tab = "display", icon = 228477, sub = "Vengeance",
        add = function() return ns.AddSoulFragVengWidget and ns.AddSoulFragVengWidget() end },
      -- Devourer Void Metamorphosis: a bar of the Soul Fragment pool (0-35/50, Soul Glutton lowers
      -- the cap) that fuels Void Metamorphosis. Reads the Soul Fragments aura stacks. Devourer-only.
      { name = "Void Metamorphosis", tab = "display", icon = 1217607, sub = "Devourer",
        add = function() return ns.AddVoidMetaWidget and ns.AddVoidMetaWidget() end },
    },
    [577]  = {},   -- Havoc
    [581]  = {},   -- Vengeance
    [1480] = {},   -- Devourer (Midnight hero-spec)
  },

  DRUID = {
    raid = { m = "aura", name = "Mark of the Wild" },   -- +3% Versatility, all specs
    resources = { "PRIMARY", "MANA", "RAGE", "ENERGY", "COMBO_POINTS", "LUNAR_POWER" },
    -- Feral & Guardian can each be in Cat OR Bear, so their main resource changes with form
    -- (Energy in Cat, Rage in Bear). "PRIMARY" is one bar that follows the current form's power
    -- and recolours to match — offered ahead of the fixed Energy/Rage bars. Balance = Astral
    -- Power, Resto = Mana.
    resourcesBySpec = {
      [102] = { "LUNAR_POWER", "MANA" },              -- Balance
      [103] = { "PRIMARY", "COMBO_POINTS", "MANA" },  -- Feral   (Energy/Rage by form + combo points)
      [104] = { "PRIMARY", "MANA" },                  -- Guardian(Energy/Rage by form)
      [105] = { "MANA" },                             -- Restoration
    },
    [102] = { { m = "form", name = "Moonkin Form", spellID = 24858 } },   -- Balance
    [103] = { { m = "form", name = "Cat Form",     spellID = 768   } },   -- Feral
    [104] = { { m = "form", name = "Bear Form",    spellID = 5487  } },   -- Guardian
    [105] = {},                                                            -- Restoration (raid buff only)
  },

  EVOKER = {
    raid = { m = "aura", name = "Blessing of the Bronze" },   -- movement-CD reduction, all specs
    resources = { "MANA", "ESSENCE" },
    -- Source of Magic: a talent buff you place on an ALLY mana-user. CONFIRMED readable on the
    -- ally (with our source) in AND out of combat via /cust ally 369459 → live ally tracker.
    [1467] = { { m = "ally", name = "Source of Magic", unit = "ally", note = "place on an ally healer" } },   -- Devastation
    [1468] = { { m = "ally", name = "Source of Magic", unit = "ally", note = "place on an ally mana-user" } },-- Preservation
    [1473] = {   -- Augmentation
      -- Ebon Might is group-wide and the CASTER gets it too, so it's tracked as a normal SELF
      -- aura (no ally scan needed) — maintain it on yourself and your allies are covered.
      { m = "aura", name = "Ebon Might" },
      { m = "ally", name = "Source of Magic", unit = "ally", note = "place on an ally healer" },
    },
  },

  HUNTER = {
    -- No OOC maintenance buff. (Hunter's Mark is a TARGET debuff, swappable mid-combat — messy to
    -- track cleanly, so it's deferred as a possible future "target debuff" feature, not seeded.)
    resources = { "FOCUS" },
    -- Pet tracker CONFIRMED working in and out of combat. MM is petless by DEFAULT (Avian
    -- Specialization locks Call Pet out — the summon stays known, so gate on the TALENT);
    -- Unbreakable Bond gives the pet back. BM/Survival are always-pet. Click-to-cast lets the
    -- user pick a Call Pet SLOT (1-5); reviveWhenDead=982 casts Revive Pet on a dead pet.
    [253] = { { m = "pet", name = "Pet", spellID = 883, reviveWhenDead = 982 } },   -- Beast Mastery
    [254] = { { m = "pet", name = "Pet", spellID = 883, petlessTalent = 466867, reviveWhenDead = 982,   -- Marksmanship
               note = "Avian Spec (default) = petless; a pet needs Unbreakable Bond" } },
    [255] = {   -- Survival
      { m = "pet", name = "Pet", spellID = 883, reviveWhenDead = 982 },
      TIP_OF_THE_SPEAR,
    },
  },

  MAGE = {
    raid = { m = "aura", name = "Arcane Intellect" },    -- +3% Intellect, all specs
    resources = { "MANA", "ARCANE_CHARGES" },
    -- Per-spec bars: Arcane Charges is Arcane-only, and Frost's Icicles are a 5-stack AURA
    -- (205473) — a segmented aura bar (like Enhancement Maelstrom Weapon), reading the real count
    -- secret-safe rather than estimating. Fire is just mana.
    resourcesBySpec = {
      [62] = { "MANA", "ARCANE_CHARGES" },                                                    -- Arcane
      [63] = { "MANA" },                                                                       -- Fire
      [64] = { "MANA", { name = "Icicles", auraId = 205473, max = 5, segments = true } },      -- Frost
    },
    specials = {
      -- Frost Shatter: the target's Shatter debuff (1246769) — a SECRET target aura read via the
      -- Cooldown Manager piggyback (needs Shatter in your CDM tracked auras). Frost-spec only.
      { name = "Shatter", tab = "display", icon = 1246769, sub = "Frost · on target",
        confirm = { title = "Needs the Cooldown Manager",
          body = "Shatter is a |cffffd100secret target debuff|r — Custodian can only read it through Blizzard's "
              .. "|cffffffffCooldown Manager|r. Make sure |cffffffffShatter|r is a tracked aura there "
              .. "(|cffffd100Edit Mode \226\134\146 Cooldown Manager \226\134\146 Tracked Bars/Buffs|r); the widget stays empty until it is.\n\n"
              .. "Once added, its options let you |cffffffffhide the game's own Shatter icon|r so it isn't shown twice." },
        add = function() return ns.AddShatterWidget and ns.AddShatterWidget() end },
    },
    [62] = {},   -- Arcane (Arcane Familiar is baked into Arcane Intellect — nothing extra to maintain)
    [63] = {},                                                                                                                                 -- Fire (raid buff only)
    [64] = { { m = "pet", name = "Water Elemental", spellID = 31687, petlessTalent = 205024 } },   -- Frost (CONFIRMED fills pet slot; Lonely Winter 205024 = petless)
  },

  MONK = {
    -- No raid buff (Mystic Touch is automatic), no out-of-combat maintenance.
    resources = { "ENERGY", "CHI", "MANA" },
    specials = {
      -- Brewmaster Stagger: a live bar of your delayed-damage pool, coloured by level. Stagger is
      -- READABLE in combat (UnitStagger), so it's a plain value bar — no secret/estimate caveat.
      { name = "Stagger", tab = "display", icon = 124275, sub = "Brewmaster",
        add = function() return ns.AddStaggerWidget and ns.AddStaggerWidget() end },
    },
    [268] = {},   -- Brewmaster
    [269] = {},   -- Windwalker
    [270] = {},   -- Mistweaver
  },

  PALADIN = {
    -- The real mistake isn't handled by "any aura up" — it's mounting (Crusader Aura, +speed)
    -- and forgetting to swap back, or running with NO aura at all. Tracking the INTENDED combat
    -- aura specifically catches every case: Crusader, the wrong aura, or none all read as
    -- "missing" and remind. Devotion (−3% dmg taken) is the default; Concentration is niche/PvP —
    -- the user picks. (Applies to all specs incl. Retribution, which is otherwise aura-only.)
    raid = { m = "aura", name = "Devotion Aura",
             choose = { "Devotion Aura", "Concentration Aura" },
             note = "track your intended combat aura; fires on Crusader (mount), the other aura, or none up" },
    resources = { "MANA", "HOLY_POWER" },
    -- Rites are LIGHTSMITH hero-talent imbues, and the two Rites are a CHOICE NODE — you take ONE
    -- (Sanctification OR Adjuration). GetWeaponEnchantInfo can't tell which is on the weapon, so the
    -- tracker gates on knowing EITHER rite by SPELL ID (ns.SpellTaken) and shows whichever you took.
    -- IDs confirmed in-game: Sanctification 433568, Adjuration 433583. (Name-based lookup failed —
    -- these hero-talent abilities aren't in the C_SpellBook enumeration, so we must use ids.)
    -- A non-Lightsmith Paladin knows neither -> never nags.
    [65] = { { m = "imbue", slot = "main", name = "Rite of Sanctification", riteIds = { 433568, 433583 }, talentGate = { mode = "require", spell = "self" }, note = "Lightsmith imbue — either Rite" } },   -- Holy
    [66] = { { m = "imbue", slot = "main", name = "Rite of Sanctification", riteIds = { 433568, 433583 }, talentGate = { mode = "require", spell = "self" }, note = "Lightsmith imbue — either Rite" } },   -- Protection
    [70] = {},                                                                                                                                    -- Retribution (aura only, no Lightsmith)
  },

  PRIEST = {
    raid = { m = "aura", name = "Power Word: Fortitude" },   -- +5% Stamina, all specs
    resources = { "MANA", "INSANITY" },
    [256] = {},                                                     -- Discipline (raid buff only)
    [257] = {},                                                     -- Holy (raid buff only)
    [258] = { { m = "form", name = "Shadowform", spellID = 232698 } },   -- Shadow
  },

  ROGUE = {
    -- No raid stat buff — poisons carry the raid utility. Poisons are self-BUFFS (auras), tracked
    -- as "any lethal / any non-lethal" so switching poisons doesn't matter. Assassination can take
    -- Dragon-Tempered Blades (2 lethal + 2 non-lethal at once), so its two trackers require 2 of a
    -- category WHILE that talent is taken (requireCountTalent) and fall back to 1 when it isn't.
    -- Outlaw / Subtlety can't take it, so they always want just 1 of each.
    resources = { "ENERGY", "COMBO_POINTS" },
    [259] = {   -- Assassination
      { m = "aura", name = "Lethal poison",     matchAny = ROGUE_LETHAL,    requireCountTalent = ROGUE_2X },
      { m = "aura", name = "Non-lethal poison", matchAny = ROGUE_NONLETHAL, requireCountTalent = ROGUE_2X },
    },
    [260] = {   -- Outlaw
      { m = "aura", name = "Lethal poison",     matchAny = ROGUE_LETHAL },
      { m = "aura", name = "Non-lethal poison", matchAny = ROGUE_NONLETHAL },
    },
    [261] = {   -- Subtlety
      { m = "aura", name = "Lethal poison",     matchAny = ROGUE_LETHAL },
      { m = "aura", name = "Non-lethal poison", matchAny = ROGUE_NONLETHAL },
    },
  },

  SHAMAN = {
    raid = { m = "aura", name = "Skyfury" },   -- +2% Mastery + auto-attack proc, all specs
    resources = { "MAELSTROM", "MANA" },       -- fallback; per-spec pinned below
    -- UnitPowerMax reports a Maelstrom max for ALL Shaman specs, so the live-max filter can't
    -- keep it off Resto/Enhancement — pin the real bars per spec. Enhancement's resource IS
    -- Maelstrom Weapon (a 10-stack aura, 344179) → a segmented aura bar, not the power bar.
    resourcesBySpec = {
      [262] = { "MAELSTROM", "MANA" },                                                              -- Elemental
      [263] = { { name = "Maelstrom Weapon", auraId = 344179, max = 10, segments = true }, "MANA" },-- Enhancement
      [264] = { "MANA" },                                                                            -- Restoration
    },
    specials = {
      { name = "Earth Shield 2/2", tab = "when", icon = 974, sub = "Self + ally",
        -- Two-shield tracking REQUIRES the Elemental Orbit talent; warn + link it so the user
        -- can hover to confirm they've taken it before adding.
        confirm = { spell = 383010,
          body = "The 2/2 tracker needs the Shaman talent |cffffd100Elemental Orbit|r (it lets you keep Earth Shield on yourself and an ally at once). Hover the talent below to check it — are you sure you've taken it?" },
        add = function() return ns.AddEarthShieldWidget and ns.AddEarthShieldWidget() end },
    },
    -- NB: Earth Shield is intentionally NOT listed as a plain aura — it's covered by the special
    -- "Earth Shield 2/2" above, so listing it here too would show TWO Earth Shield cards.
    [262] = {   -- Elemental
      { m = "aura",  name = "Lightning Shield" },
      -- Flametongue Weapon is a TALENT for Elemental (baseline for Enhancement), sharing the
      -- main-hand enchant slot with a weapon OIL. Track Flametongue only when it's talented, and
      -- suppress the oil reminder once it is — so you never get both at once. Gate = knowing
      -- Flametongue Weapon (318038; VERIFY IsPlayerSpell reflects the talent for Ele).
      { m = "imbue", slot = "main", name = "Flametongue Weapon", spellID = 318038,
        talentGate = { mode = "require", spell = 318038 }, note = "Elemental talent" },
      { m = "imbue", slot = "main", name = "Weapon oil",
        talentGate = { mode = "suppress", spell = 318038 }, note = "suppressed while Flametongue Weapon is talented" },
    },
    [263] = {   -- Enhancement
      { m = "imbue", slot = "main", name = "Windfury Weapon" },
      { m = "imbue", slot = "off",  name = "Flametongue Weapon" },
      { m = "aura",  name = "Lightning Shield" },
    },
    [264] = {   -- Restoration
      { m = "aura",  name = "Water Shield" },
      { m = "imbue", slot = "main", name = "Earthliving Weapon" },
      -- Totemic hero-talent imbue applied to the off-hand ("shield") — reads via
      -- GetWeaponEnchantInfo like the other weapon imbues. (If the slot turns out to be
      -- main/either in play, it's a one-word change here.)
      { m = "imbue", slot = "off", name = "Tidecaller's Guard" },
      { m = "ally",  name = "Earth Shield (on tank)", unit = "ally", research = true },
    },
  },

  WARLOCK = {
    -- No raid buff — utility only. Petless via the Grimoire of Sacrifice CHOICE NODE (talent
    -- 108503; the keep-pet side is Summoner's Embrace 453105) — same mechanic as MM Hunter's
    -- Avian, so gate on the talent being taken (petlessTalent), no buff needed. Click-to-cast
    -- picks the demon (Imp/Voidwalker/Felhunter/Sayaad, + Felguard for Demo); no revive.
    resources = { "MANA", "SOUL_SHARDS" },
    [265] = { { m = "pet", name = "Pet",      spellID = 688,   petlessTalent = 108503 } },   -- Affliction
    [266] = { { m = "pet", name = "Felguard", spellID = 30146, petlessTalent = 108503 } },   -- Demonology
    [267] = { { m = "pet", name = "Pet",      spellID = 688,   petlessTalent = 108503 } },   -- Destruction
  },

  WARRIOR = {
    raid = { m = "aura", name = "Battle Shout" },   -- +5% Attack Power, all specs
    resources = { "RAGE" },
    -- Each spec has its own stance (read via the shapeshift bar, not the aura).
    [71] = { { m = "form", name = "Battle Stance",    spellID = 386164 } },   -- Arms
    [72] = {   -- Fury
      { m = "form", name = "Berserker Stance", spellID = 386196 },
      IMPROVED_WHIRLWIND,
    },
    [73] = { { m = "form", name = "Defensive Stance", spellID = 386208 } },   -- Protection
  },
}
