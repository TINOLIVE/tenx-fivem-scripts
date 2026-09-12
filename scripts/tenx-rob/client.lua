local QBCore = exports['qb-core']:GetCoreObject()

-- ===== State checks =====

-- is this ped in ANY of the configured hands-up animations?
local function isHandsUp(ped)
    for i = 1, #Config.HandsUpAnims do
        local a = Config.HandsUpAnims[i]
        if IsEntityPlayingAnim(ped, a.dict, a.clip, 3) then
            return true
        end
    end
    return false
end

-- The victim's OWN robbable state (accurate - uses QB death flags).
-- returns 'dead' | 'handsup' | false
local function getOwnRobbableState()
    local ped = PlayerPedId()
    local md = (QBCore.Functions.GetPlayerData() or {}).metadata or {}

    -- flat dead = fully dead (not just bleeding out)
    if md.isdead or IsEntityDead(ped) then return 'dead' end
    if Config.RobWhileDowned and md.inlaststand then return 'dead' end

    if isHandsUp(ped) then return 'handsup' end
    if Config.AllowRobCuffed and IsPedCuffed(ped) then return 'handsup' end
    return false
end

-- What the robber can tell about a TARGET ped.
local function getTargetRobbableState(ped)
    if Config.UseRobbableState then
        local sid = GetPlayerServerId(NetworkGetPlayerIndexFromPed(ped))
        if sid and sid > 0 then
            return Player(sid).state.robbable or false
        end
        return false
    end

    if IsEntityDead(ped) or IsPedDeadOrDying(ped, true) then return 'dead' end
    if isHandsUp(ped) then return 'handsup' end
    if Config.AllowRobCuffed and IsPedCuffed(ped) then return 'handsup' end
    return false
end

-- can the robber currently perform a robbery?
local function robberCanRob()
    local ped = PlayerPedId()
    if IsPedDeadOrDying(ped, true) or IsEntityDead(ped) then return false end
    if IsPedCuffed(ped) then return false end
    return true
end

-- ===== Broadcast our own robbable state so the server can verify it =====
if Config.UseRobbableState then
    CreateThread(function()
        local last
        while true do
            local state = getOwnRobbableState() or false
            if state ~= last then
                LocalPlayer.state:set('robbable', state, true)
                last = state
            end
            Wait(Config.StatePoll or 600)
        end
    end)
end

-- ============================================================
--  DEATH REPORTING
--  The server has to know HOW you died to enforce the no-vehicle-kill rule, and
--  WHEN you died to snapshot who was standing there. Only your own client can
--  read the cause of your death, so it self-reports the moment it happens.
--
--  Trust note: you are reporting your OWN death. Lying can only protect you
--  from being looted, never let you loot someone else. Worst case a cheater
--  makes their own body unlootable — which is exactly what a disconnect does
--  anyway, so this opens nothing new.
-- ============================================================
local vehicleWeaponHashes = {}
for _, name in ipairs(Config.VehicleDeathWeapons or {}) do
    vehicleWeaponHashes[joaat(name)] = true
end

local function wasVehicleDeath(ped)
    local cause = GetPedCauseOfDeath(ped)
    if vehicleWeaponHashes[cause] then return true, cause end

    -- Hash list never covers everything (modded vehicles, odd collisions), so
    -- also ask what actually killed us. A vehicle entity = vehicle kill.
    local killer = GetPedSourceOfDeath(ped)
    if killer and killer ~= 0 and DoesEntityExist(killer) then
        if IsEntityAVehicle(killer) then return true, cause end
    end

    return false, cause
end

CreateThread(function()
    local reported = false
    while true do
        Wait(400)
        local ped = PlayerPedId()
        local md = (QBCore.Functions.GetPlayerData() or {}).metadata or {}
        local isDown = md.isdead or md.inlaststand or IsEntityDead(ped)

        if isDown and not reported then
            reported = true
            local byVehicle, cause = wasVehicleDeath(ped)
            TriggerServerEvent('playerrob:server:reportDeath', byVehicle, cause)
        elseif not isDown and reported then
            reported = false   -- revived: next death reports again
        end
    end
end)

