local function spawnPed(cfg, options)
    RequestModel(cfg.model)
    while not HasModelLoaded(cfg.model) do Wait(0) end
    local ped = CreatePed(0, cfg.model, cfg.coords.x, cfg.coords.y, cfg.coords.z - 1.0, cfg.coords.w, false, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    exports.ox_target:addLocalEntity(ped, options)
    return ped
end

local function openWeaponShop()
    local options = {}
    for k, v in pairs(Config.Weapons) do
        options[#options + 1] = {
            title = ('%s - ₦%s'):format(v.label, v.price),
            description = 'Buy weapon',
            icon = 'fa-solid fa-gun',
            onSelect = function() TriggerServerEvent('n46:prison:buy', k) end
        }
    end
    lib.registerContext({ id = 'tenx_weapon_shop', title = 'Weapon Shop', options = options })
    lib.showContext('tenx_weapon_shop')
end

CreateThread(function()
    -- medic ped
    spawnPed(Config.MedicPed, {
        {
            name = 'tenx_revive',
            icon = 'fa-solid fa-heart-pulse',
            label = ('Revive - ₦%s'):format(Config.ReviveCost),
            onSelect = function() TriggerServerEvent('n46:prison:revive') end
        },
        {
            name = 'tenx_heal',
            icon = 'fa-solid fa-kit-medical',
            label = ('Heal - ₦%s'):format(Config.HealCost),
            onSelect = function() TriggerServerEvent('n46:prison:heal') end
        }
    })

    -- weapon ped
    spawnPed(Config.WeaponPed, {
        {
            name = 'tenx_weapon_shop',
            icon = 'fa-solid fa-gun',
            label = 'Open Weapon Shop',
            onSelect = openWeaponShop
        }
    })
end)

-- fire ambulance job events after server approves
RegisterNetEvent('n46:prison:doRevive', function() TriggerEvent(Config.ReviveEvent) end)
RegisterNetEvent('n46:prison:doHeal', function() TriggerEvent(Config.HealEvent) end)

RegisterNetEvent('n46:prison:notify', function(msg, kind)
    lib.notify({ title = 'Prison', description = msg, type = kind or 'success' })
end)
