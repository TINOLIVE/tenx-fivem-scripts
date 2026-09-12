local QBCore = exports['qb-core']:GetCoreObject()
local menuOpen = false
local lastVehicle = nil   -- last car spawned by this menu (for showcase mode)
local lastPlate   = nil   -- plate of last spawned car (for virtual key cleanup)

-- Spawn a vehicle at the player, warp them in, give a plate + keys (best-effort)
local function spawnVehicle(model, showcase)
    local hash = type(model) == 'string' and joaat(model) or model
    if not IsModelInCdimage(hash) then
        QBCore.Functions.Notify('Invalid / not-streamed model: ' .. tostring(model), 'error')
        return
    end

    if lastPlate then
        pcall(function() exports['ak47_qb_vehiclekeys']:RemoveVirtualKey(lastPlate) end)
        lastPlate = nil
    end

    if showcase and lastVehicle and DoesEntityExist(lastVehicle) then
        SetEntityAsMissionEntity(lastVehicle, true, true)
        DeleteVehicle(lastVehicle)
        lastVehicle = nil
    end

    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) do
        Wait(0)
        if GetGameTimer() - started > 10000 then
            QBCore.Functions.Notify('Model took too long to load: ' .. tostring(model), 'error')
            return
        end
    end

    local ped     = PlayerPedId()
    local coords   = GetEntityCoords(ped)
    local heading  = GetEntityHeading(ped)
    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, heading, true, false)

    SetVehicleOnGroundProperly(veh)
    SetEntityAsMissionEntity(veh, true, true)
    TaskWarpPedIntoVehicle(ped, veh, -1)

    local plate = 'ADM' .. math.random(1000, 9999)
    SetVehicleNumberPlateText(veh, plate)
    SetVehicleFuelLevel(veh, 100.0)
    SetVehicleEngineOn(veh, true, true, false)
    SetModelAsNoLongerNeeded(hash)

    exports['ak47_qb_vehiclekeys']:GiveVirtualKey(plate)
    lastPlate   = plate
    lastVehicle = veh
    QBCore.Functions.Notify('Spawned ' .. tostring(model), 'success')
end

local function openMenu(vehicles, items, imports, captured, imageUrls)
    menuOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', vehicles = vehicles, items = items, imports = imports, captured = captured, imageUrls = imageUrls })
end

local function closeMenu()
    menuOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('spawn_menu:open', function(vehicles, items, imports, captured, imageUrls)
    openMenu(vehicles, items, imports, captured, imageUrls)
end)

RegisterNetEvent('spawn_menu:updateImports', function(imports)
    SendNUIMessage({ action = 'imports', imports = imports })
end)

RegisterNetEvent('spawn_menu:captured', function(captured)
    SendNUIMessage({ action = 'captured', captured = captured })
end)

-- NEW v2: pushed after a rename/reset - refreshes both vehicle + import lists live
RegisterNetEvent('spawn_menu:updateVehicles', function(vehicles, imports)
    SendNUIMessage({ action = 'vehicles', vehicles = vehicles, imports = imports })
end)

RegisterNUICallback('spawnVehicle', function(data, cb)
    if data and data.model then spawnVehicle(data.model, data.showcase) end
    cb('ok')
end)

RegisterNUICallback('giveItem', function(data, cb)
    if data and data.name then
        TriggerServerEvent('spawn_menu:giveItem', data.name, data.amount or 1)
    end
    cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
    closeMenu()
    cb('ok')
end)

-- NEW v2: rename a vehicle (persists server-side)
RegisterNUICallback('renameVehicle', function(data, cb)
    if data and data.model and data.label then
        TriggerServerEvent('spawn_menu:renameVehicle', data.model, data.label)
    end
    cb('ok')
end)

-- NEW v2: reset a vehicle's name back to default
RegisterNUICallback('resetVehicleName', function(data, cb)
    if data and data.model then
        TriggerServerEvent('spawn_menu:resetVehicleName', data.model)
    end
    cb('ok')
end)

-- ============================================================
--  CAR PHOTO CAPTURE (uses screenshot-basic)
-- ============================================================
local CAPTURE_COORDS  = vector3(-2044.0, 3216.0, 32.81) -- Fort Zancudo runway (flat & empty)
local CAPTURE_HEADING = 60.0
local capturing = false

RegisterCommand('stopcapture', function() capturing = false end, false)

