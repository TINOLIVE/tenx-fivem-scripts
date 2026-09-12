-- tenx-adminjail/client/moon.lua
-- NAIJA 2046 — "Send to Moon" (crisis parking)
--
-- No cuffs, no freeze, no leash, no timer. The player is teleported to the moon
-- point and left completely free to move. /unmoon puts them back on the exact
-- coords + heading they were standing on when you took them.
--
-- The client never decides anything here — it teleports when the server says so.
-- The target eye is only BUILT for staff, and the server re-checks the license
-- on every call, so hiding the option is convenience, not the security layer.

local Moon = Config.Moon

local isStaff  = false
local mooned   = false

-- ============================================================
--  TELEPORT (fade + collision load so nobody falls through the map)
-- ============================================================
local function teleportTo(coords)
    if not coords or not coords.x then return false end

    local fade = Moon.fadeTime or 500
    DoScreenFadeOut(fade)
    local t = GetGameTimer()
    while not IsScreenFadedOut() and GetGameTimer() - t < 3000 do Wait(0) end

    local ped = cache.ped

    -- eject from any vehicle first, or SetEntityCoords drags the car along
    if IsPedInAnyVehicle(ped, false) then
        ClearPedTasksImmediately(ped)
        Wait(100)
        ped = cache.ped
    end

    local x, y, z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0

    SetEntityCoords(ped, x, y, z, false, false, false, false)
    if coords.h then SetEntityHeading(ped, coords.h + 0.0) end

    -- hold them still while the ground streams in
    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(x, y, z)
    t = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() - t < 8000 do
        RequestCollisionAtCoord(x, y, z)
        Wait(10)
    end
    Wait(150)
    FreezeEntityPosition(ped, false)

    DoScreenFadeIn(fade)
    return true
end

-- ============================================================
--  SERVER-PUSHED EFFECTS
-- ============================================================
RegisterNetEvent('tenx-adminjail:client:applyMoon', function(data)
    if not data or not data.coords or not data.coords.x then
        print('[tenx-adminjail] ^1moon:^7 server sent no coords — moon point not saved? Run /' .. (Moon.setPointCommand or 'setmoon'))
        return
    end

    mooned = true
    LocalPlayer.state:set('naijaAdminMooned', true, true)

    teleportTo(data.coords)

    if data.resync then
        lib.notify({ type = 'inform', title = 'Moon',
            description = 'You are still on the moon. Staff will bring you back.', duration = 6000 })
    else
        lib.notify({ type = 'inform', title = 'Sent to the moon',
            description = (data.reason or 'Crisis resolution') .. '. Sit tight — staff will return you.', duration = 8000 })
    end
end)

RegisterNetEvent('tenx-adminjail:client:removeMoon', function(coords)
    mooned = false
    LocalPlayer.state:set('naijaAdminMooned', false, true)

    if coords and coords.x then
        teleportTo(coords)
        lib.notify({ type = 'success', title = 'Back on Earth',
            description = 'Returned to where you were taken from.', duration = 6000 })
    else
        -- return coords missing/corrupt: don't silently strand them
        lib.notify({ type = 'warning', title = 'Back on Earth',
            description = 'Your return spot could not be read — ask staff to move you.', duration = 8000 })
    end
end)

-- ============================================================
--  TEARDOWN
-- ============================================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    mooned = false
    FreezeEntityPosition(PlayerPedId(), false)
    LocalPlayer.state:set('naijaAdminMooned', false, true)
    DoScreenFadeIn(0)
end)

-- ============================================================
--  TARGET EYE (staff only — never registered for anyone else)
-- ============================================================
local function moonTarget(entity)
    local plyIdx = NetworkGetPlayerIndexFromPed(entity)
    if not plyIdx or plyIdx == -1 then
        lib.notify({ type = 'error', description = 'That is not a player.' })
        return
    end
    local serverId = GetPlayerServerId(plyIdx)
    if serverId == GetPlayerServerId(PlayerId()) then
        lib.notify({ type = 'error', description = 'You cannot moon yourself.' })
        return
    end

    local reason = Moon.defaultReason
    if Moon.askReason then
        local input = lib.inputDialog('Send to Moon', {
            { type = 'input', label = 'Reason', default = Moon.defaultReason, required = true },
        })
        if not input then return end
        reason = input[1]
    end

    local res = lib.callback.await('tenx-adminjail:moon:send', false, { target = serverId, reason = reason })
    lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
end

CreateThread(function()
    Wait(2000) -- let ox_lib + the server settle before asking

    isStaff = lib.callback.await('tenx-adminjail:canOpen', false) and true or false
    if not isStaff then return end

    exports[Config.TargetResource]:addGlobalPlayer({
        {
            name        = 'tenx_admin_moon',
            label       = Moon.targetLabel or 'Send to Moon',
            icon        = Moon.targetIcon or 'fa-solid fa-rocket',
            distance    = Moon.targetDistance or 3.0,
            canInteract = function()
                return isStaff and not mooned
            end,
            onSelect    = function(data)
                moonTarget(data.entity)
            end,
        },
    })
end)

-- ============================================================
--  /setmoon — stand on the spot, run it, press E (same flow as the jail tool)
-- ============================================================
RegisterCommand(Moon.setPointCommand or 'setmoon', function()
    if not isStaff then
        lib.notify({ type = 'error', description = 'You are not permitted to use this.' })
        return
    end

    lib.notify({ description = 'Stand where the moon should be • E to save • X to cancel' })

    CreateThread(function()
        local capturing = true
        while capturing do
            Wait(0)
            local ped = cache.ped
            local c = GetEntityCoords(ped)
            DrawMarker(1, c.x, c.y, c.z - 1.0, 0,0,0, 0,0,0, 0.6,0.6,0.4, 150,150,255,120, false,false,2,false,nil,nil,false)

            if IsControlJustReleased(0, Config.SaveKey) then
                capturing = false
                local coords = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) }
                local input = lib.inputDialog('Name the moon point', {
                    { type = 'input', label = 'Label', required = true, default = 'Moon' },
                })
                if input and input[1] then
                    local res = lib.callback.await('tenx-adminjail:moon:savePoint', false, {
                        label = input[1], coords = coords,
                    })
                    lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                end
            elseif IsControlJustReleased(0, Config.CancelKey) then
                capturing = false
                lib.notify({ description = 'Cancelled.' })
            end
        end
    end)
end, false)
