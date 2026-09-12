local cookieActive = false
local staminaLevel = 0

local function stopCookieEffect()
    cookieActive = false
    staminaLevel = 0
    SetRunSprintMultiplierForPlayer(PlayerId(), 1.0)
    SetSwimMultiplierForPlayer(PlayerId(), 1.0)
end

RegisterNetEvent('cookie:client:use', function()
    local ped = PlayerPedId()

    RequestAnimDict('mp_suicide')
    while not HasAnimDictLoaded('mp_suicide') do Wait(10) end

    TaskPlayAnim(ped, 'mp_suicide', 'pill', 8.0, -8.0, 2000, 49, 0, false, false, false)
    Wait(2000)
    StopAnimTask(ped, 'mp_suicide', 'pill', 1.0)

    -- If already active just refuel
    if cookieActive then
        staminaLevel = 100
        SetPedArmour(ped, 100)
        RestorePlayerStamina(PlayerId(), 1.0)
        return
    end

    -- Fresh effect
    cookieActive = true
    staminaLevel = 100
    SetPedArmour(ped, 100)
    SetRunSprintMultiplierForPlayer(PlayerId(), 1.49)
    SetSwimMultiplierForPlayer(PlayerId(), 1.0)
    RestorePlayerStamina(PlayerId(), 1.0)

    -- Drain loop
    CreateThread(function()
        while cookieActive do
            Wait(1000)
            staminaLevel = staminaLevel - 0.8
            if staminaLevel <= 0 then
                stopCookieEffect()
                break
            end
            -- Keep sprint bar full so player can always run while active
            RestorePlayerStamina(PlayerId(), 1.0)
        end
    end)
end)

-- Keep stamina maxed while cookie is active
CreateThread(function()
    while true do
        Wait(500)
        if cookieActive then
            RestorePlayerStamina(PlayerId(), 1.0)
        end
    end
end)