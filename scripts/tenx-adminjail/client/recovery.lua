-- tenx-adminjail/client/recovery.lua
-- NAIJA 2046 — Recovery tools (client side)
--
-- Two tiny handlers the server calls:
--   :revive    -> reproduces the ambulance revive on THIS client, faithfully
--   :rescueTP  -> fade + collision-safe teleport to a given spot

local Rec = Config.Recovery

-- ============================================================
--  REVIVE (run on the target's own client)
--  Faithful to ak47_qb_ambulancejob's own usage:
--    TriggerServerEvent('ak47_qb_ambulancejob:revive', myServerId)
--    TriggerEvent('ak47_qb_ambulancejob:skellyfix')
--  skellyfix is a LOCAL client event, so it MUST run here on the target — which
--  is the whole reason revive is a client event and not a server TriggerEvent.
-- ============================================================
RegisterNetEvent('tenx-adminjail:client:revive', function()
    local amb = Rec.ambulance
    local myId = GetPlayerServerId(PlayerId())

    local ok = pcall(function()
        TriggerServerEvent(amb.reviveServerEvent, myId)
    end)
    if not ok then
        print(('[tenx-adminjail] ^3recovery: revive event failed:^7 %s'):format(tostring(amb.reviveServerEvent)))
    end

    if amb.skellyFixEvent and amb.skellyFixEvent ~= '' then
        Wait(amb.skellyFixDelay or 500)
        pcall(function() TriggerEvent(amb.skellyFixEvent) end)
    end
end)

-- ============================================================
--  RESCUE TELEPORT (collision-safe — nobody falls through the map)
--  Same technique as the moon teleport: fade out, move, wait for collision to
--  stream in while frozen, fade back.
-- ============================================================
RegisterNetEvent('tenx-adminjail:client:rescueTP', function(coords)
    if not coords or not coords.x then return end

    DoScreenFadeOut(500)
    local t = GetGameTimer()
    while not IsScreenFadedOut() and GetGameTimer() - t < 3000 do Wait(0) end

    local ped = PlayerPedId()

    if IsPedInAnyVehicle(ped, false) then
        ClearPedTasksImmediately(ped)
        Wait(100)
        ped = PlayerPedId()
    end

    local x, y, z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    if coords.h then SetEntityHeading(ped, coords.h + 0.0) end

    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(x, y, z)
    t = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() - t < 8000 do
        RequestCollisionAtCoord(x, y, z)
        Wait(10)
    end
    Wait(150)
    FreezeEntityPosition(ped, false)

    DoScreenFadeIn(500)

    lib.notify({ type = 'inform', title = 'Moved by staff',
        description = 'You were teleported to safety.', duration = 6000 })
end)

-- ============================================================
--  HEAL ZONE DEBUG DRAW (staff only)
--  Toggle with the configured command. Draws a sphere at each zone so you can
--  walk the platform edges and confirm the radius covers everything. Purely
--  visual — changes nothing.
-- ============================================================
if Rec.healDebugCommand then
    local drawing = false

    RegisterCommand(Rec.healDebugCommand, function()
        -- staff gate: reuse the punishment system's own permission callback
        local ok = lib.callback.await('tenx-adminjail:canOpen', false)
        if not ok then
            lib.notify({ type = 'error', description = 'You are not permitted to use this.' })
            return
        end

        drawing = not drawing
        lib.notify({ type = 'inform',
            description = ('Heal zone draw %s'):format(drawing and 'ON' or 'OFF') })

        if not drawing then return end

        CreateThread(function()
            while drawing do
                Wait(0)
                for _, z in ipairs(Rec.HealZones or {}) do
                    if z.centre then
                        -- marker type 28 = sphere. Alpha low so you can see through it.
                        DrawMarker(28,
                            z.centre.x, z.centre.y, z.centre.z,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            (z.radius or 60.0) * 2.0, (z.radius or 60.0) * 2.0, (z.radius or 60.0) * 2.0,
                            25, 200, 120, 60,
                            false, false, 2, false, nil, nil, false)
                    end
                end
            end
        end)
    end, false)
end