-- ===== ox_target option =====
exports.ox_target:addGlobalPlayer({
    {
        name = 'rob_player',
        icon = 'fas fa-user-secret',
        label = 'Rob Player',
        distance = Config.RobDistance,

        -- NOTE: canInteract cannot ask the server (it must answer instantly), so
        -- the option still SHOWS for someone who hasn't earned proximity. The
        -- server rejects it with an exact reason + remaining time. Showing the
        -- option and explaining why is better UX than a silently missing eye.
        canInteract = function(entity)
            if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
            if entity == PlayerPedId() then return false end
            if not robberCanRob() then return false end
            if not Config.AllowRobInVehicle and IsPedInAnyVehicle(entity, false) then return false end
            return getTargetRobbableState(entity) ~= false
        end,

        onSelect = function(data)
            local targetPed = data.entity
            if not targetPed or targetPed == 0 then return end

            local state = getTargetRobbableState(targetPed)
            if not state then return end

            local targetPlayer = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))
            if not targetPlayer or targetPlayer <= 0 then return end

            local dead = state == 'dead'

            -- ==== DISPATCH — FIRST THING, NO EXCEPTIONS ====
            -- Fires before the eligibility check, the minigame and the progress
            -- bar. Click it and the cops are called, full stop. Whether you go
            -- on to fail the check, fumble the skill check or cancel out, the
            -- alert has already gone. That is the point.
            if Config.Dispatch and Config.Dispatch.enabled then
                TriggerServerEvent('playerrob:server:dispatchNow', targetPlayer, dead)
            end

            -- ==== Pre-flight check ====
            -- Ask the server BEFORE the minigame. No point making someone play
            -- a skill check just to be told they never earned the right to rob.
            local allowed, reason = lib.callback.await('playerrob:canRob', false, targetPlayer)
            if not allowed then
                return lib.notify({ title = 'Robbery', description = reason or 'You cannot rob this player', type = 'error' })
            end

            -- ==== Minigame ====
            if Config.SkillCheck and Config.SkillCheck.enabled then
                local checks = dead and Config.SkillCheck.dead or Config.SkillCheck.alive
                local passed = lib.skillCheck(checks, Config.SkillCheck.keys)
                if not passed then
                    return lib.notify({ title = 'Robbery', description = 'You fumbled it', type = 'error' })
                end
            end

            -- ==== Progress bar ====
            local success = lib.progressBar({
                duration = dead and Config.DurationDead or Config.DurationAlive,
                label = dead and 'Looting the body...' or 'Robbing player...',
                useWhileDead = false,
                canCancel = true,
                disable = { move = true, combat = true, car = true },
                anim = { dict = 'mini@repair', clip = 'fixing_a_ped' }
            })

            if success then
                TriggerServerEvent('playerrob:server:robPlayer', targetPlayer)
            else
                lib.notify({ title = 'Robbery', description = 'Robbery cancelled', type = 'error' })
            end
        end
    }
})

-- ============================================================
--  DISPATCH EMITTER
--  ps-dispatch's CustomAlert is a CLIENT export, but we don't want the robber's
--  client deciding the coords (a modded client would send police to the other
--  side of the map). So: the server validates, picks the real coords, and calls
--  back here purely to emit. The client is a speaker, not a decision-maker.
-- ============================================================
RegisterNetEvent('playerrob:client:sendDispatch', function(coords, dead)
    if not (Config.Dispatch and Config.Dispatch.enabled) then return end
    if not coords or not coords.x then return end

    local d = dead and Config.Dispatch.dead or Config.Dispatch.alive

    local ok = pcall(function()
        exports['ps-dispatch']:CustomAlert({
            coords       = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0),
            message      = d.message,
            dispatchCode = d.code,
            description  = d.description,
            radius       = 0,            -- 0 = exact pin, not a search area
            sprite       = d.sprite,
            color        = d.color,
            scale        = d.scale,
            length       = d.length,
            jobs         = Config.Dispatch.jobs,
        })
    end)

    if not ok then
        print('^1[player_rob]^7 ps-dispatch CustomAlert failed — is ps-dispatch started?')
    end
end)

-- ===== Discord screenshot =====
-- The server fires this at the robber right after a successful rob. It hands us
-- the image webhook at that moment rather than storing it in a downloadable file.
RegisterNetEvent('playerrob:client:takeShot', function(token, hook)
    if not token or type(hook) ~= 'string' or hook == '' then return end
    if not (Config.Screenshot and Config.Screenshot.Enabled) then return end

    -- ?wait=true makes Discord reply with the message JSON (which contains the
    -- attachment url). Without it the webhook returns 204 and we get nothing.
    if hook:find('%?') then
        hook = hook .. '&wait=true'
    else
        hook = hook .. '?wait=true'
    end

    local ok = pcall(function()
        exports['screenshot-basic']:requestScreenshotUpload(hook, 'files[]', {
            encoding = 'jpg',
            quality = Config.Screenshot.Quality or 0.75
        }, function(data)
            local url
            local decoded, resp = pcall(json.decode, data)
            if decoded and type(resp) == 'table' and resp.attachments and resp.attachments[1] then
                url = resp.attachments[1].url or resp.attachments[1].proxy_url
            end
            TriggerServerEvent('playerrob:server:shotDone', token, url)
        end)
    end)

    -- screenshot-basic missing / errored: tell the server so it stops waiting
    if not ok then
        TriggerServerEvent('playerrob:server:shotDone', token, nil)
    end
end)
