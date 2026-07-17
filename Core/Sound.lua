-- Core/Sound.lua : the alert-audio system — a curated library of recognizable,
-- NAMED sounds (no raw SoundKit numbers), the user's SharedMedia sounds, plus a
-- custom TTS option ("speak this text"). One entry point plays any of them.
--
-- An alert `sound` can be:
--   nil / ""            -> silent
--   <number>            -> a Blizzard SoundKit id (the curated library)
--   "<name>"            -> a SharedMedia sound, by name
--   { tts = "<text>" }  -> spoken aloud via the game's text-to-speech voice
--
-- The editor's sound picker previews on HOVER (Sound.Preview), stopping whatever
-- was playing first, so you can audition the whole list without committing.

local ADDON, ns = ...

local Sound = {}
ns.Sound = Sound

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- ── Bundled sound pack ────────────────────────────────────────────────
-- Fun, recognizable effect sounds that ship with the addon (in Sounds\). Registered
-- into SharedMedia by friendly name so they play through the normal path and become
-- available to other addons too. `ours` marks them so the picker lists each once (in
-- the curated section) rather than again in the SharedMedia dump.
local SOUND_PATH = "Interface\\AddOns\\Custodian\\Sounds\\"
local BUNDLED = {
    { name = "Acoustic Guitar",        file = "AcousticGuitar.ogg" },
    { name = "Air Horn",               file = "AirHorn.ogg" },
    { name = "Applause",               file = "Applause.ogg" },
    { name = "Banana Peel Slip",       file = "BananaPeelSlip.ogg" },
    { name = "Batman Punch",           file = "BatmanPunch.ogg" },
    { name = "Bike Horn",              file = "BikeHorn.ogg" },
    { name = "Blast",                  file = "Blast.ogg" },
    { name = "Bleat",                  file = "Bleat.ogg" },
    { name = "Boxing Arena",           file = "BoxingArenaSound.ogg" },
    { name = "Brass",                  file = "Brass.mp3" },
    { name = "Cartoon Voice Baritone", file = "CartoonVoiceBaritone.ogg" },
    { name = "Cartoon Walking",        file = "CartoonWalking.ogg" },
    { name = "Cat Meow",               file = "CatMeow2.ogg" },
    { name = "Chicken Alarm",          file = "ChickenAlarm.ogg" },
    { name = "Cow Mooing",             file = "CowMooing.ogg" },
    { name = "Double Whoosh",          file = "DoubleWhoosh.ogg" },
    { name = "Drums",                  file = "Drums.ogg" },
    { name = "Electrical Spark",       file = "ElectricalSpark.ogg" },
    { name = "Error Beep",             file = "ErrorBeep.ogg" },
    { name = "Glass",                  file = "Glass.mp3" },
    { name = "Goat Bleating",          file = "GoatBleating.ogg" },
    { name = "Heartbeat",              file = "HeartbeatSingle.ogg" },
    { name = "Kitten Meow",            file = "KittenMeow.ogg" },
    { name = "Oh No",                  file = "OhNo.ogg" },
    { name = "Ringing Phone",          file = "RingingPhone.ogg" },
    { name = "Roaring Lion",           file = "RoaringLion.ogg" },
    { name = "Robot Blip",             file = "RobotBlip.ogg" },
    { name = "Rooster",                file = "RoosterChickenCalls.ogg" },
    { name = "Sharp Punch",            file = "SharpPunch.ogg" },
    { name = "Sheep Bleat",            file = "SheepBleat.ogg" },
    { name = "Shotgun",                file = "Shotgun.ogg" },
    { name = "Squeaky Toy",            file = "SqueakyToyShort.ogg" },
    { name = "Squish Fart",            file = "SquishFart.ogg" },
    { name = "Synth Chord",            file = "SynthChord.ogg" },
    { name = "Tada Fanfare",           file = "TadaFanfare.ogg" },
    { name = "Temple Bell",            file = "TempleBellHuge.ogg" },
    { name = "Thunder",                file = "Thunder.ogg" },
    { name = "Torch",                  file = "Torch.ogg" },
    { name = "Warning Siren",          file = "WarningSiren.ogg" },
    { name = "Water Drop",             file = "WaterDrop.ogg" },
    { name = "Xylophone",              file = "Xylophone.ogg" },
}
local ours = {}
if LSM then
    for _, e in ipairs(BUNDLED) do
        LSM:Register("sound", e.name, SOUND_PATH .. e.file)
        ours[e.name] = true
    end
