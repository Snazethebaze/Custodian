-- Core/Animation.lua : one shared, self-disabling ticker.
-- This frame only runs while at least one animation is in flight and hides
-- itself the moment they finish — no always-on OnUpdate.

local ADDON, ns = ...

local Animation = {}
ns.Animation = Animation

local active = {}   -- key -> entry
local count  = 0

local driver = CreateFrame("Frame")
driver:Hide()

driver:SetScript("OnUpdate", function(_, elapsed)
    for key, a in pairs(active) do
        a.elapsed = a.elapsed + elapsed
        local t = a.elapsed / a.duration
        if t >= 1 then
            a.current = a.target
            a.apply(a.current)
            active[key] = nil
            count = count - 1
            if a.onDone then a.onDone() end
        else
            local te = t * t * (3 - 2 * t)   -- smoothstep
            a.current = a.from + (a.target - a.from) * te
            a.apply(a.current)
        end
    end
    if count <= 0 then driver:Hide() end
end)

-- Animate `key` from -> target over duration, calling apply(value) each frame.
-- Re-calling with the same key mid-flight retargets smoothly from current.
function Animation.To(key, from, target, duration, apply, onDone)
    if duration <= 0 or from == target then
        apply(target)
        if active[key] then active[key] = nil; count = count - 1 end
        if onDone then onDone() end
        return
    end
    local a = active[key]
    if a then
        a.from, a.current = a.current, a.current
        a.target, a.elapsed, a.duration = target, 0, duration
        a.apply, a.onDone = apply, onDone
    else
        active[key] = {
            from = from, current = from, target = target,
            elapsed = 0, duration = duration, apply = apply, onDone = onDone,
        }
        count = count + 1
    end
    driver:Show()
end

function Animation.Cancel(key)
    if active[key] then
        active[key] = nil
        count = count - 1
        if count <= 0 then driver:Hide() end
    end
end
