-- =====================================================================
--  tenx-plates | client: item menu, live preview, apply + sync
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()

-- Server fires this when the plate kit item is used.
RegisterNetEvent('tenx-plates:client:open', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    -- Must be in the driver's seat of the vehicle.
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then
        return QBCore.Functions.Notify(Config.Text.notInVehicle, 'error')
    end

    local netId        = VehToNet(veh)
    local currentPlate = Plates.Normalize(GetVehicleNumberPlateText(veh))
    local currentIndex = GetVehicleNumberPlateTextIndex(veh)

    local designOptions = {}
    for _, d in ipairs(Config.Designs) do
        designOptions[#designOptions + 1] = { label = d.label, value = tostring(d.index) }
    end

    local input = lib.inputDialog(Config.Text.menuTitle, {
        { type = 'input',  label = Config.Text.inputText, default = currentPlate,
          max = Config.MaxPlateLength, required = true },
        { type = 'select', label = Config.Text.inputDesign, options = designOptions,
          default = tostring(currentIndex) },
    })
    if not input then return end

    local wantText  = Plates.Normalize(input[1])
    local wantIndex = tonumber(input[2]) or currentIndex

    -- LIVE PREVIEW on the real car (temporary until server confirms).
    SetVehicleNumberPlateText(veh, wantText)
    SetVehicleNumberPlateTextIndex(veh, wantIndex)

    local confirm = lib.alertDialog({
        header   = Config.Text.confirmTitle,
        content  = ('**%s**'):format(wantText),
        centered = true,
        cancel   = true,
    })

    if confirm ~= 'confirm' then
        SetVehicleNumberPlateText(veh, currentPlate)   -- revert preview
        SetVehicleNumberPlateTextIndex(veh, currentIndex)
        return
    end

    TriggerServerEvent('tenx-plates:server:apply',
        netId, currentPlate, currentIndex, wantText, wantIndex)
end)

-- Server broadcasts the CONFIRMED plate so everyone sees it.
RegisterNetEvent('tenx-plates:client:sync', function(netId, text, index)
    local veh = NetToVeh(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleNumberPlateText(veh, text)
        if index then SetVehicleNumberPlateTextIndex(veh, index) end
    end
end)

-- Server rejected the change -> undo the local preview.
RegisterNetEvent('tenx-plates:client:revert', function(netId, plate, index)
    local veh = NetToVeh(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleNumberPlateText(veh, plate)
        SetVehicleNumberPlateTextIndex(veh, index or 0)
    end
end)