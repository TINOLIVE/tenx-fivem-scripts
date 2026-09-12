--[[
    tenx-zones :: teleport (v2)

    The client half of the server side TeleportPlayer export.

    This exists for callers with no client sequence of their own --
    a server side admin tool, or another server using this resource.

    tenx-arena should NOT use it. Arena already has safeTeleport
    with a proper collision wait and a five height ground probe, and
    that is the right home for it. Wrap that in SuspendLocal /
    ResumeLocal instead and keep every line of it.

    What follows is a competent version of the same idea, not a match
    for a tuned one.
]]

local function groundAt(x, y, z)
    -- Probe downward from several heights. A single probe at the
    -- requested Z finds nothing when the requested Z is under the map
    -- or high above it.
    for _, h in ipairs({ z + 25.0, z + 5.0, z + 100.0, 500.0, 1000.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x, y, h, false)
        if found then return gz end
    end
    return nil
end

RegisterNetEvent('tenx-zones:doTeleport', function(x, y, z, reason)
    CreateThread(function()
        local ped = PlayerPedId()

        exports[GetCurrentResourceName()]:SuspendLocal(reason)

        DoScreenFadeOut(350)
        local fadeWait = 0
        while not IsScreenFadedOut() and fadeWait < 2000 do
            Wait(50); fadeWait = fadeWait + 50
        end

        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 then
            TaskLeaveVehicle(ped, veh, 16)
            Wait(400)
            ped = PlayerPedId()
        end

        FreezeEntityPosition(ped, true)
        SetEntityCollision(ped, false, false)
        SetEntityCoordsNoOffset(ped, x, y, z + 20.0, false, false, false)

        RequestCollisionAtCoord(x, y, z)
        local waited = 0
        while not HasCollisionLoadedAroundEntity(ped) and waited < 12000 do
            RequestCollisionAtCoord(x, y, z)
            Wait(100)
            waited = waited + 100
        end

        local gz = groundAt(x, y, z)

        SetEntityCollision(ped, true, true)
        SetEntityCoordsNoOffset(ped, x, y, (gz and gz + 0.5) or z, false, false, false)
        ClearPedTasksImmediately(ped)

        Wait(250)
        FreezeEntityPosition(ped, false)
        DoScreenFadeIn(400)

        -- Tell the server it landed. That releases the claim, which
        -- disarms any armOnEntry zone we have left, so the player can
        -- walk back in rather than being clamped straight back.
        TriggerServerEvent('tenx-zones:teleportDone', reason)
        exports[GetCurrentResourceName()]:ResumeLocal(reason)
    end)
end)
