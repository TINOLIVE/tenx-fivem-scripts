local elevators = {}
local points = {}
local traveling = false
local adminOpen = false
local nearFloor = nil -- { elev, floorIndex }


-- ================= DrawText3D =================
local function DrawText3D(x, y, z, text)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.36, 0.36)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(0, 135, 81, 255)
    SetTextEntry('STRING')
    SetTextCentre(true)
    AddTextComponentString(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ================= Travel =================
local function travelTo(elev, floor)
    if traveling then return end
    traveling = true

    local veh = GetVehiclePedIsIn(cache.ped, false)
    local moveVehicle = Config.VehicleTravel and elev.access.allowVehicles
        and veh ~= 0 and GetPedInVehicleSeat(veh, -1) == cache.ped

    if Config.SkipAnimation then
        if moveVehicle then
            SetEntityCoords(veh, floor.x, floor.y, floor.z, false, false, false, false)
            SetEntityHeading(veh, floor.h)
        else
            SetEntityCoords(cache.ped, floor.x, floor.y, floor.z, false, false, false, false)
            SetEntityHeading(cache.ped, floor.h)
        end
        traveling = false
        return
    end

    SendNUIMessage({ action = 'travel', floor = floor.label, duration = Config.TravelTime,
        audio = Config.ElevatorMusic })

    if Config.ScreenEffect then
        DoScreenFadeOut(400)
        local t = GetGameTimer()
        while not IsScreenFadedOut() and GetGameTimer() - t < 1500 do Wait(0) end
    end

    if moveVehicle then
        SetEntityCoords(veh, floor.x, floor.y, floor.z, false, false, false, false)
        SetEntityHeading(veh, floor.h)
    else
        SetEntityCoords(cache.ped, floor.x, floor.y, floor.z, false, false, false, false)
        SetEntityHeading(cache.ped, floor.h)
    end

    RequestCollisionAtCoord(floor.x, floor.y, floor.z)
    local t = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(cache.ped) and GetGameTimer() - t < 3000 do Wait(10) end

    Wait(Config.TravelTime)

    SendNUIMessage({ action = 'arrived', ding = Config.DingSound, gbam = Config.GbamSound })
    if Config.ScreenEffect then DoScreenFadeIn(500) end
    if Config.DingSound then PlaySoundFrontend(-1, 'Menu_Accept', 'Phone_SoundSet_Default', true) end
    TriggerServerEvent('aec:logUse', elev.id)
    traveling = false
end

local pickerElev = nil
local pickerFrom = nil
local pickerOpen = false

local function closePicker()
    pickerOpen = false
    pickerElev = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closePicker' })
end

local function openPicker(elev, fromIndex, needsPasscode)
    pickerElev = elev
    pickerFrom = fromIndex
    pickerOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'floorPicker',
        needsPasscode = needsPasscode and true or false,
        elev = {
            id = elev.id, name = elev.name, allowVehicles = elev.access.allowVehicles,
            floors = elev.floors, fromIndex = fromIndex - 1
        }
    })
end

local function useElevator(elev, fromIndex)
    if traveling or pickerOpen then return end
    local res = lib.callback.await('aec:checkAccess', false, elev.id)
    if res == true then
        openPicker(elev, fromIndex, false)
    elseif res == 'passcode' then
        openPicker(elev, fromIndex, true)
    else
        lib.notify({ type = 'error', description = (type(res) == 'string' and res) or 'Access denied.' })
    end
end

-- NUI: player picked a floor
RegisterNUICallback('pickFloor', function(data, cb)
    cb(true)
    local elev = pickerElev
    local idx = data and data.index
    closePicker()
    if elev and idx and elev.floors[idx + 1] then
        travelTo(elev, elev.floors[idx + 1])
    end
end)

