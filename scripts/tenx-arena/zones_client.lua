-- ============================================================
--  tenx-zones INTEGRATION  (client)
-- ============================================================
-- Two jobs: suspending enforcement around our own teleports, and turning the
-- arena's own clamp off when tenx-zones owns the boundary.
--
-- OFF unless Config.Zones.useExternal is true.

ZoneLinkC = ZoneLinkC or {}

local RES = 'tenx-zones'

function ZoneLinkC.active()
    local cfg = Config.Zones
    if not (cfg and cfg.useExternal) then return false end
    return GetResourceState(RES) == 'started'
end

local warned = false

local function call(fn, ...)
    if not ZoneLinkC.active() then return nil end

    local ok, res = pcall(function(...)
        return exports[RES][fn](nil, ...)
    end, ...)

    if not ok and not warned then
        warned = true
        print(('^1[arena] tenx-zones:%s failed on the client -- %s^0')
            :format(fn, tostring(res)))
    end

    -- `ok and res or nil` turns a legitimate false into nil, which makes a
    -- successful "no" indistinguishable from a failed call.
    if ok then return res end
    return nil
end

-- ============================================================
--  SUSPENDING AROUND A TELEPORT
-- ============================================================
-- The clamp runs on this machine, so a client calling a client export takes
-- effect on the same frame. There is no hop to lose a race across.
--
-- Both halves matter. The local call stops the clamp now; tenx-zones reports
-- the claim up to its own server side so the periodic sweep holds off too.
-- Without that second half, safeTeleport's collision wait -- up to twelve
-- seconds -- outlasts the sweep interval, and the server would force-correct
-- a player in the middle of being moved. The same bug, arriving from the
-- other direction.
--
-- Named claims, so overlapping teleports nest instead of the first one to
-- finish releasing the hold for both.

function ZoneLinkC.suspend(reason)
    if not ZoneLinkC.active() then return end
    call('SuspendLocal', reason or 'arena:teleport')
end

function ZoneLinkC.resume(reason)
    if not ZoneLinkC.active() then return end
    call('ResumeLocal', reason or 'arena:teleport')
end

--- Wrap any function that moves the player.
---
--- pcall around the body so a teleport that errors still releases the claim.
--- A claim left held is a player with no boundary until it times out, which
--- is a worse outcome than whatever went wrong inside.
function ZoneLinkC.around(reason, fn, ...)
    if not ZoneLinkC.active() then return fn(...) end

    ZoneLinkC.suspend(reason)
    local ok, a, b, c = pcall(fn, ...)
    ZoneLinkC.resume(reason)

    if not ok then
        print(('^1[arena] teleport failed inside a zone claim: %s^0'):format(tostring(a)))
        return nil
    end

    return a, b, c
end

-- ============================================================
--  WHO OWNS THE CLAMP
-- ============================================================

--- Should the arena's own clamp run?
---
--- False once tenx-zones owns the boundary. Two things clamping the same
--- player is the jitter this whole split exists to remove, so this is checked
--- inside the loop rather than only at startup -- the flag can be flipped by
--- a config change and a restart, and a thread that decided at load time
--- would be wrong until the next one.
function ZoneLinkC.ownClamp()
    return not ZoneLinkC.active()
end

-- ============================================================
--  ENTERED / LEFT
-- ============================================================
-- Reacting to change only. Anything that decides money asks directly at the
-- moment it matters -- these events fire off a sweep and can be seconds
-- stale, which in a fast fight is wrong often enough to notice.

AddEventHandler('tenx-zones:entered', function(zoneId)
    if not ZoneLinkC.active() then return end
    TriggerEvent('naija-arena:zoneEntered', zoneId)
end)

AddEventHandler('tenx-zones:left', function(zoneId, reason, claim)
    if not ZoneLinkC.active() then return end
    TriggerEvent('naija-arena:zoneLeft', zoneId, reason, claim)
end)

-- Never leave a claim behind.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if not ZoneLinkC.active() then return end
    call('ClearLocalSuspends')
end)