end

-- ── Curated library ───────────────────────────────────────────────────
-- Named Blizzard alert sounds (by SOUNDKIT name, or a direct file id) plus the
-- bundled pack above — all sorted A→Z so it reads as one clean list. Blizzard
-- entries are kept only if they resolve on this client (no dead rows).
local CURATED = {
    { key = "RAID_WARNING",                 text = "Raid Warning" },
    { key = "READY_CHECK",                  text = "Ready Check" },
    { key = "ALARM_CLOCK_WARNING_3",        text = "Alarm" },
    { key = "UI_RAID_BOSS_WHISPER_WARNING", text = "Boss Warning" },
    { key = "TELL_MESSAGE",                 text = "Whisper Ping" },
    { key = "MAP_PING",                     text = "Map Ping" },
    { key = "IG_QUEST_LIST_COMPLETE",       text = "Quest Done" },
    { key = "IG_PLAYER_INVITE",             text = "Invite" },
    { key = "PVPTHROUGHQUEUE",              text = "Queue Pop" },
    { id  = 888,                            text = "Level Up" },
    { id  = 569593,                         text = "Power Aura" },
}

local library
local function buildLibrary()
    library = {}
    for _, e in ipairs(CURATED) do
        local id = e.id or (SOUNDKIT and SOUNDKIT[e.key])
        if id then library[#library + 1] = { value = id, text = e.text } end
    end
    for _, e in ipairs(BUNDLED) do
        library[#library + 1] = { value = e.name, text = e.name }
    end
    table.sort(library, function(a, b) return a.text < b.text end)
    if #library == 0 then library[1] = { value = 8959, text = "Raid Warning" } end
    return library
end

function Sound.Library()
    if not library then buildLibrary() end
    return library
end

-- Friendly label for a stored sound value (for the picker's current text).
function Sound.Text(s)
    if s == nil or s == "" then return "None" end
    if type(s) == "table" then
        local t = s.tts
        return (t and t ~= "") and ("TTS: " .. t) or "Speak text…"
    end
    for _, e in ipairs(Sound.Library()) do if e.value == s then return e.text end end
    if type(s) == "number" then return "Sound " .. s end
    return s   -- a SharedMedia name
end

-- Boss-mod / raid-tool addons dump their voice packs into SharedMedia — countdown
-- numbers, "Dispel", "Clear", raid-marker colours, etc. We drop those by SOURCE:
-- LibSharedMedia stores each sound's FILE PATH, so a sound registered from one of
-- these addons' folders is filtered out. Real media packs (SharedMedia, Causese…)
-- and Blizzard sounds are kept. This is exact, unlike guessing by name.
local BLOCKED_SOURCES = {
    "northernsky", "bigwigs", "littlewigs", "deadlyboss", "dbm-", "\\dbm\\",
    "methodraid", "\\mrt\\", "weakauras", "\\wa\\", "angryassign", "\\cell\\",
    "exorsus", "\\ert\\", "\\vrt\\", "raidtools", "bugsack", "buggrabber",
}
local function blockedSource(path)
    if type(path) ~= "string" then return false end
    local p = path:lower():gsub("/", "\\")
    for _, s in ipairs(BLOCKED_SOURCES) do if p:find(s, 1, true) then return true end end
    return false
end
-- Boss-mod / voice-pack sounds decorate their SharedMedia names with COLOUR (|c) or
-- ICON (|T / |A) escapes, or are bare countdown numbers ("1", "1. First") — real
-- media packs use plain text. That decoration is the tell, and filtering on it
-- clears out the countdowns, raid-marker/spell-icon voices and coloured call-outs
-- in one go, without hiding a plainly-named sound (even one called "Interrupt").
local function blockedName(name)
    if type(name) ~= "string" then return true end
    if name:find("|c", 1, true) or name:find("|T", 1, true) or name:find("|A", 1, true) then return true end
    if name:find("^%s*%d+%s*$") then return true end          -- "1", " 10 "
    if name:find("^%s*%d+%s*[%.:]") then return true end       -- "1. First", "2: Second"
    return false
end

-- The picker's item list: None · Speak text (TTS) · curated · (clean) SharedMedia.
function Sound.Options()
    local t = {
        { value = "",       text = "None" },
        { value = "__tts__", text = "|cff9fd6ffSpeak text (TTS)…|r" },
    }
    for _, e in ipairs(Sound.Library()) do t[#t + 1] = e end
    local lsm = {}
    local hash = ns.Media and ns.Media.SoundList and ns.Media.SoundList()
    if hash then
        for name, path in pairs(hash) do
            if not (ours[name] or blockedName(name) or blockedSource(path)) then lsm[#lsm + 1] = { value = name, text = name } end
        end
    end
    table.sort(lsm, function(a, b) return a.text < b.text end)
    for _, o in ipairs(lsm) do t[#t + 1] = o end
    return t
end

-- ── Text-to-speech ────────────────────────────────────────────────────
-- Uses the game's own TTS (the same system the Cooldown Manager speaks with). The
-- first available voice is cached; rate/volume follow the player's TTS settings
-- when exposed, else sensible defaults.
-- The player's chosen TTS voice (the Standard slot in the game's TTS settings),
-- falling back to the first installed voice, then the engine default.
function Sound.Voice()
    if TextToSpeech_GetSelectedVoice and Enum and Enum.TtsVoiceType then
        local ok, v = pcall(TextToSpeech_GetSelectedVoice, Enum.TtsVoiceType.Standard)
        if ok and v and v.voiceID then return v.voiceID end
    end
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        local voices = C_VoiceChat.GetTtsVoices()
        if voices and voices[1] then return voices[1].voiceID end
    end
    return 0
end

-- Midnight (12.0) DROPPED the `destination` argument from C_VoiceChat.SpeakText:
-- it's now SpeakText(voiceID, text, rate, volume, overlap). Passing the old 6-arg
-- shape (…, destination, rate, volume) silently misfires — that was the "TTS
-- doesn't work" bug. Branch on the interface version, like MRT / DialogueUI do.
local SPEAK_NODEST = (select(4, GetBuildInfo()) or 0) > 120000
function Sound.Speak(text)
    if not (text and text ~= "" and C_VoiceChat and C_VoiceChat.SpeakText) then return end
    local voice = Sound.Voice()
    local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
    local vol  = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100
    if SPEAK_NODEST then
        pcall(C_VoiceChat.SpeakText, voice, text, rate, vol, false)
    else
        local dest = (Enum and Enum.VoiceTtsDestination and Enum.VoiceTtsDestination.LocalPlayback) or 0
        pcall(C_VoiceChat.SpeakText, voice, text, dest, rate, vol)
    end
end

local function stopTTS()
    if C_VoiceChat and C_VoiceChat.StopSpeakingText then pcall(C_VoiceChat.StopSpeakingText) end
end

-- ── Play / preview ────────────────────────────────────────────────────
-- Plays any alert-sound shape and returns a stoppable handle for real sounds
-- (TTS is stopped via the voice API, not a handle).
function ns.PlaySound(sound)
    if not sound or sound == "" then return end
    if type(sound) == "table" then
        if sound.tts then Sound.Speak(sound.tts) end
        return
    end
    if type(sound) == "number" then
        local willPlay, handle = PlaySound(sound, "Master")
        if willPlay then return handle end
        local wp, h = PlaySoundFile(sound, "Master")   -- some ids are FileDataIDs, not SoundKits
        return wp and h or nil
    end
    local file = LSM and LSM:Fetch("sound", sound, true)
    if file then local _, handle = PlaySoundFile(file, "Master"); return handle end
end

-- Audition a value in the picker: stop the previous preview (sound OR speech), then
-- play this one. The "__tts__" sentinel and an empty text speak nothing.
local previewHandle
function Sound.StopPreview()
    if previewHandle then StopSound(previewHandle); previewHandle = nil end
    stopTTS()
end
function Sound.Preview(value)
    Sound.StopPreview()
    if value == "__tts__" or value == "" or value == nil then return end
    previewHandle = ns.PlaySound(value)
end
