-- =====================================================================
--  tenx-plates | client: police master key
--  Server tells us to unlock the nearest car (any owner).
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()

local function nearestVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then return veh end
    local coords = GetEntityCoords(ped)
    local closest, best = nil, 8.0
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(coords - GetEntityCoords(v))
        if d < best then closest, best = v, d end
    end
    return closest
end

RegisterNetEvent('tenx-plates:client:masterUnlock', function()
    local veh = nearestVehicle()
    if not veh or veh == 0 then
        return lib.notify({ type = 'error', description = 'No vehicle nearby.' })
    end

    -- unlock it
    SetVehicleDoorsLocked(veh, 1)          -- 1 = unlocked
    SetVehicleDoorsLockedForAllPlayers(veh, false)

    -- also grant an ak47 key for it so it stays drivable, if configured
    local vk = Config.VehicleKeys
    if vk and vk.enabled then
        local plate = Plates.Normalize(GetVehicleNumberPlateText(veh))
        TriggerServerEvent('tenx-plates:server:masterKey', plate)
    end

    lib.notify({ type = 'success', description = 'Vehicle unlocked.' })
end)
