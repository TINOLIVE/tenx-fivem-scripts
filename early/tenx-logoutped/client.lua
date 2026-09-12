-- tenx-logoutped/client.lua
-- NAIJA 2046 — Logout Ped
--
-- Peds here are LOCAL (networked = false). Every client spawns its own copy
-- from the same server data. Reasons:
--   * sv_entityLockdown can't reject them — they never enter the network
--   * they don't eat CNetObj/ped pool budget
--   * a client crashing can't leave an orphan ped stuck in the world for
--     everyone else. Yours dies with you; everyone else still sees theirs.

local QBCore = exports['qb-core']:GetCoreObject()

-- id -> { ped, prop, data }
local logoutPeds = {}

-- ============================================================
--  APPEARANCE SNAPSHOT
--  Read straight off the ped with natives, so this works with qb-clothing,
--  illenium-appearance, fivem-appearance or anything else — we never touch
--  their DB or exports, we just look at the finished ped.
-- ============================================================
local function buildSnapshot()
    local ped = PlayerPedId()
    local snap = {
        model      = GetEntityModel(ped),
        components = {},
        props      = {},
    }

    for i = 0, 11 do
        snap.components[#snap.components + 1] = {
            id       = i,
            drawable = GetPedDrawableVariation(ped, i),
            texture  = GetPedTextureVariation(ped, i),
            palette  = GetPedPaletteVariation(ped, i),
        }
    end

    for i = 0, 7 do
        local drawable = GetPedPropIndex(ped, i)
        if drawable ~= -1 then
            snap.props[#snap.props + 1] = {
                id       = i,
                drawable = drawable,
                texture  = GetPedPropTextureIndex(ped, i),
            }
        end
    end

    -- Face. Wrapped: these natives are the most likely to differ across builds,
    -- and a missing face is much better than no ped at all.
    pcall(function()
        local hb = GetPedHeadBlendData(ped)
        if hb then
            snap.headBlend = {
                shapeFirst = hb.shapeFirst, shapeSecond = hb.shapeSecond, shapeThird = hb.shapeThird,
                skinFirst  = hb.skinFirst,  skinSecond  = hb.skinSecond,  skinThird  = hb.skinThird,
                shapeMix   = hb.shapeMix,   skinMix     = hb.skinMix,     thirdMix   = hb.thirdMix,
            }
        end
    end)

    pcall(function()
        snap.overlays = {}
        for i = 0, 12 do
            local _, value, colourType, first, second, opacity = GetPedHeadOverlayData(ped, i)
            if value and value ~= 255 then
                snap.overlays[#snap.overlays + 1] = {
                    id = i, value = value, colourType = colourType,
                    first = first, second = second, opacity = opacity,
                }
            end
        end
    end)

    pcall(function() snap.eyeColor = GetPedEyeColor(ped) end)
    pcall(function() snap.hairColor = { GetPedHairColor(ped), GetPedHairHighlightColor(ped) } end)

    return snap
end

local lastSnapshot
CreateThread(function()
    while true do
        Wait(Config.SnapshotInterval or 60000)

        local pd = QBCore.Functions.GetPlayerData()
        if pd and pd.citizenid then
            local snap = buildSnapshot()
            local encoded = json.encode(snap)
            -- only send when something actually changed
            if encoded ~= lastSnapshot then
                lastSnapshot = encoded
                TriggerServerEvent('tenx-logoutped:snapshot', snap)
            end
        end
    end
end)

-- push one immediately on spawn so a player who drops in the first minute
-- still leaves a correct-looking ped
AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    CreateThread(function()
        Wait(5000)
        lastSnapshot = json.encode(buildSnapshot())
        TriggerServerEvent('tenx-logoutped:snapshot', json.decode(lastSnapshot))
    end)
end)

-- ============================================================
--  BUILD THE PED
-- ============================================================
local function loadModel(model)
    if not IsModelValid(model) then return false end
    RequestModel(model)
    local t = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - t < 5000 do Wait(10) end
    return HasModelLoaded(model)
end

local function applySnapshot(ped, snap)
    if not snap then return end

    if snap.headBlend then
        pcall(function()
            SetPedHeadBlendData(ped,
                snap.headBlend.shapeFirst or 0, snap.headBlend.shapeSecond or 0, snap.headBlend.shapeThird or 0,
                snap.headBlend.skinFirst or 0,  snap.headBlend.skinSecond or 0,  snap.headBlend.skinThird or 0,
                snap.headBlend.shapeMix or 0.0, snap.headBlend.skinMix or 0.0,   snap.headBlend.thirdMix or 0.0,
                false)
        end)
    end

    for _, o in ipairs(snap.overlays or {}) do
        pcall(function()
            SetPedHeadOverlay(ped, o.id, o.value, (o.opacity or 1.0) + 0.0)
            if o.colourType and o.first then
                SetPedHeadOverlayColor(ped, o.id, o.colourType, o.first, o.second or 0)
            end
        end)
    end

    if snap.hairColor then
        pcall(function() SetPedHairColor(ped, snap.hairColor[1] or 0, snap.hairColor[2] or 0) end)
    end
    if snap.eyeColor then
        pcall(function() SetPedEyeColor(ped, snap.eyeColor) end)
    end

    for _, c in ipairs(snap.components or {}) do
        SetPedComponentVariation(ped, c.id, c.drawable or 0, c.texture or 0, c.palette or 0)
    end

    for _, p in ipairs(snap.props or {}) do
        SetPedPropIndex(ped, p.id, p.drawable or 0, p.texture or 0, true)
    end