-- NUI: passcode submitted from the picker
RegisterNUICallback('submitPasscode', function(data, cb)
    cb(true)
    if not pickerElev then return end
    local res = lib.callback.await('aec:checkAccess', false, pickerElev.id, tostring(data and data.code or ''))
    if res == true then
        SendNUIMessage({
            action = 'pickerFloors',
            elev = { id = pickerElev.id, name = pickerElev.name, allowVehicles = pickerElev.access.allowVehicles,
                floors = pickerElev.floors, fromIndex = pickerFrom - 1 }
        })
    else
        SendNUIMessage({ action = 'passcodeError', error = (type(res) == 'string' and res) or 'Wrong passcode' })
    end
end)

RegisterNUICallback('closeFloorPicker', function(_, cb)
    cb(true)
    closePicker()
end)

-- ================= Build interaction points =================
local function clearPoints()
    for _, p in pairs(points) do p:remove() end
    points = {}
end

local function buildPoints()
    clearPoints()
    for _, elev in ipairs(elevators) do
        for i, f in ipairs(elev.floors) do
            local pt = lib.points.new({ coords = vec3(f.x + 0.0, f.y + 0.0, f.z + 0.0), distance = Config.DrawDistance })
            pt.elev = elev
            pt.floorIndex = i
            pt.floorLabel = f.label
            function pt:nearby()
                DrawText3D(self.coords.x, self.coords.y, self.coords.z + 0.2, 'Elevator [E]')
                if self.currentDistance < Config.InteractDist then
                    nearFloor = { elev = self.elev, floorIndex = self.floorIndex }
                    if IsControlJustReleased(0, Config.InteractKey) and not adminOpen then
                        useElevator(self.elev, self.floorIndex)
                    end
                end
            end
            function pt:onExit()
                nearFloor = nil
            end
            points[#points + 1] = pt
        end
    end
end

local function refreshElevators()
    elevators = lib.callback.await('aec:getElevators', false) or {}
    buildPoints()
    if adminOpen then
        SendNUIMessage({ action = 'setData', elevators = elevators })
    end
end

CreateThread(function()
    Wait(1500)
    refreshElevators()
end)

RegisterNetEvent('aec:refresh', function()
    refreshElevators()
end)

-- ================= Admin panel =================
local function openAdmin()
    local data = lib.callback.await('aec:getData', false)
    if not data or not data.isAdmin then
        lib.notify({ type = 'error', description = 'You are not allowed to use this.' })
        return
    end
    adminOpen = true
    elevators = data.elevators
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openAdmin', brand = data.brand, elevators = data.elevators })
end

RegisterCommand(Config.AdminCommand, function() openAdmin() end, false)

RegisterNUICallback('closeAdmin', function(_, cb)
    adminOpen = false
    SetNuiFocus(false, false)
    cb(true)
end)

-- capture the player's current position for a floor
RegisterNUICallback('capturePosition', function(_, cb)
    local c = GetEntityCoords(cache.ped)
    local h = GetEntityHeading(cache.ped)
    cb({
        x = math.floor(c.x * 100) / 100,
        y = math.floor(c.y * 100) / 100,
        z = math.floor(c.z * 100) / 100,
        h = math.floor(h * 100) / 100
    })
end)

RegisterNUICallback('saveElevator', function(data, cb)
    TriggerServerEvent('aec:save', data)
    cb(true)
end)

RegisterNUICallback('deleteElevator', function(data, cb)
    TriggerServerEvent('aec:delete', data.id)
    cb(true)
end)

-- teleport admin to a floor (to stand there / verify)
RegisterNUICallback('teleportTo', function(data, cb)
    if data and data.x then
        SetEntityCoords(cache.ped, data.x + 0.0, data.y + 0.0, data.z + 0.0, false, false, false, false)
        if data.h then SetEntityHeading(cache.ped, data.h + 0.0) end
    end
    cb(true)
end)

RegisterNetEvent('aec:printIds', function(ids)
    print('^2==== YOUR IDENTIFIERS ====^7')
    for _, id in ipairs(ids) do print('  ^3' .. id .. '^7') end
    lib.notify({ description = 'Identifiers printed to F8.' })
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearPoints() end
end)
