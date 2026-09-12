-- ============================================================
--  tenx-zones INTEGRATION  (server)
-- ============================================================
-- OFF unless Config.RZ.zones.useExternal is true. With it off, every function
-- here returns in a way that leaves the existing behaviour untouched.
--
-- The Red Zone borrows the arena's shapes, so it borrows the arena's zone ids
-- too -- there is one tenx-zones zone per arena and both resources point at
-- the same one. Nothing here creates or owns a shape.

RzZones = RzZones or {}

local RES = 'tenx-zones'

function RzZones.active()
    local cfg = Config.RZ and Config.RZ.zones
    if not (cfg and cfg.useExternal) then return false end
    return GetResourceState(RES) == 'started'
end

local failedOnce = {}

function RzZones.call(fn, ...)
    if not RzZones.active() then return nil end

    local ok, res = pcall(function(...)
        return exports[RES][fn](nil, ...)
    end, ...)

    if not ok then
        if not failedOnce[fn] then
            failedOnce[fn] = true
            print(('^1[redzone] tenx-zones:%s failed -- %s^0'):format(fn, tostring(res)))
        end
        return nil
    end

    return res
end

-- ============================================================
--  STARTUP CHECK
-- ============================================================

local NEEDED = {
    'GetExports', 'GetVersion',
    'ZoneExists', 'IsPlayerInZone', 'ValidateSpawn',
    'BindZoneToBucket', 'ReleaseZone', 'UnbindZoneFromBucket',
    'SuspendZone', 'ResumeZone', 'ClearSuspends',
    'RefreshPlayer', 'GetBindings',
}

