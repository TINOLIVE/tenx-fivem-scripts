-- ============================================================
--  NAIJA 2046 — RED ZONE  (client)
-- ============================================================
-- The mode as the player experiences it: being placed outside a zone, the
-- kill counter, the feed, and dying.
--
-- The inventory, the hotbar and the grid are all the arena's. This resource
-- never touches them -- it asks the arena to arm the player and gets out of
-- the way, so both modes feel identical to use.

local ARENA = Config.RZ.arena

local inZone = nil        -- the arena id we are in, or nil
local kills = 0
local streak = 0
local dead = false
local zones = {}
local feedLines = {}

--- Every message goes through here.
---
--- Guarded because ox_lib being absent should degrade a notification into a
--- console line, not throw from inside whatever was happening at the time.
local function notify(msg, kind, title)
    if not (lib and lib.notify) then
        print(('[redzone] %s'):format(msg))
        return
    end

    lib.notify({
        title = title or 'Red Zone',
        description = msg,
        type = kind or 'inform',
        position = 'top-center',
    })
end

--- Same for callbacks: a missing ox_lib means the panel does not open,
--- rather than an error every time somebody presses the key.
local function callback(name, cb, ...)
    if not (lib and lib.callback) then
        print('^1[redzone] ox_lib is not loaded -- check fxmanifest.lua^0')
        return
    end
    lib.callback(name, false, cb, ...)
end

--- Ask the arena to do something on the client side.
--- Same reasoning as the server wrapper: a stopped resource should mean a
--- feature quietly does nothing, not an error every frame.
local function arenaClient(fn, ...)
    if GetResourceState(ARENA) ~= 'started' then return nil end

    local ok, res = pcall(function(...) return exports[ARENA][fn](nil, ...) end, ...)

    -- `ok and res or nil` looks equivalent and is not.
    --
    -- When the export legitimately answers FALSE, `ok and res` is false and
    -- `false or nil` is nil -- so a successful "no" comes back identical to a
    -- failed call. Every boolean this wrapper carries loses the difference
    -- between "the arena said no" and "the arena never answered".
    --
    -- That matters most for isDown: a player who is fine and a broken export
    -- both read nil, so nothing can tell a healthy server from one where
    -- deaths are silently never detected.
    if ok then return res end
    return nil
end

-- ============================================================
--  GOING IN
-- ============================================================

RegisterNetEvent('naija-rz:client:enter', function(d)
    DoScreenFadeOut(400)
    Wait(450)

    inZone = d.arenaId
    dead = false
    if not d.respawn then streak = 0 end

    local ped = PlayerPedId()

    -- Undo the hold from the death screen, in every case -- entering fresh
    -- runs through here too, and a flag left set from a previous life is how
    -- somebody ends up invisible and unable to move in a new round.
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)

    -- Genuinely back up before being placed. Their script can still be
    -- holding a knockdown at this point if the death was missed, and setting
    -- health on a knocked ped changes nothing at all.
    if d.respawn then
        arenaClient('revivePlayer')
    end

    SetEntityCoordsNoOffset(ped, d.x + 0.0, d.y + 0.0, d.z + 0.0, false, false, false)

    -- A marked spawn keeps the heading it was marked with -- somebody stood
    -- there and chose which way it faces.
    if d.heading then SetEntityHeading(ped, d.heading + 0.0) end

    ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    ClearPedTasksImmediately(ped)

    Wait(200)
    DoScreenFadeIn(600)

    -- Untouchable for a moment, or someone can be camped at a spawn while
    -- their screen is still black.
    local secs = d.protection or 4
    if secs > 0 then
        CreateThread(function()
            for _ = 1, secs * 2 do
                SetEntityInvincible(PlayerPedId(), true)
                SetPlayerInvincible(PlayerId(), true)
                Wait(500)
            end
            SetEntityInvincible(PlayerPedId(), false)
            SetPlayerInvincible(PlayerId(), false)
        end)
    end

    -- Turn the arena's kit on.
    --
    -- The grid, the hotbar, the number keys and the ox_inventory block all
    -- live in the arena. Without this the server hands somebody an inventory
    -- and they get nothing on screen: a weapon they own but cannot hold, and
    -- no TAB to find out why.
    arenaClient('startKit')

    -- And ask for the contents, so it fills in rather than waiting for the
    -- next thing that happens to push it.
    arenaClient('refreshKit')

    SendNUIMessage({ action = 'rzShow', data = {
        zone = d.name, kills = kills, streak = streak,
    }})

    if not d.respawn then
        notify(Config.RZ.text.entered, 'inform', d.name)
    end
