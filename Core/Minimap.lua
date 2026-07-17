-- Core/Minimap.lua : a hand-rolled, draggable minimap button (no LibDBIcon dependency,
-- in keeping with the addon's custom, dependency-light design).
--
-- Left-click toggles the settings panel; right-click prints a hint. Drag it around the
-- ring — the angle is saved per-account in db.global.minimap, along with a hide flag
-- (toggled by /custodian minimap).

local ADDON, ns = ...

local ICON   = "Interface\\AddOns\\Custodian\\Media\\Custodian.tga"
local RADIUS = 80   -- distance from the minimap centre to the button

local btn

local function settings()
    local g = ns.A and ns.A.db and ns.A.db.global
    if not g then return nil end
    g.minimap = g.minimap or { angle = 220 }
    return g.minimap
end

-- Anchor the button on the minimap ring at its saved angle.
local function place()
    local m = settings(); if not m or not btn then return end
    local a = math.rad(m.angle or 220)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * RADIUS, math.sin(a) * RADIUS)
end

-- While dragging: convert the cursor position (in minimap space) to an angle.
local function onDrag()
    local m = settings(); if not m then return end
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    m.angle = math.deg(math.atan2(py - my, px - mx))
    place()
end

function ns.SetupMinimap()
    if btn or not Minimap then return end
    local m = settings(); if not m then return end
    if m.hide then return end   -- honour a hidden preference; created on demand later

    btn = CreateFrame("Button", "Custodian_MinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(22, 22); icon:SetTexture(ICON)
    icon:SetTexCoord(0, 1, 0, 1)   -- custom logo: show it whole (no default-icon border to trim)
    icon:SetPoint("CENTER", 0, 1)

    local ring = btn:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53); ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetPoint("TOPLEFT")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    btn:SetScript("OnClick", function(_, mouseBtn)
        if mouseBtn == "RightButton" then
            ns.Print("Minimap button: |cffffd100left-click|r opens settings, |cffffd100drag|r to move, |cffffd100/custodian minimap|r to hide.")
        elseif ns.ToggleOptions then
            ns.ToggleOptions()
        end
    end)
    btn:SetScript("OnDragStart", function() btn:SetScript("OnUpdate", onDrag) end)
    btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:AddLine("Custodian")
        GameTooltip:AddLine("Left-click to open settings.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag to move around the minimap.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    place()
end

-- /custodian minimap — show / hide the button. Returns the new shown state.
function ns.ToggleMinimap()
    local m = settings(); if not m then return false end
    m.hide = not m.hide
    if m.hide then
        if btn then btn:Hide() end
    elseif btn then
        btn:Show()
    else
        ns.SetupMinimap()
    end
    return not m.hide
end
