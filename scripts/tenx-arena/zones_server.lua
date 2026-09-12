-- ============================================================
--  tenx-zones INTEGRATION  (server)
-- ============================================================
-- Everything that hands zone ownership to tenx-zones lives in this file and
-- in zones_client.lua, so that removing it later is deleting two files and a
-- handful of call sites rather than picking integration out of the middle of
-- server.lua.
--
-- ALL OF IT IS OFF unless Config.Zones.useExternal is true. With the flag
-- off, every function here returns in a way that leaves the arena's own
-- boundary code in charge and behaving exactly as it does today. That is
-- deliberate: this can ship to a live server and change nothing until
-- somebody decides otherwise.

ZoneLink = ZoneLink or {}

local RES = 'tenx-zones'

--- Is the handover switched on AND actually possible?
---
--- Both, every time. A flag that is on while the resource is stopped would
--- otherwise mean no boundary at all -- worse than either state on its own.
function ZoneLink.active()
    local cfg = Config.Zones
    if not (cfg and cfg.useExternal) then return false end
    return GetResourceState(RES) == 'started'
end

--- Call tenx-zones, survive it being absent.
---
--- Same shape as the wrapper the Red Zone uses for the arena, for the same
--- reason: a stopped resource should mean a feature quietly does nothing
--- rather than an error every time something moves.
---
--- Returns nil on failure. Read that carefully at call sites -- nil is not
--- false. For an in/out test, nil means "could not ask", and treating it as
--- "outside" would silently stop every reward on the server.
function ZoneLink.call(fn, ...)
    if not ZoneLink.active() then return nil end

    local ok, res = pcall(function(...)
        return exports[RES][fn](nil, ...)
    end, ...)

    if not ok then
        ZoneLink.fail(fn, res)
        return nil
    end

    return res
end

local failedOnce = {}

--- Complain about a broken export once, not once per call.
function ZoneLink.fail(fn, err)
    if failedOnce[fn] then return end
    failedOnce[fn] = true
    print(('^1[arena] tenx-zones:%s failed -- %s^0'):format(fn, tostring(err)))
end

-- ============================================================
--  STARTUP CHECK
-- ============================================================
-- Every export this resource will call. Checked in one go at boot so a
-- version mismatch is one clear block in the console rather than a feature
-- at a time failing later, quietly, in front of players.

local NEEDED = {
    'GetExports', 'GetVersion',
    'GetZone', 'ZoneExists', 'GetZoneCentre', 'GetZoneArea',
    'IsPlayerInZone', 'IsPointInZone',
    'BindZoneToBucket', 'UnbindZoneFromBucket', 'ReleaseZone',
    'BindZoneToPlayers', 'UnbindZoneFromPlayers',
    'SuspendZone', 'ResumeZone',
    'RefreshPlayer', 'ValidateSpawn', 'GetBindings',
}

ZoneLink.ready = false

