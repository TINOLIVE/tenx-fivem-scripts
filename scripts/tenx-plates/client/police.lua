-- =====================================================================
--  tenx-plates | client: police plate-state changer
--  Aim at / sit in / stand near a car, run /platestate, pick a state.
-- =====================================================================

local function getNearbyVehicle()
    local ped = PlayerPedId()
    local inVeh = GetVehiclePedIsIn(ped, false)
    if inVeh ~= 0 then return inVeh end

    -- otherwise the closest car within 5m
    local coords = GetEntityCoords(ped)
    local closest, best = nil, 5.0
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local d = #(coords - GetEntityCoords(veh))
        if d < best then closest, best = veh, d end
    end
    return closest
end

RegisterCommand('platestate', function()
    local veh = getNearbyVehicle()
    if not veh or veh == 0 then
        return lib.notify({ type = 'error', description = 'No vehicle nearby.' })
    end

    local netId = VehToNet(veh)
    local plate = Plates.Normalize(GetVehicleNumberPlateText(veh))

    local options = {}
    for _, s in ipairs(Config.States) do
        options[#options + 1] = {
            title = s.label,
            description = ('Reissue plate with a %s prefix'):format(s.label),
            onSelect = function()
                TriggerServerEvent('tenx-plates:server:setState', netId, plate, s.key)
            end,
        }
    end

    lib.registerContext({
        id = 'tx_plate_states',
        title = 'Change Plate State',
        options = options,
    })
    lib.showContext('tx_plate_states')
end, false)

-- Optional: bind a key in-game via FiveM settings to "+platestate", or keep
-- it as a chat command. Job permission is enforced SERVER-side, so a
-- non-police player running this just gets silently ignored.
