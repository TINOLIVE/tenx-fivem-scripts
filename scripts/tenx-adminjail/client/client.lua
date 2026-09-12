-- tenx-adminjail/client/main.lua
-- NAIJA 2046 — Admin Punishment System (client: menu + punishment effects)
-- The client only shows UI and applies visual/lockdown effects when the SERVER
-- tells it to. It cannot self-cuff or self-release.
--
-- RESTART BEHAVIOUR: on resource stop this file tears everything down (unfreeze,
-- clear anims, delete props/vehicle, clear statebags) so nothing is left stuck.
-- On resource start the SERVER re-pushes every active punishment, so effects
-- come straight back and timers resume from the DB.

-- ============================================================
--  PROP HELPERS (shared by every punishment type)
-- ============================================================
local function loadModel(name)
    local model = joaat(name)
    if not IsModelValid(model) then
        print(('[tenx-adminjail] ^1invalid prop model:^7 %s (skipped)'):format(tostring(name)))
        return nil
    end
    RequestModel(model)
    local t = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - t < 3000 do Wait(10) end
    if not HasModelLoaded(model) then
        print(('[tenx-adminjail] ^3prop model failed to load:^7 %s'):format(tostring(name)))
        return nil
    end
    return model
end

-- Attach a list of prop configs to our ped. Returns a table of entity handles.
local function attachProps(list)
    local out = {}
    if not list then return out end
    local ped = cache.ped
    for _, cfg in ipairs(list) do
        local model = loadModel(cfg.model)
        if model then
            local c = GetEntityCoords(ped)
            local obj = CreateObject(model, c.x, c.y, c.z, false, false, false)
            local pos = cfg.pos or { x = 0.0, y = 0.0, z = 0.0 }
            local rot = cfg.rot or { x = 0.0, y = 0.0, z = 0.0 }
            AttachEntityToEntity(
                obj, ped, GetPedBoneIndex(ped, cfg.bone or 28422),
                pos.x + 0.0, pos.y + 0.0, pos.z + 0.0,
                rot.x + 0.0, rot.y + 0.0, rot.z + 0.0,
                true, true, false, true, 1, true
            )
            SetModelAsNoLongerNeeded(model)
            out[#out + 1] = obj
        end
    end
    return out
end

-- Spawn a list of "mess" props around a saved location (coords + heading).
local function spawnMess(list, coords)
    local out = {}
    if not list or not coords then return out end
    local h = (coords.h or 0.0) + 0.0
    for _, m in ipairs(list) do
        local model = loadModel(m.model)
        if model then
            local o = m.offset or { x = 0.0, y = 0.0, z = 0.0 }
            local p = GetObjectOffsetFromCoords(
                coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, h,
                o.x + 0.0, o.y + 0.0, o.z + 0.0
            )
            local obj = CreateObject(model, p.x, p.y, p.z, false, false, false)
            SetEntityHeading(obj, h + (m.heading or 0.0))
            if m.ground ~= false then PlaceObjectOnGroundProperly(obj) end
            FreezeEntityPosition(obj, true)
            SetModelAsNoLongerNeeded(model)
            out[#out + 1] = obj
        end
    end
    return out
end

local function deleteProps(list)
    if not list then return end
    for _, obj in ipairs(list) do
        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, true, true)
            DeleteEntity(obj)
        end
    end
end

local function loadAnim(dict)
    if not dict then return end
    if not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
        local t = GetGameTimer()
        while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 3000 do Wait(10) end
    end
end

-- ============================================================
--  HARD CUFF EFFECTS
-- ============================================================
local cuffActive = false
local cuffAnchor = nil
local cuffProps  = {}

local function startCuff(reason)
    if cuffActive then return end
    cuffActive = true

    local ped = cache.ped
    cuffAnchor = GetEntityCoords(ped)

    loadAnim(Config.Cuff.animDict)
    cuffProps = attachProps(Config.Cuff.props)

    -- Lock inventory (ox_inventory reads this) and disable this player's own third-eye.
    LocalPlayer.state:set('invBusy', true, true)
    LocalPlayer.state:set('naijaAdminLocked', true, true) -- synced flag for other resources
    pcall(function() exports[Config.TargetResource]:disableTargeting(true) end)

    lib.notify({ type = 'error', title = 'You have been cuffed by staff', description = 'Reason: ' .. (reason or 'N/A'), duration = 8000 })

    CreateThread(function()
        while cuffActive do
            local p = cache.ped -- re-read each loop so respawns are handled

            if not IsEntityDead(p) then
                -- keep the cuffed pose playing
                if not IsEntityPlayingAnim(p, Config.Cuff.animDict, Config.Cuff.animName, 3) then
                    TaskPlayAnim(p, Config.Cuff.animDict, Config.Cuff.animName, 8.0, -8.0, -1, 49, 0, false, false, false)
                end

                FreezeEntityPosition(p, true)

                -- anti-move: if dragged/carried past the leash, snap back
                if cuffAnchor then
                    local dist = #(GetEntityCoords(p) - cuffAnchor)
                    if dist > Config.Cuff.leashDistance then
                        SetEntityCoords(p, cuffAnchor.x, cuffAnchor.y, cuffAnchor.z, false, false, false, false)
                    end
                end

                -- block actions
                DisableControlAction(0, 24, true)  DisableControlAction(0, 25, true)  -- attack / aim
                DisableControlAction(0, 47, true)  DisableControlAction(0, 58, true)  -- weapons
                DisableControlAction(0, 263, true) DisableControlAction(0, 264, true) -- melee
                DisableControlAction(0, 140, true) DisableControlAction(0, 141, true)
                DisableControlAction(0, 142, true) DisableControlAction(0, 143, true)
                DisableControlAction(0, 45, true)  -- reload
                DisableControlAction(0, 22, true)  -- jump
                DisableControlAction(0, 44, true)  -- cover
                DisableControlAction(0, 37, true)  -- weapon wheel
                DisableControlAction(0, 23, true)  DisableControlAction(0, 75, true)  -- enter/exit vehicle
                DisableControlAction(0, 38, true)  -- E interact
                DisableControlAction(0, 21, true)  -- sprint
            end

            Wait(0)
        end
    end)
end

local function stopCuff(releaseCoords)
    if not cuffActive then return end
    cuffActive = false

    local ped = cache.ped
    ClearPedTasks(ped)
    FreezeEntityPosition(ped, false)
    deleteProps(cuffProps)
    cuffProps = {}

    LocalPlayer.state:set('invBusy', false, true)
    LocalPlayer.state:set('naijaAdminLocked', false, true)
    pcall(function() exports[Config.TargetResource]:disableTargeting(false) end)

    if releaseCoords and releaseCoords.x then
        SetEntityCoords(ped, releaseCoords.x + 0.0, releaseCoords.y + 0.0, releaseCoords.z + 0.0, false, false, false, false)
        if releaseCoords.h then SetEntityHeading(ped, releaseCoords.h + 0.0) end
    end

    cuffAnchor = nil
    lib.notify({ type = 'success', title = 'Released', description = 'You have been released by staff.', duration = 6000 })
end

RegisterNetEvent('tenx-adminjail:client:applyCuff', function(data)
    startCuff(data and data.reason)
end)

RegisterNetEvent('tenx-adminjail:client:removeCuff', function(coords)
    stopCuff(coords)
end)

-- ============================================================
--  ADMIN JAIL EFFECTS
-- ============================================================
local jailActive   = false
local jailCenter   = nil    -- vector3
local jailRadius   = 30.0
local jailInfinite = false
local jailEndTime  = nil    -- GetGameTimer() ms when a finite sentence ends

local function drawFlash(text, duration)
    CreateThread(function()
        local endAt = GetGameTimer() + duration
        while GetGameTimer() < endAt do
            Wait(0)
            if math.floor(GetGameTimer() / 250) % 2 == 0 then   -- flash on/off
                SetTextFont(1) SetTextScale(2.2, 2.2)
                SetTextColour(200, 0, 0, 255) SetTextCentre(true)
                SetTextOutline()
                SetTextEntry('STRING') AddTextComponentSubstringPlayerName(text)
                DrawText(0.5, 0.42)
            end
        end
    end)
end

local function fmtTime(secs)
    if secs < 0 then secs = 0 end
    return ('%02d:%02d'):format(math.floor(secs / 60), math.floor(secs % 60))
end

local function stopJail(coords)
    if not jailActive then return end
    jailActive = false
    jailCenter, jailEndTime, jailInfinite = nil, nil, false
    LocalPlayer.state:set('naijaAdminJailed', false, true)
    pcall(function() exports[Config.TargetResource]:disableTargeting(false) end)
    if coords and coords.x then
        SetEntityCoords(cache.ped, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, false, false, false, false)
        if coords.h then SetEntityHeading(cache.ped, coords.h + 0.0) end
    end
    lib.notify({ type = 'success', title = 'Released', description = 'Your jail sentence is over.', duration = 6000 })
end

local function startJail(data)
    -- `resync` = we're re-applying after a restart, so skip the flash/notify spam
    -- but still rebuild the leash + HUD from the server's saved time_served.
    if jailActive then return end
    jailActive   = true
    jailCenter   = data.coords and vector3(data.coords.x + 0.0, data.coords.y + 0.0, data.coords.z + 0.0) or GetEntityCoords(cache.ped)
    jailRadius   = data.radius or 30.0
    jailInfinite = (data.duration == nil)
    if not jailInfinite then
        local remaining = data.duration - (data.timeServed or 0)
        jailEndTime = GetGameTimer() + (remaining * 1000)
    else
        jailEndTime = nil
    end

    LocalPlayer.state:set('naijaAdminJailed', true, true)
    pcall(function() exports[Config.TargetResource]:disableTargeting(true) end)

    SetEntityCoords(cache.ped, jailCenter.x, jailCenter.y, jailCenter.z, false, false, false, false)

    if data.resync then
        lib.notify({ type = 'inform', title = 'Still jailed', description = 'Your sentence continues where it stopped.', duration = 6000 })
    else
        lib.notify({ type = 'error', title = 'You have been jailed by staff', description = 'Reason: ' .. (data.reason or 'N/A'), duration = 8000 })
        drawFlash(Config.Jail.overlayText, Config.Jail.overlayDuration)
    end

    CreateThread(function()
        while jailActive do
            Wait(0)
            local ped = cache.ped

            -- radius leash: any exit (including someone else's noclip) snaps back
            if #(GetEntityCoords(ped) - jailCenter) > jailRadius then
                SetEntityCoords(ped, jailCenter.x, jailCenter.y, jailCenter.z, false, false, false, false)
            end

            -- block outfit-change controls (E, etc.); third-eye already off
            for _, ctrl in ipairs(Config.Jail.disabledControls) do
                DisableControlAction(0, ctrl, true)
            end

            -- persistent HUD: bar + timer + status line
            local label
            if jailInfinite then
                label = '~r~INFINITE'
            else
                label = '~w~' .. fmtTime((jailEndTime - GetGameTimer()) / 1000)
            end
            DrawRect(0.5, 0.94, 0.24, 0.05, 0, 0, 0, 150)
            SetTextFont(4) SetTextScale(0.45, 0.45) SetTextColour(255, 255, 255, 255) SetTextCentre(true)
            SetTextEntry('STRING') AddTextComponentSubstringPlayerName('Currently being jailed by an admin  •  ' .. label)
            DrawText(0.5, 0.925)
        end
    end)
end

RegisterNetEvent('tenx-adminjail:client:applyJail', function(data) startJail(data) end)
RegisterNetEvent('tenx-adminjail:client:removeJail', function(coords) stopJail(coords) end)
RegisterNetEvent('tenx-adminjail:client:jailSync', function(data)
    if jailActive and not jailInfinite and data and data.remaining then
        jailEndTime = GetGameTimer() + (data.remaining * 1000)   -- resync to server clock
    end
end)

-- ============================================================
--  COMMUNITY SERVICE EFFECTS
-- ============================================================
local csActive      = false
local csRequired    = 0
local csDone        = 0
local csSpots       = {}
local csCurrentSpot = nil
local csVehicle     = nil
local csMessProps   = {}
local csHandProps   = {}

local function jobCfg(job)
    local jobs = Config.CommunityService.jobs
    return jobs[job] or jobs.sweep
end

local function applyUniform()
    local ped = cache.ped
    local set = (GetEntityModel(ped) == `mp_f_freemode_01`) and Config.CommunityService.uniform.female or Config.CommunityService.uniform.male
    for _, c in ipairs(set) do
        SetPedComponentVariation(ped, c.component, c.drawable, c.texture, 0)
    end
end

local function restoreSkin()
    local cs = Config.CommunityService
    if cs.restoreSkinEvent then
        TriggerEvent(cs.restoreSkinEvent)
    elseif cs.restoreSkinExport and cs.restoreSkinExport.resource then
        pcall(function() exports[cs.restoreSkinExport.resource][cs.restoreSkinExport.method]() end)
    else
        TriggerServerEvent('tenx-adminjail:community:reloadSkin')
    end
end

local function clearMess()
    deleteProps(csMessProps)
    csMessProps = {}
end

-- Move to a new target spot: wipe the old mess, spawn the new one.
local function setSpot(spot)
    clearMess()
    csCurrentSpot = spot
    if spot and spot.coords then
        csMessProps = spawnMess(jobCfg(spot.job).messProps, spot.coords)
    end
end

local function pickNextSpot()
    if #csSpots == 0 then return nil end
    return csSpots[math.random(#csSpots)]
end

local function deleteServiceVehicle()
    if csVehicle and DoesEntityExist(csVehicle) then
        SetEntityAsMissionEntity(csVehicle, true, true)
        DeleteEntity(csVehicle)
    end
    csVehicle = nil
end

local function stopCommunity(coords)
    if not csActive then return end
    csActive = false
    LocalPlayer.state:set('naijaAdminCS', false, true)
    pcall(function() exports[Config.TargetResource]:disableTargeting(false) end)
    deleteServiceVehicle()
    clearMess()
    deleteProps(csHandProps)
    csHandProps = {}
    csCurrentSpot = nil
    ClearPedTasks(cache.ped)
    restoreSkin()
    if coords and coords.x then
        SetEntityCoords(cache.ped, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, false, false, false, false)
        if coords.h then SetEntityHeading(cache.ped, coords.h + 0.0) end
    end
    lib.notify({ type = 'success', title = 'Released', description = 'Community service complete.', duration = 6000 })
end

local function startCommunity(data)
    if csActive then return end
    csActive   = true
    csRequired = data.required or 5
    csDone     = data.done or 0
    csSpots    = data.spots or {}

    LocalPlayer.state:set('naijaAdminCS', true, true)
    pcall(function() exports[Config.TargetResource]:disableTargeting(true) end)
    applyUniform()
    setSpot(pickNextSpot())

    if data.resync then
        lib.notify({ type = 'inform', title = 'Community Service',
            description = ('Still serving — %s/%s jobs done. Press U for a work vehicle.'):format(csDone, csRequired), duration = 8000 })
    else
        lib.notify({ type = 'error', title = 'Community Service',
            description = 'Reason: ' .. (data.reason or 'N/A') .. '. Press U for a work vehicle. Complete your jobs to be freed.', duration = 9000 })
    end

    -- main loop: markers, auto-clean on arrival, HUD, control lock, uniform hold
    CreateThread(function()
        local cleaning = false
        local lastUniform = 0
        while csActive do
            Wait(0)
            local ped = cache.ped

            for _, ctrl in ipairs(Config.CommunityService.disabledControls) do
                DisableControlAction(0, ctrl, true)
            end

            if GetGameTimer() - lastUniform > 4000 then applyUniform() lastUniform = GetGameTimer() end

            if csCurrentSpot and csCurrentSpot.coords then
                local sc = csCurrentSpot.coords
                local scv = vector3(sc.x + 0.0, sc.y + 0.0, sc.z + 0.0)
                DrawMarker(1, sc.x, sc.y, sc.z - 0.9, 0,0,0, 0,0,0, 1.5,1.5,0.5, 255,150,0,120, false,false,2,false,nil,nil,false)

                if not cleaning and #(GetEntityCoords(ped) - scv) < Config.CommunityService.cleanRadius then
                    cleaning = true
                    local cfg  = jobCfg(csCurrentSpot.job)
                    local anim = cfg.anim
                    loadAnim(anim and anim.dict)

                    -- props in hand for the duration of the emote
                    csHandProps = attachProps(cfg.handProps)

                    local ok = lib.progressBar({
                        duration = Config.CommunityService.cleanDuration,
                        label = cfg.label or 'Cleaning...', useWhileDead = false, canCancel = true,
                        disable = { move = true, car = true, combat = true },
                        anim = anim and { dict = anim.dict, clip = anim.name } or nil,
                    })

                    ClearPedTasks(ped)
                    deleteProps(csHandProps)
                    csHandProps = {}

                    if ok then
                        local res = lib.callback.await('tenx-adminjail:community:jobDone', false, csCurrentSpot.id)
                        if res and res.ok then
                            csDone = res.done
                            if not res.complete then
                                lib.notify({ type = 'success', description = ('Job done (%s/%s).'):format(res.done, res.required) })
                                setSpot(pickNextSpot())   -- old mess cleared, new mess spawned
                            else
                                clearMess()               -- finished: server sends removeCommunity next
                            end
                        else
                            lib.notify({ type = 'error', description = (res and res.msg) or 'Job not counted.' })
                        end
                    end
                    cleaning = false
                end
            end

            -- HUD
            DrawRect(0.5, 0.94, 0.30, 0.05, 0, 0, 0, 150)
            SetTextFont(4) SetTextScale(0.45, 0.45) SetTextColour(255, 255, 255, 255) SetTextCentre(true)
            SetTextEntry('STRING') AddTextComponentSubstringPlayerName(('Community Service — Jobs %s/%s  •  Head to the orange marker'):format(csDone, csRequired))
            DrawText(0.5, 0.925)
        end
    end)
end

RegisterNetEvent('tenx-adminjail:client:applyCommunity', function(data) startCommunity(data) end)
RegisterNetEvent('tenx-adminjail:client:removeCommunity', function(coords) stopCommunity(coords) end)

-- Service vehicle: press U (rebindable) to summon; re-summonable after relog.
RegisterCommand('naija_svcveh', function()
    if not csActive then return end
    local cs = Config.CommunityService
    local ped = cache.ped
    local model = joaat(cs.vehicleModel)
    if not IsModelValid(model) then
        lib.notify({ type = 'error', description = 'Service vehicle model is invalid.' })
        return
    end
    RequestModel(model)
    local t = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - t < 3000 do Wait(10) end
    if not HasModelLoaded(model) then return end

    deleteServiceVehicle()

    local o = GetOffsetFromEntityInWorldCoords(ped, 0.0, 3.5, 0.0)
    csVehicle = CreateVehicle(model, o.x, o.y, o.z, GetEntityHeading(ped), true, false)
    SetVehicleNumberPlateText(csVehicle, cs.vehiclePlate or 'CSERVICE')
    SetVehicleDoorsLocked(csVehicle, 1)
    SetModelAsNoLongerNeeded(model)

    -- Hand over the keys (read the plate back off the vehicle, not the config,
    -- so whatever the game actually applied is what the keys resource gets).
    if cs.vehicleKeys and cs.vehicleKeys.resource then
        local plate = GetVehicleNumberPlateText(csVehicle)
        local ok = pcall(function()
            exports[cs.vehicleKeys.resource][cs.vehicleKeys.method](plate)
        end)
        if not ok then
            print(('[tenx-adminjail] ^3vehicle keys export failed:^7 exports[%s]:%s(%s)')
                :format(cs.vehicleKeys.resource, tostring(cs.vehicleKeys.method), tostring(plate)))
        end
    end

    lib.notify({ description = 'Community service vehicle spawned. Keys are yours.' })
end, false)
RegisterKeyMapping('naija_svcveh', 'Summon community service vehicle', 'keyboard', 'U')

-- ============================================================
--  RESOURCE STOP — full teardown so nothing is left stuck
-- ============================================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- kill the loops
    cuffActive, jailActive, csActive = false, false, false

    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, false)

    deleteProps(cuffProps)
    deleteProps(csMessProps)
    deleteProps(csHandProps)
    deleteServiceVehicle()

    -- clear the synced flags other resources read, or the player stays
    -- inventory-locked forever with nothing running to unlock them
    LocalPlayer.state:set('invBusy', false, true)
    LocalPlayer.state:set('naijaAdminLocked', false, true)
    LocalPlayer.state:set('naijaAdminJailed', false, true)
    LocalPlayer.state:set('naijaAdminCS', false, true)

    pcall(function() exports[Config.TargetResource]:disableTargeting(false) end)
end)

-- ============================================================
--  LOCATION CAPTURE (shared save tool)
-- ============================================================
local function captureLocation(category, extra)
    lib.notify({ description = ('Press %s to save this spot • %s to cancel'):format('E', 'X') })
    CreateThread(function()
        local capturing = true
        while capturing do
            Wait(0)
            local ped = cache.ped
            local c = GetEntityCoords(ped)
            DrawMarker(1, c.x, c.y, c.z - 1.0, 0, 0, 0, 0, 0, 0, 0.6, 0.6, 0.4, 0, 150, 255, 120, false, false, 2, false, nil, nil, false)

            if IsControlJustReleased(0, Config.SaveKey) then
                capturing = false
                local coords = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) }
                local fields = { { type = 'input', label = 'Label', required = true, default = extra and extra.default or '' } }
                if extra and extra.promptRadius then
                    fields[#fields + 1] = { type = 'number', label = 'Leash radius (metres)', default = extra.radius or 30, min = 5 }
                end
                local input = lib.inputDialog('Name this location', fields)
                if input and input[1] then
                    local payload = { category = category, label = input[1], coords = coords }
                    if extra and extra.promptRadius then payload.radius = input[2] or extra.radius end
                    if extra and extra.job_type then payload.job_type = extra.job_type end
                    local res = lib.callback.await('tenx-adminjail:saveLocation', false, payload)
                    lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                end
            elseif IsControlJustReleased(0, Config.CancelKey) then
                capturing = false
                lib.notify({ description = 'Cancelled.' })
            end
        end
    end)
end

-- ============================================================
--  MENU
-- ============================================================
local function punishMenu(player)
    lib.registerContext({
        id = 'opadmin_punish',
        title = ('Punish: %s'):format(player.name),
        menu = 'opadmin_search_results',
        options = {
            {
                title = 'Hard Cuff',
                description = 'Full freeze. No timer. Released from the menu.',
                icon = 'handcuffs',
                onSelect = function()
                    local input = lib.inputDialog('Hard Cuff — ' .. player.name, {
                        { type = 'input', label = 'Reason', required = true },
                        { type = 'input', label = 'Evidence (Discord image URL)', required = false },
                    })
                    if not input then return end
                    local res = lib.callback.await('tenx-adminjail:applyPunishment', false, {
                        citizenid = player.citizenid,
                        name = player.name,
                        type = 'cuff',
                        reason = input[1],
                        evidence = input[2],
                    })
                    lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                end,
            },
            {
                title = 'Admin Jail',
                description = 'Send to a jail. Timer or infinite. Free inside, cannot leave.',
                icon = 'building-lock',
                onSelect = function()
                    local jails = lib.callback.await('tenx-adminjail:getLocations', false, 'jail')
                    if not jails or #jails == 0 then
                        lib.notify({ type = 'error', description = 'No jail locations saved. Add one in Manage Locations.' })
                        return
                    end
                    local jailOpts = {}
                    for _, j in ipairs(jails) do
                        jailOpts[#jailOpts + 1] = {
                            title = j.label,
                            description = ('Radius: %sm'):format(math.floor(j.radius or 30)),
                            onSelect = function()
                                local input = lib.inputDialog('Admin Jail — ' .. player.name, {
                                    { type = 'input',    label = 'Reason', required = true },
                                    { type = 'input',    label = 'Evidence (Discord image URL)', required = false },
                                    { type = 'number',   label = 'Minutes (leave blank if Infinite)', min = 1 },
                                    { type = 'checkbox', label = 'Infinite (no timer)' },
                                })
                                if not input then return end
                                local res = lib.callback.await('tenx-adminjail:applyPunishment', false, {
                                    citizenid = player.citizenid,
                                    name      = player.name,
                                    type      = 'jail',
                                    reason    = input[1],
                                    evidence  = input[2],
                                    minutes   = input[3],
                                    infinite  = input[4] and true or false,
                                    jailId    = j.id,
                                })
                                lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                            end,
                        }
                    end
                    lib.registerContext({ id = 'opadmin_pickjail', title = 'Choose Jail', menu = 'opadmin_punish', options = jailOpts })
                    lib.showContext('opadmin_pickjail')
                end,
            },
            {
                title = 'Community Service',
                description = 'Locked uniform + cleaning jobs around the city. Freed on completion.',
                icon = 'broom',
                onSelect = function()
                    local input = lib.inputDialog('Community Service — ' .. player.name, {
                        { type = 'input',  label = 'Reason', required = true },
                        { type = 'input',  label = 'Evidence (Discord image URL)', required = false },
                        { type = 'number', label = 'Number of jobs', default = Config.CommunityService.defaultJobs, min = 1 },
                    })
                    if not input then return end
                    local res = lib.callback.await('tenx-adminjail:applyPunishment', false, {
                        citizenid = player.citizenid,
                        name      = player.name,
                        type      = 'community',
                        reason    = input[1],
                        evidence  = input[2],
                        jobs      = input[3],
                    })
                    lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                end,
            },
        },
    })
    lib.showContext('opadmin_punish')
end

local function searchFlow()
    local input = lib.inputDialog('Search Player', {
        { type = 'input', label = 'Name (type part of it)', required = true },
    })
    if not input or not input[1] then return end

    local results = lib.callback.await('tenx-adminjail:searchPlayers', false, input[1])
    if not results or #results == 0 then
        lib.notify({ type = 'error', description = 'No players found.' })
        return
    end

    local options = {}
    for _, p in ipairs(results) do
        options[#options + 1] = {
            title = p.name,
            description = p.online and '🟢 Online' or '⚫ Offline (will apply on next login)',
            onSelect = function() punishMenu(p) end,
        }
    end

    lib.registerContext({ id = 'opadmin_search_results', title = 'Search Results', menu = 'opadmin_main', options = options })
    lib.showContext('opadmin_search_results')
end

local function currentlyServing()
    local active = lib.callback.await('tenx-adminjail:getActive', false)
    local options = {}
    if not active or #active == 0 then
        options[1] = { title = 'Nobody is serving a punishment.', disabled = true }
    else
        for _, r in ipairs(active) do
            options[#options + 1] = {
                title = ('%s — %s'):format(r.player_name or r.citizenid, r.type),
                description = ('%s • Reason: %s'):format(r.online and '🟢 Online' or '⚫ Offline', r.reason or ''),
                onSelect = function()
                    local ok = lib.alertDialog({
                        header = 'Release ' .. (r.player_name or r.citizenid) .. '?',
                        content = 'This releases them and clears all effects.',
                        centered = true, cancel = true,
                    })
                    if ok == 'confirm' then
                        local res = lib.callback.await('tenx-adminjail:release', false, r.id)
                        lib.notify({ type = res.ok and 'success' or 'error', description = res.msg })
                        currentlyServing()
                    end
                end,
            }
        end
    end
    lib.registerContext({ id = 'opadmin_serving', title = 'Currently Serving', menu = 'opadmin_main', options = options })
    lib.showContext('opadmin_serving')
end

local function locationsMenu()
    lib.registerContext({
        id = 'opadmin_locations',
        title = 'Manage Locations',
        menu = 'opadmin_main',
        options = {
            {
                title = 'Set Release Point',
                description = 'Walk to the spot (e.g. Legion Square garage / hospital) and press E.',
                icon = 'location-dot',
                onSelect = function() captureLocation('release', { default = 'Release Point' }) end,
            },
            {
                title = 'Add Jail Location',
                description = 'Walk to the spot and press E. Sets a jail + its leash radius.',
                icon = 'building-lock',
                onSelect = function() captureLocation('jail', { default = 'Jail', promptRadius = true, radius = Config.Jail.defaultRadius }) end,
            },
            {
                title = 'Add Cleaning Spot',
                description = 'Pick a job type, then stand facing the mess and press E.',
                icon = 'broom',
                onSelect = function()
                    local opts = {}
                    for job, cfg in pairs(Config.CommunityService.jobs) do
                        opts[#opts + 1] = {
                            title = cfg.label or job,
                            description = 'Your facing direction sets where the props spawn.',
                            onSelect = function()
                                captureLocation('cleaning', { default = cfg.label or job, job_type = job })
                            end,
                        }
                    end
                    lib.registerContext({ id = 'opadmin_jobtype', title = 'Cleaning Job Type', menu = 'opadmin_locations', options = opts })
                    lib.showContext('opadmin_jobtype')
                end,
            },
            {
                title = 'View Saved Locations',
                description = 'See / delete saved release, jail and cleaning spots.',
                icon = 'list',
                onSelect = function()
                    local locs = lib.callback.await('tenx-adminjail:getLocations', false)
                    local opts = {}
                    if not locs or #locs == 0 then
                        opts[1] = { title = 'No locations saved.', disabled = true }
                    else
                        for _, l in ipairs(locs) do
                            opts[#opts + 1] = {
                                title = ('[%s] %s'):format(l.category, l.label),
                                description = 'Select to delete',
                                onSelect = function()
                                    local ok = lib.alertDialog({ header = 'Delete?', content = l.label, centered = true, cancel = true })
                                    if ok == 'confirm' then
                                        lib.callback.await('tenx-adminjail:deleteLocation', false, l.id)
                                        lib.notify({ type = 'success', description = 'Deleted.' })
                                    end
                                end,
                            }
                        end
                    end
                    lib.registerContext({ id = 'opadmin_loclist', title = 'Saved Locations', menu = 'opadmin_locations', options = opts })
                    lib.showContext('opadmin_loclist')
                end,
            },
        },
    })
    lib.showContext('opadmin_locations')
end

local function logsMenu()
    local logs = lib.callback.await('tenx-adminjail:getLogs', false)
    local options = {}
    if not logs or #logs == 0 then
        options[1] = { title = 'No logs yet.', disabled = true }
    else
        for _, l in ipairs(logs) do
            options[#options + 1] = {
                title = ('%s — %s (%s)'):format(l.player_name or '?', l.type, l.status),
                description = ('By %s • %s\nReason: %s'):format(l.issued_by_name or '?', l.created_at or '', l.reason or ''),
            }
        end
    end
    lib.registerContext({ id = 'opadmin_logs', title = 'Recent Logs', menu = 'opadmin_main', options = options })
    lib.showContext('opadmin_logs')
end

local function openMainMenu()
    lib.registerContext({
        id = 'opadmin_main',
        title = 'Admin Punishment',
        options = {
            { title = 'Search Player', description = 'Find a player (online or offline) to punish.', icon = 'magnifying-glass', onSelect = searchFlow },
            { title = 'Currently Serving', description = 'Active punishments — release from here.', icon = 'list-check', onSelect = currentlyServing },
            { title = 'Manage Locations', description = 'Set the release point and manage saved spots.', icon = 'map-location-dot', onSelect = locationsMenu },
            { title = 'Logs', description = 'Recent punishment history.', icon = 'clock-rotate-left', onSelect = logsMenu },
        },
    })
    lib.showContext('opadmin_main')
end

-- ============================================================
--  COMMAND / KEYBIND  (permission is enforced server-side)
-- ============================================================
RegisterCommand(Config.Command, function()
    local canOpen = lib.callback.await('tenx-adminjail:canOpen', false)
    if not canOpen then
        lib.notify({ type = 'error', description = 'You are not permitted to use this.' })
        return
    end
    openMainMenu()
end, false)

if Config.OpenKeybind then
    RegisterKeyMapping(Config.Command, 'Open Admin Punishment menu', 'keyboard', Config.OpenKeybind)
end
