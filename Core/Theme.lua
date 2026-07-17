-- Core/Theme.lua : the addon's "global.css" — every styling knob in ONE place.
--
-- Change a value here and it reflects everywhere: the settings-panel chrome, the
-- colour composer, the dropdowns, move mode. Colours are { r, g, b [, a] } in 0-1.
-- (Per-widget bar/icon colours are USER data in the profile — NOT theme.) Loaded
-- FIRST (before UIKit/Panel/Widgets) so everything can read ns.Theme.
--
-- UIKit re-exposes the two workhorses as ACCENT and COL for terse call sites; the
-- rest is applied via T.rgba(token) which spreads a colour into r,g,b,a.

local ADDON, ns = ...

local T = {}
ns.Theme = T

-- Spread a colour token into r, g, b, a for the WoW setters:
--   tex:SetColorTexture(T.rgba(T.surface.window))   fs:SetTextColor(T.rgba(T.text.label))
function T.rgba(c) return c[1], c[2], c[3], c[4] end

-- ── The one source colour ─────────────────────────────────────────────
-- Retint the ENTIRE UI from here (buttons, checks, sliders, headers, focus rings…).
T.accent = { 0.24, 0.62, 0.98 }

-- ── Surfaces (backgrounds), darkest → lightest ────────────────────────
T.surface = {
    window       = { 0.055, 0.065, 0.085, 0.97 },  -- the settings window
    dialog       = { 0.07, 0.08, 0.11, 0.985 },    -- composer / prompt / spell picker
    header       = { 0.09, 0.11, 0.15 },            -- panel title bar
    titlebar     = { 0.10, 0.12, 0.16 },            -- dialog title strips
    panel        = { 0.10, 0.11, 0.13 },            -- list / dropdown menu / scroll views
    form         = { 0.11, 0.15, 0.22 },            -- inset sub-form (new-tracker box)
    control      = { 0.155, 0.170, 0.205 },         -- button / check / editbox fill
    controlFocus = { 0.10, 0.13, 0.19 },            -- editbox fill while focused
    controlAlt   = { 0.13, 0.15, 0.19 },            -- wizard nav button, resting
    controlHot   = { 0.18, 0.28, 0.42 },            -- wizard nav button, hover
    sliderTrack  = { 0.03, 0.035, 0.05 },
    edge         = { 0, 0, 0 },                      -- 1px borders
}

-- ── Text ──────────────────────────────────────────────────────────────
T.text = {
    title  = { 0.8, 0.88, 1.0 },     -- dialog / window titles
    header = { 0.55, 0.80, 1.0 },    -- section headers (accent-tinted)
    label  = { 0.62, 0.66, 0.73 },   -- field labels + secondary text
    muted  = { 0.55, 0.58, 0.64 },   -- dimmest helper text
    info   = { 0.72, 0.80, 0.92 },   -- wizard explainer copy
    thumb  = { 0.85, 0.92, 1.0 },    -- slider thumb, resting
}

-- ── Interaction feel (alphas 0-1, durations in seconds) ───────────────
T.fx = {
    hover      = 0.11,   -- highlight fade-in on enter
    leave      = 0.13,   -- fade-out on leave
    press      = 0.10,   -- fade on mouse-up
    fade       = 0.16,   -- panel open fade
    editorFade = 0.14,   -- editor pane fade on selection change
    hoverAlpha = 0.24,   -- button highlight strength on hover
    checkAlpha = 0.22,   -- checkbox hover strength
    menuAlpha  = 0.25,   -- dropdown row hover strength
    activeAlpha = 0.52,  -- button "on"/selected resting highlight
    pressAlpha = 0.42,   -- button highlight while held
}

-- ── Move mode / HUD chrome ────────────────────────────────────────────
T.hud = {
    main         = { 0.10, 0.55, 0.95 },        -- group handle/zone tint
    attached     = { 0.20, 0.75, 0.35 },        -- group member tint
    lone         = { 0.45, 0.45, 0.55 },        -- standalone tint
    overlay      = { 0.09, 0.52, 0.82 },        -- move-mode wash (base blue)
    overlayAlpha = 0.14,                        -- move-mode wash opacity (faint: live preview shows through)
    border       = 2,                           -- move-mode role-border thickness (px)
    borderAlpha  = 0.95,                         -- move-mode role-border opacity (the prominent "ours" marker)
    slide        = 0.18,                        -- linked-reflow slide seconds
}