local function captureVehicles(models)
    if capturing then QBCore.Functions.Notify('Already capturing...', 'error'); return end
    if GetResourceState('screenshot-basic') ~= 'started' then
        QBCore.Functions.Notify('screenshot-basic is not started (add: ensure screenshot-basic)', 'error'); return
    end
    capturing = true
    closeMenu()
    Wait(300)

    local ped  = PlayerPedId()
    local pid  = PlayerId()
    local home = GetEntityCoords(ped)
    local homeH = GetEntityHeading(ped)
    local spot = CAPTURE_COORDS

    DoScreenFadeOut(200)
    Wait(350)
    DisplayRadar(false)
    SetPlayerControl(pid, false, 0)
    RequestCollisionAtCoord(spot.x, spot.y, spot.z)
    SetEntityCoords(ped, spot.x, spot.y, spot.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)

    local ct = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() - ct < 8000 do
        RequestCollisionAtCoord(spot.x, spot.y, spot.z)
        Wait(20)
    end
    Wait(400)

    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    RenderScriptCams(true, false, 0, true, true)
    DoScreenFadeIn(400)
    Wait(300)

    local total = #models
    local curIdx, saved = 0, 0

    CreateThread(function()
        while capturing do
            SetTextFont(4); SetTextScale(0.55, 0.55); SetTextColour(255, 255, 255, 255); SetTextOutline(); SetTextCentre(true)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName(('Taking pictures  %d / %d'):format(curIdx, total))
            EndTextCommandDisplayText(0.5, 0.86)
            SetTextFont(4); SetTextScale(0.42, 0.42); SetTextColour(255, 120, 120, 255); SetTextOutline(); SetTextCentre(true)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName('Press BACKSPACE (or /stopcapture) to cancel')
            EndTextCommandDisplayText(0.5, 0.90)
            Wait(0)
        end
    end)

    for i = 1, total do
        if not capturing then break end
        curIdx = i
        SetPlayerWantedLevel(pid, 0, false); SetPlayerWantedLevelNow(pid, false)
        local model = models[i]
        local hash = joaat(model)
        if IsModelInCdimage(hash) then
            RequestModel(hash)
            local t = GetGameTimer()
            while not HasModelLoaded(hash) and GetGameTimer() - t < 8000 do Wait(0) end
            if HasModelLoaded(hash) then
                local veh = CreateVehicle(hash, spot.x, spot.y, spot.z, CAPTURE_HEADING, false, false)
                SetVehicleOnGroundProperly(veh)
                FreezeEntityPosition(veh, true)
                SetVehicleDirtLevel(veh, 0.0)
                SetVehicleDoorsShut(veh, true)

                local camPos = GetOffsetFromEntityInWorldCoords(veh, 4.2, 5.5, 1.6)
                SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
                PointCamAtEntity(cam, veh, 0.0, 0.0, 0.4, true)
                Wait(800)

                local done = false
                exports['screenshot-basic']:requestScreenshot({ encoding = 'png', quality = 1.0 }, function(data)
                    TriggerServerEvent('spawn_menu:saveShot', model, tostring(data))
                    saved = saved + 1
                    done = true
                end)
                local wt = GetGameTimer()
                while not done and GetGameTimer() - wt < 6000 do Wait(0) end

                SetEntityAsMissionEntity(veh, true, true)
                DeleteVehicle(veh)
                SetModelAsNoLongerNeeded(hash)
            end
        end
        if IsControlJustPressed(0, 177) then capturing = false end
        Wait(40)
    end

    capturing = false
    DoScreenFadeOut(250)
    Wait(300)
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, true)
    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    SetPlayerControl(pid, true, 0)
    SetEntityCoords(ped, home.x, home.y, home.z, false, false, false, false)
    SetEntityHeading(ped, homeH)
    DisplayRadar(true)
    Wait(250)
    DoScreenFadeIn(400)
    QBCore.Functions.Notify(('Captured %d photos. Reopen the menu (Fivemanage) or restart spawn_menu (local).'):format(saved), 'success')
end

RegisterNUICallback('capturePhotos', function(data, cb)
    local models = (data and data.models) or {}
    if #models > 0 then captureVehicles(models) end
    cb('ok')
end)

RegisterNUICallback('resetPhotos', function(_, cb)
    TriggerServerEvent('spawn_menu:resetPhotos')
    cb('ok')
end)

RegisterNUICallback('addImports', function(data, cb)
    if data and data.text then TriggerServerEvent('spawn_menu:addImports', data.text) end
    cb('ok')
end)

RegisterNUICallback('removeImport', function(data, cb)
    if data and data.model then TriggerServerEvent('spawn_menu:removeImport', data.model) end
    cb('ok')
end)

RegisterNUICallback('clearImports', function(_, cb)
    TriggerServerEvent('spawn_menu:clearImports')
    cb('ok')
end)

-- ESC closes the menu
CreateThread(function()
    while true do
        if menuOpen then
            if IsControlJustReleased(0, 322) or IsControlJustReleased(0, 177) then
                closeMenu()
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)
