local QBCore = exports['qb-core']:GetCoreObject()

local function notify(src, msg, kind)
    TriggerClientEvent('n46:prison:notify', src, msg, kind or 'success')
end

local function charge(src, amount)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local bank = Player.PlayerData.money[Config.Account] or 0
    if bank < amount then
        notify(src, 'Not enough money in bank', 'error')
        return false
    end
    Player.Functions.RemoveMoney(Config.Account, amount)
    return true
end

RegisterNetEvent('n46:prison:revive', function()
    local src = source
    if not charge(src, Config.ReviveCost) then return end
    TriggerClientEvent('n46:prison:doRevive', src)
    notify(src, ('₦%s deducted (Revive)'):format(Config.ReviveCost), 'success')
end)

RegisterNetEvent('n46:prison:heal', function()
    local src = source
    if not charge(src, Config.HealCost) then return end
    TriggerClientEvent('n46:prison:doHeal', src)
    notify(src, ('₦%s deducted (Heal)'):format(Config.HealCost), 'success')
end)

RegisterNetEvent('n46:prison:buy', function(weapon)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local item = Config.Weapons[weapon]
    if not item then return end
    if not charge(src, item.price) then return end
    exports.ox_inventory:AddItem(src, weapon, 1)
    notify(src, ('You bought %s for ₦%s'):format(item.label, item.price), 'success')
end)