end)

RegisterNetEvent('naija-rz:client:leave', function()
    inZone = nil
    kills, streak = 0, 0
    feedLines = {}

    -- Let go of the body, always.
    --
    -- Leaving while the death screen is running -- /exitred, a staff pull, or
    -- the resource stopping -- would otherwise drop somebody back into the
    -- city frozen, invisible and unable to be hit. Unconditional because the
    -- cost of doing it when it was not needed is nothing, and the cost of
    -- missing it once is a player who has to reconnect.
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)

    if dead then arenaClient('revivePlayer') end
    dead = false

    -- Kit off: weapons go back to ox_inventory's world and TAB stops
    -- opening our grid.
    arenaClient('stopKit')

    SendNUIMessage({ action = 'rzHide' })
end)

RegisterNetEvent('naija-rz:client:zones', function(list)
    zones = list or {}
end)

-- ============================================================
--  KILLS
-- ============================================================

RegisterNetEvent('naija-rz:client:killed', function(d)
    kills = d.kills or (kills + 1)
    streak = d.streak or 0

    SendNUIMessage({ action = 'rzShow', data = {
        kills = kills, streak = streak,
    }})

    SendNUIMessage({ action = 'rzKill', data = {
        victim = d.victim,
        coins = d.coins,
        points = d.points,
        streakMessage = d.streakMessage,
        drop = d.drop,
        dropCount = d.dropCount,
    }})

    if d.streakMessage then
        notify(('%s — +%s coins'):format(d.streakMessage, d.coins), 'success')
    end
end)

RegisterNetEvent('naija-rz:client:feed', function(d)
    SendNUIMessage({ action = 'rzFeed', data = d })
end)

--- The one number that decides how long a player stays down.
---
--- Config.RZ.down.delay, with the old respawnDelay honoured as a fallback so
--- an un-updated config still works. Everything reads through here rather
--- than reaching for a config key of its own -- the countdown on screen, the
--- revive, the heal and the respawn are all the same wait, and the surest way
--- to make them disagree is to let each one look it up separately.
local function downDelay()
    local d = (Config.RZ.down or {}).delay
    if d then return d end
    return Config.RZ.respawnDelay or 10.0
end

local function downGrace()
    return (Config.RZ.down or {}).grace or 5.0
end

