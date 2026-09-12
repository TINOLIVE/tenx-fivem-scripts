local QBCore = exports['qb-core']:GetCoreObject()
local ox = exports.ox_inventory

-- ============================================================
--  STATE
-- ============================================================
-- Runtime mirror only. The DB is the source of truth for who is owed what.
local Event = {
    active  = false,
    preview = false,  -- dry run: zone visuals only, nobody is touched
    id      = nil,
    coords  = nil,
    radius  = 0.0,
    startRadius = 0.0,
    roster  = {}, -- [identifier] = { src = number|nil, name = string }
    downed  = {}, -- [identifier] = true, populated by ak47_qb_ambulancejob events
    eliminated = {}, -- [identifier] = true, out for the round, sat in holding
    startedBy = nil,
    override = nil,  -- per-round toggles from the panel; never touches config
    forceClose = false,
    kills = {},      -- [identifier] = kill count for this round
    optedIn = {},    -- [identifier] = true, signed up rather than caught in the sweep
    startedByName = nil,
    phase = 0,       -- which shrink phase is current
    phaseDamage = 0, -- health per second the zone is taking right now
    nextCoords = nil,-- where the next circle will be, during the wait
    nextRadius = nil,
}

local autoEndTimer = nil

-- Forward declarations. These functions reference each other across the file
-- (startEvent kicks off the loot and shrink loops, runShrink ends the round),
-- so they're declared up here and assigned further down.
local endEvent
local runShrink
local spawnLoot
local clearLoot
local runLootRespawn
local scatterRoster
local spawnAirdrop
local runAirdrops

-- Panel state. Declared here because the round functions above write to them
-- and the panel section at the bottom of the file reads them.
local pushPanel
local startPreview
local findSourceByLicense
local findClearPoint
local Queue = {}          -- [license] = { src, name }
local queueOrder = {}     -- join order, so the panel can show who signed up first
local roundStartedAt
local nextCloseAt
local nextDropAt

-- ============================================================
--  HELPERS
-- ============================================================
local function dbg(msg, ...)
    if Config.Debug then
        print(('[naija-rz] ' .. msg):format(...))
    end
end

local function notify(src, msg, ntype)
    TriggerClientEvent('ox_lib:notify', src, {
        title = 'FFA',
        description = msg,
        type = ntype or 'inform',
        position = Config.NotifyPosition or 'center-right'
    })
end