function RzZones.check()
    if not (Config.RZ.zones and Config.RZ.zones.useExternal) then return true end

    if GetResourceState(RES) ~= 'started' then
        print('^1[redzone] Config.RZ.zones.useExternal is on but ' .. RES ..
              ' is not started. Refusing to run with no boundary owner.^0')
        return false
    end

    -- GetExports rather than a nil check per name: indexing a missing export
    -- THROWS in FiveM rather than returning nil, so the naive check is itself
    -- an error.
    local ok, list = pcall(function() return exports[RES]:GetExports() end)
    if not ok or type(list) ~= 'table' then
        print('^1[redzone] ' .. RES .. ' has no GetExports() -- too old for ' ..
              'this build.^0')
        return false
    end

    local have = {}
    for _, name in ipairs(list) do have[name] = true end

    local missing = {}
    for _, name in ipairs(NEEDED) do
        if not have[name] then missing[#missing + 1] = name end
    end

    if #missing > 0 then
        print('^1[redzone] ---- tenx-zones is missing exports ----^0')
        for _, name in ipairs(missing) do print('^1    ' .. name .. '^0') end
        return false
    end

    print('^2[redzone] tenx-zones boundary handover active^0')
    return true
end

-- ============================================================
--  THE ZONE FOR A RED ZONE
-- ============================================================
-- Asked of the arena, because the arena owns the arena-to-zone mapping. One
-- shape, two consumers -- there is no second zone for the Red Zone to own.

-- ============================================================
--  NO ARENA-ID TRANSLATION HERE
-- ============================================================
-- There used to be a zoneIdFor() and an insideZone() in this file that turned
-- an arena id into a zone id by asking the arena. Both are gone, and it is
-- worth saying why rather than leaving a gap.
--
-- Zone ids are NOT arena ids and never were. The live audit reads:
--
--     zone 1 = arena 1        zone 4 = arena 5
--     zone 2 = arena 3        zone 5 = arena 6
--     zone 3 = arena 4        zone 6 = arena 7
--
-- Arena 2 does not exist, so everything from Weed Ramps onward is offset.
-- Anything assuming they matched would have had GOV enforcing Groove
-- Street's boundary, silently.
--
-- This mode no longer has an arena id to translate. Its zones come from
-- GetZonesByTag and their ids ARE zone ids, all the way through: the picker
-- lists them, spawns key on them, membership tests take them. There is no
-- conversion left to get wrong.

-- ============================================================
--  THE DEATH WINDOW -- NOT NEEDED HERE
-- ============================================================
-- Deliberately empty, and worth saying why rather than leaving a gap.
--
-- Suspend claims exist to stop a clamp fighting a teleport. Red Zone domes
-- are passable in both directions and never clamp anyone, so there is nothing
-- to fight -- the ambulance script can move a downed player wherever it likes
-- and no boundary will drag them back.
--
-- The arena keeps its claims, because its walls are real. If Red Zone domes
-- are ever made solid, these come back with them.

function RzZones.claimDown(_) end
function RzZones.releaseDown(_) end

-- ============================================================
--  IS THIS KILL INSIDE THE ZONE
-- ============================================================

-- insideZone used to live here. Removed rather than left unused: its
-- fallback passed the id straight to the arena's insideArena, and the live
-- audit has since proved zone ids and arena ids are different number spaces
-- -- zone 4 is arena 5. It would have answered about the wrong shape, and
-- said nothing.
--
-- sameZone below is what the kill path uses, and it never converts anything.

--- Can an entry spawn live here?
---
--- 'outside', not 'inside'. The opposite of the arena's team spawns, and the
--- reason ValidateSpawn takes a direction at all.
--- @param zoneId number a tenx-zones sphere id, NOT an arena id
function RzZones.validateEntrySpawn(zoneId, coords)
    if not RzZones.active() then return nil end
    if not zoneId then return nil end

    -- The id IS the zone now.
    --
    -- Spawns used to key on an arena id and be translated through the arena's
    -- mapping. They key on the sphere directly since the Red Zone stopped
    -- borrowing the arena's shapes, so translating would look up a polygon
    -- that has nothing to do with the dome being marked.
    local ok, why = RzZones.call('ValidateSpawn', zoneId, coords,
        (Config.RZ.zones or {}).spawnTolerance or 5.0, 'outside')

    if ok == nil then return nil end
    return ok == true, why
end


-- ============================================================
--  SCHEMA UPGRADE
-- ============================================================
-- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, so
-- the new column never appears from re-running tenx-redzone.sql on a live server.
-- Added here instead, once, on boot.

local function ensureColumns()
    -- arena_id must become nullable first. A row keyed on zone_id has no
    -- arena, and NOT NULL would reject the insert -- which would look like
    -- spawn marking silently failing.
    pcall(function()
        MySQL.query.await('ALTER TABLE tenx_rz_spawns MODIFY `arena_id` INT NULL')
    end)

    pcall(function()
        MySQL.query.await('ALTER TABLE tenx_rz_spawns ADD COLUMN `zone_id` INT NULL')
    end)

    pcall(function()
        MySQL.query.await('ALTER TABLE tenx_rz_spawns ADD KEY `by_zone` (`zone_id`)')
    end)
end

-- ============================================================
--  THE ZONE LIST
-- ============================================================

--- Rebuild the offered zones from whatever carries the tag.
---
--- Fills the same Zones and Spawns shapes the old path produced, so
--- everything downstream -- the picker, the counts, the entry -- is unchanged.
---
--- A zone with no spawns is not offered at all. Better than computing a point
--- that knows nothing about what is actually there and dropping somebody on a
--- roof or in the sea.
--- Tell tenx-zones a player's bucket changed.
---
--- Removed by accident when the arena-id translation helpers went, which left
--- enter() calling a nil field and throwing before it could teleport anyone.
--- tenx-zones polls the bucket itself, so this is the instant path rather than
--- the only correct one -- but without it a player waits up to a poll interval
--- for the zone to apply.
function RzZones.refresh(src)
    if not RzZones.active() then return end
    RzZones.call('RefreshPlayer', src)
end

function RzZones.refreshZones()
    local tag = (Config.RZ.zones or {}).tag or 'redzone'
    local ids = RzZones.call('GetZonesByTag', tag)

    if type(ids) ~= 'table' then
        -- Could not ask. Leave the list alone rather than emptying it: an
        -- empty list closes the mode for everyone, and a failed call is not
        -- the same as "there are no zones".
        return false
    end

    local zones, spawns = RzZoneTables()
    local fresh = {}

    for _, zoneId in ipairs(ids) do
        local z = RzZones.call('GetZone', zoneId)

        if z and spawns[zoneId] and #spawns[zoneId] > 0 then
            fresh[zoneId] = {
                id = zoneId,
                name = z.name or ('Zone ' .. zoneId),
                spawnPoints = spawns[zoneId],
            }
        end
    end

    RzSetZones(fresh)
    return true
end

-- ============================================================
--  BINDING
-- ============================================================
-- Every tagged zone, bound once to the one standing bucket. Nothing binds or
-- releases per match, because there are no Red Zone matches -- it is a place.

function RzZones.bindAll(why)
    if not RzZones.active() then return end

    local tag = (Config.RZ.zones or {}).tag or 'redzone'
    local bucket = (Config.RZ.zones or {}).bucket or 2100

    local ids = RzZones.call('GetZonesByTag', tag)
    if type(ids) ~= 'table' then
        print('^3[redzone] could not read the zone list to bind^0')
        return
    end

    -- Empty opts. No armOnEntry: these domes are passable in both directions
    -- and never block anyone, so there is nothing to arm. The sphere marks
    -- where a fight is, it does not hold anybody in it.
    for _, zoneId in ipairs(ids) do
        RzZones.call('BindZoneToBucket', zoneId, bucket, {})
    end

    print(('[redzone] bound %s zone(s) to bucket %s after %s')
        :format(#ids, bucket, why))

    -- Verify rather than assume.
    local bindings = RzZones.call('GetBindings')
    if type(bindings) == 'table' then
        for _, zoneId in ipairs(ids) do
            if not bindings[zoneId] then
                print(('^3[redzone] zone %s did not bind^0'):format(zoneId))
            end
        end
    end
end

-- ============================================================
--  WHICH SPHERE IS THIS PLAYER IN
-- ============================================================

--- The zone a player is standing in, or nil.
---
--- Asked at the moment it matters rather than read from a membership table.
--- The entered/left events fire off a sweep and can be seconds stale, and in
--- a fast fight that is wrong often enough to notice.
function RzZones.zoneOf(src)
    if not RzZones.active() then return nil end

    local zones = RzZoneTables()
    for zoneId in pairs(zones or {}) do
        if RzZones.call('IsPlayerInZone', src, zoneId) == true then
            return zoneId
        end
    end

    return nil
end

--- Are both of them in the SAME sphere?
---
--- Same, not merely both inside something. Entry spawns sit outside the dome,
--- so without this the spawn area is a free hunting ground -- camp one
--- entrance, kill people who have not started yet, keep the coins and the
--- streak.
function RzZones.sameZone(a, b)
    local za = RzZones.zoneOf(a)
    if not za then return false, nil end
    if RzZones.call('IsPlayerInZone', b, za) ~= true then return false, nil end
    return true, za
end

-- ============================================================
--  RE-BINDING
-- ============================================================

function RzZones.rebind(why)
    RzZones.bindAll(why)
end

AddEventHandler('tenx-zones:server:ready', function(version)
    if not RzZones.active() then return end
    RzZones.rebind('a tenx-zones restart')
end)

-- Our own start. tenx-zones loads first, so `ready` has already been and gone
-- by now and is never waited for.
CreateThread(function()
    Wait(2500)
    if not RzZones.check() then return end

    ensureColumns()

    if RzReloadSpawns then RzReloadSpawns() end
    RzZones.bindAll('startup')
end)

AddEventHandler('playerDropped', function()
    local src = source
    if RzZones.active() then RzZones.call('ClearSuspends', src) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if not RzZones.active() then return end

    for _, id in ipairs(GetPlayers()) do
        local s = tonumber(id)
        if s then RzZones.call('ClearSuspends', s) end
    end
end)
