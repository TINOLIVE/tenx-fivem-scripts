-- =====================================================================
--  tenx-plates | server: job plates + keys (target-driven)
--  - Stamps fleet plate (NCPD / NCMS) ONLY if not already stamped.
--  - Removes the old spawn-plate key so there's a single key.
--  - No cleanup polling (removed by request).
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()

local function fleetPlateFor(job)
    return Config.JobPlatePrefix and Config.JobPlatePrefix[job]
end

RegisterNetEvent('tenx-plates:server:jobkey', function(job, netId, curPlate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not job or not netId then return end

    local pJob = Player.PlayerData.job
    if not pJob or pJob.name ~= job then return end
    if Config.JobVehiclesRequireOnDuty and not pJob.onduty then return end

    local vk = Config.VehicleKeys
    if not vk or not vk.enabled then return end
    local lv = vk.localVehicle and true or false

    local prefix = fleetPlateFor(job)
    curPlate = Plates.Normalize(curPlate or '')

    local plate
    if prefix then
        plate = prefix
        -- ONLY stamp + swap keys if the car isn't already on the fleet plate.
        -- Prevents re-stamping churn that makes ak47 hand out a "new" car.
        if curPlate ~= plate then
            TriggerClientEvent('tenx-plates:client:sync', -1, netId, plate)
            if curPlate ~= '' then
                pcall(function() exports[vk.resource]:RemoveKey(src, curPlate, lv) end)
            end
        end
    else
        plate = curPlate
    end

    if not plate or plate == '' then return end

    pcall(function() exports[vk.resource]:GiveKey(src, plate, lv) end)
end)