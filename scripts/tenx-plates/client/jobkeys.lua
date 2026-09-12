-- =====================================================================
--  tenx-plates | client: job vehicle plates + keys (all-in-one)
--  - AUTO: on-duty member near their job car -> stamp NCPD/NCMS + swap
--    keys, ONCE per car (no loop churn).
--  - TARGET: "Get Key" option, only visible to the right on-duty job.
--  Target: ox_target.
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()

-- model HASH -> job
local modelToJob = {}
CreateThread(function()
    for job, models in pairs(Config.JobVehicles or {}) do
        for _, m in ipairs(models) do
            modelToJob[GetHashKey(m)] = job
        end
    end
end)

local function jobOfVeh(veh)
    if not veh or veh == 0 then return nil end
    return modelToJob[GetEntityModel(veh)]
end

local function fleetPlateFor(job)
    return Config.JobPlatePrefix and Config.JobPlatePrefix[job]
end

-- right job + on duty?
local function onDutyFor(job)
    local pd = QBCore.Functions.GetPlayerData()
    if not pd or not pd.job then return false end
    if pd.job.name ~= job then return false end
    if Config.JobVehiclesRequireOnDuty and not pd.job.onduty then return false end
    return true
end

-- shared: stamp plate locally + tell server to swap keys
local function applyFleet(veh, job)
    local prefix = fleetPlateFor(job)
    local netId  = VehToNet(veh)
    local old    = Plates.Normalize(GetVehicleNumberPlateText(veh))
    if prefix and old ~= prefix then
        SetVehicleNumberPlateText(veh, prefix)   -- instant local feedback
    end
    TriggerServerEvent('tenx-plates:server:jobkey', job, netId, old)
end

-- ---------- AUTO: handle each job car once, when on duty ----------
local handled = {}
CreateThread(function()
    while true do
        Wait(1000)
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if not handled[veh] and DoesEntityExist(veh) then
                local job = jobOfVeh(veh)
                if job and onDutyFor(job) then
                    handled[veh] = true
                    applyFleet(veh, job)
                end
            end
        end
        for veh in pairs(handled) do
            if not DoesEntityExist(veh) then handled[veh] = nil end
        end
    end
end)

-- ---------- TARGET: manual "Get Key" (right on-duty job only) ----------
CreateThread(function()
    exports.ox_target:addGlobalVehicle({
        {
            name  = 'txplates_getkey',
            icon  = 'fas fa-key',
            label = 'Get Key',
            distance = 3.0,
            canInteract = function(entity)
                local job = jobOfVeh(entity)
                return job ~= nil and onDutyFor(job)
            end,
            onSelect = function(data)
                local veh = data.entity
                local job = jobOfVeh(veh)
                if not job then return end
                applyFleet(veh, job)
                lib.notify({ type = 'success', description = 'Key received.' })
            end,
        },
    })
end)