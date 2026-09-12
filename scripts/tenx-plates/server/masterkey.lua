-- =====================================================================
--  tenx-plates | server: police master key item
--  Registers the item; only police may use it. Grants a key server-side.
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()

local function isPolice(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData.job and Player.PlayerData.job.name
    for _, j in ipairs(Config.PoliceJobs or {}) do
        if job == j then return true end
    end
    return false
end

-- Item use: police master key -> tell client to unlock nearest car.
QBCore.Functions.CreateUseableItem(Config.MasterKeyItem or 'police_masterkey', function(source)
    local src = source
    if not isPolice(src) then
        return TriggerClientEvent('QBCore:Notify', src, 'You cannot use this.', 'error')
    end
    TriggerClientEvent('tenx-plates:client:masterUnlock', src)
end)

-- Grant an ak47 key for the unlocked car (police only).
RegisterNetEvent('tenx-plates:server:masterKey', function(plate)
    local src = source
    if not isPolice(src) then return end
    plate = Plates.Normalize(plate or '')
    if plate == '' then return end
    local vk = Config.VehicleKeys
    if not vk or not vk.enabled then return end
    pcall(function()
        exports[vk.resource]:GiveKey(src, plate, vk.localVehicle and true or false)
    end)
end)