end

local function attachSign(ped)
    if not (Config.Sign and Config.Sign.enabled) then return nil end

    local model = joaat(Config.Sign.model)
    if not IsModelValid(model) then
        print(('[tenx-logoutped] ^3sign prop invalid:^7 %s (ped spawns without it)'):format(Config.Sign.model))
        return nil
    end
    if not loadModel(model) then return nil end

    local c = GetEntityCoords(ped)
    local obj = CreateObject(model, c.x, c.y, c.z, false, false, false)
    local pos, rot = Config.Sign.pos, Config.Sign.rot
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, Config.Sign.bone or 28422),
        pos.x + 0.0, pos.y + 0.0, pos.z + 0.0,
        rot.x + 0.0, rot.y + 0.0, rot.z + 0.0,
        true, true, false, true, 1, true)
    SetEntityAlpha(obj, Config.Alpha or 150, false)
    SetModelAsNoLongerNeeded(model)
    return obj
end

local function removePed(id)
    local entry = logoutPeds[id]
    if not entry then return end

    if entry.prop and DoesEntityExist(entry.prop) then
        DeleteEntity(entry.prop)
    end
    if entry.ped and DoesEntityExist(entry.ped) then
        DeleteEntity(entry.ped)
    end
    logoutPeds[id] = nil
end

local function spawnLogoutPed(data)
    if not data or not data.id or logoutPeds[data.id] then return end
    if not data.coords then return end

    local model = (data.snapshot and data.snapshot.model) or `mp_m_freemode_01`
    if not loadModel(model) then
        model = `mp_m_freemode_01`
        if not loadModel(model) then return end
    end

    local ped = CreatePed(4, model,
        data.coords.x + 0.0, data.coords.y + 0.0, data.coords.z - 1.0,
        (data.heading or 0.0) + 0.0,
        false,  -- networked = false: local only
        false)

    if not ped or ped == 0 then return end

    applySnapshot(ped, data.snapshot)

    SetEntityAlpha(ped, Config.Alpha or 150, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    SetEntityAsMissionEntity(ped, true, true)
    SetModelAsNoLongerNeeded(model)

    if Config.Anim and Config.Anim.enabled then
        RequestAnimDict(Config.Anim.dict)
        local t = GetGameTimer()
        while not HasAnimDictLoaded(Config.Anim.dict) and GetGameTimer() - t < 3000 do Wait(10) end
        if HasAnimDictLoaded(Config.Anim.dict) then
            TaskPlayAnim(ped, Config.Anim.dict, Config.Anim.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
        end
    end

    local prop = attachSign(ped)

    logoutPeds[data.id] = { ped = ped, prop = prop, data = data }
end

RegisterNetEvent('tenx-logoutped:spawn', function(data) spawnLogoutPed(data) end)
RegisterNetEvent('tenx-logoutped:remove', function(id) removePed(id) end)

-- New joiners / resource restarts: server sends everything still standing.
RegisterNetEvent('tenx-logoutped:sync', function(list)
    for _, data in ipairs(list or {}) do
        spawnLogoutPed(data)
    end
end)

-- ============================================================
--  FLOATING TEXT
-- ============================================================
local function drawText3D(coords, text)
    SetTextScale(Config.Text.scale or 0.4, Config.Text.scale or 0.4)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextEntry('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(coords.x, coords.y, coords.z, 0)
    DrawText(0.0, 0.0)

    local count, length = GetLineCountAndMaxLength(text)
    DrawRect(0.0, 0.0125 * count, 0.017 + (length / 370), 0.03 * count, 0, 0, 0, 140)
    ClearDrawOrigin()
end

function GetLineCountAndMaxLength(text)
    local count, maxLen = 0, 0
    for line in text:gmatch('[^\n]+') do
        count = count + 1
        if #line > maxLen then maxLen = #line end
    end
    return math.max(count, 1), maxLen
end

CreateThread(function()
    while true do
        local wait = 500
        local pcoords = GetEntityCoords(PlayerPedId())
        local dist = Config.Text.distance or 15.0

        for id, entry in pairs(logoutPeds) do
            if entry.ped and DoesEntityExist(entry.ped) then
                local c = GetEntityCoords(entry.ped)
                if #(pcoords - c) < dist then
                    wait = 0
                    local d = entry.data

                    local lines = {
                        ('~y~%s'):format(d.name or 'Unknown'),
                        ('~w~ID: ~b~%s'):format(d.serverId or '?'),
                        ('~r~%s'):format(d.reason or 'DISCONNECTED'),
                    }

                    if Config.Text.showCountdown and d.expiresAt then
                        local left = d.expiresAt - os.time()
                        if left > 0 then
                            lines[#lines + 1] = ('~w~%d:%02d left'):format(math.floor(left / 60), left % 60)
                        end
                    end

                    if Config.Text.showRawReason and d.rawReason then
                        lines[#lines + 1] = ('~c~%s'):format(d.rawReason)
                    end

                    drawText3D(vector3(c.x, c.y, c.z + 1.1), table.concat(lines, '\n'))
                end
            end
        end

        Wait(wait)
    end
end)

-- ============================================================
--  TEARDOWN
-- ============================================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for id in pairs(logoutPeds) do
        removePed(id)
    end
end)