--- Start the death screen and the clock.
---
--- Called by the watcher the moment it sees a death, and again by the server
--- when it has a killer name. Guarded so the second call only fills in the
--- name -- the clock is not restarted and the player does not wait twice.
---
--- THE CLIENT OWNS THE CLOCK. It used to start only when the server's died
--- event arrived, so anything that stopped that event arriving -- a kill
--- report the server rejected, a death it did not classify, an export that
--- did not answer -- left the player lying on the ambulance script's own
--- bleedout screen for its four minutes, in a mode that promised them ten
--- seconds. The server still decides WHERE they come back; it is no longer
--- the only thing that can decide WHEN.
function BeginDeath(killer, seconds)
    if dead then
        -- Already counting. The second call used to fill in the killer's
        -- name on the death card; there is no card to fill in now, so it
        -- has nothing left to do.
        return
    end

    dead = true
    streak = 0

    local wait = seconds or downDelay()

    -- No death screen is drawn, and the ped is not held either.
    --
    -- There used to be four lines here -- invincible, invisible, no
    -- collision, frozen -- so that a downed player could not be shot,
    -- camped or moved during the wait. All four were polish rather than
    -- load-bearing: the watcher only reports a death on the `down and not
    -- wasDown` edge, so a second hit on someone already down credits nobody
    -- regardless. What they DID produce was a player who was invisible,
    -- passed through the world and could not move for ten seconds, with the
    -- camera sitting where they fell. That reads as noclip. It was invisible
    -- for as long as the full-screen death card covered it and obvious the
    -- moment the card came out.
    --
    -- SetEntityInvincible(ped, true) leaving with them also closes a leak:
    -- nothing in client:enter cleared it, so it was only ever undone by the
    -- tail of the spawn-protection loop. With Config.RZ.spawnProtection at 0
    -- that loop is skipped and the player stayed invincible for the rest of
    -- the session.
    --
    -- So: die normally, ragdoll, lie there. The blackout at the end is
    -- already in client:enter -- DoScreenFadeOut, then the revive, teleport
    -- and heal happen behind it, then DoScreenFadeIn.
    --
    -- The unconditional release in client:enter and client:leave stays. It
    -- costs nothing when there is nothing to release and covers anything
    -- else that puts a player into one of these states.

    CreateThread(function()
        Wait(math.floor(wait * 1000))
        if inZone and dead then
            TriggerServerEvent('naija-rz:server:respawn')
            dead = false

            -- Dying strips the ped. Ask for the grid again so the kit comes
            -- back in their hands rather than only in the database.
            Wait(600)
            arenaClient('refreshKit')
        end
    end)
end

--- The server's version of the same death, with a killer name attached.
--- Arrives after ours in the normal case and only supplies the name.
RegisterNetEvent('naija-rz:client:died', function(d)
    BeginDeath(d and d.killer, d and d.respawn)
end)

-- ============================================================
--  REPORTING A KILL
-- ============================================================
-- The victim reports it, not the killer.
--
-- The killer's client is the one with something to gain from lying, and the
-- server checks the pair are in the same zone either way.

--- Who put us down.
---
--- GetPedSourceOfDeath only answers for a ped that is actually DEAD, and with
--- an ambulance script that knocks people out instead of killing them it
--- returns nothing at all. So it is tried first and then we ask the other
--- players directly: HasEntityBeenDamagedByEntity works on a living ped and
--- is the only thing that answers for a knockdown.
local function findKiller()
    local ped = PlayerPedId()

    local src = GetPedSourceOfDeath(ped)
    if src and src ~= ped and IsEntityAPed(src) then
        local p = NetworkGetPlayerIndexFromPed(src)
        if p and p ~= -1 then return GetPlayerServerId(p) end
    end

    -- Everyone we can see is in our zone -- routing buckets already made sure
    -- of that -- so no distance or zone test is needed here.
    for _, p in ipairs(GetActivePlayers()) do
        local other = GetPlayerPed(p)
        if other and other ~= ped and DoesEntityExist(other)
           and HasEntityBeenDamagedByEntity(ped, other, true) then
            return GetPlayerServerId(p)
        end
    end

    return nil
end

--- Am I down, decided here, without asking anyone.
---
--- The same signals the arena checks, minus the one it alone has -- its own
--- ArenaBodyState, fed by the ambulance script's events. Everything else is
--- readable from this client.
---
--- ak47_qb_ambulancejob leaves a knocked player with a LIVE ped on full
--- health, so IsEntityDead alone answers "fine" for someone lying on their
--- own bleedout screen. That is why the state flags and the metadata are
--- checked too, and why the health floor is 101 rather than 0.
local qbCore = nil

