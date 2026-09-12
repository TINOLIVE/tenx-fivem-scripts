local blip = nil
local radiusBlip = nil
local nextBlip = nil
local nextEdgeBlip = nil
local inArena = false
local ammoMode = 'infinite'
local primaryWeapon = 'WEAPON_ASSAULTRIFLE'

-- Live ring state, pushed from the server.
local ring = { active = false, coords = nil, radius = 0.0, damage = false, preview = false }
local outsideRing = false
local killedByRing = false
local closingUntil = 0
local damageCarry = 0.0

-- The whole revive sequence, timing included, in one place.
--
-- Their death screen is slow to appear. Firing the revive immediately lands
-- it BEFORE the screen exists -- the screen then comes up anyway with nothing
-- left to dismiss it, and sits there while the player walks around alive.
-- So we wait for it to be up, then revive into it.
local function reviveThroughAmbulance()
    local res = Config.AmbulanceResource

    Wait(Config.ReviveDelay or 1500)
    TriggerEvent(('%s:revive'):format(res))

    if Config.ReviveRetry then
        CreateThread(function()
            Wait(Config.ReviveRetryDelay or 2000)
            TriggerEvent(('%s:revive'):format(res))
        end)
    end
end

-- Clearing limb damage after a revive. Their revive takes a moment to settle,
-- and a skellyfix that lands before it finishes does nothing at all -- which
-- is how players end up leaving a round still limping. One helper so the
-- timing is set in one place instead of guessed at three call sites.
local function clearSkelly()
    if not Config.FixSkellyOnRevive then return end

    local res = Config.AmbulanceResource

    Wait(Config.SkellyDelay or 400)
    TriggerEvent(('%s:skellyfix'):format(res))

    if Config.SkellyRetry then
        CreateThread(function()
            Wait(Config.SkellyRetryDelay or 1500)
            TriggerEvent(('%s:skellyfix'):format(res))
        end)
    end
end

-- ============================================================
--  SAFE TELEPORT
-- ============================================================
-- Shared by all three teleports: the start drop, elimination, and the round
-- end gather. Pulls the player out of any vehicle, freezes them, waits for
-- terrain to stream in, then probes for ground before placing them.
-- Without the wait-and-probe, players drop through unloaded map into the sea.
local function safeTeleport(x, y, approxZ, heading, settleTime)
    local ped = PlayerPedId()
    local playerId = PlayerId()

    if IsPedInAnyVehicle(ped, false) then
        local veh = GetVehiclePedIsIn(ped, false)
        TaskLeaveVehicle(ped, veh, 16)
        Wait(200)
        ped = PlayerPedId()
    end

    -- Invincible and frozen for the whole move. On a slow machine the terrain
    -- can take many seconds to stream in, and without this the player is
    -- falling through unloaded map the entire time and lands dead.
    SetEntityInvincible(ped, true)
    SetPlayerInvincible(playerId, true)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)

    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, approxZ + 30.0, false, false, false)

    -- Wait for collision. Generous timeout so potato machines aren't punished.
    local limit = (settleTime or 20) * 1000
    local waited = 0

    RequestCollisionAtCoord(x + 0.0, y + 0.0, approxZ + 0.0)
    NewLoadSceneStart(x + 0.0, y + 0.0, approxZ + 0.0, 0.0, 0.0, 0.0, 150.0, 0)

    while waited < limit do
        ped = PlayerPedId()
        RequestCollisionAtCoord(x + 0.0, y + 0.0, approxZ + 0.0)

        -- Keep pinning them in place; streaming can shove an unfrozen ped.
        SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, approxZ + 30.0, false, false, false)

        if HasCollisionLoadedAroundEntity(ped) then
            -- Collision says loaded, but confirm we can actually find ground
            -- before trusting it.
            local found = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, approxZ + 30.0, false)
            if found then break end
        end

        Wait(100)
        waited = waited + 100
    end

    NewLoadSceneStop()

    -- Probe from several heights; a single call misses on slopes and cliffs.
    local groundZ = nil
    for _, probe in ipairs({ approxZ + 30.0, approxZ + 5.0, approxZ, 500.0, 300.0, 100.0, 50.0 }) do
        local found, z = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probe + 0.0, false)
        if found and z then
            groundZ = z
            break
        end
    end

    -- Never found ground. Fall back to the reference height rather than
    -- dropping them into the void.
    if not groundZ then groundZ = approxZ end

    ped = PlayerPedId()
    SetEntityCollision(ped, true, true)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, groundZ + 0.5, false, false, false)
    SetEntityHeading(ped, heading or (math.random(0, 359) + 0.0))
    ClearPedTasksImmediately(ped)

    -- Let physics settle them onto the surface before handing control back.
    Wait(300)
    FreezeEntityPosition(ped, false)

    -- Hold invincibility a moment longer to absorb any residual drop, then
    -- clear it. Anyone who is meant to stay invincible (eliminated players)
    -- gets it reapplied by their own handler after this returns.
    CreateThread(function()
        Wait(2500)
        local p = PlayerPedId()
        if not LocalPlayer.state.rzOut then
            SetEntityInvincible(p, false)
            SetPlayerInvincible(PlayerId(), false)
        end
    end)

    return PlayerPedId()
end

-- ============================================================
--  ZONE LIFECYCLE
-- ============================================================
local function destroyZone()
    if blip then RemoveBlip(blip) blip = nil end
    if radiusBlip then RemoveBlip(radiusBlip) radiusBlip = nil end
    if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
    if nextEdgeBlip then RemoveBlip(nextEdgeBlip) nextEdgeBlip = nil end
    ring.next = nil
    ring.active = false
    ring.coords = nil
    ring.radius = 0.0
    ring.preview = false
    ring.closed = false
    inArena = false
    outsideRing = false
end