local function getLicense(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return nil
end

local function isStaff(src)
    local license = getLicense(src)
    return license ~= nil and Config.Staff[license] ~= nil
end

local function hasPermission(src)
    if src == 0 then return true end -- server console
    if isStaff(src) then return true end
    if Config.AcePermission and IsPlayerAceAllowed(src, Config.AcePermission) then return true end
    return false
end

local function getCitizenId(src)
    local Player = QBCore.Functions.GetPlayer(src)
    return Player and Player.PlayerData.citizenid or nil
end

local function newEventId()
    return ('ffa_%s_%s'):format(os.time(), math.random(1000, 9999))
end

-- 2D distance only. The arena is a cylinder, not a sphere: a player on top of
-- a hill is still in the arena, and an admin starting the event from noclip
-- altitude doesn't push the whole zone into the sky.
local function distanceTo(src)
    if not Event.coords then return math.huge end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return math.huge end
    local c = GetEntityCoords(ped)
    return #(vector2(c.x, c.y) - vector2(Event.coords.x, Event.coords.y))
end

-- 2D distance from a player to any point.
local function distanceToPoint(src, point)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return math.huge end
    local c = GetEntityCoords(ped)
    return #(vector2(c.x, c.y) - vector2(point.x, point.y))
end

-- Everyone currently standing in the lobby. This is who gets swept when a
-- round starts -- not whoever happens to be inside the arena radius.
local function playersInLobby()
    local found = {}
    for _, playerId in ipairs(GetPlayers()) do
        local id = tonumber(playerId)
        if distanceToPoint(id, Config.Lobby.coords) <= Config.Lobby.radius then
            found[#found + 1] = id
        end
    end
    return found
end

-- Random point within `spread` metres of the holding coord, so a full lobby
-- of eliminated players doesn't end up standing inside each other.
local function holdingAreaPoint()
    local base = Config.Respawn.coords
    local spread = Config.Respawn.spread or 0.0

    if spread <= 0.0 then
        return base.x, base.y, base.z, base.w
    end

    local angle = math.random() * math.pi * 2
    local dist = math.sqrt(math.random()) * spread

    return base.x + (math.cos(angle) * dist),
           base.y + (math.sin(angle) * dist),
           base.z,
           math.random(0, 359) + 0.0
end

-- ============================================================
--  THE QUEUE
-- ============================================================
-- Players sign up at the ped and carry on with their day. The queue is the
-- roster source when a round starts -- they get pulled in from wherever they
-- are, no need to stand anywhere in particular.
local function queueCount()
    local n = 0
    for _ in pairs(Queue) do n = n + 1 end
    return n
end

local function pushQueueState()
    GlobalState.rzQueue = { count = queueCount(), max = Config.Queue.maxQueue or 64 }
end

local function inQueue(src)
    local license = getLicense(src)
    return license ~= nil and Queue[license] ~= nil
end

local function addToQueue(src)
    local license = getLicense(src)
    if not license then return false, 'Could not identify you.' end
    if Queue[license] then return false, 'You are already signed up.' end

    if queueCount() >= (Config.Queue.maxQueue or 64) then
        return false, 'The queue is full.'
    end

    -- Someone already owed an inventory must not be swept again -- that is the
    -- same guard that protects against double confiscation.
    local owed = MySQL.scalar.await('SELECT identifier FROM tenx_rz_snapshots WHERE identifier = ?', { license })
    if owed then
        return false, 'You still have items held from a previous round. Tell an admin.'
    end

    Queue[license] = { src = src, name = GetPlayerName(src) }
    queueOrder[#queueOrder + 1] = license

    Player(src).state:set('rzQueued', true, true)
    pushQueueState()
    if pushPanel then pushPanel() end

    return true, ('You are in. %s waiting.'):format(queueCount())
end

local function removeFromQueue(src, silent)
    local license = getLicense(src)
    if not license or not Queue[license] then return false, 'You are not signed up.' end

    Queue[license] = nil
    for i, l in ipairs(queueOrder) do
        if l == license then table.remove(queueOrder, i) break end
    end

    if GetPlayerName(src) then
        Player(src).state:set('rzQueued', nil, true)
    end

    pushQueueState()
    if pushPanel then pushPanel() end

    return true, silent and '' or 'You left the queue.'
end

local function clearQueue()
    for license in pairs(Queue) do
        local src = findSourceByLicense(license)
        if src then Player(src).state:set('rzQueued', nil, true) end
    end
    Queue = {}
    queueOrder = {}
    pushQueueState()
end

RegisterNetEvent('naija-rz:server:joinQueue', function()
    local src = source
    local ok, msg = addToQueue(src)
    notify(src, msg, ok and 'success' or 'error')
end)

RegisterNetEvent('naija-rz:server:leaveQueue', function()
    local src = source
    local ok, msg = removeFromQueue(src)
    notify(src, msg, ok and 'inform' or 'error')
end)

-- ============================================================
--  ALIVE COUNTER
-- ============================================================
local function pushStats()
    if not Event.active or Event.preview then
        GlobalState.rzStats = false
        return
    end

    local total, alive = 0, 0
    for license in pairs(Event.roster) do
        total = total + 1
        if not Event.eliminated[license] then alive = alive + 1 end
    end

    GlobalState.rzStats = { alive = alive, total = total }

    -- Each player's own kill count, sent only to them.
    for license, data in pairs(Event.roster) do
        local src = data.src or findSourceByLicense(license)
        if src and GetPlayerName(src) then
            TriggerClientEvent('naija-rz:client:myKills', src, Event.kills[license] or 0)
        end
    end
end

-- ============================================================
--  BROADCAST ZONE TO CLIENTS
-- ============================================================
local function pushZoneState()
    if Event.active then
        GlobalState.rzActive = {
            active = true,
            x = Event.coords.x,
            y = Event.coords.y,
            z = Event.coords.z,
            radius = Event.radius,
            ammoMode = Config.AmmoMode,
            primary = Config.PrimaryWeapon,
            preview = Event.preview or false,
            phase = Event.phase or 0,
            totalPhases = #(Config.Shrink.phases or {}),
            -- The next circle, announced during the wait so clients can draw
            -- it on the map. Nil while the ring is actually moving.
            next = Event.nextCoords and {
                x = Event.nextCoords.x,
                y = Event.nextCoords.y,
                z = Event.nextCoords.z,
                radius = Event.nextRadius
            } or false,
            ringDamage = (Config.RingDamage.enabled and not Event.preview) and {
                tick = Config.RingDamage.tickInterval,
                -- Whatever the CURRENT phase bites for, applied everywhere
                -- outside the ring. Retreating to where an earlier, gentler
                -- ring used to be buys nothing.
                damage = Event.phaseDamage or 1,
                lethal = Config.RingDamage.lethal,
                warn = Config.RingDamage.warn
            } or false
        }
    else
        GlobalState.rzActive = { active = false }
    end
end

-- ============================================================
--  GIVE THE ARENA LOADOUT
-- ============================================================
local function giveLoadout(src)
    for _, entry in ipairs(Config.Loadout) do
        local metadata = entry.metadata and table.clone(entry.metadata) or {}

        if entry.name == Config.PrimaryWeapon
           and (Config.AmmoMode == 'fixed' or Config.AmmoMode == 'items') then
            metadata.ammo = Config.FixedAmmo
        end

        ox:AddItem(src, entry.name, entry.count or 1, metadata)
    end

    if Config.AmmoMode == 'items' then
        ox:AddItem(src, Config.AmmoItem, Config.AmmoItemCount)
    end
end

-- ============================================================
--  TAKE INVENTORY  (snapshot FIRST, strip SECOND)
-- ============================================================
local function takeInventory(src)
    if not Event.active then return false end

    -- Preview mode is a dry run. Never take anything, no matter what.
    if Event.preview then return false end

    local license = getLicense(src)
    if not license then
        dbg('Refused to sweep player %s - no license identifier found', src)
        return false
    end

    -- Already on the roster? Never touch them again. This is the guard that
    -- stops a double-confiscation overwriting somebody's real inventory.
    if Event.roster[license] then return false end

    -- Staff immunity only covers being caught incidentally. Signing up at the
    -- ped is a decision to play, and it overrides it.
    local optedIn = Event.optedIn and Event.optedIn[license]

    if Config.StaffImmune and isStaff(src) and not (Config.StaffCanPlay and optedIn) then
        dbg('Skipping staff member %s (did not sign up)', GetPlayerName(src))
        return false
    end

    -- Belt and braces: check the DB too, in case runtime state got out of sync.
    local existing = MySQL.scalar.await('SELECT identifier FROM tenx_rz_snapshots WHERE identifier = ?', { license })
    if existing then
        dbg('Player %s already has an outstanding snapshot - refusing to sweep again', GetPlayerName(src))
        Event.roster[license] = { src = src, name = GetPlayerName(src) }
        return false
    end

    local items = ox:GetInventoryItems(src)
    if not items then
        dbg('Could not read inventory for %s', GetPlayerName(src))
        notify(src, Config.Text.take_failed, 'error')
        return false
    end

    -- Flatten to a clean array so slot + metadata survive the round trip.
    local snapshot = {}
    for _, v in pairs(items) do
        if v and v.name then
            snapshot[#snapshot + 1] = {
                name     = v.name,
                count    = v.count,
                slot     = v.slot,
                metadata = v.metadata
            }
        end
    end

    local encoded = json.encode(snapshot)

    -- WRITE FIRST. If this fails, the player keeps everything and sits the round out.
    local ok, err = pcall(function()
        MySQL.insert.await(
            'INSERT INTO tenx_rz_snapshots (identifier, citizenid, player_name, event_id, inventory, status) VALUES (?, ?, ?, ?, ?, ?)',
            { license, getCitizenId(src), GetPlayerName(src), Event.id, encoded, 'active' }
        )
    end)

    if not ok then
        print(('[naija-rz] SNAPSHOT WRITE FAILED for %s - inventory left untouched. Error: %s')
            :format(GetPlayerName(src), tostring(err)))
        notify(src, Config.Text.take_failed, 'error')
        return false
    end

    -- Only now is it safe to strip.
    ox:ClearInventory(src)
    giveLoadout(src)

    Event.roster[license] = { src = src, name = GetPlayerName(src) }
    pushStats()

    Player(src).state:set('rzActive', true, true)

    notify(src, Config.Text.stripped, 'success')
    dbg('Swept %s (%s items stored)', GetPlayerName(src), #snapshot)

    return true
end

-- ============================================================
--  RESTORE ONE PLAYER
-- ============================================================
local function restoreOne(row, src, isRoundEnd)
    local snapshot = json.decode(row.inventory) or {}
    local failed = {}

    if src then
        -- Wipe whatever they're holding now: the arena weapon, and anything
        -- they looted off a corpse during the round.
        ox:ClearInventory(src)

        for _, item in ipairs(snapshot) do
            local success = ox:AddItem(src, item.name, item.count, item.metadata, item.slot)
            if not success then
                -- Second try without forcing the original slot.
                success = ox:AddItem(src, item.name, item.count, item.metadata)
            end
            if not success then
                failed[#failed + 1] = item
            end
        end

        -- Anything that genuinely wouldn't fit goes to a recovery stash
        -- rather than disappearing.
        if #failed > 0 then
            local stashId = ('tenx_rz_recovery_%s'):format(row.identifier)
            ox:RegisterStash(stashId, 'FFA Recovery', Config.RecoveryStashSlots, Config.RecoveryStashWeight, row.identifier)
            for _, item in ipairs(failed) do
                ox:AddItem(stashId, item.name, item.count, item.metadata)
            end
            print(('[naija-rz] %s had %s item(s) that would not fit. Moved to recovery stash. Open with /ffarecover'):format(row.player_name or row.identifier, #failed))
            notify(src, ('%s item(s) did not fit and are in your recovery stash. Tell an admin.'):format(#failed), 'warning')
        else
            notify(src, Config.Text.restored, 'success')
        end

        -- Revive via ak47_qb_ambulancejob. Routed through our own client event
        -- because their docs document the revive as a CLIENT TriggerEvent, so
        -- firing it locally on their machine is the version guaranteed to exist.
        -- Also clears skelly damage, otherwise players walk out of the arena
        -- carrying permanent limb injuries and driving penalties.
        TriggerClientEvent('naija-rz:client:revive', src)

        -- Pull survivors to the holding area so the whole roster finishes in
        -- one place. Eliminated players are already there.
        local wasEliminated = Event.eliminated[row.identifier] and true or false

        if isRoundEnd and Config.Respawn.gatherSurvivorsOnEnd and not wasEliminated then
            local hx, hy, hz, hw = holdingAreaPoint()
            TriggerClientEvent('naija-rz:client:eventOver', src, { x = hx, y = hy, z = hz, w = hw }, true)
        else
            -- No teleport. Just clear any leftover invincibility.
            TriggerClientEvent('naija-rz:client:eventOver', src, nil, false)
        end

        Player(src).state:set('rzActive', nil, true)
        Player(src).state:set('rzOut', nil, true)
        Event.downed[row.identifier] = nil
        Event.eliminated[row.identifier] = nil
    end

    -- Move the row into the permanent log, then clear the debt.
    MySQL.insert.await(
        'INSERT INTO tenx_rz_log (identifier, citizenid, player_name, event_id, inventory, failed, taken_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { row.identifier, row.citizenid, row.player_name, row.event_id, row.inventory,
          (#failed > 0 and json.encode(failed) or nil), row.taken_at }
    )
    MySQL.update.await('DELETE FROM tenx_rz_snapshots WHERE identifier = ?', { row.identifier })

    dbg('Restored %s (%s items, %s failed)', row.player_name or row.identifier, #snapshot, #failed)
    return true
end

-- Find the online source for a license, if any.
function findSourceByLicense(license)
    for _, playerId in ipairs(GetPlayers()) do
        local id = tonumber(playerId)
        if getLicense(id) == license then return id end
    end
    return nil
end

-- Last player standing. If more than one is still alive when a round is
-- ended by hand, the one with the most kills takes it -- rather than picking
-- arbitrarily or recording nobody.
local function determineWinner()
    local alive = {}

    for license, data in pairs(Event.roster) do
        if not Event.eliminated[license] then
            alive[#alive + 1] = {
                license = license,
                name = data.name or 'Unknown',
                kills = Event.kills[license] or 0
            }
        end
    end

    if #alive == 0 then return nil end

    table.sort(alive, function(a, b) return a.kills > b.kills end)
    return alive[1], #alive
end

local function logRound(reason)
    if not Event.id then return end

    local winner, aliveCount = determineWinner()
    local total = 0
    for _ in pairs(Event.roster) do total = total + 1 end

    -- A round nobody joined isn't worth a row.
    if total == 0 then return end

    MySQL.insert.await(
        'INSERT INTO tenx_rz_rounds (event_id, winner_name, winner_id, winner_kills, players, duration, radius, end_reason, started_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            Event.id,
            winner and winner.name or nil,
            winner and winner.license or nil,
            winner and winner.kills or 0,
            total,
            roundStartedAt and (os.time() - roundStartedAt) or 0,
            math.floor(Event.startRadius or 0),
            reason or 'ended',
            Event.startedByName
        }
    )

    if winner then
        print(('[naija-rz] Round won by %s with %s kill(s), %s players'):format(
            winner.name, winner.kills, total))

        TriggerClientEvent('naija-rz:client:winner', -1, {
            name = winner.name,
            kills = winner.kills,
            players = total,
            shared = (aliveCount or 1) > 1
        })
    else
        print(('[naija-rz] Round ended with no survivors, %s players'):format(total))
    end
end

-- ============================================================
--  END THE EVENT  (roster-based, not location-based)
-- ============================================================
function endEvent(adminSrc)
    if Event.preview then
        Event.active = false
        Event.preview = false
        Event.id = nil
        Event.coords = nil
        pushZoneState()
        if adminSrc then notify(adminSrc, 'Preview stopped.', 'success') end
        return 0
    end

    if not Event.active then
        if adminSrc then notify(adminSrc, Config.Text.not_live, 'error') end
        return 0
    end

    -- Work out and record the winner BEFORE the roster is torn down.
    logRound(adminSrc and 'admin' or 'auto')

    Event.active = false
    if autoEndTimer then autoEndTimer = nil end
    pushZoneState()

    clearLoot()

    -- Pull EVERY outstanding snapshot. Not "everyone in the area" - everyone
    -- the script owes, wherever they physically ended up.
    local rows = MySQL.query.await('SELECT * FROM tenx_rz_snapshots') or {}
    local restored, offline = 0, 0

    for _, row in ipairs(rows) do
        local src = findSourceByLicense(row.identifier)
        if src then
            restoreOne(row, src, true)
            restored = restored + 1
        else
            -- Offline. Leave the debt standing, flag it, pay it on next login.
            MySQL.update.await('UPDATE tenx_rz_snapshots SET status = ? WHERE identifier = ?', { 'pending', row.identifier })
            offline = offline + 1
        end
    end

    for license in pairs(Event.eliminated) do
        local src = findSourceByLicense(license)
        if src then Player(src).state:set('rzOut', nil, true) end
    end

    Event.roster = {}
    Event.downed = {}
    Event.eliminated = {}
    Event.override = nil
    Event.forceClose = false
    Event.kills = {}
    Event.optedIn = {}
    Event.startedByName = nil
    Event.phase = 0
    Event.phaseDamage = 0
    Event.nextCoords = nil
    Event.nextRadius = nil
    GlobalState.rzStats = false
    Event.id = nil
    Event.coords = nil
    roundStartedAt = nil
    nextCloseAt = nil
    nextDropAt = nil

    local msg = Config.Text.event_ended:format(restored)
    if offline > 0 then
        msg = msg .. (' %s offline, they get theirs on next login.'):format(offline)
    end

    if adminSrc then notify(adminSrc, msg, 'success') end
    print('[naija-rz] ' .. msg)

    return restored
end

-- ============================================================
--  START THE EVENT
-- ============================================================
local function startEvent(src, radius)
    if Event.active then
        notify(src, Config.Text.already_live, 'error')
        return
    end

    -- Arena centre: pinned in config, or wherever the admin is standing.
    local coords = Config.ArenaCentre or GetEntityCoords(GetPlayerPed(src))

    Event.active    = true
    Event.preview   = false
    Event.id        = newEventId()
    Event.coords    = coords
    Event.radius    = radius
    Event.startRadius = radius
    Event.roster    = {}
    Event.downed    = {}
    Event.eliminated = {}
    Event.startedBy = getLicense(src)
    Event.startedByName = (src and src ~= 0 and GetPlayerName(src)) or 'console'
    Event.forceClose = false
    Event.kills = {}
    roundStartedAt = os.time()
    nextCloseAt = nil
    nextDropAt = nil

    pushZoneState()

    -- Who gets swept in. The queue is the normal source -- players signed up
    -- at the ped and are scattered across the city. The lobby radius still
    -- works alongside it if you have it switched on.
    local swept = 0
    local candidates, seen = {}, {}

    Event.optedIn = {}

    if Config.Queue.enabled then
        for _, license in ipairs(queueOrder) do
            if Queue[license] then
                -- Everyone in the queue asked to be here, staff included.
                Event.optedIn[license] = true
                local id = findSourceByLicense(license)
                if id and not seen[id] then
                    seen[id] = true
                    candidates[#candidates + 1] = id
                end
            end
        end
    end

    if Config.Lobby.enabled then
        for _, id in ipairs(playersInLobby()) do
            if not seen[id] then
                seen[id] = true
                candidates[#candidates + 1] = id
            end
        end
    end

    if not Config.Queue.enabled and not Config.Lobby.enabled then
        for _, playerId in ipairs(GetPlayers()) do
            local id = tonumber(playerId)
            if distanceTo(id) <= radius and not seen[id] then
                seen[id] = true
                candidates[#candidates + 1] = id
            end
        end
    end

    for _, id in ipairs(candidates) do
        if takeInventory(id) then swept = swept + 1 end
    end

    -- The queue has done its job. Emptying it here means a player can sign up
    -- again for the next round without a stale entry pulling them in twice.
    clearQueue()

    local msg = Config.Text.event_started:format(swept, math.floor(radius))
    notify(src, msg, 'success')
    print(('[naija-rz] %s started event %s. %s'):format(GetPlayerName(src), Event.id, msg))

    local eventId = Event.id

    -- Spread everyone out. Start only — never again for the rest of the round.
    if Config.StartScatter.enabled then
        CreateThread(function()
            Wait(500) -- let the loadout land before they move
            if Event.active and Event.id == eventId then
                scatterRoster()
            end
        end)
    end

    -- Per-round toggles from the panel. Absent means "use the config", so
    -- starting from a command behaves exactly as it always did.
    local ov = Event.override or {}

    if Config.Shrink.enabled and ov.shrink ~= false then
        CreateThread(function() runShrink(eventId) end)
    end

    if Config.Loot.enabled and ov.loot ~= false then
        CreateThread(function()
            Wait(1000) -- let clients build the zone first
            spawnLoot(1.0)
            runLootRespawn(eventId)
        end)
    end

    if Config.Airdrop.enabled and ov.airdrop ~= false then
        CreateThread(function() runAirdrops(eventId) end)
    end

    if pushPanel then pushPanel() end
end

-- ============================================================
--  ROLLING ENTRY  (client reports, server verifies)
-- ============================================================
RegisterNetEvent('naija-rz:server:enteredZone', function()
    local src = source
    if not Event.active then return end

    -- Never trust the client. Confirm they really are inside the sphere.
    -- Small tolerance for movement between the client event and this check.
    if distanceTo(src) > (Event.radius + 15.0) then
        dbg('Rejected entry claim from %s - server says they are %.1fm away', GetPlayerName(src), distanceTo(src))
        return
    end

    takeInventory(src)
end)

-- ============================================================
--  AUTO-END: LAST MAN STANDING
-- ============================================================
-- ============================================================
--  GROUND LOOT
-- ============================================================
-- Piles are script-owned state, not ox_inventory drops. Players press E on a
-- pile and the server hands the items over directly. Nothing physical is ever
-- created in the world, so nothing can survive the round or leak into the
-- economy -- ending the event is just clearing a table.
local lootPiles = {}
local lootNextId = 0

-- Random point inside the ring, biased so loot spreads evenly by area rather
-- than clustering at the centre. Reads Event.coords live, so replenished loot
-- and late airdrops land inside wherever the circle has travelled to -- not
-- where it started.
local function randomPointInRing(minF, maxF)
    local angle = math.random() * math.pi * 2
    minF = minF or Config.Loot.minDistanceFactor or 0.10
    maxF = maxF or Config.Loot.maxDistanceFactor or 0.90
    local t = minF + (math.sqrt(math.random()) * (maxF - minF))
    local dist = Event.radius * t

    return Event.coords.x + (math.cos(angle) * dist),
           Event.coords.y + (math.sin(angle) * dist)
end

-- Send the pile list out so clients can draw markers, prompts and blips.
local function pushLootState()
    if not Config.Loot.enabled then
        GlobalState.rzLoot = false
        return
    end

    local points = {}
    for _, pile in pairs(lootPiles) do
        points[#points + 1] = {
            id = pile.id,
            x = pile.x, y = pile.y, z = pile.z,
            label = pile.label,
            airdrop = pile.airdrop or nil,
            distance = pile.distance
        }
    end

    GlobalState.rzLoot = {
        points = points,
        blip = Config.Loot.blip,
        marker = Config.Loot.marker,
        distance = Config.Loot.collectDistance or 2.0,
        drawDistance = Config.Loot.drawDistance or 80.0,
        airdropBlip = Config.Airdrop.blip,
        airdropMarker = Config.Airdrop.marker,
        airdropDistance = Config.Airdrop.collectDistance or 3.0
    }
end

function clearLoot()
    local n = 0
    for _ in pairs(lootPiles) do n = n + 1 end

    lootPiles = {}
    GlobalState.rzLoot = false

    dbg('Cleared %s loot piles', n)
    return n
end
-- ============================================================
--  START SCATTER
-- ============================================================
-- Spread the roster across the ring at the moment the round begins. Runs once,
-- on start only. Mid-round arrivals are left where they walked in, and this is
-- completely separate from the death teleport to the holding area.
function scatterRoster()
    if not Config.StartScatter.enabled then return 0 end
    if not Event.active or Event.preview then return 0 end

    local cfg = Config.StartScatter
    local placed = {}
    local count = 0

    for license, data in pairs(Event.roster) do
        local src = data.src
        if src and GetPlayerName(src) then
            -- Dry land, outside your no-spawn areas, spaced from everyone
            -- already placed. Spacing is dropped before dryness is.
            local x, y, z, clean = findClearPoint(
                cfg.minDistanceFactor, cfg.maxDistanceFactor,
                placed, cfg.minSpacing or 25.0)

            if not clean then
                dbg('Compromised spawn point for %s', GetPlayerName(src))
            end

            placed[#placed + 1] = { x, y }

            if Config.Drop and Config.Drop.enabled then
                TriggerClientEvent('naija-rz:client:drop', src, {
                    x = x, y = y, z = z,
                    height = Config.Drop.height or 320.0,
                    autoOpenAt = Config.Drop.autoOpenAt or 90.0,
                    protect = Config.Drop.protectUntilLanded ~= false,
                    showControls = Config.Drop.showControls ~= false,
                    controlsDuration = Config.Drop.controlsDuration or 12
                })
            else
                TriggerClientEvent('naija-rz:client:scatter', src, x, y, z, cfg.settleTime or 20)
            end

            count = count + 1
        end
    end

    dbg('Scattered %s players across the ring', count)
    return count
end

-- Ground height has to come from a client, since the server has no collision.
-- We ask someone who is actually inside the ring so the area is streamed in.
local function findClientInRing()
    for _, playerId in ipairs(GetPlayers()) do
        local id = tonumber(playerId)
        if distanceTo(id) <= Event.radius then return id end
    end
    return nil
end

-- Is this point inside an area you've marked as off limits?
local function inNoSpawnZone(x, y)
    for _, z in ipairs(Config.NoSpawn.zones or {}) do
        if #(vector2(x, y) - vector2(z.x + 0.0, z.y + 0.0)) <= (z.radius or 0.0) then
            return true, z.label
        end
    end
    return false
end

-- Asks a client where the floor is AND whether that floor is underwater.
-- Water is the reason people end up in the sea, and checking it here means
-- you never have to mark the coastline by hand.
local function probeGround(x, y)
    local client = findClientInRing()
    if not client then
        return Event.coords.z, false
    end

    local res = lib.callback.await('naija-rz:client:groundZ', client, x, y, Event.coords.z)

    if type(res) == 'table' then
        return res.z or Event.coords.z, res.water and true or false
    end

    -- Older shape, or the callback failed.
    return res or Event.coords.z, false
end

local function resolveGroundZ(x, y)
    local z = probeGround(x, y)
    return z
end

-- One clear point: inside the ring, out of the water, out of your no-spawn
-- areas, and optionally spaced away from points already chosen.
function findClearPoint(minF, maxF, placed, spacing)
    local attempts = Config.NoSpawn.attempts or 40
    local fallbackX, fallbackY, fallbackZ

    for i = 1, attempts do
        local x, y = randomPointInRing(minF, maxF)

        if not inNoSpawnZone(x, y) then
            local z, water = probeGround(x, y)

            if not fallbackX then fallbackX, fallbackY, fallbackZ = x, y, z end

            local wet = water and Config.NoSpawn.avoidWater
            local clash = false

            if placed and spacing and spacing > 0 then
                for _, prev in ipairs(placed) do
                    if #(vector2(x, y) - vector2(prev[1], prev[2])) < spacing then
                        clash = true
                        break
                    end
                end
            end

            if not wet and not clash then
                return x, y, z, true
            end

            -- Spacing is a nice-to-have; dry land is not. Keep a dry point as
            -- the fallback even if it was too close to someone else.
            if not wet then fallbackX, fallbackY, fallbackZ = x, y, z end
        end
    end

    -- Nothing perfect found. Return the best we saw rather than stalling the
    -- round, but say so in the console so you know the zones need a look.
    dbg('No clear point after %s tries -- using the closest match', attempts)
    return fallbackX or Event.coords.x, fallbackY or Event.coords.y,
           fallbackZ or Event.coords.z, false
end

-- Piles hold a LIST of items, so a supply pile and an airdrop crate are the
-- same structure -- the crate just has more in it and different visuals.
local function createPile(x, y, z, items, opts)
    opts = opts or {}
    lootNextId = lootNextId + 1

    lootPiles[lootNextId] = {
        id = lootNextId,
        x = x, y = y, z = z,
        items = items,
        label = opts.label or 'Supplies',
        airdrop = opts.airdrop or false,
        distance = opts.distance
    }

    return lootNextId
end

local function spawnLootPile(entry)
    local x, y, z = findClearPoint()

    createPile(x, y, z,
        { { name = entry.name, count = entry.count or 1, metadata = entry.metadata } },
        { label = entry.label or (Config.Loot.blip and Config.Loot.blip.label) or 'Supplies' })

    return true
end

-- ============================================================
--  AIRDROP
-- ============================================================
function spawnAirdrop()
    if not Config.Airdrop.enabled or not Event.active or Event.preview then return end

    -- Inside the CURRENT ring, not the original, so it never lands somewhere
    -- the zone has already made lethal -- and on dry land, clear of your
    -- no-spawn areas, so it never lands in the sea either.
    local x, y, z = findClearPoint(0.05, 0.75)

    local items = {}
    for _, entry in ipairs(Config.Airdrop.items) do
        items[#items + 1] = {
            name = entry.name,
            count = entry.count or 1,
            metadata = entry.metadata
        }
    end

    createPile(x, y, z, items, {
        label = Config.Airdrop.label or 'Airdrop',
        airdrop = true,
        distance = Config.Airdrop.collectDistance or 3.0
    })

    pushLootState()

    if Config.Airdrop.announce then
        TriggerClientEvent('naija-rz:client:airdrop', -1, { x = x, y = y, z = z })
    end

    print(('[naija-rz] Airdrop landed at %.1f, %.1f'):format(x, y))
end

function runAirdrops(eventId)
    if not Config.Airdrop.enabled then return end

    local times = Config.Airdrop.spawnAfter
    if type(times) ~= 'table' then times = { times } end

    local elapsed = 0
    for _, at in ipairs(times) do
        local wait = (at - elapsed) * 1000

        if wait > 0 then
            nextDropAt = os.time() + math.floor(wait / 1000)
            if pushPanel then pushPanel() end
            Wait(wait)
        end
        elapsed = at

        if not Event.active or Event.id ~= eventId then return end
        spawnAirdrop()
        nextDropAt = nil
        if pushPanel then pushPanel() end
    end

    nextDropAt = nil
end

function spawnLoot(fraction)
    if not Config.Loot.enabled or not Event.active then return 0 end

    local spawned = 0

    for _, entry in ipairs(Config.Loot.items) do
        local count = math.floor((entry.piles or 1) * (fraction or 1.0))
        for _ = 1, count do
            if not Event.active then break end
            if spawnLootPile(entry) then spawned = spawned + 1 end
            Wait(50) -- spread the work out so we don't stall a frame
        end
    end

    pushLootState()
    dbg('Spawned %s loot piles', spawned)
    return spawned
end

-- ============================================================
--  COLLECTING A PILE
-- ============================================================
-- Server authoritative throughout: the client only ever says which pile it
-- wants. Position, roster membership and whether the pile still exists are
-- all checked here, and the pile is removed before the items are handed over
-- so two players pressing E at the same moment can't both get it.
RegisterNetEvent('naija-rz:server:collectLoot', function(pileId)
    local src = source
    if not Event.active or Event.preview then return end

    local license = getLicense(src)

    -- Staff and spectators can SEE the piles but not take them. Silently
    -- ignoring the keypress just looks broken, so say why.
    if not license or not Event.roster[license] then
        return notify(src, 'You are not in this round, so you cannot take supplies.', 'error')
    end

    if Event.eliminated[license] then
        return notify(src, 'You are out of the round.', 'error')
    end

    local pile = lootPiles[pileId]
    if not pile then return end

    -- Never trust the client's word on proximity.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local pos = GetEntityCoords(ped)
    local reach = (Config.Loot.collectDistance or 2.0) + 3.0
    if #(pos - vec3(pile.x, pile.y, pile.z)) > reach then
        dbg('Rejected loot grab from %s: too far away', GetPlayerName(src))
        return
    end

    -- Claim it first. Whoever gets here second finds nothing.
    lootPiles[pileId] = nil

    local given, leftover = 0, {}

    for _, item in ipairs(pile.items) do
        local ok = ox:AddItem(src, item.name, item.count, item.metadata)
        if ok then
            given = given + 1
        else
            -- Didn't fit. Keep it in the pile rather than deleting it.
            leftover[#leftover + 1] = item
        end
    end

    if #leftover > 0 then
        pile.items = leftover
        lootPiles[pileId] = pile
        notify(src, ('No room for %s of the items.'):format(#leftover), 'error')
    end

    pushLootState()

    if given > 0 then
        TriggerClientEvent('naija-rz:client:collected', src, pile.label, given, pile.airdrop)
        dbg('%s collected %s item stack(s) from %s', GetPlayerName(src), given, pile.label)
    end
end)

function runLootRespawn(eventId)
    if not Config.Loot.enabled or not Config.Loot.respawn then return end

    while Event.active and Event.id == eventId do
        Wait(Config.Loot.respawnInterval * 1000)
        if not Event.active or Event.id ~= eventId then return end
        spawnLoot(Config.Loot.respawnFraction or 0.4)
    end
end


-- ============================================================
--  THE SHRINKING RING
-- ============================================================
-- The circle MOVES. Each phase picks a new centre inside the current circle
-- and travels there while shrinking, so players have to rotate rather than
-- stand still. The next circle is announced and drawn on everyone's map
-- during the wait, exactly like Warzone's tac map, so the rotation is a
-- decision rather than a surprise.

-- A new centre that keeps the smaller circle entirely inside the current one.
local function pickNextCentre(centre, currentRadius, nextRadius)
    local drift = Config.Shrink.drift
    if drift == nil then drift = 1.0 end
    drift = math.min(1.0, math.max(0.0, drift))

    -- How far the centre can move and still fit. Zero when the next circle is
    -- the same size, which is why it grows as the circle gets smaller.
    local maxOffset = math.max(0.0, (currentRadius - nextRadius)) * drift
    if maxOffset <= 0.1 then
        return centre.x, centre.y
    end

    -- sqrt for an even spread by area rather than clustering at the middle.
    local angle = math.random() * math.pi * 2
    local dist = math.sqrt(math.random()) * maxOffset

    return centre.x + math.cos(angle) * dist,
           centre.y + math.sin(angle) * dist
end

function runShrink(eventId)
    if not Config.Shrink.enabled then return end

    local phases = Config.Shrink.phases or {}
    if #phases == 0 then return end

    local startDelay = Config.Shrink.startDelay or 0
    local budget = math.max(30, (Config.Shrink.totalDuration or 1800) - startDelay)
    local slice = budget / #phases
    local holdFrac = math.min(0.9, math.max(0.0, Config.Shrink.holdFraction or 0.6))

    local holdTime = slice * holdFrac
    local closeTime = slice - holdTime

    print(('[naija-rz] Zone: %.0fs total, %s phases, %.0fs wait + %.0fs closing each')
        :format(Config.Shrink.totalDuration or 1800, #phases, holdTime, closeTime))

    Event.phase = 0
    Event.phaseDamage = phases[1].damage or 1
    pushZoneState()

    nextCloseAt = os.time() + startDelay
    if pushPanel then pushPanel() end
    Wait(startDelay * 1000)

    for i, phase in ipairs(phases) do
        if not Event.active or Event.id ~= eventId then return end

        local fromRadius = Event.radius
        local fromX, fromY = Event.coords.x, Event.coords.y
        local targetRadius = Event.startRadius * (phase.radius or 0)
        local isLast = i >= #phases

        -- Where the next circle will be. Chosen now so it can be shown during
        -- the wait -- that preview is the whole point.
        local targetX, targetY = pickNextCentre(Event.coords, fromRadius, targetRadius)

        Event.nextCoords = { x = targetX, y = targetY, z = Event.coords.z }
        Event.nextRadius = targetRadius
        Event.phase = i - 1
        pushZoneState()

        TriggerClientEvent('naija-rz:client:ringClosing', -1, {
            target = math.floor(targetRadius),
            from = math.floor(fromRadius),
            duration = math.floor(closeTime),
            wait = math.floor(holdTime),
            closeNo = i,
            totalCloses = #phases,
            isLast = isLast,
            damage = phase.damage,
            moved = math.floor(math.sqrt((targetX - fromX) ^ 2 + (targetY - fromY) ^ 2))
        })

        dbg('Phase %s/%s announced: %.0fm -> %.0fm, centre moves %.0fm, %s dmg/s',
            i, #phases, fromRadius, targetRadius,
            math.sqrt((targetX - fromX) ^ 2 + (targetY - fromY) ^ 2), phase.damage)

        -- ── WAIT: nothing moves, the next circle is on the map ──
        nextCloseAt = os.time() + math.floor(holdTime)
        if pushPanel then pushPanel() end

        local waited = 0
        local gap = holdTime * 1000
        while waited < gap do
            if not Event.active or Event.id ~= eventId then return end
            if Event.forceClose then
                Event.forceClose = false
                dbg('Close pulled forward by an admin')
                break
            end
            Wait(250)
            waited = waited + 250
        end

        if not Event.active or Event.id ~= eventId then return end

        -- ── CLOSE: travel to the new centre and shrink at the same time ──
        TriggerClientEvent('naija-rz:client:ringMoving', -1)

        local steps = math.max(1, math.floor(closeTime * 2))
        for step = 1, steps do
            if not Event.active or Event.id ~= eventId then return end

            local t = step / steps
            Event.radius = fromRadius + ((targetRadius - fromRadius) * t)
            Event.coords = vec3(
                fromX + ((targetX - fromX) * t),
                fromY + ((targetY - fromY) * t),
                Event.coords.z)

            pushZoneState()
            Wait(500)
        end

        Event.radius = targetRadius
        Event.coords = vec3(targetX, targetY, Event.coords.z)
        Event.phase = i
        Event.nextCoords = nil
        Event.nextRadius = nil

        -- The bite gets harder the moment the phase lands, everywhere at once.
        Event.phaseDamage = phase.damage or 1
        pushZoneState()

        if isLast then
            TriggerClientEvent('naija-rz:client:zoneClosed', -1)
            nextCloseAt = nil
            if pushPanel then pushPanel() end
            print('[naija-rz] Ring fully closed. Everywhere is now lethal.')
            return
        end
    end
end

-- ============================================================
--  KILL FEED
-- ============================================================
-- The victim's client reports who killed it, since only the client can read
-- the killer ped. The server decides whether the entry is legitimate before
-- broadcasting, so nobody can spam the feed with invented kills.
RegisterNetEvent('naija-rz:server:reportKill', function(killerServerId, cause)
    local victim = source
    if not Event.active or Event.preview then return end

    local vLicense = getLicense(victim)
    if not vLicense or not Event.roster[vLicense] then return end

    local victimName = GetPlayerName(victim)
    local killerName = nil

    if cause ~= 'zone' and killerServerId and killerServerId > 0 and killerServerId ~= victim then
        local kLicense = getLicense(killerServerId)
        -- Only credit kills between players actually in the round.
        if kLicense and Event.roster[kLicense] then
            killerName = GetPlayerName(killerServerId)
        end
    end

    if killerName then
        local kLicense = getLicense(killerServerId)
        Event.kills[kLicense] = (Event.kills[kLicense] or 0) + 1
        TriggerClientEvent('naija-rz:client:myKills', killerServerId, Event.kills[kLicense])
    end

    TriggerClientEvent('naija-rz:client:killFeed', -1, {
        killer = killerName,
        victim = victimName,
        killerKills = killerName and Event.kills[getLicense(killerServerId)] or nil,
        cause = killerName and 'kill' or (cause or 'died')
    })

    dbg('Kill feed: %s -> %s (%s)', killerName or 'none', victimName or '?', cause or 'died')
end)

-- ============================================================
--  DEATH -> ELIMINATED, MOVED TO HOLDING AREA
-- ============================================================
local function handleArenaDeath(src)
    if not Event.active or not Config.Respawn.enabled then return end

    local license = getLicense(src)
    if not license or not Event.roster[license] then return end
    if Event.eliminated[license] then return end -- already out, don't double-fire

    Event.eliminated[license] = true
    Event.downed[license] = true
    pushStats()

    -- Flag them immediately so the ring stops chipping them the instant they
    -- go down. The holding area sits outside the ring, so without this they'd
    -- be killed there over and over.
    Player(src).state:set('rzOut', true, true)

    SetTimeout(Config.Respawn.delay * 1000, function()
        if not GetPlayerName(src) then return end

        local hx, hy, hz, hw = holdingAreaPoint()

        TriggerClientEvent('naija-rz:client:eliminate', src, { x = hx, y = hy, z = hz, w = hw }, {
            health = Config.Respawn.health,
            armour = Config.Respawn.armour,
            godmode = Config.Respawn.godmode,
            settleTime = (Config.StartScatter and Config.StartScatter.settleTime) or 20
        })

        if Config.Respawn.disarm then
            -- Full clear. Their real inventory is already safe in the DB, so
            -- there is nothing to lose here and it catches looted pistols too.
            ox:ClearInventory(src)
        end

        dbg('%s eliminated, moved to holding area', GetPlayerName(src))
    end)
end

-- ak47_qb_ambulancejob fires these server-side when a player goes down or dies.
-- Event driven, so no polling of player health.
local function markDowned(src)
    if not Event.active then return end
    local license = getLicense(src)
    if license and Event.roster[license] then
        Event.downed[license] = true
        dbg('%s is down', GetPlayerName(src) or license)
        handleArenaDeath(src)
    end
end

RegisterNetEvent('ak47_qb_ambulancejob:onPlayerDeath', function()
    markDowned(source)
end)

RegisterNetEvent('ak47_qb_ambulancejob:onPlayerDown', function()
    markDowned(source)
end)

-- Clear the flag if they get revived mid-event.
RegisterNetEvent('ak47_qb_ambulancejob:onPlayerRevive', function()
    local license = getLicense(source)
    -- Deliberately does NOT clear Event.eliminated. Being revived by a medic
    -- does not put you back in the round.
    if license and not Event.eliminated[license] then
        Event.downed[license] = nil
    end
end)

local function countAlive()
    local alive = 0

    for license, data in pairs(Event.roster) do
        if not Event.eliminated[license] and not Event.downed[license] then
            local src = data.src or findSourceByLicense(license)
            if src and GetPlayerName(src) then
                alive = alive + 1
            end
        end
    end

    return alive
end

CreateThread(function()
    while true do
        Wait(3000)

        if Event.active and Config.AutoEndLastManStanding then
            local alive = countAlive()
            local total = 0
            for _ in pairs(Event.roster) do total = total + 1 end

            if total >= 2 and alive <= 1 then
                if not autoEndTimer then
                    autoEndTimer = true
                    dbg('Last man standing - ending in %s seconds', Config.AutoEndDelay)
                    SetTimeout(Config.AutoEndDelay * 1000, function()
                        if Event.active then endEvent(nil) end
                    end)
                end
            end
        end
    end
end)

-- ============================================================
--  DISCONNECT / RECONNECT
-- ============================================================
AddEventHandler('playerDropped', function()
    local src = source
    local license = getLicense(src)
    if not license then return end

    if Queue[license] then
        Queue[license] = nil
        for i, l in ipairs(queueOrder) do
            if l == license then table.remove(queueOrder, i) break end
        end
        pushQueueState()
    end

    if Event.roster[license] then
        Event.roster[license].src = nil
        -- The DB row stays. They are still owed their inventory.
        dbg('%s disconnected mid-event. Snapshot preserved.', GetPlayerName(src) or license)
    end
end)

-- Pay outstanding debts when someone logs back in.
RegisterNetEvent('QBCore:Server:PlayerLoaded', function()
    local src = source
    Wait(3000) -- let ox_inventory finish loading their inventory first

    local license = getLicense(src)
    if not license then return end

    local row = MySQL.single.await('SELECT * FROM tenx_rz_snapshots WHERE identifier = ?', { license })
    if not row then return end

    if row.status == 'pending' then
        -- Event is over, they were offline for the end. Pay them now.
        restoreOne(row, src)
        print(('[naija-rz] Paid outstanding snapshot to %s on login'):format(GetPlayerName(src)))
    elseif Event.active then
        -- Event still running and they rejoined. Put them back on the roster
        -- so they still get restored at the end.
        Event.roster[license] = { src = src, name = GetPlayerName(src) }
        Player(src).state:set('rzActive', true, true)
    else
        -- Event isn't running but the row is still 'active' - orphan. Pay it.
        restoreOne(row, src)
    end
end)

-- ============================================================
--  CRASH RECOVERY
-- ============================================================
-- If the server crashed or the resource was restarted mid-event, every
-- outstanding snapshot gets flagged so it is paid out on next login.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Don't leave free guns on the ground if the resource is restarted mid-round.
    clearLoot()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Wait(2000)

    local rows = MySQL.query.await("SELECT * FROM tenx_rz_snapshots WHERE status = 'active'") or {}
    if #rows == 0 then
        pushZoneState()
        return
    end

    print(('[naija-rz] Found %s orphaned snapshot(s) from a previous session. Restoring.'):format(#rows))

    for _, row in ipairs(rows) do
        local src = findSourceByLicense(row.identifier)
        if src then
            restoreOne(row, src)
        else
            MySQL.update.await('UPDATE tenx_rz_snapshots SET status = ? WHERE identifier = ?', { 'pending', row.identifier })
        end
    end

    pushZoneState()
end)

-- ============================================================
--  COMMANDS
-- ============================================================
-- ============================================================
--  PREVIEW / TEST SHRINK
-- ============================================================
-- Runs the real shrink logic at compressed timings with everything else
-- switched off: no sweeping, no loot, no ring damage, no eliminations.
-- Purely so you can watch the ring close and check the numbers.
local function runPreviewShrink(eventId, speed)
    local phases = Config.Shrink.phases or {}
    if #phases == 0 then return end

    local budget = math.max(10, ((Config.Shrink.totalDuration or 1800) - (Config.Shrink.startDelay or 0)) / speed)
    local slice = budget / #phases
    local holdFrac = math.min(0.9, math.max(0.0, Config.Shrink.holdFraction or 0.6))
    local holdTime = slice * holdFrac
    local closeTime = math.max(1, slice - holdTime)
    local startDelay = math.max(1, (Config.Shrink.startDelay or 0) / speed)

    print(('[naija-rz] PREVIEW: %s phases at %sx, %.1fs each'):format(#phases, speed, slice))
    Wait(startDelay * 1000)

    for i, phase in ipairs(phases) do
        if not Event.active or not Event.preview or Event.id ~= eventId then return end

        local fromRadius = Event.radius
        local fromX, fromY = Event.coords.x, Event.coords.y
        local targetRadius = Event.startRadius * (phase.radius or 0)
        local targetX, targetY = pickNextCentre(Event.coords, fromRadius, targetRadius)

        Event.nextCoords = { x = targetX, y = targetY, z = Event.coords.z }
        Event.nextRadius = targetRadius
        pushZoneState()

        TriggerClientEvent('naija-rz:client:ringClosing', -1, {
            target = math.floor(targetRadius), from = math.floor(fromRadius),
            duration = math.floor(closeTime), wait = math.floor(holdTime),
            closeNo = i, totalCloses = #phases, isLast = i >= #phases,
            damage = phase.damage,
            moved = math.floor(math.sqrt((targetX - fromX) ^ 2 + (targetY - fromY) ^ 2))
        })
        print(('[naija-rz] PREVIEW: phase %s -> %.0fm, centre moves %.0fm')
            :format(i, targetRadius, math.sqrt((targetX - fromX) ^ 2 + (targetY - fromY) ^ 2)))

        Wait(holdTime * 1000)
        if not Event.active or Event.id ~= eventId then return end

        TriggerClientEvent('naija-rz:client:ringMoving', -1)

        local steps = math.max(1, math.floor(closeTime * 2))
        for step = 1, steps do
            if not Event.active or Event.id ~= eventId then return end
            local t = step / steps
            Event.radius = fromRadius + ((targetRadius - fromRadius) * t)
            Event.coords = vec3(fromX + ((targetX - fromX) * t),
                                fromY + ((targetY - fromY) * t),
                                Event.coords.z)
            pushZoneState()
            Wait(500)
        end

        Event.radius = targetRadius
        Event.coords = vec3(targetX, targetY, Event.coords.z)
        Event.phase = i
        Event.nextCoords = nil
        Event.nextRadius = nil
        pushZoneState()
    end

    if Event.preview and Event.id == eventId then
        TriggerClientEvent('naija-rz:client:zoneClosed', -1)
        Wait(2500)
        Event.active = false
        Event.preview = false
        Event.id = nil
        Event.coords = nil
        pushZoneState()
        print('[naija-rz] PREVIEW: finished.')
    end
end

function startPreview(src, radius, speed)
    radius = math.max(5.0, math.min(Config.MaxRadius, tonumber(radius) or Config.DefaultRadius))
    speed  = math.max(1.0, tonumber(speed) or 5.0)

    -- Centre on the admin where we have one, otherwise the configured arena
    -- centre. Never GetPlayerPed(0) -- that is invalid on the server and would
    -- put the whole ring at the map origin.
    local coords
    if src and src ~= 0 and GetPlayerName(src) then
        coords = Config.ArenaCentre or GetEntityCoords(GetPlayerPed(src))
    else
        coords = Config.ArenaCentre
    end

    if not coords then
        return false, 'Set Config.ArenaCentre to preview from the console.'
    end

    Event.active      = true
    Event.preview     = true
    Event.id          = newEventId()
    Event.coords      = coords
    Event.radius      = radius
    Event.startRadius = radius
    Event.roster      = {}
    Event.downed      = {}
    Event.eliminated  = {}

    pushZoneState()

    local eventId = Event.id
    CreateThread(function() runPreviewShrink(eventId, speed) end)

    return true, ('Preview running at %sx speed from %sm. Nobody is being touched.')
        :format(speed, math.floor(radius))
end

RegisterCommand('ffatestshrink', function(src, args)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    if Event.active then
        return notify(src, Event.preview and 'A preview is already running. /ffateststop first.'
                                          or Config.Text.already_live, 'error')
    end

    local ok, msg = startPreview(src, tonumber(args[1]), tonumber(args[2]))

    if src == 0 then
        print('[naija-rz] ' .. msg)
    else
        notify(src, msg, ok and 'inform' or 'error')
    end
end, false)

RegisterCommand('ffateststop', function(src)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    if not Event.preview then
        return notify(src, 'No preview running.', 'error')
    end

    Event.active = false
    Event.preview = false
    Event.id = nil
    Event.coords = nil
    pushZoneState()

    notify(src, 'Preview stopped.', 'success')
end, false)

RegisterCommand('ffastart', function(src, args)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    local radius = tonumber(args[1]) or Config.DefaultRadius
    if radius > Config.MaxRadius then radius = Config.MaxRadius end
    if radius < 5.0 then radius = 5.0 end

    if Event.active then
        return notify(src, Event.preview and 'A preview is running. /ffateststop first.'
                                          or Config.Text.already_live, 'error')
    end

    if Config.ConfirmBeforeStart then
        -- Count who would actually be swept, using the same source the real
        -- start uses, so the number in the dialog is never a lie.
        local count, names = 0, {}
        local candidates

        if Config.Lobby.enabled then
            candidates = playersInLobby()
        else
            candidates = {}
            local coords = Config.ArenaCentre or GetEntityCoords(GetPlayerPed(src))
            for _, playerId in ipairs(GetPlayers()) do
                local id = tonumber(playerId)
                local targetPed = GetPlayerPed(id)
                if targetPed and targetPed ~= 0
                   and #(GetEntityCoords(targetPed) - coords) <= radius then
                    candidates[#candidates + 1] = id
                end
            end
        end

        for _, id in ipairs(candidates) do
            if not (Config.StaffImmune and isStaff(id)) then
                count = count + 1
                names[#names + 1] = GetPlayerName(id)
            end
        end

        TriggerClientEvent('naija-rz:client:confirmStart', src, count, radius, names)
    else
        startEvent(src, radius)
    end
end, false)

RegisterNetEvent('naija-rz:server:confirmedStart', function(radius)
    local src = source
    if not hasPermission(src) then return end
    startEvent(src, tonumber(radius) or Config.DefaultRadius)
end)

RegisterCommand('ffaend', function(src)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end
    endEvent(src ~= 0 and src or nil)
end, false)

RegisterCommand('ffastatus', function(src)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    local rows = MySQL.query.await('SELECT identifier, player_name, status, taken_at FROM tenx_rz_snapshots') or {}

    if src == 0 then
        print(('[naija-rz] Event active: %s | Outstanding snapshots: %s'):format(tostring(Event.active), #rows))
        for _, r in ipairs(rows) do
            print(('  %s (%s) - %s'):format(r.player_name or '?', r.identifier, r.status))
        end
        return
    end

    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ('%s — %s'):format(r.player_name or '?', r.status)
    end

    TriggerClientEvent('naija-rz:client:showStatus', src, {
        active = Event.active,
        radius = Event.radius,
        outstanding = #rows,
        lines = lines
    })
end, false)

-- Manual failsafe: restore one specific player by server id.
RegisterCommand('ffarestore', function(src, args)
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    local target = tonumber(args[1])
    if not target then return notify(src, 'Usage: /ffarestore <server id>', 'error') end

    local license = getLicense(target)
    if not license then return notify(src, 'No license found for that id.', 'error') end

    local row = MySQL.single.await('SELECT * FROM tenx_rz_snapshots WHERE identifier = ?', { license })
    if not row then return notify(src, 'That player has no outstanding snapshot.', 'error') end

    restoreOne(row, target)
    Event.roster[license] = nil
    notify(src, ('Restored %s.'):format(GetPlayerName(target)), 'success')
end, false)

-- Open your recovery stash if anything ever failed to fit.
RegisterCommand('ffarecover', function(src, args)
    local target = tonumber(args[1]) or src
    if target ~= src and not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    local license = getLicense(target)
    if not license then return end

    local stashId = ('tenx_rz_recovery_%s'):format(license)
    exports.ox_inventory:RegisterStash(stashId, 'FFA Recovery', Config.RecoveryStashSlots, Config.RecoveryStashWeight, license)
    exports.ox_inventory:forceOpenInventory(src, 'stash', stashId)
end, false)

-- Print your own license so you can paste it into config.lua.
RegisterCommand('ffawhoami', function(src)
    if src == 0 then return end
    local license = getLicense(src)
    notify(src, license or 'No license identifier found.', 'inform')
    print(('[naija-rz] %s => %s'):format(GetPlayerName(src), license or 'none'))
end, false)


-- ============================================================
--  LIVE SETTINGS
-- ============================================================
-- config.lua holds the DEFAULTS and is never rewritten. Anything changed in
-- the panel is saved to settings.json and merged over Config when the
-- resource starts, so every existing read of Config just picks it up with no
-- other code needing to know settings exist.
local Defaults = nil
local SETTINGS_FILE = 'settings.json'

local function deepCopy(t)
    if type(t) ~= 'table' then return t end
    -- Vectors are their own type in FiveM Lua, not tables, so they fall out
    -- at the check above and are copied by value. Nothing extra needed.
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

-- Arrays are replaced wholesale, not merged. Merging an item list index by
-- index would leave orphaned entries behind when the list gets shorter.
local function deepMerge(target, patch)
    for k, v in pairs(patch) do
        if type(v) == 'table' and type(target[k]) == 'table' and not v[1] and not target[k][1] then
            deepMerge(target[k], v)
        else
            target[k] = deepCopy(v)
        end
    end
end

-- Saved coords come back as plain tables. Everything downstream expects
-- vectors, so rebuild them right after any merge.
local function normaliseCoords()
    local l = Config.Lobby and Config.Lobby.coords
    if type(l) == 'table' and l.x and not l.type then
        Config.Lobby.coords = vec3(l.x + 0.0, l.y + 0.0, l.z + 0.0)
    end

    local r = Config.Respawn and Config.Respawn.coords
    if type(r) == 'table' and r.x and not r.type then
        Config.Respawn.coords = vec4(r.x + 0.0, r.y + 0.0, r.z + 0.0, (r.w or 0.0) + 0.0)
    end

    local a = Config.ArenaCentre
    if type(a) == 'table' and a.x and not a.type then
        Config.ArenaCentre = vec3(a.x + 0.0, a.y + 0.0, a.z + 0.0)
    end
end

local function loadSettings()
    Defaults = deepCopy(Config)

    local raw = LoadResourceFile(GetCurrentResourceName(), SETTINGS_FILE)
    if not raw or raw == '' then return false end

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        print('[naija-rz] settings.json is unreadable, ignoring it and using config.lua')
        return false
    end

    deepMerge(Config, data)
    normaliseCoords()
    print('[naija-rz] Loaded saved settings over config.lua')
    return true
end

local function saveSettings(patch)
    deepMerge(Config, patch)
    normaliseCoords()

    -- Only the difference from config.lua is written, so the file stays small
    -- and anything you later change in config.lua still takes effect unless
    -- the panel has explicitly overridden it.
    local ok = SaveResourceFile(GetCurrentResourceName(), SETTINGS_FILE, json.encode(patch, { indent = true }), -1)
    if not ok then
        print('[naija-rz] Could not write settings.json. Changes apply now but will not survive a restart.')
    end
    return ok
end

local function resetSettings()
    if Defaults then
        for k in pairs(Config) do Config[k] = nil end
        deepMerge(Config, Defaults)
        normaliseCoords()
    end
    SaveResourceFile(GetCurrentResourceName(), SETTINGS_FILE, '{}', -1)
end

CreateThread(function()
    Wait(0)
    loadSettings()
end)

-- Everything the panel is allowed to edit. Anything not on this list can only
-- be changed in config.lua, which keeps the cosmetic client-side settings
-- (HUD placement, notification position) out of reach of a live edit that
-- clients would never see.
local function collectSettings()
    return {
        lobby = {
            enabled = Config.Lobby.enabled,
            coords = { x = Config.Lobby.coords.x, y = Config.Lobby.coords.y, z = Config.Lobby.coords.z },
            radius = Config.Lobby.radius
        },
        arena = {
            defaultRadius = Config.DefaultRadius,
            maxRadius = Config.MaxRadius,
            confirmBeforeStart = Config.ConfirmBeforeStart,
            staffImmune = Config.StaffImmune
        },
        loadout = {
            items = Config.Loadout,
            primary = Config.PrimaryWeapon,
            ammoMode = Config.AmmoMode,
            fixedAmmo = Config.FixedAmmo,
            ammoItem = Config.AmmoItem,
            ammoItemCount = Config.AmmoItemCount
        },
        loot = {
            enabled = Config.Loot.enabled,
            items = Config.Loot.items,
            respawn = Config.Loot.respawn,
            respawnInterval = Config.Loot.respawnInterval,
            respawnFraction = Config.Loot.respawnFraction,
            collectDistance = Config.Loot.collectDistance,
            minDistanceFactor = Config.Loot.minDistanceFactor,
            maxDistanceFactor = Config.Loot.maxDistanceFactor
        },
        airdrop = {
            enabled = Config.Airdrop.enabled,
            items = Config.Airdrop.items,
            spawnAfter = type(Config.Airdrop.spawnAfter) == 'table'
                and Config.Airdrop.spawnAfter or { Config.Airdrop.spawnAfter },
            collectDistance = Config.Airdrop.collectDistance,
            announce = Config.Airdrop.announce
        },
        shrink = {
            enabled = Config.Shrink.enabled,
            startDelay = Config.Shrink.startDelay,
            totalDuration = Config.Shrink.totalDuration,
            holdFraction = Config.Shrink.holdFraction,
            phases = Config.Shrink.phases
        },
        damage = {
            enabled = Config.RingDamage.enabled,
            tickInterval = Config.RingDamage.tickInterval,
            lethal = Config.RingDamage.lethal
        },
        death = {
            coords = {
                x = Config.Respawn.coords.x, y = Config.Respawn.coords.y,
                z = Config.Respawn.coords.z, w = Config.Respawn.coords.w
            },
            spread = Config.Respawn.spread,
            delay = Config.Respawn.delay,
            health = Config.Respawn.health,
            armour = Config.Respawn.armour,
            gatherSurvivorsOnEnd = Config.Respawn.gatherSurvivorsOnEnd
        },
        scatter = {
            enabled = Config.StartScatter.enabled,
            minSpacing = Config.StartScatter.minSpacing,
            minDistanceFactor = Config.StartScatter.minDistanceFactor,
            maxDistanceFactor = Config.StartScatter.maxDistanceFactor,
            settleTime = Config.StartScatter.settleTime
        },
        autoEnd = Config.AutoEndLastManStanding,
        autoEndDelay = Config.AutoEndDelay
    }
end

-- Map the panel's flat shape back onto the Config layout.
local function applySettings(input)
    local patch = {}
    local function num(v, fallback) local n = tonumber(v) return n or fallback end

    if input.lobby then
        patch.Lobby = {
            enabled = input.lobby.enabled and true or false,
            radius = num(input.lobby.radius, Config.Lobby.radius)
        }
        local c = input.lobby.coords
        -- Plain table, not vec3: vectors do not survive json.encode, so the
        -- saved file would reload as nonsense. Converted on use below.
        if c then patch.Lobby.coords = { x = num(c.x, 0.0), y = num(c.y, 0.0), z = num(c.z, 0.0) } end
    end

    if input.arena then
        patch.DefaultRadius = num(input.arena.defaultRadius, Config.DefaultRadius)
        patch.MaxRadius = num(input.arena.maxRadius, Config.MaxRadius)
        patch.ConfirmBeforeStart = input.arena.confirmBeforeStart and true or false
        patch.StaffImmune = input.arena.staffImmune and true or false
    end

    if input.loadout then
        if input.loadout.items then
            local list = {}
            for _, it in ipairs(input.loadout.items) do
                if it.name and it.name ~= '' then
                    list[#list + 1] = { name = it.name, count = math.max(1, num(it.count, 1)) }
                end
            end
            patch.Loadout = list
        end
        patch.PrimaryWeapon = input.loadout.primary or Config.PrimaryWeapon
        patch.AmmoMode = input.loadout.ammoMode or Config.AmmoMode
        patch.FixedAmmo = num(input.loadout.fixedAmmo, Config.FixedAmmo)
        patch.AmmoItem = input.loadout.ammoItem or Config.AmmoItem
        patch.AmmoItemCount = num(input.loadout.ammoItemCount, Config.AmmoItemCount)
    end

    if input.loot then
        patch.Loot = {
            enabled = input.loot.enabled and true or false,
            respawn = input.loot.respawn and true or false,
            respawnInterval = num(input.loot.respawnInterval, Config.Loot.respawnInterval),
            respawnFraction = num(input.loot.respawnFraction, Config.Loot.respawnFraction),
            collectDistance = num(input.loot.collectDistance, Config.Loot.collectDistance),
            minDistanceFactor = num(input.loot.minDistanceFactor, Config.Loot.minDistanceFactor),
            maxDistanceFactor = num(input.loot.maxDistanceFactor, Config.Loot.maxDistanceFactor)
        }
        if input.loot.items then
            local list = {}
            for _, it in ipairs(input.loot.items) do
                if it.name and it.name ~= '' then
                    list[#list + 1] = {
                        name = it.name,
                        count = math.max(1, num(it.count, 1)),
                        piles = math.max(1, num(it.piles, 1))
                    }
                end
            end
            patch.Loot.items = list
        end
    end

    if input.airdrop then
        patch.Airdrop = {
            enabled = input.airdrop.enabled and true or false,
            announce = input.airdrop.announce and true or false,
            collectDistance = num(input.airdrop.collectDistance, Config.Airdrop.collectDistance)
        }
        if input.airdrop.items then
            local list = {}
            for _, it in ipairs(input.airdrop.items) do
                if it.name and it.name ~= '' then
                    list[#list + 1] = { name = it.name, count = math.max(1, num(it.count, 1)) }
                end
            end
            patch.Airdrop.items = list
        end
        if input.airdrop.spawnAfter then
            local times = {}
            for _, t in ipairs(input.airdrop.spawnAfter) do
                local n = tonumber(t)
                if n and n > 0 then times[#times + 1] = n end
            end
            table.sort(times)
            patch.Airdrop.spawnAfter = #times > 0 and times or { 150 }
        end
    end

    if input.shrink then
        patch.Shrink = {
            enabled = input.shrink.enabled and true or false,
            startDelay = math.max(1, num(input.shrink.startDelay, Config.Shrink.startDelay)),
            totalDuration = math.max(60, num(input.shrink.totalDuration, Config.Shrink.totalDuration)),
            holdFraction = math.min(0.9, math.max(0.0, num(input.shrink.holdFraction, Config.Shrink.holdFraction))),
            phases = (function()
                if not input.shrink.phases then return Config.Shrink.phases end
                local list = {}
                for _, ph in ipairs(input.shrink.phases) do
                    list[#list + 1] = {
                        radius = math.min(1.0, math.max(0.0, num(ph.radius, 0.5))),
                        damage = math.max(0.1, num(ph.damage, 1))
                    }
                end
                return #list > 0 and list or Config.Shrink.phases
            end)()
        }
    end

    if input.damage then
        patch.RingDamage = {
            enabled = input.damage.enabled and true or false,
            tickInterval = math.max(200, num(input.damage.tickInterval, Config.RingDamage.tickInterval)),
            lethal = input.damage.lethal and true or false,
            warn = Config.RingDamage.warn
        }
    end

    if input.death then
        patch.Respawn = {
            enabled = Config.Respawn.enabled,
            spread = math.max(0.0, num(input.death.spread, Config.Respawn.spread)),
            delay = math.max(0, num(input.death.delay, Config.Respawn.delay)),
            health = math.max(1, num(input.death.health, Config.Respawn.health)),
            armour = math.max(0, num(input.death.armour, Config.Respawn.armour)),
            disarm = Config.Respawn.disarm,
            godmode = Config.Respawn.godmode,
            gatherSurvivorsOnEnd = input.death.gatherSurvivorsOnEnd and true or false
        }
        local c = input.death.coords
        if c then
            patch.Respawn.coords = { x = num(c.x, 0.0), y = num(c.y, 0.0), z = num(c.z, 0.0), w = num(c.w, 0.0) }
        end
    end

    if input.scatter then
        patch.StartScatter = {
            enabled = input.scatter.enabled and true or false,
            minSpacing = math.max(0.0, num(input.scatter.minSpacing, Config.StartScatter.minSpacing)),
            minDistanceFactor = math.min(0.9, math.max(0.0, num(input.scatter.minDistanceFactor, 0.05))),
            maxDistanceFactor = math.min(0.98, math.max(0.05, num(input.scatter.maxDistanceFactor, 0.45))),
            attempts = Config.StartScatter.attempts,
            settleTime = math.max(1, num(input.scatter.settleTime, Config.StartScatter.settleTime))
        }
    end

    if input.autoEnd ~= nil then patch.AutoEndLastManStanding = input.autoEnd and true or false end
    if input.autoEndDelay ~= nil then patch.AutoEndDelay = math.max(0, num(input.autoEndDelay, Config.AutoEndDelay)) end

    return patch
end

-- ============================================================
--  ADMIN PANEL
-- ============================================================
-- Everything the panel can do, it does through here, and every call is
-- permission-checked on arrival. The panel being open grants nothing.

local panelWatchers = {}   -- [src] = true, admins with the panel open

local function secondsUntil(stamp)
    if not stamp then return nil end
    local left = stamp - os.time()
    return left >= 0 and left or nil
end

-- Snapshot of everything the panel renders. Built fresh each push so the
-- panel can never show state the server doesn't actually have.
local function buildPanelState()
    local players = {}

    for license, data in pairs(Event.roster) do
        local src = data.src or findSourceByLicense(license)
        players[#players + 1] = {
            name = (src and GetPlayerName(src)) or data.name or 'Unknown',
            id = src,
            online = src ~= nil,
            identifier = license,
            alive = not Event.eliminated[license]
        }
    end

    table.sort(players, function(a, b)
        if a.alive ~= b.alive then return a.alive end
        return (a.name or '') < (b.name or '')
    end)

    local records = {}
    local rows = MySQL.query.await('SELECT identifier, player_name, status FROM tenx_rz_snapshots') or {}
    for _, r in ipairs(rows) do
        records[#records + 1] = {
            identifier = r.identifier,
            name = r.player_name,
            status = r.status
        }
    end

    local lobbyNames, lobbyCount = {}, 0
    if Config.Lobby.enabled then
        for _, id in ipairs(playersInLobby()) do
            if not (Config.StaffImmune and isStaff(id)) then
                lobbyCount = lobbyCount + 1
                lobbyNames[#lobbyNames + 1] = GetPlayerName(id)
            end
        end
    end

    local piles, drops = 0, 0
    for _, pile in pairs(lootPiles) do
        if pile.airdrop then drops = drops + 1 else piles = piles + 1 end
    end

    return {
        active = Event.active,
        preview = Event.preview,
        radius = Event.radius,
        startRadius = Event.startRadius,
        totalDuration = Config.Shrink.totalDuration,
        phases = Config.Shrink.phases,
        maxRadius = Config.MaxRadius,
        defaultRadius = Config.DefaultRadius,
        elapsed = roundStartedAt and (os.time() - roundStartedAt) or 0,
        nextCloseIn = secondsUntil(nextCloseAt),
        nextDropIn = secondsUntil(nextDropAt),
        players = players,
        records = records,
        lobby = { count = lobbyCount, names = lobbyNames },
        piles = piles,
        drops = drops,
        queue = (function()
            local list = {}
            for _, license in ipairs(queueOrder) do
                local q = Queue[license]
                if q then
                    local id = findSourceByLicense(license)
                    list[#list + 1] = {
                        name = (id and GetPlayerName(id)) or q.name or 'Unknown',
                        id = id,
                        online = id ~= nil,
                        identifier = license
                    }
                end
            end
            return list
        end)(),
        queueEnabled = Config.Queue.enabled and true or false,
        noSpawn = Config.NoSpawn.zones or {}
    }
end

function pushPanel()
    if not next(panelWatchers) then return end
    local data = buildPanelState()
    for src in pairs(panelWatchers) do
        if GetPlayerName(src) then
            TriggerClientEvent('naija-rz:client:panelUpdate', src, data)
        else
            panelWatchers[src] = nil
        end
    end
end

-- Refresh anyone watching, twice a second while something is happening and
-- lazily otherwise, so an idle open panel costs almost nothing.
CreateThread(function()
    while true do
        if next(panelWatchers) then
            pushPanel()
            Wait(Event.active and 1000 or 3000)
        else
            Wait(2000)
        end
    end
end)

RegisterNetEvent('naija-rz:server:panelClosed', function()
    panelWatchers[source] = nil
end)

AddEventHandler('playerDropped', function()
    panelWatchers[source] = nil
end)

-- ── the one entry point every panel action goes through ──
lib.callback.register('naija-rz:server:panel', function(src, name, data)
    if not hasPermission(src) then
        return { ok = false, message = 'You are not allowed to do that.' }
    end

    data = data or {}

    if name == 'start' then
        if Event.active then
            return { ok = false, message = Event.preview
                and 'A preview is running. Stop it first.' or 'A round is already running.' }
        end

        local radius = tonumber(data.radius) or Config.DefaultRadius
        radius = math.max(5.0, math.min(Config.MaxRadius, radius))

        -- Per-round overrides. These never touch config.lua -- they last for
        -- this round only and reset when it ends.
        local o = data.options or {}
        Event.override = {
            loot = o.loot ~= false,
            airdrop = o.airdrop ~= false,
            shrink = o.shrink ~= false
        }

        -- Queued players are out in the city doing something else. Give them
        -- a few seconds' warning before yanking them out of it.
        local warn = tonumber(Config.Queue.warning) or 0
        if Config.Queue.enabled and warn > 0 and queueCount() > 0 then
            for license in pairs(Queue) do
                local id = findSourceByLicense(license)
                if id then TriggerClientEvent('naija-rz:client:queueWarning', id, warn) end
            end
            Wait(warn * 1000)
        end

        startEvent(src, radius)

        if not Event.active then
            return { ok = false, message = 'Could not start the round.' }
        end

        local swept = 0
        for _ in pairs(Event.roster) do swept = swept + 1 end

        pushPanel()
        return { ok = true, message = swept > 0
            and ('Round started. %s swept in.'):format(swept)
            or 'Round started, but nobody was in the lobby.' }
    end

    if name == 'end' then
        if not Event.active then return { ok = false, message = 'No round is running.' } end
        local n = endEvent(src)
        pushPanel()
        return { ok = true, message = ('Round ended. %s inventories returned.'):format(n) }
    end

    if name == 'previewStart' then
        if Event.active then
            return { ok = false, message = 'Something is already running. End it first.' }
        end
        local ok, msg = startPreview(src, data.radius, data.speed)
        pushPanel()
        return { ok = ok, message = msg }
    end

    if name == 'previewStop' then
        if not Event.preview then return { ok = false, message = 'No preview is running.' } end
        Event.active = false
        Event.preview = false
        Event.id = nil
        Event.coords = nil
        pushZoneState()
        pushPanel()
        return { ok = true, message = 'Preview stopped.' }
    end

    if name == 'knockOut' then
        local target = tonumber(data.id)
        if not target or not GetPlayerName(target) then
            return { ok = false, message = 'That player is not online.' }
        end

        local license = getLicense(target)
        if not license or not Event.roster[license] then
            return { ok = false, message = 'That player is not in the round.' }
        end
        if Event.eliminated[license] then
            return { ok = false, message = 'They are already out.' }
        end

        handleArenaDeath(target)
        pushPanel()
        return { ok = true, message = ('%s knocked out.'):format(GetPlayerName(target)) }
    end

    if name == 'restore' then
        local license = data.identifier
        if not license then return { ok = false, message = 'No player given.' } end

        local row = MySQL.single.await('SELECT * FROM tenx_rz_snapshots WHERE identifier = ?', { license })
        if not row then return { ok = false, message = 'Nothing is being held for that player.' } end

        local target = findSourceByLicense(license)
        if not target then
            MySQL.update.await('UPDATE tenx_rz_snapshots SET status = ? WHERE identifier = ?', { 'pending', license })
            pushPanel()
            return { ok = true, message = 'They are offline. Their items are queued for next login.' }
        end

        restoreOne(row, target, false)
        Event.roster[license] = nil
        Event.eliminated[license] = nil
        pushStats()
        pushPanel()
        return { ok = true, message = ('Returned %s their inventory.'):format(row.player_name or 'player') }
    end

    if name == 'getRounds' then
        local rows = MySQL.query.await(
            'SELECT winner_name, winner_kills, players, duration, radius, end_reason, started_by, ended_at FROM tenx_rz_rounds ORDER BY id DESC LIMIT 40') or {}

        local top = MySQL.query.await(
            [=[SELECT winner_name AS name, COUNT(*) AS wins, SUM(winner_kills) AS kills
               FROM tenx_rz_rounds
               WHERE winner_name IS NOT NULL
               GROUP BY winner_name, winner_id
               ORDER BY wins DESC, kills DESC
               LIMIT 10]=]) or {}

        return { ok = true, rounds = rows, top = top }
    end

    if name == 'myPosition' then
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then
            return { ok = false, message = 'Could not read your position.' }
        end
        local c = GetEntityCoords(ped)
        return { ok = true, coords = {
            x = tonumber(('%.2f'):format(c.x)),
            y = tonumber(('%.2f'):format(c.y)),
            z = tonumber(('%.2f'):format(c.z)),
            w = tonumber(('%.2f'):format(GetEntityHeading(ped)))
        } }
    end

    if name == 'addNoSpawn' then
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then
            return { ok = false, message = 'Could not read your position.' }
        end

        local c = GetEntityCoords(ped)
        local radius = math.max(5.0, tonumber(data.radius) or 50.0)

        Config.NoSpawn.zones = Config.NoSpawn.zones or {}
        Config.NoSpawn.zones[#Config.NoSpawn.zones + 1] = {
            x = tonumber(('%.2f'):format(c.x)),
            y = tonumber(('%.2f'):format(c.y)),
            radius = radius,
            label = (data.label ~= '' and data.label) or ('Zone %s'):format(#Config.NoSpawn.zones + 1)
        }

        saveSettings({ NoSpawn = { zones = Config.NoSpawn.zones } })
        pushPanel()
        return { ok = true, message = ('Marked a %sm no-spawn area here.'):format(math.floor(radius)) }
    end

    if name == 'removeNoSpawn' then
        local idx = tonumber(data.index)
        local zones = Config.NoSpawn.zones or {}
        if not idx or not zones[idx] then
            return { ok = false, message = 'That area is already gone.' }
        end

        local label = zones[idx].label
        table.remove(zones, idx)
        saveSettings({ NoSpawn = { zones = zones } })
        pushPanel()
        return { ok = true, message = ('Removed %s.'):format(label or 'the area') }
    end

    if name == 'clearQueue' then
        clearQueue()
        pushPanel()
        return { ok = true, message = 'Queue emptied.' }
    end

    if name == 'kickQueue' then
        local target = findSourceByLicense(data.identifier or '')
        if not target then return { ok = false, message = 'They are not online.' } end
        removeFromQueue(target)
        notify(target, 'An admin removed you from the queue.', 'error')
        pushPanel()
        return { ok = true, message = 'Removed from the queue.' }
    end

    if name == 'getSettings' then
        return { ok = true, settings = collectSettings() }
    end

    if name == 'saveSettings' then
        if Event.active then
            return { ok = false, message = 'End the round before changing settings.' }
        end

        local patch = applySettings(data.settings or {})
        local written = saveSettings(patch)

        pushPanel()
        return {
            ok = true,
            settings = collectSettings(),
            message = written and 'Settings saved. They survive a restart.'
                              or 'Applied, but settings.json could not be written.'
        }
    end

    if name == 'resetSettings' then
        if Event.active then
            return { ok = false, message = 'End the round before changing settings.' }
        end
        resetSettings()
        pushPanel()
        return { ok = true, settings = collectSettings(), message = 'Back to config.lua defaults.' }
    end

    if name == 'action' then
        if not Event.active or Event.preview then
            return { ok = false, message = 'No round is running.' }
        end

        if data.action == 'forceAirdrop' then
            CreateThread(function() spawnAirdrop() ; pushPanel() end)
            return { ok = true, message = 'Crate on the way.' }
        end

        if data.action == 'spawnLoot' then
            CreateThread(function() spawnLoot(0.5) ; pushPanel() end)
            return { ok = true, message = 'More supplies scattered.' }
        end

        if data.action == 'clearLoot' then
            local n = clearLoot()
            pushPanel()
            return { ok = true, message = ('Cleared %s piles.'):format(n) }
        end

        if data.action == 'forceShrink' then
            if (Event.phase or 0) >= #(Config.Shrink.phases or {}) then
                return { ok = false, message = 'The ring is already fully closed.' }
            end
            -- Jump the queue: bring the next close forward to right now.
            Event.forceClose = true
            return { ok = true, message = 'Closing the ring now.' }
        end

        return { ok = false, message = 'Unknown action.' }
    end

    return { ok = false, message = 'Unknown action.' }
end)

-- ── open it ──────────────────────────────────────────────
RegisterCommand('ffa', function(src)
    if src == 0 then
        print('[naija-rz] /ffa opens the admin panel and can only be run in game.')
        return
    end
    if not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    panelWatchers[src] = true
    TriggerClientEvent('naija-rz:client:openPanel', src, buildPanelState())
end, false)