local function amIDown()
    local ped = PlayerPedId()

    if IsEntityDead(ped) or IsPedFatallyInjured(ped) then return true end
    if GetEntityHealth(ped) <= 100 then return true end

    -- CUFFED counts as down. The ambulance script restrains a downed player
    -- rather than killing the ped, so this is often the ONLY thing that
    -- changes -- health stays full and nothing else moves.
    --
    -- Nobody is arrested inside a Red Zone, so cuffed here means downed.
    if IsPedCuffed(ped) then return true end

    -- Different ambulance scripts use different names, so check the lot.
    local st = LocalPlayer.state
    for _, flag in ipairs({ 'dead', 'isDead', 'isdead', 'laststand',
                            'inLaststand', 'inlaststand', 'downed',
                            'knockedout' }) do
        if st[flag] then return true end
    end

    -- QBCore metadata, with the core object fetched once and kept.
    -- GetCoreObject marshals the whole table across a resource boundary, and
    -- this runs twice a second for as long as anyone is in a zone.
    if qbCore == nil then
        local ok, core = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        qbCore = (ok and core) or false
    end

    if qbCore then
        local ok, pd = pcall(function()
            return qbCore.Functions.GetPlayerData()
        end)

        if ok and pd and pd.metadata then
            if pd.metadata.isdead or pd.metadata.inlaststand then return true end
        end
    end

    return false
end

CreateThread(function()
    local wasDown = false

    while true do
        -- Twice a second while in a zone.
        --
        -- This asks the ARENA whether we are down, and a cross-resource call
        -- is paid for by the resource being called. At five times a second it
        -- was enough on its own to put several milliseconds on the arena's
        -- row in resmon, for the whole time anybody was in a zone.
        --
        -- Noticing a death 250ms later is not something a player can feel --
        -- the screen takes longer than that to fade.
        Wait(inZone and 500 or 1500)

        if inZone then
            -- The ARENA's answer, not the ped's.
            --
            -- ak47_qb_ambulancejob leaves a knocked player with a live ped on
            -- full health, so IsEntityDead said "fine" while their script ran
            -- its own bleedout underneath and moved the player itself. That is
            -- the instant teleport with no heal, and the death screen showing
            -- seconds later when the two finally disagreed.
            --
            -- The arena listens to their script's events and has done since it
            -- hit the same wall. Asking it is one call; solving it again here
            -- would be the same bug in a second place.
            -- Either answer will do.
            --
            -- The arena is asked, because it listens to the ambulance
            -- script's own events and is the only thing that knows about
            -- being KNOCKED rather than dead. But this mode no longer depends
            -- on getting an answer: if the arena is old, stopped, mid-restart
            -- or its ambulance integration is not matching, the local check
            -- below still notices and the respawn still happens.
            --
            -- Duplicating a check the arena owns is not free -- two copies
            -- can drift -- and it is the right trade here anyway. The cost of
            -- drift is a death noticed slightly differently. The cost of
            -- depending on one answer was a player lying on an ambulance
            -- bleedout screen for four minutes in a mode that promised them
            -- ten seconds.
            -- The arena's full answer, not a boolean.
            --
            -- knocked and dead both mean respawn here, and the arena is the
            -- only thing that knows about knocked -- their script leaves a
            -- knocked player with a live ped on full health, so every native
            -- check this client can make answers "fine".
            --
            -- The local check stays as a backstop for the case where the
            -- arena is old, stopped or mid-restart. Either is enough.
            local d = arenaClient('deathState')
            local down = (type(d) == 'table' and d.down == true)
                or arenaClient('isDown') == true
                or amIDown()

            if down and not wasDown then
                local killerId = findKiller()

                -- Our own clock starts NOW, not when the server replies.
                -- Whatever the server decides about the kill, the ten seconds
                -- are already running.
                BeginDeath(nil, downDelay())

                if killerId then
                    TriggerServerEvent('naija-rz:server:kill', killerId, 'shot')
                else
                    -- Fell, drowned, /kill, or their own grenade. Still a
                    -- death, just nobody's kill.
                    --
                    -- REPORTED, not respawned. This used to fire
                    -- server:respawn directly, which is not a death report --
                    -- it is the thing that PLACES you. The server obliged
                    -- instantly: spawn picked, client:enter sent with
                    -- respawn = true, which cleared `dead`, revived, healed
                    -- and teleported within a frame or two of dying. The
                    -- countdown thread below then woke at `delay`, found
                    -- `dead` already false and did nothing, so it never threw.
                    -- The full-screen death card hid all of it until the card
                    -- was removed.
                    --
                    -- server:kill with no killer runs the server's
                    -- no-creditable-killer branch: the streak resets, the
                    -- death is written, the down claim is taken and
                    -- client:died comes back -- and nothing is placed. The
                    -- respawn happens where it always should have, at the end
                    -- of the countdown below.
                    TriggerServerEvent('naija-rz:server:kill', nil, 'self')
                end

                -- NO revive here. It happens at the end of the countdown,
                -- with the respawn.
                --
                -- Reviving on the spot was meant to take the player off the
                -- ambulance script before it could run its own timer. It does
                -- not work, because that script needs seven to ten seconds to
                -- even register the death -- so the revive arrived before
                -- there was anything to cancel, did nothing, and then their
                -- screen appeared long after we had already healed and
                -- respawned the player.
                --
                -- Waiting the full count and reviving once at the end is both
                -- simpler and correct: by then their script has caught up, so
                -- the revive lands on something, and there is only ever one
                -- clock running.
            end

            wasDown = down
        else
            wasDown = false
        end
    end
end)

