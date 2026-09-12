-- =====================================================================
--  tenx-plates | server: police change a vehicle's plate STATE (prefix + texture)
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

RegisterNetEvent('tenx-plates:server:setState', function(netId, oldPlate, stateKey)
    local src = source
    if not isPolice(src) then return end

    oldPlate = Plates.Normalize(oldPlate)
    local state = Plates.GetState(stateKey)
    if not state then return end

    -- must be a registered/owned car
    local ownerCid = MySQL.scalar.await(
        'SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { oldPlate })
    if not ownerCid then
        return TriggerClientEvent('QBCore:Notify', src, 'This car is not registered.', 'error')
    end

    -- generate a unique plate for the chosen state
    local newPlate, plateIndex
    for _ = 1, 25 do
        local p, idx = Plates.GenerateForState(stateKey, tostring(math.random()) .. os.time())
        local taken = MySQL.scalar.await(
            'SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1', { p })
        if not taken then newPlate, plateIndex = p, idx break end
    end
    if not newPlate then
        return TriggerClientEvent('QBCore:Notify', src, 'Could not generate a plate, try again.', 'error')
    end

    -- change the plate everywhere (cascade). No src passed = officer gets no keys.
    exports[GetCurrentResourceName()]:CascadePlate(oldPlate, newPlate)

    -- persist BOTH the plate and the matching texture index into props.
    local mods = MySQL.scalar.await(
        'SELECT mods FROM player_vehicles WHERE plate = ? LIMIT 1', { newPlate })
    if mods then
        local props = json.decode(mods) or {}
        props.plate = newPlate
        props.plateIndex = plateIndex
        MySQL.update.await('UPDATE player_vehicles SET mods = ? WHERE plate = ?',
            { json.encode(props), newPlate })
    end

    -- re-issue the OWNER's key for the new plate if they're online (keys are
    -- tied to the plate string, so a change would otherwise lock them out).
    local vk = Config.VehicleKeys
    if vk and vk.enabled then
        local ownerSrc = QBCore.Functions.GetPlayerByCitizenId(ownerCid)
        ownerSrc = ownerSrc and ownerSrc.PlayerData.source
        if ownerSrc then
            pcall(function()
                exports[vk.resource]:RemoveKey(ownerSrc, oldPlate, vk.localVehicle and true or false)
                exports[vk.resource]:GiveKey(ownerSrc, newPlate, vk.localVehicle and true or false)
            end)
        end
    end

    -- live-update the physical car for everyone (reuses the existing sync event)
    TriggerClientEvent('tenx-plates:client:sync', -1, netId, newPlate, plateIndex)
    TriggerClientEvent('QBCore:Notify', src,
        ('Plate changed to %s (%s).'):format(newPlate, state.label), 'success')
end)