local function buildZone(data)
    ammoMode = data.ammoMode or 'infinite'
    primaryWeapon = data.primary or Config.PrimaryWeapon

    ring.active = true
    ring.coords = vec3(data.x, data.y, data.z)
    ring.radius = data.radius + 0.0
    ring.damage = data.ringDamage or false
    ring.preview = data.preview or false
    ring.phase = data.phase or 0

    -- The pulse belongs to the travelling phase; a preview on the map is not
    -- an emergency.
    if data.next then closingUntil = 0 end

    -- Radius blips can't be resized or moved, so they're swapped out as the
    -- ring travels and shrinks.
    if radiusBlip then RemoveBlip(radiusBlip) end
    radiusBlip = AddBlipForRadius(data.x, data.y, data.z, ring.radius)
    SetBlipColour(radiusBlip, 1)
    SetBlipAlpha(radiusBlip, 110)

    -- The NEXT circle, while it's announced but hasn't started moving. This
    -- is the tac-map preview: you can see where you need to be and decide
    -- when to rotate, which is the whole game.
    if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
    if nextEdgeBlip then RemoveBlip(nextEdgeBlip) nextEdgeBlip = nil end

    if data.next then
        ring.next = data.next

        nextBlip = AddBlipForRadius(data.next.x, data.next.y, data.next.z, data.next.radius + 0.0)
        SetBlipColour(nextBlip, 0)      -- white outline, distinct from the live red ring
        SetBlipAlpha(nextBlip, 128)

        nextEdgeBlip = AddBlipForCoord(data.next.x, data.next.y, data.next.z)
        SetBlipSprite(nextEdgeBlip, 1)
        SetBlipColour(nextEdgeBlip, 0)
        SetBlipScale(nextEdgeBlip, 0.6)
        SetBlipAsShortRange(nextEdgeBlip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('Next zone')
        EndTextCommandSetBlipName(nextEdgeBlip)
    else
        ring.next = nil
    end

    if not blip then
        blip = AddBlipForCoord(data.x, data.y, data.z)
        SetBlipSprite(blip, 313)
        SetBlipColour(blip, 1)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('Red Zone')
        EndTextCommandSetBlipName(blip)
    else
        -- The circle travels, so its centre marker has to travel with it.
        SetBlipCoords(blip, data.x, data.y, data.z)
    end
end

AddStateBagChangeHandler('rzActive', 'global', function(_, _, value)
    if value and value.active then
        buildZone(value)
    else
        destroyZone()
    end
end)

CreateThread(function()
    Wait(2000)
    local data = GlobalState.rzActive
    if data and data.active then buildZone(data) end
end)

-- ============================================================
--  ENTRY DETECTION + RING DAMAGE
-- ============================================================
-- Both run off one 2D distance check. Sleeps at 1500ms when no event is
-- running, so it costs nothing the rest of the time.
CreateThread(function()
    while true do
        local sleep = 1500

        if ring.active and ring.coords then
            sleep = 500

            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            -- 2D on purpose: hills and rooftops don't put you outside the ring.
            local dist = #(vector2(pos.x, pos.y) - vector2(ring.coords.x, ring.coords.y))
            local inside = dist <= ring.radius

            -- Rolling entry. Server re-checks position before taking anything.
            if inside and not inArena then
                inArena = true
                if not ring.preview then
                    TriggerServerEvent('naija-rz:server:enteredZone')
                end
            elseif not inside and inArena then
                inArena = false
                -- Walking out does NOT return your inventory. That only
                -- happens when the admin ends the event.
            end

            -- Eliminated players sit in a holding area that is deliberately
            -- outside the ring. They must never be chipped there, or they'd be
            -- killed and teleported in a loop until the event ends.
            outsideRing = (not inside)
                and LocalPlayer.state.rzActive
                and not LocalPlayer.state.rzOut
                and true or false
        else
            outsideRing = false
        end

        Wait(sleep)
    end
end)

-- Damage tick for anyone caught outside the closing ring.
CreateThread(function()
    while true do
        local sleep = 1000

        if outsideRing and ring.damage then
            sleep = ring.damage.tick or 1000

            local ped = PlayerPedId()
            local health = GetEntityHealth(ped)

            if health > 0 then
                -- Health is an integer, so fractional damage has to build up
                -- across ticks rather than being thrown away each time. A
                -- phase doing 0.5 a second was previously subtracting nothing
                -- at all and reading as "0 health a second" on screen.
                damageCarry = damageCarry + (ring.damage.damage or 3)
                local apply = math.floor(damageCarry)
                damageCarry = damageCarry - apply

                if apply < 1 then
                    Wait(sleep)
                    goto continue
                end

                local newHealth = health - apply

                if not ring.damage.lethal and newHealth < 101 then
                    -- Floor at 1 HP so the ring pressures but never kills.
                    newHealth = 101
                end

                if newHealth <= 100 and ring.damage.lethal then
                    -- Flag it so the kill feed can attribute this to the zone
                    -- rather than reporting it as an unexplained death.
                    killedByRing = true
                    SetEntityHealth(ped, 0)
                else
                    SetEntityHealth(ped, math.max(newHealth, 101))
                end
            end
        else
            damageCarry = 0.0
        end

        ::continue::
        Wait(sleep)
    end
end)

-- On-screen warning while outside.
CreateThread(function()
    while true do
        local sleep = 500

        if outsideRing and ring.damage and ring.damage.warn then
            sleep = 0
            SetTextFont(4)
            SetTextScale(0.55, 0.55)
            SetTextColour(220, 40, 40, 255)
            SetTextOutline()
            SetTextCentre(true)
            BeginTextCommandDisplayText('STRING')
            local dmg = (ring.damage and ring.damage.damage) or 0
            AddTextComponentSubstringPlayerName(
                ring.closed
                    and ('~r~THE ZONE HAS CLOSED~s~  -  ~r~%.1f~s~ health a second, everywhere'):format(dmg)
                    or  ('~r~OUTSIDE THE ZONE~s~  -  ~r~%.1f~s~ health a second'):format(dmg))
            EndTextCommandDisplayText(0.5, 0.86)
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  PREVIEW HUD
-- ============================================================
-- Only drawn during /ffatestshrink. Shows the ring closing in real numbers so
-- you can confirm the timings and radius are doing what you expect.
local function drawDebugText(text, y, r, g, b)
    SetTextFont(4)
    SetTextScale(0.42, 0.42)
    SetTextColour(r, g, b, 255)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.5, y)
end

CreateThread(function()
    while true do
        local sleep = 500

        if ring.active and ring.preview and ring.coords then
            sleep = 0

            local pos = GetEntityCoords(PlayerPedId())
            local dist = #(vector2(pos.x, pos.y) - vector2(ring.coords.x, ring.coords.y))
            local inside = dist <= ring.radius

            drawDebugText('~y~PREVIEW~s~  -  nobody is being touched', 0.80, 255, 255, 255)
            drawDebugText(('ring radius  ~b~%.0fm~s~     you  ~b~%.0fm~s~ from centre')
                :format(ring.radius, dist), 0.835, 255, 255, 255)

            if inside then
                drawDebugText('~g~INSIDE~s~', 0.87, 255, 255, 255)
            else
                drawDebugText('~r~OUTSIDE~s~  (no damage in preview)', 0.87, 255, 255, 255)
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  RING CLOSING WARNING
-- ============================================================
RegisterNetEvent('naija-rz:client:ringClosing', function(data)
    if not LocalPlayer.state.rzActive and not ring.preview then return end

    -- Older shape, in case anything still calls it with two arguments.
    if type(data) ~= 'table' then
        data = { target = data, duration = 3, closeNo = 0, totalCloses = 0 }
    end

    -- This fires at the START of the wait, not the close. The zone is
    -- announced, drawn on the map, and nothing moves yet.
    SendNUIMessage({
        action = 'hud:banner',
        kind = 'announced',
        target = data.target,
        from = data.from,
        duration = data.wait,
        closeNo = data.closeNo,
        totalCloses = data.totalCloses,
        isLast = data.isLast,
        moved = data.moved,
        damage = data.damage
    })

    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
end)

-- The ring has started travelling.
RegisterNetEvent('naija-rz:client:ringMoving', function()
    if not LocalPlayer.state.rzActive and not ring.preview then return end

    closingUntil = GetGameTimer() + 60000
    SendNUIMessage({ action = 'hud:banner', kind = 'closing' })
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
end)

RegisterNetEvent('naija-rz:client:zoneClosed', function()
    if not LocalPlayer.state.rzActive then return end
    closingUntil = 0
    ring.closed = true
    SendNUIMessage({ action = 'hud:banner', kind = 'closed' })
end)

RegisterNetEvent('naija-rz:client:winner', function(data)
    SendNUIMessage({
        action = 'hud:winner',
        name = data.name,
        kills = data.kills,
        players = data.players,
        shared = data.shared
    })
end)

-- ============================================================
--  LOOT: BLIPS, MARKERS, COLLECT PROMPT
-- ============================================================
local lootBlips = {}
local lootPoints = {}
local lootCfg = { distance = 2.0 }
local nearestPile = nil
local promptShown = false

local function clearLootBlips()
    for _, b in ipairs(lootBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    lootBlips = {}
end

local function hidePrompt()
    if promptShown then
        lib.hideTextUI()
        promptShown = false
    end
    nearestPile = nil
end

local function buildLoot(data)
    clearLootBlips()

    if not data or not data.points then
        lootPoints = {}
        hidePrompt()
        return
    end

    lootPoints = data.points
    lootCfg.distance = data.distance or 2.0
    lootCfg.marker = data.marker
    lootCfg.airdropMarker = data.airdropMarker
    lootCfg.airdropDistance = data.airdropDistance or 3.0
    lootCfg.drawDistance = data.drawDistance or 80.0
    local b = data.blip

    -- If the pile we were stood on has just been taken, drop the prompt.
    if nearestPile then
        local stillThere = false
        for _, p in ipairs(lootPoints) do
            if p.id == nearestPile.id then stillThere = true break end
        end
        if not stillThere then hidePrompt() end
    end

    local ab = data.airdropBlip

    for _, point in ipairs(lootPoints) do
        local cfg = point.airdrop and ab or b
        if cfg and cfg.enabled ~= false then
            local blip = AddBlipForCoord(point.x, point.y, point.z)
            SetBlipSprite(blip, cfg.sprite or 478)
            SetBlipColour(blip, cfg.colour or 2)
            SetBlipScale(blip, cfg.scale or 0.7)
            SetBlipAsShortRange(blip, cfg.shortRange ~= false)
            if point.airdrop then SetBlipFlashes(blip, true) end
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(cfg.label or point.label or 'Supplies')
            EndTextCommandSetBlipName(blip)
            lootBlips[#lootBlips + 1] = blip
        end
    end
end

AddStateBagChangeHandler('rzLoot', 'global', function(_, _, value)
    if value then buildLoot(value) else buildLoot(nil) end
end)

CreateThread(function()
    Wait(2500)
    local data = GlobalState.rzLoot
    if data then buildLoot(data) end
end)

-- Markers, nearest-pile detection and the [E] prompt. One loop, and it sleeps
-- fully whenever there is no loot or you aren't in the round.
CreateThread(function()
    while true do
        local sleep = 750

        -- Visible to anyone while a round is live, including staff who were
        -- never swept in. Only collecting is restricted, not seeing.
        if #lootPoints > 0 and ring.active and not LocalPlayer.state.rzOut then
            local pos = GetEntityCoords(PlayerPedId())
            local closest, closestDist = nil, math.huge
            local drewAny = false

            for _, point in ipairs(lootPoints) do
                local dist = #(pos - vec3(point.x, point.y, point.z))

                local isDrop = point.airdrop
                local viewRange = isDrop and 400.0 or (lootCfg.drawDistance or 80.0)

                if dist < viewRange then
                    drewAny = true
                    local m = (isDrop and lootCfg.airdropMarker or lootCfg.marker) or {}
                    local radius = point.distance
                        or (isDrop and lootCfg.airdropDistance or lootCfg.distance)
                        or 2.0

                    -- Flat circle on the ground showing exactly how close you
                    -- need to be. This IS the pickup zone, drawn to scale.
                    DrawMarker(
                        25,
                        point.x, point.y, point.z + 0.05,
                        0.0, 0.0, 0.0,
                        0.0, 0.0, 0.0,
                        radius * 2.0, radius * 2.0, radius * 2.0,
                        m.r or 90, m.g or 220, m.b or 120, m.circleAlpha or 90,
                        false, false, 2, nil, nil, false
                    )

                    if isDrop then
                        -- Big red box standing on the ground, visible across
                        -- the arena so the whole lobby converges on it.
                        DrawMarker(
                            1,
                            point.x, point.y, point.z,
                            0.0, 0.0, 0.0,
                            0.0, 0.0, 0.0,
                            m.scale or 3.0, m.scale or 3.0, m.height or 4.0,
                            m.r or 235, m.g or 45, m.b or 45, m.a or 130,
                            false, false, 2, nil, nil, false
                        )
                    elseif m.cone ~= false then
                        -- Bobbing cone above it so it's findable from a distance.
                        DrawMarker(
                            21,
                            point.x, point.y, point.z + (m.height or 1.2),
                            0.0, 0.0, 0.0,
                            0.0, 180.0, 0.0,
                            m.scale or 0.5, m.scale or 0.5, m.scale or 0.5,
                            m.r or 90, m.g or 220, m.b or 120, m.a or 180,
                            true, true, 2, nil, nil, false
                        )
                    end
                end

                if dist < closestDist then
                    closest, closestDist = point, dist
                end

                if isDrop then sleep = 0 end
            end

            if drewAny then sleep = 0 end

            local reach = closest and (closest.distance
                or (closest.airdrop and lootCfg.airdropDistance or lootCfg.distance)
                or 2.0) or 0.0

            if closest and closestDist <= reach then
                nearestPile = closest
                if not promptShown then
                    local label = ('[E]  Collect %s'):format(closest.label or 'supplies')
                    if not LocalPlayer.state.rzActive then
                        label = '[E]  Supplies  ~c~(not in the round)'
                    end
                    lib.showTextUI(label, { position = 'left-center' })
                    promptShown = true
                end
                sleep = 0
            elseif promptShown then
                hidePrompt()
            end
        elseif promptShown then
            hidePrompt()
        end

        Wait(sleep)
    end
end)

-- The keypress itself. Separate loop so it only runs while a prompt is up.
CreateThread(function()
    while true do
        local sleep = 300

        if promptShown and nearestPile then
            sleep = 0
            if IsControlJustReleased(0, 38) then -- E
                local id = nearestPile.id
                hidePrompt()
                TriggerServerEvent('naija-rz:server:collectLoot', id)
                Wait(300)
            end
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('naija-rz:client:collected', function(label, stacks, wasAirdrop)
    if wasAirdrop then
        SendNUIMessage({ action = 'hud:banner', kind = 'crate' })
    end

    lib.notify({
        title = wasAirdrop and 'Airdrop secured' or 'Picked up',
        description = ('%s item%s from the %s'):format(
            stacks or 1, (stacks or 1) == 1 and '' or 's', label or 'supplies'),
        type = 'success',
        position = Config.NotifyPosition or 'center-right',
        duration = 3500
    })
end)

-- ============================================================
--  AIRDROP ANNOUNCEMENT
-- ============================================================
RegisterNetEvent('naija-rz:client:airdrop', function(coords)
    if not LocalPlayer.state.rzActive and not ring.preview then return end

    SendNUIMessage({ action = 'hud:banner', kind = 'airdrop' })

    local pos = GetEntityCoords(PlayerPedId())
    local dist = #(vector2(pos.x, pos.y) - vector2(coords.x, coords.y))

    lib.notify({
        title = 'Airdrop',
        description = ('A crate has landed %sm away.'):format(math.floor(dist)),
        type = 'warning',
        position = Config.NotifyPosition or 'center-right',
        duration = 8000
    })

    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
end)

-- ============================================================
--  KILL FEED
-- ============================================================
RegisterNetEvent('naija-rz:client:killFeed', function(entry)
    if not LocalPlayer.state.rzActive and not ring.preview then return end

    SendNUIMessage({
        action = 'hud:kill',
        killer = entry.killer,
        victim = entry.victim,
        cause = entry.cause,
        kills = entry.killerKills,
        mine = entry.killer ~= nil and entry.killer == GetPlayerName(PlayerId() and GetPlayerServerId(PlayerId()) or -1) or false,
        ttl = ((Config.Hud or {}).feedDuration or 8) * 1000
    })
end)

-- Report our own death, since only this client can read who did it.
CreateThread(function()
    local wasDead = false

    while true do
        local sleep = 500

        if LocalPlayer.state.rzActive and not LocalPlayer.state.rzOut then
            local ped = PlayerPedId()
            local dead = IsEntityDead(ped)

            if dead and not wasDead then
                wasDead = true

                local killerServerId = 0
                local killerPed = GetPedSourceOfDeath(ped)

                if killerPed and killerPed ~= 0 and killerPed ~= ped then
                    local killerPlayer = NetworkGetPlayerIndexFromPed(killerPed)
                    if killerPlayer and killerPlayer ~= -1 then
                        killerServerId = GetPlayerServerId(killerPlayer)
                    end
                end

                -- killedByRing is set by the damage loop just before it
                -- finishes someone off, so zone deaths are labelled correctly.
                TriggerServerEvent('naija-rz:server:reportKill', killerServerId,
                                   killedByRing and 'zone' or 'died')
                killedByRing = false
            elseif not dead then
                wasDead = false
            end
        else
            wasDead = false
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  HUD  (rendered by the NUI layer, not drawn text)
-- ============================================================
-- Everything the player sees during a round is a real interface element now.
-- The page is always loaded; it just renders nothing until there's something
-- to show, and it never takes focus so it can't block input.
local hudVisible = false

local function hud(payload)
    SendNUIMessage(payload)
end

local function setHudVisible(on)
    if hudVisible == on then return end
    hudVisible = on
    hud({ action = 'hud:visible', visible = on })
end

-- Push the alive count whenever it moves.
CreateThread(function()
    local lastAlive, lastTotal = nil, nil

    while true do
        local stats = GlobalState.rzStats
        local inRound = LocalPlayer.state.rzActive or ring.preview

        if stats and inRound then
            setHudVisible(true)
            if stats.alive ~= lastAlive or stats.total ~= lastTotal then
                lastAlive, lastTotal = stats.alive, stats.total
                hud({ action = 'hud:alive', alive = stats.alive, total = stats.total })
            end
        else
            setHudVisible(false)
            lastAlive, lastTotal = nil, nil
        end

        Wait(500)
    end
end)

-- ============================================================
--  ROUND OVER
-- ============================================================
RegisterNetEvent('naija-rz:client:eventOver', function(coords, teleport)
    local ped = PlayerPedId()

    -- Drop invincibility no matter what, so nobody walks away immortal.
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)

    clearLootBlips()
    hidePrompt()

    SendNUIMessage({ action = 'hud:banner', kind = 'over' })

    if not teleport or not coords then return end

    DoScreenFadeOut(400)
    Wait(450)

    safeTeleport(coords.x, coords.y, coords.z, coords.w, 20)

    DoScreenFadeIn(500)

    lib.notify({
        title = 'Round over',
        description = 'You survived. Everything has been returned.',
        type = 'success',
        position = Config.NotifyPosition or 'center-right',
        duration = 8000
    })
end)

-- ============================================================
--  START SCATTER
-- ============================================================
-- Fires once, at the start of a round. Drops you at a random spot in the ring.
-- The freeze and collision wait matter: teleporting into terrain that hasn't
-- streamed in yet drops you through the map into the sea.
RegisterNetEvent('naija-rz:client:scatter', function(x, y, approxZ, settleTime)
    DoScreenFadeOut(400)
    Wait(450)

    safeTeleport(x, y, approxZ, nil, settleTime)

    DoScreenFadeIn(500)

    SendNUIMessage({ action = 'hud:banner', kind = 'fight' })

    lib.notify({
        title = 'Fight',
        description = 'You have been dropped into the zone.',
        type = 'inform',
        position = Config.NotifyPosition or 'center-right',
        duration = 5000
    })
end)

-- ============================================================
--  ELIMINATION -> HOLDING AREA
-- ============================================================
RegisterNetEvent('naija-rz:client:eliminate', function(coords, opts)
    local ped = PlayerPedId()

    -- Revive before moving them, or the teleport lands a corpse -- and give
    -- their death screen time to appear first, or the revive has nothing to
    -- dismiss and the screen survives the teleport.
    reviveThroughAmbulance()
    clearSkelly()

    Wait(400)

    DoScreenFadeOut(400)
    Wait(450)

    ped = safeTeleport(coords.x, coords.y, coords.z, coords.w,
                       opts and opts.settleTime or 20)

    SetEntityHealth(ped, opts and opts.health or 200)
    SetPedArmour(ped, opts and opts.armour or 0)
    ClearPedBloodDamage(ped)

    -- Unkillable while they wait, so the holding area doesn't turn into its
    -- own deathmatch with everyone bouncing through the teleport repeatedly.
    if opts and opts.godmode then
        -- Reapplied on a loop for a few seconds, because safeTeleport clears
        -- its own landing invincibility shortly after it returns.
        CreateThread(function()
            for _ = 1, 8 do
                local p = PlayerPedId()
                SetEntityInvincible(p, true)
                SetPlayerInvincible(PlayerId(), true)
                Wait(500)
            end
        end)
    end

    Wait(250)
    DoScreenFadeIn(500)

    SendNUIMessage({ action = 'hud:banner', kind = 'eliminated' })

    lib.notify({
        title = 'Eliminated',
        description = 'You are out. Your inventory comes back when the event ends.',
        type = 'error',
        position = Config.NotifyPosition or 'center-right',
        duration = 8000
    })
end)

-- Drop invincibility the moment the event releases them.
AddStateBagChangeHandler('rzOut', ('player:%s'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    if not value then
        local ped = PlayerPedId()
        SetEntityInvincible(ped, false)
        SetPlayerInvincible(PlayerId(), false)
    end
end)

-- ============================================================
--  GROUND HEIGHT PROBE
-- ============================================================
-- The server has no collision, so it asks a client inside the ring where the
-- floor is before dropping a loot pile.
lib.callback.register('naija-rz:client:groundZ', function(x, y, fallbackZ)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, fallbackZ + 0.0)

    local attempts = 0
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and attempts < 20 do
        Wait(20)
        attempts = attempts + 1
    end

    -- Water first. This is what stops people being dropped in the sea, and it
    -- covers every coastline and lake without anyone marking them by hand.
    local isWater = false
    local hasWater, waterZ = GetWaterHeight(x + 0.0, y + 0.0, fallbackZ + 0.0)
    if not hasWater then
        hasWater, waterZ = TestProbeAgainstWater(x + 0.0, y + 0.0, 500.0, x + 0.0, y + 0.0, -100.0)
    end

    -- Probe downward from a few heights, since one call often misses on slopes.
    local groundZ = nil
    for _, probe in ipairs({ fallbackZ + 60.0, fallbackZ + 20.0, fallbackZ, 300.0, 100.0 }) do
        local found, z = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probe + 0.0, false)
        if found then groundZ = z break end
    end

    if hasWater and waterZ then
        -- Ground under the waterline, or no ground found at all over water,
        -- means the sea. Either way it is not somewhere to put a player.
        if not groundZ or groundZ < (waterZ - 0.5) then
            isWater = true
            groundZ = groundZ or waterZ
        end
    end

    return { z = groundZ or fallbackZ, water = isWater }
end)

-- ============================================================
--  INFINITE AMMO
-- ============================================================
CreateThread(function()
    while true do
        local sleep = 1500

        if inArena and ammoMode == 'infinite'
           and LocalPlayer.state.rzActive and not LocalPlayer.state.rzOut then
            sleep = 500
            local ped = PlayerPedId()
            SetPedInfiniteAmmo(ped, true, joaat(primaryWeapon))
            SetPedInfiniteAmmoClip(ped, true)
        end

        Wait(sleep)
    end
end)

-- Turn infinite ammo back off the moment the flag clears.
AddStateBagChangeHandler('rzActive', ('player:%s'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    if not value then
        local ped = PlayerPedId()
        SetPedInfiniteAmmo(ped, false, joaat(primaryWeapon))
        SetPedInfiniteAmmoClip(ped, false)
    end
end)

-- ============================================================
--  START CONFIRMATION
-- ============================================================
RegisterNetEvent('naija-rz:client:confirmStart', function(count, radius, names)
    local list = ''
    if names and #names > 0 then
        local shown = {}
        for i = 1, math.min(#names, 15) do shown[i] = names[i] end
        list = '\n\n' .. table.concat(shown, ', ')
        if #names > 15 then
            list = list .. (' and %s more'):format(#names - 15)
        end
    end

    local confirm = lib.alertDialog({
        header = 'Start FFA?',
        content = ('**%s player(s)** inside a **%sm** radius will have their entire inventory taken and stored.%s\n\nThey get everything back when you run `/ffaend`.')
            :format(count, math.floor(radius), list),
        centered = true,
        cancel = true,
        labels = { confirm = 'Start it', cancel = 'Cancel' }
    })

    if confirm == 'confirm' then
        TriggerServerEvent('naija-rz:server:confirmedStart', radius)
    end
end)

-- ============================================================
--  REVIVE  (ak47_qb_ambulancejob)
-- ============================================================
RegisterNetEvent('naija-rz:client:revive', function()
    reviveThroughAmbulance()
    clearSkelly()
end)

-- ============================================================
--  STATUS
-- ============================================================
RegisterNetEvent('naija-rz:client:showStatus', function(data)
    local content = ('**Event running:** %s\n**Radius:** %sm\n**Inventories held:** %s')
        :format(data.active and 'yes' or 'no', math.floor(data.radius or 0), data.outstanding)

    if data.lines and #data.lines > 0 then
        content = content .. '\n\n' .. table.concat(data.lines, '\n')
    end

    lib.alertDialog({
        header = 'FFA Status',
        content = content,
        centered = true,
        cancel = false
    })
end)

-- ============================================================
--  CLEANUP
-- ============================================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    destroyZone()
    clearLootBlips()
    hidePrompt()
    local ped = PlayerPedId()
    SetPedInfiniteAmmo(ped, false, joaat(primaryWeapon))
    SetPedInfiniteAmmoClip(ped, false)
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)
    DoScreenFadeIn(0)
end)

-- ============================================================
--  ADMIN PANEL  (NUI)
-- ============================================================
-- The panel is a view. It never decides anything -- it renders what the
-- server sends and posts intent back. Every action is re-validated server
-- side, exactly like the chat commands are, so having the page open grants
-- nothing on its own.
local panelOpen = false

local function setPanel(open, data)
    panelOpen = open
    SetNuiFocus(open, open)
    SendNUIMessage({
        action = open and 'open' or 'close',
        state = data
    })
end

RegisterNetEvent('naija-rz:client:openPanel', function(data)
    setPanel(true, data)
end)

RegisterNetEvent('naija-rz:client:panelUpdate', function(data)
    if not panelOpen then return end
    SendNUIMessage({ action = 'update', state = data })
end)

RegisterNetEvent('naija-rz:client:closePanel', function()
    if panelOpen then setPanel(false) end
end)

RegisterNUICallback('close', function(_, cb)
    setPanel(false)
    TriggerServerEvent('naija-rz:server:panelClosed')
    cb({})
end)

-- Every callback below is a thin pipe to the server. The reply the panel
-- shows is whatever the server decided, not something invented here.
local function relay(name)
    RegisterNUICallback(name, function(data, cb)
        lib.callback('naija-rz:server:panel', false, function(result)
            cb(result or { ok = false, message = 'No reply from the server.' })
        end, name, data)
    end)
end

relay('start')
relay('end')
relay('previewStart')
relay('previewStop')
relay('action')
relay('knockOut')
relay('restore')
relay('getSettings')
relay('saveSettings')
relay('resetSettings')
relay('myPosition')
relay('addNoSpawn')
relay('removeNoSpawn')
relay('clearQueue')
relay('kickQueue')
relay('getRounds')

-- Close cleanly if the resource stops while the panel is open, otherwise the
-- player is left with a focused cursor and no way to dismiss it.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if panelOpen then
        SetNuiFocus(false, false)
        panelOpen = false
    end
end)

-- ============================================================
--  QUEUE PED
-- ============================================================
-- A ped standing somewhere public with floating text over its head. Sign up
-- here, then carry on with whatever you were doing -- when a round starts you
-- get pulled in from wherever you are.
local queuePed = nil
local queueBlip = nil
local queuePrompt = false

local function drawText3D(coords, text, scale, r, g, b)
    local onScreen, sx, sy = World3dToScreen2d(coords.x, coords.y, coords.z)
    if not onScreen then return end

    local cam = GetGameplayCamCoords()
    local dist = #(cam - coords)
    local shrink = 1.0 / (dist * 0.06) * (1.0 / GetGameplayCamFov()) * 100.0

    SetTextFont(4)
    SetTextScale(0.0, (scale or 0.4) * shrink)
    SetTextColour(r or 255, g or 255, b or 255, 255)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end

local function spawnQueuePed()
    if not Config.Queue or not Config.Queue.enabled then return end
    if queuePed and DoesEntityExist(queuePed) then return end

    local cfg = Config.Queue.ped
    local model = joaat(cfg.model)

    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 100 do
        Wait(50)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then
        print('[naija-rz] Queue ped model would not load: ' .. tostring(cfg.model))
        return
    end

    queuePed = CreatePed(4, model, cfg.coords.x, cfg.coords.y, cfg.coords.z - 1.0, cfg.coords.w, false, true)
    SetEntityAsMissionEntity(queuePed, true, true)
    if cfg.freeze then FreezeEntityPosition(queuePed, true) end
    if cfg.invincible then SetEntityInvincible(queuePed, true) end
    SetBlockingOfNonTemporaryEvents(queuePed, true)
    if cfg.scenario then TaskStartScenarioInPlace(queuePed, cfg.scenario, 0, true) end
    SetModelAsNoLongerNeeded(model)

    local b = Config.Queue.blip
    if b and b.enabled and not queueBlip then
        queueBlip = AddBlipForCoord(cfg.coords.x, cfg.coords.y, cfg.coords.z)
        SetBlipSprite(queueBlip, b.sprite or 313)
        SetBlipColour(queueBlip, b.colour or 2)
        SetBlipScale(queueBlip, b.scale or 0.8)
        SetBlipAsShortRange(queueBlip, b.shortRange ~= false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(b.label or 'Red Zone Sign-up')
        EndTextCommandSetBlipName(queueBlip)
    end

    -- ox_target if you'd rather have it than a press-E prompt.
    if Config.Queue.useTarget then
        exports.ox_target:addLocalEntity(queuePed, {
            {
                name = 'tenx_rz_queue_join',
                label = Config.Queue.label or 'Join Battle Royale',
                icon = 'fa-solid fa-crosshairs',
                canInteract = function() return not LocalPlayer.state.rzQueued end,
                onSelect = function() TriggerServerEvent('naija-rz:server:joinQueue') end
            },
            {
                name = 'tenx_rz_queue_leave',
                label = 'Leave the queue',
                icon = 'fa-solid fa-xmark',
                canInteract = function() return LocalPlayer.state.rzQueued and true or false end,
                onSelect = function() TriggerServerEvent('naija-rz:server:leaveQueue') end
            }
        })
    end
end

local function removeQueuePed()
    if queuePed and DoesEntityExist(queuePed) then
        DeleteEntity(queuePed)
    end
    queuePed = nil
    if queueBlip then RemoveBlip(queueBlip) queueBlip = nil end
    if queuePrompt then lib.hideTextUI() queuePrompt = false end
end

CreateThread(function()
    Wait(1200)
    spawnQueuePed()
end)

-- Floating sign and the press-E prompt. Sleeps hard when nobody is near.
CreateThread(function()
    while true do
        local sleep = 1000

        if Config.Queue and Config.Queue.enabled and queuePed and DoesEntityExist(queuePed) then
            local cfg = Config.Queue
            local pos = GetEntityCoords(PlayerPedId())
            local pedPos = GetEntityCoords(queuePed)
            local dist = #(pos - pedPos)

            if dist < (cfg.drawDistance or 25.0) then
                sleep = 0

                -- Three separate lines, well spaced and sat clear of the
                -- ped's head. Stacked tight they read as one jumbled string.
                local head = pedPos + vec3(0.0, 0.0, 1.25)
                local queued = LocalPlayer.state.rzQueued
                local q = GlobalState.rzQueue or { count = 0 }

                drawText3D(head + vec3(0.0, 0.0, 0.62),
                    '~y~' .. (cfg.label or 'JOIN BATTLE ROYALE'), 0.62, 255, 255, 255)

                drawText3D(head + vec3(0.0, 0.0, 0.34),
                    queued and '~g~YOU ARE SIGNED UP' or ('~s~' .. (cfg.sublabel or 'Red Zone')),
                    0.40, 235, 235, 235)

                drawText3D(head,
                    ('~b~%s~s~ waiting'):format(q.count or 0), 0.36, 235, 235, 235)

                if not cfg.useTarget and dist < (cfg.interactDistance or 2.5) then
                    if not queuePrompt then
                        lib.showTextUI(queued and '[E]  Leave the queue' or '[E]  Join Battle Royale',
                                       { position = 'left-center' })
                        queuePrompt = true
                    end

                    if IsControlJustReleased(0, 38) then
                        TriggerServerEvent(queued and 'naija-rz:server:leaveQueue'
                                                   or 'naija-rz:server:joinQueue')
                        Wait(400)
                    end
                elseif queuePrompt then
                    lib.hideTextUI()
                    queuePrompt = false
                end
            elseif queuePrompt then
                lib.hideTextUI()
                queuePrompt = false
            end
        end

        Wait(sleep)
    end
end)

-- Heads-up before queued players get pulled out of whatever they're doing.
RegisterNetEvent('naija-rz:client:queueWarning', function(seconds)
    SendNUIMessage({ action = 'hud:banner', kind = 'starting', seconds = seconds })
    lib.notify({
        title = 'Red Zone',
        description = ('You are being pulled into the arena in %s seconds.'):format(seconds),
        type = 'warning',
        position = Config.NotifyPosition or 'center-right',
        duration = seconds * 1000
    })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    removeQueuePed()
end)

-- ============================================================
--  THE ZONE WALL
-- ============================================================
-- A visible barrier at the ring's edge. Only the arc nearest you is drawn:
-- on a 1000m arena you can never see the far side anyway, and drawing the
-- whole circumference would cost frames for nothing.
--
-- Built from DrawPoly quads rather than markers. Marker type 43 is not a flat
-- plane -- fed a wall's dimensions it renders as huge skewed triangles across
-- the screen. Two triangles make a proper quad, which is what a wall is.
-- Polys are single sided, so each is drawn twice with opposite winding or the
-- wall vanishes when you're on the other side of it.
local function wallQuad(x1, y1, x2, y2, zBottom, zTop, r, g, b, a)
    DrawPoly(x1, y1, zBottom, x2, y2, zBottom, x1, y1, zTop, r, g, b, a)
    DrawPoly(x2, y2, zBottom, x2, y2, zTop,    x1, y1, zTop, r, g, b, a)
    DrawPoly(x1, y1, zTop,    x2, y2, zBottom, x1, y1, zBottom, r, g, b, a)
    DrawPoly(x1, y1, zTop,    x2, y2, zTop,    x2, y2, zBottom, r, g, b, a)
end

CreateThread(function()
    while true do
        local sleep = 500
        local cfg = Config.ZoneWall

        -- Only players actually in the round see it. Cayo is part of the RP
        -- city; nobody flying past should find a black wall across the sky.
        local mine = LocalPlayer.state.rzActive or ring.preview or (cfg and cfg.showToEveryone)

        if cfg and cfg.enabled and mine and ring.active and ring.coords and ring.radius > 0 then
            local pos = GetEntityCoords(PlayerPedId())
            local dx, dy = pos.x - ring.coords.x, pos.y - ring.coords.y
            local distFromCentre = math.sqrt(dx * dx + dy * dy)
            local distToEdge = math.abs(ring.radius - distFromCentre)

            if distToEdge <= (cfg.drawWithin or 220.0) then
                sleep = 0

                local r, g, b = cfg.colour.r or 30, cfg.colour.g or 30, cfg.colour.b or 30
                local alpha = cfg.alpha or 120

                -- Pulse while a close is running: a warning you feel rather
                -- than one you have to read.
                if cfg.pulse and closingUntil > GetGameTimer() then
                    local t = (GetGameTimer() % 900) / 900
                    alpha = math.floor(alpha * (0.5 + 0.5 * math.abs(math.sin(t * math.pi))))
                end

                local zBottom = ring.coords.z - 4.0
                local zTop = zBottom + (cfg.height or 12.0)

                if cfg.style == 'sphere' then
                    -- A dome over the whole zone. Drawn as a full ring of
                    -- quads rather than a marker so it holds its shape at any
                    -- radius, with the top edge stepped in to suggest a curve.
                    local segs = 48
                    local step = (math.pi * 2) / segs

                    for i = 0, segs - 1 do
                        local a1, a2 = step * i, step * (i + 1)
                        wallQuad(
                            ring.coords.x + math.cos(a1) * ring.radius,
                            ring.coords.y + math.sin(a1) * ring.radius,
                            ring.coords.x + math.cos(a2) * ring.radius,
                            ring.coords.y + math.sin(a2) * ring.radius,
                            zBottom, zTop + (cfg.height or 12.0) * 1.5,
                            r, g, b, alpha)
                    end
                else
                    -- Just the arc you're facing.
                    local bearing = math.atan(dy, dx)
                    local arc = math.rad(cfg.arc or 90.0)
                    local segs = math.max(6, cfg.segments or 34)
                    local step = (arc * 2) / segs

                    for i = 0, segs - 1 do
                        local a1 = bearing - arc + (step * i)
                        local a2 = bearing - arc + (step * (i + 1))
                        wallQuad(
                            ring.coords.x + math.cos(a1) * ring.radius,
                            ring.coords.y + math.sin(a1) * ring.radius,
                            ring.coords.x + math.cos(a2) * ring.radius,
                            ring.coords.y + math.sin(a2) * ring.radius,
                            zBottom, zTop,
                            r, g, b, alpha)
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  THE DROP
-- ============================================================
-- Dropped in from height with a parachute rather than appearing on the ground.
-- It solves the spawn problem by itself: nobody lands on top of anybody and
-- everyone picks their own spot.
local dropping = false

RegisterNetEvent('naija-rz:client:drop', function(d)
    if dropping then return end
    dropping = true

    local playerId = PlayerId()

    DoScreenFadeOut(400)
    Wait(450)

    local ped = PlayerPedId()

    if IsPedInAnyVehicle(ped, false) then
        TaskLeaveVehicle(ped, GetVehiclePedIsIn(ped, false), 16)
        Wait(200)
        ped = PlayerPedId()
    end

    -- Nothing can hurt them until they are on the ground. Someone who has
    -- never used a parachute should not die before the round has started.
    SetEntityInvincible(ped, true)
    SetPlayerInvincible(playerId, true)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)

    local dropZ = (d.z or 0.0) + (d.height or 320.0)
    SetEntityCoordsNoOffset(ped, d.x + 0.0, d.y + 0.0, dropZ, false, false, false)

    -- Stream the ground in underneath them while they're still frozen, so the
    -- terrain is there by the time they need to land on it.
    RequestCollisionAtCoord(d.x + 0.0, d.y + 0.0, d.z + 0.0)
    NewLoadSceneStart(d.x + 0.0, d.y + 0.0, d.z + 0.0, 0.0, 0.0, 0.0, 300.0, 0)

    local waited = 0
    while waited < 12000 do
        RequestCollisionAtCoord(d.x + 0.0, d.y + 0.0, d.z + 0.0)
        if HasCollisionLoadedAroundEntity(PlayerPedId()) then break end
        Wait(100)
        waited = waited + 100
    end
    NewLoadSceneStop()

    ped = PlayerPedId()
    GiveWeaponToPed(ped, joaat('GADGET_PARACHUTE'), 1, false, false)
    SetPedCanRagdoll(ped, true)

    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)

    -- Into freefall rather than a standing drop, so the animation is right.
    SetPedToRagdoll(ped, 800, 800, 0, false, false, false)
    Wait(200)
    ForcePedMotionState(ped, joaat('motionstate_parachuting'), false, false, false)

    DoScreenFadeIn(600)

    if d.showControls then
        SendNUIMessage({ action = 'hud:drop', seconds = d.controlsDuration or 12 })
    end

    -- Watch them down: open the chute for anyone still falling too low, and
    -- hand invincibility back only once they are actually on the ground.
    CreateThread(function()
        local opened = false
        local guard = GetGameTimer() + 120000

        while dropping and GetGameTimer() < guard do
            local p = PlayerPedId()
            local pos = GetEntityCoords(p)
            local state = GetPedParachuteState(p)

            -- 0 = none, 1 = deploying, 2 = open, 3 = falling with it out
            if state == 2 then opened = true end

            if not opened and state <= 0 then
                local found, groundZ = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z, false)
                local above = found and (pos.z - groundZ) or 999.0

                if above <= (d.autoOpenAt or 90.0) then
                    ForcePedToOpenParachute(p)
                    opened = true
                    SendNUIMessage({ action = 'hud:banner', kind = 'chute' })
                end
            end

            -- On the ground and stable: the drop is over.
            if not IsPedFalling(p) and not IsPedInParachuteFreeFall(p) and state <= 0 then
                local found, groundZ = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z, false)
                if found and (pos.z - groundZ) < 1.5 then
                    Wait(500)
                    dropping = false

                    local final = PlayerPedId()
                    RemoveWeaponFromPed(final, joaat('GADGET_PARACHUTE'))

                    if not LocalPlayer.state.rzOut then
                        SetEntityInvincible(final, false)
                        SetPlayerInvincible(PlayerId(), false)
                    end

                    SendNUIMessage({ action = 'hud:dropEnd' })
                    break
                end
            end

            Wait(250)
        end

        -- Failsafe: never leave someone invincible because the loop got stuck.
        if dropping then
            dropping = false
            local final = PlayerPedId()
            RemoveWeaponFromPed(final, joaat('GADGET_PARACHUTE'))
            if not LocalPlayer.state.rzOut then
                SetEntityInvincible(final, false)
                SetPlayerInvincible(PlayerId(), false)
            end
            SendNUIMessage({ action = 'hud:dropEnd' })
        end
    end)
end)

RegisterNetEvent('naija-rz:client:myKills', function(n)
    SendNUIMessage({ action = 'hud:kills', kills = n or 0 })
end)