-- ============================================================
--  THE PANEL
-- ============================================================

local panelOpen = false

local function openPanel()
    if panelOpen then return end

    callback('naija-rz:server:zones', function(res)
        panelOpen = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'rzOpen', data = res or { zones = {} } })
    end)
end

local function closePanel()
    panelOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'rzClose' })
end

RegisterCommand('rz', function() openPanel() end, false)

RegisterNUICallback('rzEnter', function(d, cb)
    closePanel()
    TriggerServerEvent('naija-rz:server:enter', d.id)
    cb({})
end)

RegisterNUICallback('rzLeave', function(_, cb)
    closePanel()
    TriggerServerEvent('naija-rz:server:leave')
    cb({})
end)

RegisterNUICallback('rzClose', function(_, cb)
    closePanel()
    cb({})
end)

RegisterNUICallback('rzBoard', function(_, cb)
    callback('naija-rz:server:board', function(res)
        cb(res or { rows = {} })
    end)
end)

-- Escape closes it, like everything else on this server.
CreateThread(function()
    while true do
        Wait(panelOpen and 0 or 500)
        if panelOpen then
            DisableControlAction(0, 200, true)
            if IsDisabledControlJustReleased(0, 200) or IsControlJustReleased(0, 194) then
                closePanel()
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if panelOpen then SetNuiFocus(false, false) end

    -- Same reasoning as leaving: nobody should be left held by a resource
    -- that is no longer running.
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
end)

-- ============================================================
--  WHAT THIS OFFERS OTHER RESOURCES
-- ============================================================

exports('isInZone', function() return inZone ~= nil end)
exports('getKills', function() return kills end)
exports('getStreak', function() return streak end)

-- ============================================================
--  MARKING SPAWNS
-- ============================================================
-- Stand where you want players to appear and mark it.
--
-- Deliberately OUTSIDE the zone: players arrive with their kit and walk in,
-- rather than being dropped into the middle of a fight they never saw coming.

RegisterCommand('rzspawn', function(_, args)
    local sub = (args[1] or ''):lower()

    if sub == 'clear' then
        local id = tonumber(args[2])
        if not id then
            return notify('rzspawn clear <zone id>  --  run rzspawn list for ids', 'error')
        end
        TriggerServerEvent('naija-rz:server:clearSpawns', id)
        return
    end

    if sub == 'list' or sub == '' then
        callback('naija-rz:server:spawnList', function(list)
            if not list or #list == 0 then
                return notify('No arenas found. Is the arena resource running?', 'error')
            end

            print('^3[redzone] zones and their spawn counts^0')
            for _, z in ipairs(list) do
                local mark = z.spawns > 0 and '^2' or '^1'
                print(('  %s%-3s %-24s %s spawn(s)^0'):format(mark, z.id, z.name, z.spawns))
            end
            print('^3  rzspawn add <id>   where you stand^0')
            print('^3  rzspawn clear <id>^0')

            notify('Zone list is in the console (F8).', 'inform')
        end)
        return
    end

    if sub == 'add' then
        local id = tonumber(args[2])
        if not id then
            return notify('rzspawn add <zone id>  --  stand outside the zone first', 'error')
        end

        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)

        TriggerServerEvent('naija-rz:server:addSpawn', id,
            tonumber(('%.2f'):format(c.x)),
            tonumber(('%.2f'):format(c.y)),
            tonumber(('%.2f'):format(c.z)),
            tonumber(('%.2f'):format(GetEntityHeading(ped))))
        return
    end

    notify('rzspawn list | add <id> | clear <id>', 'inform')