--- Ask tenx-zones what it offers and compare.
---
--- Through GetExports rather than one pcall per name: indexing an export that
--- does not exist THROWS rather than returning nil, so a plain nil check is
--- itself an error. One pcall to reach the list, then a set comparison.
function ZoneLink.check()
    if not (Config.Zones and Config.Zones.useExternal) then return true end

    if GetResourceState(RES) ~= 'started' then
        print('^1[arena] Config.Zones.useExternal is on but ' .. RES ..
              ' is not started.^0')
        print('^1[arena] Start it first, or turn the flag off. Refusing to ' ..
              'run with no boundary owner.^0')
        return false
    end

    local ok, list = pcall(function() return exports[RES]:GetExports() end)
    if not ok or type(list) ~= 'table' then
        print('^1[arena] ' .. RES .. ' has no GetExports() -- it is too old ' ..
              'for this build of the arena.^0')
        return false
    end

    local have = {}
    for _, name in ipairs(list) do have[name] = true end

    local missing = {}
    for _, name in ipairs(NEEDED) do
        if not have[name] then missing[#missing + 1] = name end
    end

    if #missing > 0 then
        print('^1[arena] ---- tenx-zones is missing exports the arena needs ----^0')
        for _, name in ipairs(missing) do print('^1    ' .. name .. '^0') end
        print('^1[arena] Update tenx-zones, or set Config.Zones.useExternal = false.^0')
        return false
    end

    local ver = select(2, pcall(function() return exports[RES]:GetVersion() end))
    print(('^2[arena] tenx-zones %s -- boundary handover active^0')
        :format(tostring(ver)))

    ZoneLink.ready = true
    return true
end

-- ============================================================
--  BINDING
-- ============================================================
-- A zone does nothing until it is bound. Matches bind on start and release on
-- end; the lobby never binds, because the lobby has no walls.

--- The zone id for an arena, or nil if it has not been migrated.
function ZoneLink.zoneIdFor(arenaId)
    local arenas = ArenaZoneState and ArenaZoneState() or {}
    local a = arenas[arenaId]
    return a and a.zoneId or nil
end

function ZoneLink.bindMatch(arenaId, bucket)
    if not ZoneLink.active() then return end

    local zoneId = ZoneLink.zoneIdFor(arenaId)
    if not zoneId then return end

    -- armOnEntry, always.
    --
    -- Players can be placed outside a boundary before a match settles, and a
    -- zone that is solid from the instant it binds would clamp them in before
    -- they have arrived. Arming on first entry costs nothing when everyone is
    -- already inside, and is the difference between working and not for any
    -- mode that drops players outside on purpose.
    ZoneLink.call('BindZoneToBucket', zoneId, bucket, { armOnEntry = true })
end

function ZoneLink.releaseMatch(arenaId)
    if not ZoneLink.active() then return end

    local zoneId = ZoneLink.zoneIdFor(arenaId)
    if not zoneId then return end

    ZoneLink.call('ReleaseZone', zoneId)
end

--- Tell tenx-zones a player's bucket changed.
---
--- Called at every bucket move in this resource. tenx-zones also polls, so
--- this is the instant path rather than the only correct one -- but a forgotten
--- call still means up to a couple of seconds of the wrong zone applying, so
--- they are all wired.
function ZoneLink.refresh(src)
    if not ZoneLink.active() then return end
    ZoneLink.call('RefreshPlayer', src)
end

-- ============================================================
--  RE-BINDING AFTER A tenx-zones RESTART
-- ============================================================
-- Bindings are runtime state and deliberately do not survive a restart -- a
-- stale binding walling players into a match that no longer exists is worse
-- than a moment with no wall. So every live match has to be re-bound.

--- Rebuild every binding this resource is responsible for.
---
--- @param why string  where the rebuild came from, for the log line
function ZoneLink.rebind(why)
    if not ZoneLink.active() then return end

    local n = 0

    local _, matches = ArenaZoneState()

    for _, m in pairs(matches or {}) do
        if m.arenaId and m.slot then
            ZoneLink.bindMatch(m.arenaId, ArenaBucketFor(m.arenaId, m.slot))
            n = n + 1
        end
    end

    print(('[arena] re-bound %s live match zone(s) after %s'):format(n, why))

    -- Trust nothing, including this loop.
    --
    -- Compare what tenx-zones now thinks it has against what we just asked
    -- for. A mismatch is not fatal, but it is exactly the kind of thing that
    -- otherwise shows up as one arena mysteriously having no walls.
    local bindings = ZoneLink.call('GetBindings')
    if type(bindings) == 'table' then
        for _, m in pairs(matches or {}) do
            local zoneId = ZoneLink.zoneIdFor(m.arenaId)
            if zoneId and not bindings[zoneId] then
                print(('^3[arena] zone %s for arena %s did not bind -- ' ..
                       'that match has no boundary^0'):format(zoneId, m.arenaId))
            end
        end
    end
end

-- tenx-zones restarting underneath a running server.
AddEventHandler('tenx-zones:server:ready', function(version)
    if not ZoneLink.active() then return end
    print(('[arena] tenx-zones %s came up'):format(tostring(version)))
    ZoneLink.rebind('a tenx-zones restart')
end)

-- And the other direction: this resource starting after tenx-zones, which is
-- the normal load order. `ready` will already have been and gone, so it is
-- never waited for.
CreateThread(function()
    Wait(2000)
    if not ZoneLink.check() then return end
    ZoneLink.rebind('startup')
end)

-- ============================================================
--  QUESTIONS THE ARENA ASKS
-- ============================================================

--- Is this player inside the arena's shape?
---
--- Falls back to the arena's own test when the handover is off, so callers do
--- not need to know which mode they are in.
---
--- Never returns nil: a failed call falls back rather than answering
--- "outside". Rewards are decided on this, and a silent nil would stop every
--- payout on the server the moment an export went missing.
function ZoneLink.insideArena(src, arenaId)
    if ZoneLink.active() then
        local zoneId = ZoneLink.zoneIdFor(arenaId)

        if zoneId then
            local res = ZoneLink.call('IsPlayerInZone', src, zoneId)
            if res ~= nil then return res == true end
            -- fall through on failure
        end
    end

    return ArenaInsideOwn(src, arenaId)
end

--- Can a spawn point live here?
---
--- @param want string 'inside' for team spawns, 'outside' for entry spawns
--- @return boolean ok, string|nil why
function ZoneLink.validateSpawn(arenaId, coords, tolerance, want)
    if not ZoneLink.active() then return nil end

    local zoneId = ZoneLink.zoneIdFor(arenaId)
    if not zoneId then return nil end

    local ok, why = ZoneLink.call('ValidateSpawn', zoneId, coords,
                                  tolerance or 5.0, want or 'inside')

    if ok == nil then return nil end
    return ok == true, why
end

--- A point guaranteed to be inside, for flying an admin to a zone.
function ZoneLink.centre(arenaId)
    if not ZoneLink.active() then return nil end

    local zoneId = ZoneLink.zoneIdFor(arenaId)
    if not zoneId then return nil end

    return ZoneLink.call('GetZoneCentre', zoneId)
end

--- Does the shape still exist? Gates matchmaking.
---
--- True when the handover is off, so the arena's own bounds check stays the
--- authority in that mode.
function ZoneLink.zoneUsable(arenaId)
    if not ZoneLink.active() then return true end

    local zoneId = ZoneLink.zoneIdFor(arenaId)
    if not zoneId then return false end

    local res = ZoneLink.call('ZoneExists', zoneId)
    -- nil means we could not ask. Say yes: refusing to matchmake because an
    -- export hiccuped is worse than a match in a zone that turns out to be
    -- gone, which the sweep will catch.
    if res == nil then return true end

    return res == true
end

-- A zone disappearing under a live arena. Logged rather than acted on -- the
-- match in progress keeps its binding until it ends, and the arena simply
-- stops being offered for new ones.
AddEventHandler('tenx-zones:server:zoneUnavailable', function(zoneId, why)
    if not ZoneLink.active() then return end

    local arenas = ArenaZoneState and ArenaZoneState() or {}
    for id, a in pairs(arenas) do
        if a.zoneId == zoneId then
            print(('^3[arena] arena %s (%s) has lost its zone: %s^0')
                :format(id, a.name, tostring(why)))
        end
    end
end)

-- ============================================================
--  THE DEATH WINDOW
-- ============================================================
-- A claim held across the whole time a player is down.
--
-- The ambulance script is escrowed and moves downed players on its own
-- schedule -- it takes seven to ten seconds even to register a death. Any
-- teleport it does inside this claim reads as a deliberate move rather than
-- an unexplained one, so the boundary neither fights it nor treats it as a
-- player escaping.

function ZoneLink.claimDown(src)
    if not ZoneLink.active() then return end
    ZoneLink.call('SuspendZone', src, 'arena:down')
end

function ZoneLink.releaseDown(src)
    if not ZoneLink.active() then return end
    ZoneLink.call('ResumeZone', src, 'arena:down')
end

--- The arena owns the arena-to-zone mapping, so it answers.
---
--- The Red Zone borrows the arena's shapes, so it borrows the ids too. One
--- zone per arena, two consumers, no second mapping to drift.
exports('zoneIdFor', function(arenaId)
    return ZoneLink.zoneIdFor(arenaId)
end)

exports('zoneClaimDown', function(src) ZoneLink.claimDown(src) end)
exports('zoneReleaseDown', function(src) ZoneLink.releaseDown(src) end)

-- Never leave a claim held by a resource that has stopped, or a player who
-- has gone.
AddEventHandler('playerDropped', function()
    local src = source
    if ZoneLink.active() then ZoneLink.call('ClearSuspends', src) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if not ZoneLink.active() then return end

    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then ZoneLink.call('ClearSuspends', src) end
    end
end)
