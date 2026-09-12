-- ============================================================
--  MIGRATION — arena polygons into tenx-zones
-- ============================================================
--  Run ONCE, from the server console:
--
--      arenazonemigrate          dry run, prints what it would do
--      arenazonemigrate go       does it
--
--  Safe to run again. importKey makes it converge rather than duplicate, so
--  a run that fails halfway can simply be repeated.
--
--  Requires tenx-zones started. Does NOT require Config.Zones.useExternal to
--  be on -- migrate first, check the shapes in the tenx-zones builder, then
--  flip the flag.
-- ============================================================

local RES = 'tenx-zones'

--- The key that makes this idempotent.
---
--- Not the zone NAME. Two arenas can legitimately be called the same thing,
--- renaming one in the builder would silently merge it into the other, and
--- a display name is something people change. The arena id is stable, never
--- reused, and never shown to a player.
local function importKeyFor(arenaId)
    return ('tenx:arena:%s'):format(arenaId)
end

RegisterCommand('arenazonemigrate', function(src, args)
    if src ~= 0 then
        print('[migrate] server console only')
        return
    end

    local commit = (args[1] == 'go')

    if GetResourceState(RES) ~= 'started' then
        print('^1[migrate] ' .. RES .. ' is not started.^0')
        return
    end

    local arenas = ArenaZoneState and ArenaZoneState() or nil
    if not arenas then
        print('^1[migrate] the arena has not finished loading yet -- wait and retry.^0')
        return
    end

    print('^3[migrate] ---- arena zones -> tenx-zones ----^0')
    if not commit then
        print('^3[migrate] DRY RUN. Nothing is written. Add "go" to commit.^0')
    end

    local done, skipped, failed = 0, 0, 0

    for id, a in pairs(arenas) do
        local key = importKeyFor(id)

        if not (a.bounds and a.bounds.points and #a.bounds.points >= 3) then
            print(('  ^3skip^0  arena %s (%s) -- no polygon to import'):format(id, a.name))
            skipped = skipped + 1

        elseif a.zoneId then
            -- Already pointing somewhere. Re-running with the same importKey
            -- updates that zone in place rather than making a second one, so
            -- this is reported rather than treated as an error.
            print(('  ^2have^0  arena %s (%s) -> zone %s'):format(id, a.name, a.zoneId))
            skipped = skipped + 1

        elseif not commit then
            print(('  ^2would^0 arena %s (%s) -- %s points, z %.1f..%.1f')
                :format(id, a.name, #a.bounds.points,
                        a.bounds.minZ or 0, a.bounds.maxZ or 0))
            done = done + 1

        else
            local ok, zoneId = pcall(function()
                return exports[RES]:CreateZone({
                    name      = a.name,
                    kind      = 'poly',
                    points    = a.bounds.points,
                    minZ      = a.bounds.minZ,
                    maxZ      = a.bounds.maxZ,

                    -- Solid, but every bind this resource makes uses
                    -- armOnEntry -- so a player placed outside is not clamped
                    -- in before they have walked in. Solid without arming
                    -- would break the Red Zone's entry on the first player.
                    solid     = true,
                    importKey = key,
                })
            end)

            if ok and zoneId then
                a.zoneId = zoneId

                if ArenaPersistZone then
                    ArenaPersistZone(id)
                end

                print(('  ^2ok^0    arena %s (%s) -> zone %s'):format(id, a.name, zoneId))
                done = done + 1
            else
                print(('  ^1fail^0  arena %s (%s) -- %s')
                    :format(id, a.name, tostring(zoneId)))
                failed = failed + 1
            end
        end
    end

    print(('^3[migrate] %s done, %s skipped, %s failed^0'):format(done, skipped, failed))

    if commit and failed == 0 and done > 0 then
        print('^2[migrate] Check the shapes in the tenx-zones builder before^0')
        print('^2[migrate] setting Config.Zones.useExternal = true.^0')
    end
end, true)

-- ============================================================
--  VERIFY — is each arena still pointing at its own shape?
-- ============================================================
--  arenazoneverify
--
--  Zone ids used to be reusable: AUTO_INCREMENT on MariaDB recomputes the
--  counter as MAX(id)+1 at startup, so deleting the highest-numbered zone and
--  restarting handed that id to the next one created. Deletes are soft now and
--  the id can never be reissued -- but our seven arenas were imported BEFORE
--  that changed, and PVP is already live against them.
--
--  So an arena could be pointing at an id that has since become a different
--  shape. It would not error. It would enforce the wrong boundary somewhere
--  else on the map, and the first anyone knew would be a player clamped in
--  mid-air over the wrong district.
--
--  Cheap to check, so it is checked rather than assumed.

RegisterCommand('arenazoneverify', function(src)
    if src ~= 0 then
        print('[verify] server console only')
        return
    end

    if GetResourceState(RES) ~= 'started' then
        print('^1[verify] ' .. RES .. ' is not started.^0')
        return
    end

    local arenas = ArenaZoneState and ArenaZoneState() or nil
    if not arenas then
        print('^1[verify] the arena has not finished loading yet -- wait and retry.^0')
        return
    end

    print('^3[verify] ---- arena -> zone mapping ----^0')

    local good, bad, unmapped, unkeyed = 0, 0, 0, 0

    for id, a in pairs(arenas) do
        if not a.zoneId then
            print(('  ^3none^0  arena %s (%s) -- not migrated'):format(id, a.name))
            unmapped = unmapped + 1
        else
            local key = importKeyFor(id)

            local ok, res, why, actualId = pcall(function()
                return exports[RES]:VerifyZoneMapping(a.zoneId, key)
            end)

            if not ok then
                print(('  ^1err^0   arena %s (%s) -- %s'):format(id, a.name, tostring(res)))
                bad = bad + 1

            elseif res == true then
                print(('  ^2ok^0    arena %s (%s) -> zone %s'):format(id, a.name, a.zoneId))
                good = good + 1

            else
                -- A zone drawn by hand rather than imported has no key. That
                -- is not a mismatch and must not be reported as one -- but it
                -- cannot be verified this way either, so it is called out
                -- separately and needs eyes on the shape.
                local reason = tostring(why or 'no reason given')

                if reason:find('no import key') or reason:find('import_key') then
                    print(('  ^3hand^0  arena %s (%s) -> zone %s -- drawn by hand, ' ..
                           'check the shape yourself'):format(id, a.name, a.zoneId))
                    unkeyed = unkeyed + 1
                else
                    print(('  ^1WRONG^0 arena %s (%s) -> zone %s'):format(id, a.name, a.zoneId))
                    print(('          %s'):format(reason))

                    if actualId then
                        print(('          ^2fix: set zoneId to %s^0'):format(actualId))
                    end

                    bad = bad + 1
                end
            end
        end
    end

    print(('^3[verify] %s ok, %s wrong, %s unmapped, %s hand-drawn^0')
        :format(good, bad, unmapped, unkeyed))

    if bad > 0 then
        print('^1[verify] Fix these before trusting the live PVP boundary.^0')
        print('^1[verify] arenazonerepair will re-point them from their import keys.^0')
    end
end, true)

-- ============================================================
--  REPAIR
-- ============================================================
--  arenazonerepair          dry run
--  arenazonerepair go       writes
--
--  Re-points each arena at whatever zone actually holds its import key. A
--  field update, not a re-migration -- the shapes are fine, only the ids
--  recorded against them are wrong.

RegisterCommand('arenazonerepair', function(src, args)
    if src ~= 0 then
        print('[repair] server console only')
        return
    end

    local commit = (args[1] == 'go')
    local arenas = ArenaZoneState and ArenaZoneState() or nil
    if not arenas then
        print('^1[repair] the arena has not finished loading yet.^0')
        return
    end

    if not commit then
        print('^3[repair] DRY RUN. Add "go" to commit.^0')
    end

    local fixed = 0

    for id, a in pairs(arenas) do
        local key = importKeyFor(id)

        local ok, found = pcall(function()
            return exports[RES]:GetZoneByImportKey(key)
        end)

        local foundId = ok and found and (type(found) == 'table' and found.id or found) or nil

        if foundId and foundId ~= a.zoneId then
            print(('  arena %s (%s): %s -> %s'):format(id, a.name,
                tostring(a.zoneId), tostring(foundId)))

            if commit then
                a.zoneId = foundId
                if ArenaPersistZone then ArenaPersistZone(id) end
            end

            fixed = fixed + 1
        end
    end

    print(('^3[repair] %s arena(s) %s^0'):format(fixed, commit and 'repaired' or 'would be repaired'))
end, true)