end, false)

-- ============================================================
--  THE LOBBY PED
-- ============================================================
-- A ped in the arena's lobby with a bubble over it that opens the zone
-- picker.
--
-- The BUBBLE belongs to the arena -- it owns the prompt system, the styling
-- and the key reading, and there is no sense in a second copy of all that
-- living here. We hand it a position and the NAME of an export, and it calls
-- back when somebody presses the key. Exactly what registerBoard does for the
-- wall, for exactly the same reason: a function does not survive crossing a
-- resource boundary.
--
-- The ped itself is ours, because it is our mode's ped.

local lobbyPed = nil

local function removeLobbyPed()
    if lobbyPed and DoesEntityExist(lobbyPed) then
        DeleteEntity(lobbyPed)
    end
    lobbyPed = nil

    -- pcall covers both the resource being gone and the export not existing.
    if GetResourceState(ARENA) == 'started' then
        pcall(function() exports[ARENA]:unregisterPrompt('redzone_entry') end)
    end
end

local function createLobbyPed()
    local cfg = Config.RZ.prompt
    if not (cfg and cfg.enabled and cfg.ped) then return end
    if lobbyPed and DoesEntityExist(lobbyPed) then return end
    if GetResourceState(ARENA) ~= 'started' then return end

    -- The prompt system is newer than the exports this resource hard-requires
    -- at startup, so it is checked here rather than in that list: an arena
    -- without it should cost you this one ped, not the whole mode.
    --
    -- THROUGH pcall, because indexing an export that does not exist raises
    -- "No such export" rather than returning nil. Written as a plain nil
    -- check, the guard meant to survive an old arena was itself the thing
    -- that crashed against one. arenaIsCompatible in server.lua already does
    -- it this way; this should have followed it.
    local hasPrompt = pcall(function()
        return exports[ARENA].registerPrompt
    end)

    if not hasPrompt then
        print('^3[redzone] this arena has no registerPrompt -- lobby ped skipped, /rz still works^0')
        return
    end

    local hash = joaat(cfg.ped.model)
    RequestModel(hash)

    local tries = 0
    while not HasModelLoaded(hash) and tries < 120 do
        Wait(50)
        tries = tries + 1
    end
    if not HasModelLoaded(hash) then
        print('^1[redzone] could not load the lobby ped model^0')
        return
    end

    local c = cfg.ped.coords
    lobbyPed = CreatePed(4, hash, c.x, c.y, c.z - 1.0, c.w or 0.0, false, true)
    SetEntityAsMissionEntity(lobbyPed, true, true)
    FreezeEntityPosition(lobbyPed, true)
    SetEntityInvincible(lobbyPed, true)
    SetBlockingOfNonTemporaryEvents(lobbyPed, true)
    if cfg.ped.scenario then
        TaskStartScenarioInPlace(lobbyPed, cfg.ped.scenario, 0, true)
    end
    SetModelAsNoLongerNeeded(hash)

    -- Coordinates, not the entity: an entity handle means nothing in another
    -- resource, so the arena is told where the bubble goes rather than what
    -- it is attached to.
    pcall(function()
        exports[ARENA]:registerPrompt('redzone_entry', {
            coords = vec3(c.x, c.y, c.z),
            distance = cfg.distance or 2.5,
            title = cfg.title or 'RED ZONE',
            actions = {
                {
                    key = cfg.key or 38,
                    keyLabel = cfg.keyLabel or 'E',
                    label = cfg.label or 'Open the Red Zone',
                    export = 'openFromPrompt',
                }
            }
        })
    end)
end

--- What the arena calls back when the key is pressed.
---
--- openPanel directly rather than through an event: it is a local defined
--- earlier in this file and therefore in scope here, and inventing an event
--- name that nothing registers is a handler that silently never fires.
exports('openFromPrompt', function()
    openPanel()
end)

-- In the arena's lobby only. The picker is for deciding where to go, and the
-- lobby is where that decision gets made.
CreateThread(function()
    Wait(4000)
    local was = nil

    while true do
        Wait(1000)
        local now = LocalPlayer.state.arenaLobby == true

        if now ~= was then
            was = now
            if now then createLobbyPed() else removeLobbyPed() end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeLobbyPed()
end)

-- ============================================================
--  NOBODY STAYS DOWN IN A ZONE
-- ============================================================
-- The same guarantee the arena's lobby makes, applied here.
--
-- The lobby has a loop that does not care WHY somebody is down or whether
-- anything reported it -- it notices, waits out the death screen, revives and
-- heals. That works because it asks one question on a timer rather than
-- depending on a chain of events arriving.
--
-- The death watcher above is still the normal path and still what credits the
-- kill. This sits underneath it and catches everything it misses: a knocked
-- state their script never published, a kill report the server rejected, an
-- export that was not answering. If a player has been down for longer than
-- the countdown should have taken, they are picked up regardless.
--
-- Deliberately slower than the main path. If the watcher is working this
-- never fires, and if it is not, this is the difference between a ten second
-- wait and a four minute bleedout.

CreateThread(function()
    local downSince = nil
    local recovering = false

    while true do
        Wait(math.floor(((Config.RZ.down or {}).checkEvery or 2.0) * 1000))

        if not inZone then
            downSince = nil

        elseif recovering then
            -- Leave it alone while a recovery is in flight.

        else
            -- Every signal, from either side. Same question the lobby asks.
            local d = arenaClient('deathState')
            local down = (type(d) == 'table' and d.down == true)
                or arenaClient('isDown') == true
                or amIDown()

            if not down then
                downSince = nil

            else
                downSince = downSince or GetGameTimer()

                -- The countdown plus a margin. Long enough that the normal
                -- path always wins when it is working, short enough that a
                -- player never sits through somebody else's bleedout.
                -- The normal path fires at delay. This is delay + grace, so
                -- it only ever runs when that has already failed.
                local limit = (downDelay() * 1000) + (downGrace() * 1000)

                if GetGameTimer() - downSince > limit then
                    recovering = true

                    print('^3[redzone] still down after the countdown -- picking them up^0')

                    -- Up first, then whole, then placed. Same order the lobby
                    -- uses: reviving after healing means their script can put
                    -- the health straight back down.
                    arenaClient('revivePlayer')

                    local ped = PlayerPedId()

                    -- Cuffs off. The restraint is how their script holds a
                    -- downed player, and nothing clears it when we are the
                    -- ones picking them up -- it would follow them into the
                    -- city and lock their inventory.
                    pcall(SetEnableHandcuffs, ped, false)
                    pcall(ClearPedSecondaryTask, ped)

                    pcall(SetEntityHealth, ped, GetEntityMaxHealth(ped))
                    pcall(ClearPedBloodDamage, ped)
                    pcall(ResetPedVisibleDamage, ped)
                    pcall(ClearPedTasksImmediately, ped)

                    -- Let go of the hold the death screen put on them, in
                    -- case this fired while that was still running.
                    FreezeEntityPosition(ped, false)
                    SetEntityVisible(ped, true, false)
                    SetEntityCollision(ped, true, true)
                    SetEntityInvincible(ped, false)

                    -- And put them at a spawn, which is the half the lobby
                    -- does not need to do.
                    dead = false
                    TriggerServerEvent('naija-rz:server:respawn')

                    Wait(3000)
                    downSince = nil
                    recovering = false
                end
            end
        end
    end
end)
