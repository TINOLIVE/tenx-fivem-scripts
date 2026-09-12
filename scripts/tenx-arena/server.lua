local QBCore = exports['qb-core']:GetCoreObject()
local ox = exports.ox_inventory

-- ============================================================
--  STATE
-- ============================================================
local Arenas = {}        -- [id] = arena table, loaded from the database
local Occupants = {}     -- [src] = { arenaId, slot, key }, who is inside which instance
local panelWatchers = {} -- [src] = true, admins with the builder open

local pushPanel

-- Declared up here because endMatch (defined above the room section) clears
-- the room that spawned the match. Left as locals further down, it would read
-- a nil global and silently skip the cleanup.
local Rooms, RoomOf

-- The match inventory lives at the bottom of the file, but the match
-- lifecycle above has to build it and clear it.
local buildMatchInventory, clearInventory

-- Assigned at the bottom; the arena disable and delete paths above call it.

-- Built near the bottom, but the lobby entry above needs it to open the panel
-- the moment someone comes in.
local playerPanelState

-- Same reason: exitrz has to clear a player's room membership, and that lives
-- further down the file.
local playerKey

-- eviction paths above both have to clear it, and the shop itself is
-- built at the bottom of the file.


-- The inventory code that owns these sits further down.
local rzSave, rzWearWeapons

-- And the arena builder above clears spawns, which has to refresh the zone
-- counts -- a local declared further down would just be a nil global here,
-- silently doing nothing behind an `if`.


-- Live matches, keyed by instance. Declared up here because the panel state
-- builder near the top of the file counts them, and it runs on a timer -- so
-- a declaration further down meant a nil global every refresh.
local Matches = {}      -- [matchKey] = live match; several per arena

-- ============================================================
--  HELPERS
-- ============================================================
local function dbg(msg, ...)
    if Config.Debug then print(('[arena] ' .. msg):format(...)) end
end

-- The character's name in the city, not their FiveM account name. A
-- leaderboard full of Steam handles reads like a different game to the one
-- people are playing.
local function nameOf(src)
    local ok, player = pcall(function()
        return QBCore.Functions.GetPlayer(src)
    end)

    if ok and player and player.PlayerData and player.PlayerData.charinfo then
        local ci = player.PlayerData.charinfo
        local first = ci.firstname or ''
        local last = ci.lastname or ''
        local full = (first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')
        if full ~= '' then return full end
    end

    -- Not loaded in yet, or no character. Fall back rather than show nothing.
    return GetPlayerName(src) or 'Player'
end

--- An old board kind, resolved to what it means now.
---
--- Boards live in the database, so renaming a kind would strand every wall
--- already marked. Nothing maps to ranked on purpose: a board marked before
--- ranked existed should never quietly start showing it.
local function boardKind(kind)
    kind = kind or 'pvp'
    if (Config.Boards or {})[kind] then return kind end
    return (Config.BoardAliases or {})[kind] or 'pvp'
end

-- One place the mode is named, so it reads the same everywhere.
--- A score the mode actually offers, or the nearest one it does.
---
--- Config is the authority: change the options there and anything stored from
--- before is pulled back into range rather than surviving the change.
local function validScore(modeId, want, fallback)
    local mode
    for _, m in ipairs(Config.Modes or {}) do
        if m.id == modeId then mode = m break end
    end
    if not mode then return fallback or 10 end

    want = tonumber(want)
    if not want then return fallback or mode.defaultScore end

    for _, allowed in ipairs(mode.scores or {}) do
        if allowed == want then return want end
    end

    -- Not on the list: take the closest that is.
    local best, bestGap = mode.defaultScore, math.huge
    for _, allowed in ipairs(mode.scores or {}) do
        local gap = math.abs(allowed - want)
        if gap < bestGap then best, bestGap = allowed, gap end
    end
    return best
end

local function brandName()
    return (Config.Brand or {}).modeName or 'PVP'
end

local function notify(src, msg, ntype)
    TriggerClientEvent('ox_lib:notify', src, {
        title = (Config.Brand or {}).notifyTitle or 'Arena',
        description = msg,
        type = ntype or 'inform',
        -- Top-centre, not the side. The side of the screen is where every
        -- other resource on the server puts its own, and an arena message
        -- lost in that column is a message nobody reads.
        position = Config.NotifyPosition or 'top-center'
    })
end

--- Is this player standing in the main city?
---
--- The exploit this closes: mid-RP, about to be shot or arrested, and one
--- typed word moves you into a PvP bucket. The lobby ped stays the only way
--- in from the city -- walking to a place is something other players can
--- see, follow and interrupt. A command is not.
---
--- The test is "not bucket 0", not "is 2046", on purpose: it keeps working
--- for any mode added later with its own bucket, and it does not break if
--- the lobby is ever renumbered.
---
--- Server-side because that is the only side that counts. Anyone with an
--- executor can fire the panel event directly, so hiding the command
--- client-side would stop nobody.
---
--- On by default with no config entry needed. Set
---     Config.Meeting.lobbyOnly = false
--- in config.lua to switch it off.
local function inMainCity(src)
    if (Config.Meeting or {}).lobbyOnly == false then return false end

    -- An unreadable bucket blocks nobody. Refusing on an error would lock
    -- players out of their own lobby the first time the native hiccups.
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then return false end

    return (tonumber(bucket) or 0) == 0
end

--- One message, one place, so both doors say the same thing.
local function refuseFromCity(src)
    notify(src, ('Head to the %s ped to get in -- this only works once you are inside.')
        :format(brandName()), 'error')
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
    if src == 0 then return true end
    if isStaff(src) then return true end
    if Config.AcePermission and IsPlayerAceAllowed(src, Config.AcePermission) then return true end
    return false
end

-- One arena can host several matches at once, each in its own bucket. Two
-- matches at identical coordinates in different buckets cannot see or shoot
-- each other, so a single good arena serves several 1v1s instead of everyone
-- waiting for the one space.
local function instancesPer()
    return math.max(1, Config.Buckets.instancesPerArena or 6)
end

local function bucketFor(arenaId, slot)
    slot = slot or 1
    return (Config.Buckets.base or 4200) + (arenaId * instancesPer()) + slot
end

-- Which instance slots of an arena are currently in use.
local function usedSlots(arenaId)
    local used = {}
    for _, m in pairs(Matches) do
        if m.arenaId == arenaId and m.slot then used[m.slot] = true end
    end
    return used
end

-- The lowest free instance of an arena, or nil if every one is busy.
local function freeSlot(arenaId)
    local used = usedSlots(arenaId)
    for i = 1, instancesPer() do
        if not used[i] then return i end
    end
    return nil
end

-- ============================================================
--  LOADING AND SAVING
-- ============================================================
-- The flexible parts of an arena live in a JSON blob, so the shape can grow
-- without a migration every time something is added.
-- MySQL TINYINT(1) comes back as a Lua boolean through oxmysql, not a number,
-- depending on driver and version. Comparing it to 1 therefore fails and the
-- value reads as false -- which is why arenas came back switched off after
-- every restart no matter what was saved. Accept every shape it can arrive in.
local function truthy(v)
    return v == true or v == 1 or v == '1'
end

local function rowToArena(row)
    local ok, data = pcall(json.decode, row.data or '{}')
    if not ok or type(data) ~= 'table' then data = {} end

    return {
        id = row.id,
        name = row.name,
        enabled = truthy(row.enabled),
        -- Always a polygon by the time it leaves here. Rectangles marked
        -- before this are converted, so nothing downstream has to know which
        -- kind it started as.
        bounds = Poly.normalise(data.bounds),

        -- The tenx-zones shape this arena maps to, once migrated. Lives in
        -- the JSON blob rather than a new column so no schema change is
        -- needed and an un-migrated arena simply has nil here.
        zoneId = data.zoneId,

        spawns = data.spawns or { A = {}, B = {} },
        createdBy = data.createdBy,
        loadout = data.loadout,                    -- nil means use the config default
        showWall = data.showWall ~= false,
        createdBy = row.created_by
    }
end

local function arenaToData(a)
    return json.encode({
        bounds = a.bounds,
        zoneId = a.zoneId,
        spawns = a.spawns or { A = {}, B = {} },

        -- Anything on the arena that has to survive a restart must be
        -- listed here -- there is no automatic serialisation.

        loadout = a.loadout,
        showWall = a.showWall ~= false,
        createdBy = a.createdBy
    })
end

local function pushArenas()
    -- Clients need the bounds to draw walls and hold themselves inside.
    local out = {}
    for id, a in pairs(Arenas) do
        if a.enabled and a.bounds then
            out[#out + 1] = {
                id = id,
                name = a.name,
                bounds = a.bounds,
                showWall = a.showWall
            }
        end
    end
    GlobalState.arenaZones = out
end

local function loadArenas()
    local rows = MySQL.query.await('SELECT * FROM tenx_arena_zones ORDER BY id') or {}
    Arenas = {}
    for _, row in ipairs(rows) do
        Arenas[row.id] = rowToArena(row)
    end
    pushArenas()

    local on = 0
    for _, a in pairs(Arenas) do if a.enabled then on = on + 1 end end
    print(('[arena] Loaded %s arena(s), %s switched on'):format(#rows, on))
end

local function saveArena(a)
    local ok = pcall(function()
        MySQL.update.await(
            'UPDATE tenx_arena_zones SET name = ?, data = ?, enabled = ? WHERE id = ?',
            { a.name, arenaToData(a), a.enabled and 1 or 0, a.id })
    end)

    -- Say so rather than failing quietly. A save that does not happen looks
    -- exactly like a save that did until the next restart.
    if not ok then
        print(('^1[arena] could not save arena %s -- changes will be lost on restart^0')
            :format(a.id))
    end

    pushArenas()
    return ok
end

-- The schema has grown across updates and it is easy to miss one. Rather than
-- letting a missing table surface as a command that silently does nothing,
-- say so at boot.
local function checkSchema()
    local required = {
        'tenx_arena_zones',
        'tenx_arena_stats',
        'tenx_arena_matches',
        'tenx_arena_boards',
        'tenx_arena_props',
        'tenx_arena_rz_inv',
        'tenx_arena_rz_ledger',
        'tenx_arena_ranked',
        'tenx_arena_ranked_history'
    }

    -- ── columns added after a table first shipped ──
    --
    -- CREATE TABLE IF NOT EXISTS does NOTHING when the table already exists,
    -- so a column added in a later version never appears no matter how many
    -- times the SQL is re-run. Somebody re-runs it, sees no error, and the
    -- feature still fails -- which is a miserable thing to debug.
    --
    -- So they are added here instead, once, on boot.
    local patches = {
        { table = 'tenx_arena_boards', column = 'kind',
          sql = "ALTER TABLE `tenx_arena_boards` ADD COLUMN `kind` VARCHAR(16) NOT NULL DEFAULT 'pvp'" },
    }

    for _, patch in ipairs(patches) do
        local ok, has = pcall(function()
            return MySQL.scalar.await([[
                SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME = ? AND COLUMN_NAME = ?
            ]], { patch.table, patch.column })
        end)

        if ok and (has or 0) == 0 then
            local added = pcall(function() MySQL.update.await(patch.sql) end)
            if added then
                print(('[arena] added the missing `%s` column to %s')
                    :format(patch.column, patch.table))
            else
                print(('^1[arena] could not add `%s` to %s -- add it by hand^0')
                    :format(patch.column, patch.table))
            end
        end
    end

    local missing = {}

    for _, t in ipairs(required) do
        local ok = pcall(function()
            MySQL.scalar.await(('SELECT 1 FROM %s LIMIT 1'):format(t))
        end)
        if not ok then missing[#missing + 1] = t end
    end

    if #missing > 0 then
        print('^1[arena] MISSING DATABASE TABLES: ' .. table.concat(missing, ', ') .. '^0')
        print('^1[arena] Run tenx-arena.sql against your database. ' ..
              'Until you do, parts of the script will not work.^0')
    else
        print('[arena] Database schema is up to date')
    end
end

CreateThread(function()
    Wait(500)
    checkSchema()
    loadArenas()

    -- Buckets are configured once at boot. Population off means no traffic or
    -- pedestrians wandering through a match.
    if Config.Buckets.stripPopulation then
        for id in pairs(Arenas) do
            local b = bucketFor(id)
            SetRoutingBucketPopulationEnabled(b, false)
            SetRoutingBucketEntityLockdownMode(b, Config.Buckets.lockdown or 'relaxed')
        end
    end
end)

-- ============================================================
--  MOVING PLAYERS IN AND OUT
-- ============================================================
local function prepareBucket(arenaId, slot)
    local b = bucketFor(arenaId, slot)
    if Config.Buckets.stripPopulation then
        SetRoutingBucketPopulationEnabled(b, false)
        SetRoutingBucketEntityLockdownMode(b, Config.Buckets.lockdown or 'relaxed')
    end
    return b
end

local function matchKey(arenaId, slot)
    return ('%s:%s'):format(arenaId, slot or 1)
end

local function giveLoadout(src, arena)
    local list = (arena and arena.loadout) or Config.DefaultLoadout or {}

    for _, item in ipairs(list) do
        if item.name and item.name ~= '' then
            ox:AddItem(src, item.name, item.count or 1)
        end
    end

    if Config.DefaultAmmo and Config.DefaultAmmo.name then
        ox:AddItem(src, Config.DefaultAmmo.name, Config.DefaultAmmo.count or 100)
    end
end

-- Put a player into an arena: own bucket, spawned on their team's point.
local function sendToArena(src, arenaId, team, withLoadout, slot)
    local arena = Arenas[arenaId]
    if not arena or not arena.bounds then
        return false, 'That arena has no boundary set yet.'
    end

    slot = slot or freeSlot(arenaId) or 1

    team = (team == 'B') and 'B' or 'A'
    local points = (arena.spawns and arena.spawns[team]) or {}

    if #points == 0 then
        return false, ('Team %s has no spawn points yet.'):format(team)
    end

    local point = points[math.random(#points)]

    local bucket = prepareBucket(arenaId, slot)

    -- The zone follows the INSTANCE, not the player. Binding is idempotent,
    -- so calling it on each arrival is simpler than tracking whether this
    -- instance already has its boundary up.
    if ZoneLink then ZoneLink.bindMatch(arenaId, bucket) end

    SetPlayerRoutingBucket(src, bucket)
    if ZoneLink then ZoneLink.refresh(src) end
    Occupants[src] = { arenaId = arenaId, slot = slot, key = matchKey(arenaId, slot) }

    Player(src).state:set('arenaId', arenaId, true)
    Player(src).state:set('arenaTeam', team, true)

    TriggerClientEvent('naija-arena:client:enter', src, {
        arena = { id = arenaId, name = arena.name, bounds = arena.bounds, showWall = arena.showWall },
        spawn = point,
        team = team
    })

    if withLoadout then
        Wait(600)
        giveLoadout(src, arena)
    end

    dbg('%s -> arena %s instance %s (%s) bucket %s',
        GetPlayerName(src), arenaId, slot, team, bucket)
    if pushPanel then pushPanel() end
    return true, ('Sent to %s as Team %s.'):format(arena.name, team)
end

local function removeFromArena(src, returnCoords)
    if not Occupants[src] then return false, 'They are not in an arena.' end

    Occupants[src] = nil
    SetPlayerRoutingBucket(src, 0)
    if ZoneLink then ZoneLink.refresh(src) end

    -- Save what they were carrying BEFORE wiping the live copy.
    --
    -- This wiped without writing back, so anything picked up, bought or
    -- rearranged during a match was thrown away -- and the next load rebuilt
    -- the grid from a stale copy, which is why a carefully arranged bag came
    -- back scattered.
    local key = playerKey(src)
    if key and RzSyncFromMatch then RzSyncFromMatch(src, key) end

    if clearInventory then clearInventory(src) end

    if GetPlayerName(src) then
        -- Every one of these has to go. Leaving arenaMatch set is what left a
        -- scoreboard on screen for someone who was no longer in an arena.
        -- FALSE, not nil.
        --
        -- Setting a statebag to nil REMOVES the key, and that removal does
        -- not reliably reach clients. The server clears the flag, believes it
        -- has, and the client keeps the old value for the rest of the
        -- session -- so one player who has been in and out of the lobby ends
        -- up permanently "in the lobby" as far as their own game is
        -- concerned: no city blip, lobby peds following them around, and
        -- weapons handed out with no ammunition in a real match. Nobody who
        -- never entered the lobby sees any of it, which is what made it look
        -- like one player's machine being strange.
        --
        -- false replicates like any other value. Every client test here reads
        -- `== true` or `not ...`, both of which handle false correctly.
        Player(src).state:set('arenaId', false, true)
        Player(src).state:set('arenaTeam', false, true)
        Player(src).state:set('arenaMatch', false, true)
        Player(src).state:set('arenaPending', false, true)
        TriggerClientEvent('naija-arena:client:leave', src, returnCoords)
    end

    if pushPanel then pushPanel() end
    return true, 'Back in the main world.'
end

AddEventHandler('playerDropped', function()
    local src = source
    Occupants[src] = nil
    panelWatchers[src] = nil
end)

-- Someone reconnecting must never be left stranded in a bucket.
RegisterNetEvent('QBCore:Server:PlayerLoaded', function()
    local src = source
    Wait(1500)
    if not Occupants[src] then
        SetPlayerRoutingBucket(src, 0)
        if ZoneLink then ZoneLink.refresh(src) end
    end
end)

-- ============================================================
--  BOUNDARY BACKSTOP
-- ============================================================
-- The wall is held client side because it has to run every frame. This is the
-- server's check: a slow sweep that catches anyone who has ended up well
-- outside their arena, whether through a teleport, a script conflict, or a
-- client that stopped cooperating.
CreateThread(function()
    while true do
        Wait(4000)

        for src, o in pairs(Occupants) do
            if not GetPlayerName(src) then
                Occupants[src] = nil
            else
                local arena = Arenas[o.arenaId]
                local ped = GetPlayerPed(src)

                if arena and arena.bounds and arena.bounds.points and ped and ped ~= 0 then
                    local c = GetEntityCoords(ped)
                    local b = arena.bounds
                    local slack = 12.0

                    -- Generous slack: this is a backstop for someone who has
                    -- ended up well outside, not a second clamp. The client
                    -- handles the boundary itself, and fighting it from here
                    -- would feel like being tugged.
                    local _, _, dist = Poly.nearestEdge(b.points, c.x, c.y)
                    local outFlat = (not Poly.contains(b.points, c.x, c.y)) and dist > slack

                    local out = outFlat
                             or c.z < (b.minZ - slack) or c.z > (b.maxZ + slack)

                    if out then
                        dbg('%s was outside arena %s -- putting them back', GetPlayerName(src), o.arenaId)
                        TriggerClientEvent('naija-arena:client:forceInside', src, arena.bounds)
                    end
                end
            end
        end
    end
end)

-- ============================================================
--  PANEL
-- ============================================================
-- ============================================================
--  THE LOBBY
-- ============================================================
-- The lobby is the same physical spot as the city, in its own routing bucket.
-- A crowd of arena players waiting for a match is therefore invisible to
-- everyone doing RP in that street -- and they cannot shoot each other while
-- they wait, because to the city they are not there.

local InLobby = {}   -- [src] = true

local function lobbyBucket()
    return Config.Meeting.bucket or 4100
end

CreateThread(function()
    Wait(800)
    local b = lobbyBucket()
    SetRoutingBucketPopulationEnabled(b, false)
    SetRoutingBucketEntityLockdownMode(b, 'relaxed')
    print(('[arena] %s lobby ready in bucket %s'):format(brandName(), b))
end)

function IsInLobby(src)
    return InLobby[src] == true
end

local function enterLobby(src)
    if InLobby[src] then return false, ('You are already in %s.'):format(brandName()) end
    if Occupants[src] then return false, 'Leave the arena first.' end

    InLobby[src] = true
    SetPlayerRoutingBucket(src, lobbyBucket())
    if ZoneLink then ZoneLink.refresh(src) end

    Player(src).state:set('arenaLobby', true, true)

    local c = Config.Meeting.coords
    TriggerClientEvent('naija-arena:client:enterLobby', src, {
        x = c.x, y = c.y, z = c.z, w = c.w
    })

    dbg('%s entered the lobby', GetPlayerName(src))
    return true, ('Welcome to %s.'):format(brandName())
end

local function leaveLobby(src, silent)
    if not InLobby[src] then return false, ('You are not in %s.'):format(brandName()) end

    InLobby[src] = nil
    SetPlayerRoutingBucket(src, 0)
    if ZoneLink then ZoneLink.refresh(src) end
    Player(src).state:set('arenaLobby', false, true)

    local c = Config.Meeting.exitCoords or Config.Meeting.entry.coords
    TriggerClientEvent('naija-arena:client:leaveLobby', src, {
        x = c.x, y = c.y, z = c.z, w = c.w
    })

    if not silent then
        dbg('%s left the lobby', GetPlayerName(src))
    end
    return true, 'Back to the city.'
end

-- removeFromArena puts everyone back in bucket 0, so anyone returning to the
-- lobby has to be put back into its bucket afterwards.
function ReturnToLobby(src)
    if not GetPlayerName(src) then return end

    InLobby[src] = true
    SetPlayerRoutingBucket(src, lobbyBucket())
    if ZoneLink then ZoneLink.refresh(src) end
    Player(src).state:set('arenaLobby', true, true)

    local c = Config.Meeting.coords
    TriggerClientEvent('naija-arena:client:enterLobby', src, {
        x = c.x, y = c.y, z = c.z, w = c.w, quiet = true
    })
end

-- Keep the stored name current.
--
-- The leaderboard reads names out of the stats table, and a row keeps
-- whatever was saved when it was written. Change how names are resolved and
-- every existing row still shows the old one until that player finishes
-- another match. So the name is refreshed whenever we see them, not only at
-- match end.
local function refreshStoredName(src)
    local key = playerKey(src)
    if not key then return end

    local name = nameOf(src)
    if not name or name == '' then return end

    pcall(function()
        MySQL.update.await(
            'UPDATE tenx_arena_stats SET name = ? WHERE identifier = ?',
            { name, key })
    end)
end

RegisterNetEvent('naija-arena:server:enterLobby', function()
    local src = source
    local ok, msg = enterLobby(src)
    notify(src, msg, ok and 'success' or 'error')

    if ok then
        CreateThread(function()
            refreshStoredName(src)
            -- Assigned further down the file; this runs long after load, but
            -- guard it rather than depend on that.
            if PushBillboard then PushBillboard() end
        end)
    end

    -- Deliberately does NOT open the menu. Coming in and opening the menu are
    -- two separate decisions -- people want to look around, read the board, or
    -- wait for a friend before picking a mode.
end)

RegisterNetEvent('naija-arena:server:leaveLobby', function()
    local src = source
    local ok, msg = leaveLobby(src)
    notify(src, msg, ok and 'inform' or 'error')
end)

-- ── surviving a restart ──
--
-- Routing buckets outlive the resource. Restart the script while someone is
-- in the lobby and the server forgets they are there, but the player is still
-- sitting in bucket 2046 -- so asking to leave gets "you are not in the Red
-- Zone" while they are visibly standing in it.
--
-- On start, anyone found in one of our buckets is adopted back. Nobody has to
-- do anything about it.
CreateThread(function()
    Wait(2500)

    local lb = lobbyBucket()
    local base = Config.Buckets.base or 4200
    local top = base + ((Config.Buckets.instancesPerArena or 6) * 200)

    local recovered, evicted = 0, 0

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local ok, bucket = pcall(GetPlayerRoutingBucket, src)

        if ok and bucket and bucket ~= 0 then
            if bucket == lb then
                -- Still in the lobby. Pick them back up rather than stranding
                -- them.
                InLobby[src] = true
                Player(src).state:set('arenaLobby', true, true)

                local c = Config.Meeting.coords
                TriggerClientEvent('naija-arena:client:enterLobby', src, {
                    x = c.x, y = c.y, z = c.z, w = c.w, quiet = true
                })
                recovered = recovered + 1

            elseif bucket >= 2100 and bucket < 2600 then
                -- Left over from the version that had free-for-all zones.
                --
                -- Anyone sitting in one of those buckets when this update
                -- lands is in a world with nobody in it. Kept deliberately:
                -- deleting the rescue with the feature would strand exactly
                -- the people who were using it.
                ReturnToLobby(src)
                notify(src, 'That mode is gone. You are back at the lobby.', 'inform')
                evicted = evicted + 1

            elseif bucket >= base and bucket <= top then
                -- They were in a match that no longer exists. Put them in the
                -- lobby, which is where a finished match leaves you anyway.
                ReturnToLobby(src)
                notify(src, 'That match ended when the script restarted.', 'inform')
                evicted = evicted + 1
            end
        end
    end

    if recovered > 0 or evicted > 0 then
        print(('[arena] after restart: %s recovered in the lobby, %s moved out of dead arenas')
            :format(recovered, evicted))
    end
end)

-- Unconditional way out. Never refuses, never checks whether we think you are
-- if you are in one of our buckets, this gets you out.
RegisterCommand('exitrz', function(src)
    if src == 0 then return end

    local wasSomewhere = InLobby[src] or Occupants[src] ~= nil

    -- Clear every trace of arena state, whether we were tracking it or not.
    InLobby[src] = nil
    Occupants[src] = nil

    -- Including a claim from another resource. This is the command people run
    -- when something is stuck, so it has to be able to unstick a mode that
    -- stopped without releasing whoever it was holding.
    --
    -- Through the global, not the table: Claimed is a local declared much
    -- further down this file and is simply not in scope here. Referencing it
    -- would read a nil global and silently do nothing.
    if ClearClaim then ClearClaim(src) end

    Player(src).state:set('arenaLobby', false, true)
    Player(src).state:set('arenaMatch', false, true)
    Player(src).state:set('arenaId', false, true)
    Player(src).state:set('arenaTeam', false, true)
    Player(src).state:set('arenaPending', false, true)

    -- Leave any room too, or they are stuck in a lobby for a match that will
    -- never start.
    local key = playerKey(src)
    if key and RoomOf and RoomOf[key] then
        RoomOf[key] = nil
    end

    SetPlayerRoutingBucket(src, 0)
    if ZoneLink then ZoneLink.refresh(src) end

    local c = Config.Meeting.exitCoords or Config.Meeting.entry.coords
    TriggerClientEvent('naija-arena:client:forceExit', src, {
        x = c.x, y = c.y, z = c.z, w = c.w
    })

    notify(src, wasSomewhere and 'Back to the city.'
        or ('Cleared any leftover %s state and put you in the city.'):format(brandName()), 'success')

    print(('[arena] %s used exitrz'):format(GetPlayerName(src)))
end, false)

RegisterCommand('rzleave', function(src)
    if src == 0 then return end
    if Occupants[src] then
        removeFromArena(src)
        return
    end
    local ok, msg = leaveLobby(src)
    notify(src, msg, ok and 'inform' or 'error')
end, false)

AddEventHandler('playerDropped', function()
    InLobby[source] = nil
end)

local function buildPanelState()
    local list = {}

    for id, a in pairs(Arenas) do
        local inside = 0
        local running = 0
        for _, o in pairs(Occupants) do
            if o.arenaId == id then inside = inside + 1 end
        end
        for _, m in pairs(Matches) do
            if m.arenaId == id then running = running + 1 end
        end

        list[#list + 1] = {
            id = id,
            name = a.name,
            enabled = a.enabled,
            hasBounds = a.bounds ~= nil,
            showWall = a.showWall,
            bounds = a.bounds,
            spawnsA = #((a.spawns or {}).A or {}),
            spawnsB = #((a.spawns or {}).B or {}),
            loadout = a.loadout or Config.DefaultLoadout,
            usesDefaultLoadout = a.loadout == nil,
            occupants = inside,
            running = running,
            instances = instancesPer(),
            free = instancesPer() - running,
            bucket = bucketFor(id, 1)
        }
    end

    table.sort(list, function(x, y) return x.id < y.id end)

    local occ = {}
    for src, o in pairs(Occupants) do
        if GetPlayerName(src) then
            occ[#occ + 1] = {
                id = src,
                name = nameOf(src),
                arenaId = o.arenaId,
                slot = o.slot,
                team = Player(src).state.arenaTeam
            }
        end
    end

    return { arenas = list, occupants = occ, defaultLoadout = Config.DefaultLoadout }
end

function pushPanel()
    if not next(panelWatchers) then return end
    local data = buildPanelState()
    for src in pairs(panelWatchers) do
        if GetPlayerName(src) then
            TriggerClientEvent('naija-arena:client:panelUpdate', src, data)
        else
            panelWatchers[src] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(next(panelWatchers) and 2000 or 4000)
        if next(panelWatchers) then pushPanel() end
    end
end)

RegisterNetEvent('naija-arena:server:panelClosed', function()
    panelWatchers[source] = nil
end)

-- Every panel action arrives here and is permission-checked on the way in.
-- Having the page open grants nothing on its own.
lib.callback.register('naija-arena:server:panel', function(src, name, data)
    if not hasPermission(src) then
        return { ok = false, message = Config.Text.no_permission }
    end

    data = data or {}
    local arena = data.id and Arenas[tonumber(data.id)] or nil

    -- ── creating ──
    if name == 'createArena' then
        local label = (data.name ~= '' and data.name) or 'New arena'

        local id = MySQL.insert.await(
            'INSERT INTO tenx_arena_zones (name, data, created_by) VALUES (?, ?, ?)',
            { label, json.encode({ spawns = { A = {}, B = {} }, showWall = true }), GetPlayerName(src) })

        -- Created switched ON. Nobody makes an arena intending it to be off,
        -- and it can't be used until it has a boundary and spawns anyway.
        Arenas[id] = {
            id = id, name = label, enabled = true,
            spawns = { A = {}, B = {} }, showWall = true
        }

        prepareBucket(id)
        pushArenas()
        pushPanel()
        return { ok = true, id = id,
                 message = ('Created "%s" and switched it on. Now mark its two corners.'):format(label) }
    end

    if name == 'deleteArena' then
        if not arena then return { ok = false, message = 'That arena is already gone.' } end

        for s, o in pairs(Occupants) do
            if o.arenaId == arena.id then removeFromArena(s) end
        end

        MySQL.update.await('DELETE FROM tenx_arena_zones WHERE id = ?', { arena.id })
        Arenas[arena.id] = nil
        pushArenas()
        pushPanel()
        return { ok = true, message = ('Deleted "%s".'):format(arena.name) }
    end

    if name == 'renameArena' then
        if not arena then return { ok = false, message = 'No such arena.' } end
        arena.name = (data.name ~= '' and data.name) or arena.name
        saveArena(arena)
        pushPanel()
        return { ok = true, message = 'Renamed.' }
    end

    if name == 'toggleArena' then
        if not arena then return { ok = false, message = 'No such arena.' } end
        arena.enabled = not arena.enabled

        if not arena.enabled then
            for s, o in pairs(Occupants) do
                if o.arenaId == arena.id then removeFromArena(s) end
            end
            -- Anyone in it, who is in a different bucket and
            -- would otherwise be left standing in a zone that is switched off.
        end

        saveArena(arena)
        pushPanel()
        return { ok = true, message = arena.enabled and 'Arena switched on.' or 'Arena switched off.' }
    end

    if name == 'toggleWall' then
        if not arena then return { ok = false, message = 'No such arena.' } end
        arena.showWall = not arena.showWall
        saveArena(arena)
        pushPanel()
        return { ok = true, message = arena.showWall and 'Boundary is visible.' or 'Boundary is hidden.' }
    end

    -- ── marking the box ──
    if name == 'markPoints' then
        if not arena then return { ok = false, message = 'No such arena.' } end

        local pts = data.points
        if type(pts) ~= 'table' or #pts < 3 then
            return { ok = false, message = 'A zone needs at least three points.' }
        end

        local minZ, maxZ = math.huge, -math.huge
        local points = {}

        for _, p in ipairs(pts) do
            points[#points + 1] = { x = p.x + 0.0, y = p.y + 0.0 }
            if p.z < minZ then minZ = p.z end
            if p.z > maxZ then maxZ = p.z end
        end

        arena.bounds = {
            points = points,
            minZ = minZ - (Config.Builder.floorGrace or 3.0),
            maxZ = maxZ + (Config.Builder.height or 25.0)
        }

        saveArena(arena)
        pushArenas()
        pushPanel()

        local area = Poly.area(points)
        return { ok = true, message = ('Zone set: %s points, about %.0f square metres.')
            :format(#points, area) }
    end

    if name == 'clearBounds' then
        if not arena then return { ok = false, message = 'No such arena.' } end
        arena.bounds = nil
        arena.pending = nil
        saveArena(arena)
        pushPanel()
        return { ok = true, message = 'Boundary cleared. Mark two corners again.' }
    end

    -- ── spawn points ──
    if name == 'addSpawn' then
        if not arena then return { ok = false, message = 'No such arena.' } end

        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return { ok = false, message = 'Could not read your position.' } end

        local team = data.team == 'B' and 'B' or 'A'
        local c = GetEntityCoords(ped)

        -- A spawn outside the zone would drop someone straight into the wall.
        --
        -- Team spawns are 'inside'. The Red Zone marks its own entry spawns
        -- and those are deliberately OUTSIDE, which is why the direction is
        -- passed rather than assumed.
        local zoneOk, zoneWhy = nil, nil
        if ZoneLink then
            zoneOk, zoneWhy = ZoneLink.validateSpawn(
                arena.id, c, (Config.Zones or {}).spawnTolerance, 'inside')
        end

        if zoneOk == false then
            return { ok = false, message = zoneWhy or 'That spot is outside the zone boundary.' }
        end

        -- nil means the handover is off or could not answer, so the arena's
        -- own test stands.
        if zoneOk == nil and arena.bounds and arena.bounds.points then
            if not Poly.contains(arena.bounds.points, c.x, c.y) then
                return { ok = false, message = 'That spot is outside the zone boundary.' }
            end
        end

        arena.spawns = arena.spawns or { A = {}, B = {} }
        arena.spawns[team] = arena.spawns[team] or {}
        arena.spawns[team][#arena.spawns[team] + 1] = {
            x = tonumber(('%.2f'):format(c.x)),
            y = tonumber(('%.2f'):format(c.y)),
            z = tonumber(('%.2f'):format(c.z)),
            w = tonumber(('%.2f'):format(GetEntityHeading(ped)))
        }

        saveArena(arena)
        pushPanel()
        return { ok = true, message = ('Team %s spawn added (%s total).'):format(team, #arena.spawns[team]) }
    end



    if name == 'clearSpawns' then
        if not arena then return { ok = false, message = 'No such arena.' } end
        local team = data.team == 'B' and 'B' or 'A'
        arena.spawns = arena.spawns or {}
        arena.spawns[team] = {}
        saveArena(arena)
        pushPanel()
        return { ok = true, message = ('Team %s spawns cleared.'):format(team) }
    end

    -- ── loadout ──
    if name == 'setLoadout' then
        if not arena then return { ok = false, message = 'No such arena.' } end

        if data.useDefault then
            arena.loadout = nil
        else
            local list = {}
            for _, it in ipairs(data.items or {}) do
                if it.name and it.name ~= '' then
                    list[#list + 1] = { name = it.name, count = math.max(1, tonumber(it.count) or 1) }
                end
            end
            arena.loadout = list
        end

        saveArena(arena)
        pushPanel()
        return { ok = true, message = 'Loadout saved.' }
    end

    -- ── testing ──
    if name == 'testEnter' then
        if not arena then return { ok = false, message = 'No such arena.' } end

        -- Dropping in to check the walls is not a match. If this ever set the
        -- match flag, the scoreboard would appear and stay.
        Player(src).state:set('arenaMatch', false, true)

        local ok, msg = sendToArena(src, arena.id, data.team, data.loadout ~= false)
        return { ok = ok, message = msg }
    end

    if name == 'testLeave' then
        local ok, msg = removeFromArena(src)
        return { ok = ok, message = msg }
    end

    if name == 'pullOut' then
        local target = tonumber(data.player)
        if not target or not GetPlayerName(target) then
            return { ok = false, message = 'That player is not online.' }
        end
        local ok, msg = removeFromArena(target)
        if ok then notify(target, 'An admin pulled you out of the arena.', 'inform') end
        return { ok = ok, message = msg }
    end

    if name == 'teleportTo' then
        if not arena or not arena.bounds then
            return { ok = false, message = 'That arena has no boundary yet.' }
        end
        local b = arena.bounds

        -- GetZoneCentre is guaranteed inside the shape. A raw centroid is
        -- not: on a concave zone -- an L-shaped arena, or one drawn round a
        -- building -- the average of the points can land outside the polygon,
        -- and an admin flown there arrives inside a wall.
        local cx, cy = nil, nil
        if ZoneLink then cx, cy = ZoneLink.centre(arena.id) end
        if not cx then cx, cy = Poly.centre(b.points) end
        TriggerClientEvent('naija-arena:client:goTo', src, {
            x = cx, y = cy,
            z = b.minZ + (Config.Builder.floorGrace or 3.0)
        })
        return { ok = true, message = ('Heading to %s.'):format(arena.name) }
    end

    return { ok = false, message = 'Unknown action.' }
end)

-- ============================================================
--  COMMANDS
-- ============================================================
RegisterCommand('arena', function(src)
    if src == 0 then
        print('[arena] /arena opens the builder and can only be run in game.')
        return
    end
    if not hasPermission(src) then return notify(src, Config.Text.no_permission, 'error') end

    panelWatchers[src] = true
    TriggerClientEvent('naija-arena:client:openPanel', src, buildPanelState())
end, false)

-- Reopen the builder after marking a zone in the world.
RegisterNetEvent('naija-arena:server:reopenBuilder', function()
    local src = source
    if not hasPermission(src) then return end

    panelWatchers[src] = true
    TriggerClientEvent('naija-arena:client:openPanel', src, buildPanelState())
end)

RegisterCommand('arenaout', function(src)
    if src == 0 then return end
    local ok, msg = removeFromArena(src)
    notify(src, msg, ok and 'success' or 'error')
end, false)

RegisterCommand('arenawhoami', function(src)
    if src == 0 then return end
    local license = getLicense(src)
    notify(src, license or 'No license identifier found.', 'inform')
    print(('[arena] %s => %s'):format(GetPlayerName(src), license or 'none'))
end, false)

-- Nobody should be left stuck in a bucket if the resource stops.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- EVERYONE this resource moved, not just those in a match.
    --
    -- This walked Occupants only, so a player standing in the lobby when the
    -- arena stopped stayed in bucket 2046 -- an empty world with nothing left
    -- running that knows how to take them out. The only way back was an admin
    -- flying in. Checks the actual bucket rather than the tables, since a
    -- lost table entry is exactly what strands someone.
    local lobby = (Config.Meeting and Config.Meeting.bucket) or 2046
    local base  = (Config.Buckets and Config.Buckets.base) or 4200

    for _, id in ipairs(GetPlayers()) do
        local psrc = tonumber(id)
        if psrc then
            local b = GetPlayerRoutingBucket(psrc)
            -- Ours only. A bucket some other resource set is left alone.
            if b == lobby or (base > 0 and b >= base) then
                SetPlayerRoutingBucket(psrc, 0)
                if ZoneLink then ZoneLink.refresh(psrc) end
            end
        end
    end
end)

-- ============================================================
--  STAGE 2: MEETING ZONES, PARTIES, QUEUE, MATCHMAKING
-- ============================================================

local Parties = {}      -- [code] = { code, leader, mode, score, members, weapons, locked }
local PartyOf = {}      -- [license] = code
local Queue = {}        -- [mode] = { { kind='solo'|'party', key=..., size=n } }
-- Matches is declared at the top of the file: the panel state builder above
-- reads it, and a second local here would shadow it so the two halves of the
-- file would be looking at different tables.
local Pending = {}      -- [id] = a match waiting on ready-check / map vote
local Dummies = {}      -- [key] = { name, team } -- test-mode fillers

local nextPending = 0

--- The default weapon for a slot, or false when the list is empty.
---
--- These lists were indexed straight -- Config.Weapons.primary[1].id -- which
--- is fine right up until the list is empty. Taking the rifles out emptied
--- primary, and every one of those reads then threw on a nil index: no queue
--- match could start and room voting fell over, because the throw happened
--- while the match was being built.
---
--- false rather than nil, because false is what DefaultRoomWeapons already
--- uses to mean "this slot has nothing" and the rest of the code reads it.
local function defaultWeapon(slot)
    local list = (Config.Weapons or {})[slot]
    local first = list and list[1]
    return (first and first.id) or false
end

local function modeById(id)
    for _, m in ipairs(Config.Modes) do
        if m.id == id then return m end
    end
    return Config.Modes[1]
end

function playerKey(src)
    return getLicense(src)
end

--- The other direction: who on the server is this key?
---
--- Walked rather than kept as a table, because a cached map has to be
--- maintained on join and drop and goes stale the one time somebody forgets.
--- The player list is short and this is only called when something is
--- actually being given to someone.
---
--- Returns nil when they are offline, which is a normal answer -- items can
--- be added to a key whose owner is not connected.
function srcForKey(key)
    if not key then return nil end

    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        if src and playerKey(src) == key then return src end
    end

    return nil
end


-- The old database-driven meeting zones are gone. The lobby is a single
-- fixed location in its own bucket now, set in Config.Meeting, so there is
-- nothing to mark or load. The tenx_arena_meeting table is unused and can be
-- dropped if you like.

-- ============================================================
--  PARTIES
-- ============================================================
local function makeCode()
    local chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' -- no I/O/0/1, they get misread
    for _ = 1, 50 do
        local code = ''
        for _ = 1, (Config.Party.codeLength or 4) do
            local i = math.random(#chars)
            code = code .. chars:sub(i, i)
        end
        if not Parties[code] then return code end
    end
    return tostring(math.random(1000, 9999))
end

local function partyPublic(party)
    if not party then return nil end

    local members = {}
    for _, key in ipairs(party.order) do
        local m = party.members[key]
        if m then
            members[#members + 1] = {
                key = key,
                name = m.name,
                id = m.src,
                leader = key == party.leader,
                dummy = m.dummy or false,
                ready = m.ready or false
            }
        end
    end

    local mode = modeById(party.mode)
    return {
        code = party.code,
        mode = party.mode,
        modeLabel = mode.label,
        perTeam = mode.perTeam,
        score = party.score,
        weapons = party.weapons,
        members = members,
        size = #members,
        queued = party.queued or false
    }
end

local function notifyParty(party, event, payload)
    if not party then return end
    for _, key in ipairs(party.order) do
        local m = party.members[key]
        if m and m.src and GetPlayerName(m.src) then
            TriggerClientEvent(event, m.src, payload)
        end
    end
end

local pushPlayerPanel -- forward

local function refreshParty(party)
    if not party then return end
    notifyParty(party, 'naija-arena:client:party', partyPublic(party))
end

local function createParty(src, mode)
    local key = playerKey(src)
    if not key then return nil, 'Could not identify you.' end
    if PartyOf[key] then return nil, 'You are already in a party.' end

    local m = modeById(mode or Config.DefaultMode)
    local code = makeCode()

    Parties[code] = {
        code = code,
        leader = key,
        mode = m.id,
        score = m.defaultScore,
        weapons = {
            primary = defaultWeapon('primary'),
            sidearm = defaultWeapon('sidearm')
        },
        members = { [key] = { name = nameOf(src), src = src, ready = true } },
        order = { key },
        queued = false
    }

    PartyOf[key] = code
    return Parties[code]
end

local function leaveParty(src, silent)
    local key = playerKey(src)
    local code = key and PartyOf[key]
    if not code then return false, 'You are not in a party.' end

    local party = Parties[code]
    PartyOf[key] = nil
    if not party then return true, '' end

    party.members[key] = nil
    for i, k in ipairs(party.order) do
        if k == key then table.remove(party.order, i) break end
    end

    -- Leader left: hand it to whoever is next, or bin the party.
    if party.leader == key then
        party.leader = party.order[1]
    end

    if #party.order == 0 then
        Parties[code] = nil
    else
        refreshParty(party)
    end

    return true, silent and '' or 'You left the party.'
end

-- ============================================================
--  QUEUE
-- ============================================================
local function queueEntryFor(key)
    local code = PartyOf[key]
    if code then return 'party', code end
    return 'solo', key
end

local function dequeue(kind, entryKey)
    for mode, list in pairs(Queue) do
        for i = #list, 1, -1 do
            if list[i].kind == kind and list[i].key == entryKey then
                table.remove(list, i)
            end
        end
    end
end

local function queueCounts()
    local out = {}
    for _, m in ipairs(Config.Modes) do
        local n = 0
        for _, e in ipairs(Queue[m.id] or {}) do n = n + e.size end
        out[m.id] = n
    end
    return out
end

local function pushQueueState()
    GlobalState.arenaQueue = queueCounts()
end

-- Free arenas: set up, switched on, and not already hosting a match.
local function freeArenas()
    local out = {}
    for id, a in pairs(Arenas) do
        -- With the handover on, a zoneId that no longer resolves takes the
        -- arena out of the list rather than starting a match with no walls.
        local shapeOk = a.bounds ~= nil
        if ZoneLink and ZoneLink.active() then
            shapeOk = ZoneLink.zoneUsable(id)
        end

        if a.enabled and shapeOk
           and #((a.spawns or {}).A or {}) > 0
           and #((a.spawns or {}).B or {}) > 0 then
            -- An arena is offered while it still has a free instance. Being
            -- in use no longer takes it off the list.
            local slot = freeSlot(id)
            if slot then
                out[#out + 1] = {
                    id = id, name = a.name, image = a.image,
                    running = instancesPer() - (freeSlot(id) and 0 or 0),
                    free = (function()
                        local used = usedSlots(id)
                        local n = 0
                        for i = 1, instancesPer() do if not used[i] then n = n + 1 end end
                        return n
                    end)()
                }
            end
        end
    end
    return out
end

-- ============================================================
--  MATCHMAKING
-- ============================================================
-- Pull entries out of a mode's queue until both teams are full. Parties are
-- kept whole -- a party of three never gets split across the two sides, which
-- is the whole reason someone made a party.
-- Declared here because forming a match calls it and it is defined below.
local beginMapVote

--- Form a match from the queue.
---
--- Ranked and casual never mix: a ranked player waiting is not a body a
--- casual player can be matched against, and the other way round would put
--- somebody's rating on a game they thought was for fun.
local function tryMatch(modeId, ranked)
    local mode = modeById(modeId)
    local list = Queue[modeId]
    if not list or #list == 0 then return end

    local need = mode.perTeam * 2
    -- Only people who asked for the same kind of match.
    ranked = ranked == true

    local eligible = {}
    for i, e in ipairs(list) do
        if (e.ranked == true) == ranked then
            eligible[#eligible + 1] = { i = i, e = e }
        end
    end

    local total = 0
    for _, item in ipairs(eligible) do total = total + item.e.size end
    if total < need then return end

    local teams = { A = {}, B = {} }
    local sizeA, sizeB = 0, 0
    local taken = {}

    -- Biggest groups first, so a 3-stack is placed before the solos that have
    -- to fill in around it.
    --
    -- Ties break on queue position, so two groups of the same size are placed
    -- in the order they joined. table.sort is not stable, so without this the
    -- same queue could form differently on two runs -- which matters now that
    -- the first group placed is the one whose score target the match takes.
    local sorted = eligible
    table.sort(sorted, function(x, y)
        if x.e.size ~= y.e.size then return x.e.size > y.e.size end
        return x.i < y.i
    end)

    -- Whoever is placed first decides how long the match runs. The largest
    -- group has the most people to disappoint, and waiting longest is the
    -- tiebreak.
    local matchScore = nil

    for _, item in ipairs(sorted) do
        local e = item.e
        local target = nil

        if sizeA + e.size <= mode.perTeam then
            target = 'A'
        elseif sizeB + e.size <= mode.perTeam then
            target = 'B'
        end

        if target then
            for _, member in ipairs(e.members) do
                teams[target][#teams[target] + 1] = member
            end
            if target == 'A' then sizeA = sizeA + e.size else sizeB = sizeB + e.size end
            taken[item.i] = true

            if not matchScore then matchScore = e.score end
        end

        if sizeA == mode.perTeam and sizeB == mode.perTeam then break end
    end

    if sizeA < mode.perTeam or sizeB < mode.perTeam then return end

    -- Remove what we used, highest index first so the rest stay valid.
    local indices = {}
    for i in pairs(taken) do indices[#indices + 1] = i end
    table.sort(indices, function(a, b) return a > b end)
    for _, i in ipairs(indices) do table.remove(list, i) end

    pushQueueState()

    nextPending = nextPending + 1
    local pid = nextPending

    Pending[pid] = {
        id = pid,
        mode = mode.id,
        -- What the people in it asked for, not what the mode defaults to.
        -- Still validated on the way in, so this is always a score the mode
        -- offers.
        score = validScore(mode.id, matchScore, mode.defaultScore),
        -- Carried all the way to the end: it decides whether ratings move.
        ranked = ranked,
        teams = teams,
        ready = {},
        phase = 'ready',
        arenas = freeArenas(),
        votes = {},
        endsAt = os.time() + (Config.Queue.readyCheck or 20)
    }

    -- Dummies are always ready; they exist to fill slots, not to click.
    for _, team in pairs(teams) do
        for _, m in ipairs(team) do
            if m.dummy then Pending[pid].ready[m.key] = true end
        end
    end

    -- ── no accept step ──
    --
    -- Joining the queue is the agreement. Asking again afterwards is a second
    -- question about a decision already made, and it only ever costs matches:
    -- one person steps away and everybody else goes back to waiting.
    if not Config.Queue.requireAccept then
        for _, team in pairs(teams) do
            for _, m in ipairs(team) do
                if m.key then Pending[pid].ready[m.key] = true end

                if m.src and GetPlayerName(m.src) then
                    Player(m.src).state:set('arenaPending', pid, true)

                    -- Told, not asked.
                    TriggerClientEvent('naija-arena:client:matchFound', m.src, {
                        id = pid,
                        mode = mode.label,
                        seconds = Config.Queue.foundFor or 3
                    })
                end
            end
        end

        -- Straight on to the map vote once they have had a moment to read it.
        SetTimeout((Config.Queue.foundFor or 3) * 1000, function()
            local pp = Pending[pid]
            if pp and pp.phase == 'ready' then
                if beginMapVote then beginMapVote(pid) end
            end
        end)

        dbg('Match %s formed: %s, %s v %s (no accept step)', pid, mode.id, sizeA, sizeB)
        return pid
    end

    for _, team in pairs(teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                Player(m.src).state:set('arenaPending', pid, true)
                TriggerClientEvent('naija-arena:client:readyCheck', m.src, {
                    id = pid,
                    mode = mode.label,
                    seconds = Config.Queue.readyCheck or 20
                })
            end
        end
    end

    dbg('Match %s formed: %s, %s v %s', pid, mode.id, sizeA, sizeB)
    return pid
end

local startPendingMatch -- forward

local function cancelPending(pid, reason, blameKey)
    local p = Pending[pid]
    if not p then return end

    Pending[pid] = nil

    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                Player(m.src).state:set('arenaPending', false, true)
                TriggerClientEvent('naija-arena:client:matchCancelled', m.src, {
                    reason = reason or 'Match cancelled.',
                    blamed = blameKey == m.key
                })
            end
        end
    end

    dbg('Match %s cancelled: %s', pid, reason or 'no reason')
end

-- Map voting. Everyone picks; most votes wins; ties broken at random.
beginMapVote = function(pid)
    local p = Pending[pid]
    if not p then return end

    if #p.arenas == 0 then
        cancelPending(pid, 'No free arena was available.')
        return
    end

    -- One arena, or voting switched off: no point asking.
    if #p.arenas == 1 or (Config.Queue.mapVote or 0) <= 0 then
        p.arenaId = p.arenas[math.random(#p.arenas)].id
        startPendingMatch(pid)
        return
    end

    p.phase = 'vote'
    p.endsAt = os.time() + Config.Queue.mapVote

    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:mapVote', m.src, {
                    id = pid,
                    arenas = p.arenas,
                    seconds = Config.Queue.mapVote
                })
            end
        end
    end

    SetTimeout(Config.Queue.mapVote * 1000, function()
        local pp = Pending[pid]
        if not pp or pp.phase ~= 'vote' then return end

        local tally = {}
        for _, arenaId in pairs(pp.votes) do
            tally[arenaId] = (tally[arenaId] or 0) + 1
        end

        local best, bestVotes = nil, -1
        for _, a in ipairs(pp.arenas) do
            local v = tally[a.id] or 0
            if v > bestVotes then best, bestVotes = a.id, v end
        end

        pp.arenaId = best or pp.arenas[math.random(#pp.arenas)].id
        startPendingMatch(pid)
    end)
end

function startPendingMatch(pid)
    local p = Pending[pid]
    if not p then return end

    local arena = Arenas[p.arenaId]
    if not arena then
        cancelPending(pid, 'That arena is no longer available.')
        return
    end

    p.phase = 'starting'

    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:matchStarting', m.src, {
                    arena = arena.name,
                    seconds = Config.Queue.startDelay or 5
                })
            end
        end
    end

    SetTimeout((Config.Queue.startDelay or 5) * 1000, function()
        local pp = Pending[pid]
        if not pp then return end
        Pending[pid] = nil

        local match = {
            -- From the pending match, which got it from the queue.
            ranked = pp.ranked or false,
            arenaId = pp.arenaId,
            mode = pp.mode,
            score = pp.score,
            scores = { A = 0, B = 0 },
            kills = {},
            deaths = {},
            dead = {},
            arenaId = pp.arenaId,
            teams = pp.teams,
            weapons = pp.weapons or {
                primary = defaultWeapon('primary'),
                sidearm = defaultWeapon('sidearm')
            },
            startedAt = os.time(),
            phase = 'live'
        }

        local pslot = freeSlot(pp.arenaId) or 1
        match.slot = pslot
        match.key = matchKey(pp.arenaId, pslot)
        Matches[match.key] = match

        local roster = {}
        for teamId, team in pairs(pp.teams) do
            for _, m in ipairs(team) do
                roster[#roster + 1] = { id = m.src, name = m.name, team = teamId, dummy = m.dummy }
            end
        end

        for teamId, team in pairs(pp.teams) do
            for _, m in ipairs(team) do
                if m.src and GetPlayerName(m.src) then
                    -- Out of the lobby. Leaving this set meant a match
                    -- rearrangement wrote itself back into the kept
                    -- inventory as though it had happened in the lobby.
                    InLobby[m.src] = nil

                    -- The STATEBAG as well, not just the table.
                    --
                    -- These two were saying different things for the whole of
                    -- a match: the server knew the player had left the lobby,
                    -- the client was still being told they were in it. The
                    -- client's lobby rules -- weapons handed out with no
                    -- ammunition, trigger disabled -- only stayed off because
                    -- arenaMatch happened to arrive first. When it did not,
                    -- and it is a separate replication with its own timing,
                    -- the player spawned into a match holding a gun they
                    -- could not fire while everyone else played normally.
                    Player(m.src).state:set('arenaLobby', false, true)

                    Player(m.src).state:set('arenaPending', false, true)
                    Player(m.src).state:set('arenaMatch', true, true)
                    Player(m.src).state:set('arenaTeam', teamId, true)

                    sendToArena(m.src, pp.arenaId, teamId, false, pslot)

                    -- The grid. A match started from the QUEUE never built
                    -- one -- only rooms did -- so anyone matchmaking arrived
                    -- with an empty inventory and no weapon.
                    if Config.MatchInventory and Config.MatchInventory.enabled then
                        buildMatchInventory(m.src, match)
                    end

                    TriggerClientEvent('naija-arena:client:matchBegin', m.src, {
                        arena = arena.name,
                        mode = match.mode,
                        score = match.score,
                        team = teamId,
                        weapons = match.weapons,
                        roster = roster
                    })
                end
            end
        end

        dbg('Match live in arena %s (%s)', pp.arenaId, match.mode)
        if pushPanel then pushPanel() end
    end)
end

local function allReady(p)
    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if not p.ready[m.key] then return false end
        end
    end
    return true
end

RegisterNetEvent('naija-arena:server:ready', function(pid, accept)
    local src = source
    local p = Pending[tonumber(pid) or 0]
    if not p or p.phase ~= 'ready' then return end

    local key = playerKey(src)
    if not key then return end

    if accept == false then
        cancelPending(p.id, ('%s declined.'):format(nameOf(src)), key)
        return
    end

    p.ready[key] = true

    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:readyUpdate', m.src, {
                    id = p.id,
                    ready = (function()
                        local n = 0
                        for _ in pairs(p.ready) do n = n + 1 end
                        return n
                    end)(),
                    total = (function()
                        local n = 0
                        for _, t in pairs(p.teams) do n = n + #t end
                        return n
                    end)()
                })
            end
        end
    end

    if allReady(p) then beginMapVote(p.id) end
end)

RegisterNetEvent('naija-arena:server:vote', function(pid, arenaId)
    local src = source
    local p = Pending[tonumber(pid) or 0]
    if not p or p.phase ~= 'vote' then return end

    local key = playerKey(src)
    if not key then return end

    p.votes[key] = tonumber(arenaId)

    local tally = {}
    for _, aid in pairs(p.votes) do tally[aid] = (tally[aid] or 0) + 1 end

    for _, team in pairs(p.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:voteUpdate', m.src, tally)
            end
        end
    end
end)

-- Ready-check timeout: anyone who didn't answer is the reason it failed.
CreateThread(function()
    while true do
        Wait(1000)
        for pid, p in pairs(Pending) do
            if p.phase == 'ready' and os.time() >= p.endsAt then
                if allReady(p) then
                    beginMapVote(pid)
                else
                    cancelPending(pid, 'Someone did not accept in time.')
                end
            end
        end
    end
end)

-- ============================================================
--  THE PLAYER PANEL
-- ============================================================
local function nearbyPlayers(src)
    local out = {}
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return out end

    local pos = GetEntityCoords(ped)
    local range = Config.Party.inviteRange or 12.0
    local myKey = playerKey(src)

    for _, playerId in ipairs(GetPlayers()) do
        local id = tonumber(playerId)
        local key = playerKey(id)

        if id ~= src and key and not PartyOf[key] then
            local theirPed = GetPlayerPed(id)
            if theirPed and theirPed ~= 0 then
                local d = #(GetEntityCoords(theirPed) - pos)
                if d <= range then
                    out[#out + 1] = { id = id, name = nameOf(id), key = key, distance = math.floor(d) }
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

local blank = { wins = 0, losses = 0, kills = 0, deaths = 0, matches = 0, points = 0 }

local function statsFor(key)
    -- Wrapped, because a missing table here would take the whole player panel
    -- down with it -- /rz would just do nothing, with no clue why.
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT * FROM tenx_arena_stats WHERE identifier = ?', { key })
    end)

    if not ok then
        return blank
    end

    return row or blank
end

function playerPanelState(src)
    local key = playerKey(src)
    local party = key and PartyOf[key] and Parties[PartyOf[key]] or nil

    local modes = {}
    for _, m in ipairs(Config.Modes) do
        modes[#modes + 1] = {
            id = m.id, label = m.label, perTeam = m.perTeam,
            scores = m.scores, defaultScore = m.defaultScore
        }
    end

    return {
        name = nameOf(src),
        modes = modes,
        weapons = Config.Weapons,
        items = Config.PickableItems or {},
        scoring = Config.Match.scoring or 'rounds',
        roundOptions = Config.Match.roundOptions or { 1, 3, 5 },
        killOptions = Config.Match.scoreOptions or { 3, 5, 7, 10, 15 },
        oxPath = Config.OxImagePath,
        party = partyPublic(party),
        nearby = nearbyPlayers(src),
        queue = queueCounts(),
        arenas = freeArenas(),
        stats = key and statsFor(key) or nil,
        -- The Back to lobby button only appears where it does something.
        -- Whether the room picks weapons or everyone brings their own.
        ownWeapons = Config.OwnWeapons and true or false,

        -- Which modes the ranked panel may offer, and how many are waiting
        -- in each ranked queue -- counted separately from casual, because
        -- they never match against each other.
        rankedModes = Config.Ranked.rankedModes or {},

        -- For the wager picker: what may be staked, and what this player
        -- actually has, so amounts they cannot cover are shown as such.
        wagerAmounts = (Config.Wager and Config.Wager.enabled ~= false)
            and (Config.Wager.amounts or { 0 }) or { 0 },
        coins = (function()
            local k = playerKey(src)
            return k and RzCoins(k) or 0
        end)(),
        rankedQueue = (function()
            local out = {}
            for modeId, list in pairs(Queue) do
                local n = 0
                for _, e in ipairs(list) do
                    if e.ranked then n = n + e.size end
                end
                out[modeId] = n
            end
            return out
        end)(),

        -- Are YOU in a queue, and which one.
        --
        -- This used to be read off the party, so anyone queueing solo -- most
        -- people -- never saw the Leave queue button at all.
        queuedIn = (function()
            local key = playerKey(src)
            if not key then return nil end

            for modeId, list in pairs(Queue) do
                for _, e in ipairs(list) do
                    if e.key == key then return modeId end
                end
            end
            return nil
        end)(),
        inMatch = (Player(src).state.arenaMatch == true),
        inLobby = InLobby[src] == true,
        testMode = Config.TestMode.enabled and hasPermission(src) or false,
        dummies = (function()
            local n = 0
            for _ in pairs(Dummies) do n = n + 1 end
            return n
        end)()
    }
end

function pushPlayerPanel(src)
    if not GetPlayerName(src) then return end
    TriggerClientEvent('naija-arena:client:playerUpdate', src, playerPanelState(src))
end

lib.callback.register('naija-arena:server:player', function(src, name, data)
    data = data or {}
    local key = playerKey(src)
    if not key then return { ok = false, message = 'Could not identify you.' } end

    local party = PartyOf[key] and Parties[PartyOf[key]] or nil

    if name == 'state' then
        return { ok = true, state = playerPanelState(src) }
    end

    -- ── party ──
    if name == 'createParty' then
        local p, err = createParty(src, data.mode)
        if not p then return { ok = false, message = err } end
        refreshParty(p)
        return { ok = true, state = playerPanelState(src), message = ('Party created. Code %s.'):format(p.code) }
    end

    if name == 'leaveParty' then
        local ok, msg = leaveParty(src)
        return { ok = ok, state = playerPanelState(src), message = msg }
    end

    if name == 'joinByCode' then
        local code = (data.code or ''):upper()
        local target = Parties[code]
        if not target then return { ok = false, message = 'No party with that code.' } end
        if PartyOf[key] then return { ok = false, message = 'Leave your party first.' } end

        local mode = modeById(target.mode)
        if #target.order >= mode.perTeam then
            return { ok = false, message = 'That party is full.' }
        end

        target.members[key] = { name = nameOf(src), src = src, ready = true }
        target.order[#target.order + 1] = key
        PartyOf[key] = code
        refreshParty(target)
        return { ok = true, state = playerPanelState(src), message = ('Joined %s.'):format(code) }
    end

    if name == 'invite' then
        if not party then return { ok = false, message = 'Make a party first.' } end
        if party.leader ~= key then return { ok = false, message = 'Only the leader can invite.' } end

        local target = tonumber(data.player)
        if not target or not GetPlayerName(target) then
            return { ok = false, message = 'They are not online.' }
        end

        local tKey = playerKey(target)
        if not tKey then return { ok = false, message = 'Could not identify them.' } end
        if PartyOf[tKey] then return { ok = false, message = 'They are already in a party.' } end

        local mode = modeById(party.mode)
        if #party.order >= mode.perTeam then
            return { ok = false, message = 'Your party is full.' }
        end

        TriggerClientEvent('naija-arena:client:invite', target, {
            code = party.code,
            from = nameOf(src),
            mode = mode.label,
            seconds = Config.Party.inviteTimeout or 30
        })

        return { ok = true, message = ('Invite sent to %s.'):format(GetPlayerName(target)) }
    end

    if name == 'kick' then
        if not party or party.leader ~= key then
            return { ok = false, message = 'Only the leader can remove people.' }
        end

        local tKey = data.key
        local member = tKey and party.members[tKey]
        if not member then return { ok = false, message = 'They are not in your party.' } end

        if member.dummy then
            Dummies[tKey] = nil
            party.members[tKey] = nil
            for i, k in ipairs(party.order) do
                if k == tKey then table.remove(party.order, i) break end
            end
            refreshParty(party)
            return { ok = true, state = playerPanelState(src), message = 'Dummy removed.' }
        end

        if member.src then leaveParty(member.src, true) end
        refreshParty(party)
        return { ok = true, state = playerPanelState(src), message = 'Removed from the party.' }
    end

    -- ── match setup ──
    if name == 'setMode' then
        if not party or party.leader ~= key then
            return { ok = false, message = 'Only the leader can change the mode.' }
        end
        local m = modeById(data.mode)
        party.mode = m.id
        party.score = m.defaultScore

        -- Shrinking the mode can leave the party over the new team size.
        while #party.order > m.perTeam do
            local dropKey = party.order[#party.order]
            local dropped = party.members[dropKey]
            if dropped and dropped.src then
                leaveParty(dropped.src, true)
                notify(dropped.src, 'The party changed to a smaller mode and you were dropped.', 'error')
            else
                Dummies[dropKey] = nil
                party.members[dropKey] = nil
                table.remove(party.order)
            end
        end

        refreshParty(party)
        return { ok = true, state = playerPanelState(src), message = ('Mode set to %s.'):format(m.label) }
    end

    if name == 'setScore' then
        if not party or party.leader ~= key then
            return { ok = false, message = 'Only the leader can change the score.' }
        end
        -- Only a score the mode actually offers.
        --
        -- math.max(1, ...) accepted anything, so a first-to-500 was one
        -- crafted message away -- and a stored 30 from before the cap would
        -- have survived a config change that was meant to remove it.
        party.score = validScore(party.mode, data.score, party.score)

        refreshParty(party)
        return { ok = true, message = ('First to %s.'):format(party.score) }
    end

    if name == 'setWeapon' then
        if not party or party.leader ~= key then
            return { ok = false, message = 'Only the leader can change weapons.' }
        end
        local slot = data.slot == 'sidearm' and 'sidearm' or 'primary'
        party.weapons = party.weapons or {}
        party.weapons[slot] = data.weapon
        refreshParty(party)
        return { ok = true, message = 'Weapon set.' }
    end

    -- ── queue ──
    if name == 'joinQueue' then
        local modeId = (party and party.mode) or data.mode or Config.DefaultMode
        local mode = modeById(modeId)
        local kind, entryKey = queueEntryFor(key)

        dequeue(kind, entryKey)

        local members = {}
        if party then
            if party.leader ~= key then
                return { ok = false, message = 'Only the leader can queue the party.' }
            end
            for _, k in ipairs(party.order) do
                local m = party.members[k]
                if m then
                    members[#members + 1] = { key = k, name = m.name, src = m.src, dummy = m.dummy }
                end
            end
            party.queued = true
        else
            members[1] = { key = key, name = nameOf(src), src = src }
        end

        if #members > mode.perTeam then
            return { ok = false, message = ('Too many for %s.'):format(mode.label) }
        end

        -- Ranked or casual is decided by which panel you queued from, not by
        -- the mode. The same 1v1 can be either, and mixing the two queues
        -- would put someone's rating on the line against a person messing
        -- about with a friend.
        local wantRanked = data.ranked == true

        -- The score has to travel with the entry.
        --
        -- A party already carries its own; a solo player picking "first to 5"
        -- on the ranked panel had that number thrown away here and got the
        -- mode default instead, which made the score picker decorative.
        -- validScore pulls anything out of range back to something the mode
        -- actually offers, so a crafted value cannot set an arbitrary target.
        local wantScore = (party and party.score)
            or validScore(modeId, data.score, mode.defaultScore)

        Queue[modeId] = Queue[modeId] or {}
        Queue[modeId][#Queue[modeId] + 1] = {
            kind = kind, key = entryKey, size = #members, members = members,
            mode = modeId, ranked = wantRanked, score = wantScore
        }

        pushQueueState()
        if party then refreshParty(party) end

        local formed = tryMatch(modeId, wantRanked)
        return {
            ok = true,
            state = playerPanelState(src),
            message = formed and 'Match found.' or ('In the queue for %s.'):format(mode.label)
        }
    end

    if name == 'leaveQueue' then
        local kind, entryKey = queueEntryFor(key)
        dequeue(kind, entryKey)
        if party then party.queued = false ; refreshParty(party) end
        pushQueueState()
        return { ok = true, state = playerPanelState(src), message = 'Left the queue.' }
    end

    -- ── leaderboard ──
    if name == 'leaderboard' then
        local rows = MySQL.query.await(
            'SELECT name, wins, losses, kills, deaths, matches, points FROM tenx_arena_stats ORDER BY wins DESC, kills DESC LIMIT 25') or {}
        return { ok = true, board = rows, you = statsFor(key) }
    end

    -- ── test mode ──
    if name == 'addDummy' then
        if not Config.TestMode.enabled or not hasPermission(src) then
            return { ok = false, message = 'Test mode is off.' }
        end
        if not party then return { ok = false, message = 'Make a party first.' } end

        local mode = modeById(party.mode)
        if #party.order >= mode.perTeam then
            return { ok = false, message = 'Party is already full for this mode.' }
        end

        local n = 0
        for _ in pairs(Dummies) do n = n + 1 end
        if n >= (Config.TestMode.maxDummies or 9) then
            return { ok = false, message = 'Too many dummies already.' }
        end

        local dKey = ('dummy:%s'):format(math.random(100000, 999999))
        local dName = ('%s %s'):format(Config.TestMode.namePrefix or 'DUMMY', n + 1)

        Dummies[dKey] = { name = dName }
        party.members[dKey] = { name = dName, src = nil, dummy = true, ready = true }
        party.order[#party.order + 1] = dKey

        refreshParty(party)
        return { ok = true, state = playerPanelState(src), message = ('%s added.'):format(dName) }
    end

    if name == 'fillDummies' then
        if not Config.TestMode.enabled or not hasPermission(src) then
            return { ok = false, message = 'Test mode is off.' }
        end

        -- Fill the other side of the queue so a match can actually form solo.
        local modeId = (party and party.mode) or Config.DefaultMode
        local mode = modeById(modeId)
        local members = {}

        for i = 1, mode.perTeam do
            local dKey = ('dummy:%s'):format(math.random(100000, 999999))
            local dName = ('%s %s'):format(Config.TestMode.namePrefix or 'DUMMY', i)
            Dummies[dKey] = { name = dName }
            members[#members + 1] = { key = dKey, name = dName, src = nil, dummy = true }
        end

        Queue[modeId] = Queue[modeId] or {}
        Queue[modeId][#Queue[modeId] + 1] = {
            kind = 'party', key = ('dummies:%s'):format(math.random(10000, 99999)),
            size = #members, members = members, mode = modeId
        }

        pushQueueState()
        local formed = tryMatch(modeId)

        return {
            ok = true,
            state = playerPanelState(src),
            message = formed and 'Dummy side added and the match formed.'
                              or ('%s dummies queued for %s.'):format(#members, mode.label)
        }
    end

    if name == 'clearDummies' then
        if not hasPermission(src) then return { ok = false, message = Config.Text.no_permission } end
        Dummies = {}
        for _, list in pairs(Queue) do
            for i = #list, 1, -1 do
                local allDummy = true
                for _, m in ipairs(list[i].members) do
                    if not m.dummy then allDummy = false break end
                end
                if allDummy then table.remove(list, i) end
            end
        end
        pushQueueState()
        return { ok = true, state = playerPanelState(src), message = 'Dummies cleared.' }
    end

    return { ok = false, message = 'Unknown action.' }
end)

RegisterNetEvent('naija-arena:server:acceptInvite', function(code)
    local src = source
    local key = playerKey(src)
    if not key or PartyOf[key] then return end

    local party = Parties[(code or ''):upper()]
    if not party then return notify(src, 'That party no longer exists.', 'error') end

    local mode = modeById(party.mode)
    if #party.order >= mode.perTeam then
        return notify(src, 'That party filled up.', 'error')
    end

    party.members[key] = { name = nameOf(src), src = src, ready = true }
    party.order[#party.order + 1] = key
    PartyOf[key] = party.code

    refreshParty(party)
    notify(src, 'You joined the party.', 'success')
    pushPlayerPanel(src)
end)

-- Someone leaving takes their queue entry and party slot with them.
AddEventHandler('playerDropped', function()
    local src = source
    local key = playerKey(src)
    if not key then return end

    local kind, entryKey = queueEntryFor(key)
    dequeue(kind, entryKey)
    if PartyOf[key] then leaveParty(src, true) end
    pushQueueState()
end)

RegisterCommand(Config.Meeting.command or 'rz', function(src)
    if src == 0 then
        print('[arena] /' .. (Config.Meeting.command or 'rz') .. ' can only be run in game.')
        return
    end

    -- Not from the city. See inMainCity().
    if inMainCity(src) then
        refuseFromCity(src)
        return
    end

    -- A command that does nothing tells you nothing. If building the panel
    -- state throws, the player gets told and the reason lands in the console.
    local ok, state = pcall(playerPanelState, src)

    if not ok then
        print(('^1[arena] /%s failed for %s: %s^0')
            :format(Config.Meeting.command or 'rz', GetPlayerName(src), tostring(state)))
        notify(src, ('The %s menu could not open. An admin should check the console.'):format(brandName()), 'error')
        return
    end

    TriggerClientEvent('naija-arena:client:openPlayer', src, state)
end, false)

RegisterNetEvent('naija-arena:server:requestPanel', function()
    local src = source

    -- The ped only offers this option to somebody already in the lobby, so
    -- a call arriving from bucket 0 did not come from the ped. Same gate as
    -- the command, because this event IS the command's other door.
    --
    -- naija-arena:server:enterLobby is deliberately NOT gated -- that one is
    -- the ped's "let me in" option and has to work from the city.
    if inMainCity(src) then
        refuseFromCity(src)
        return
    end

    TriggerClientEvent('naija-arena:client:openPlayer', src, playerPanelState(src))
end)

-- ── admin: mark a meeting zone ──


-- ============================================================
--  STAGE 3: SCORING, RESPAWNS, WIN CONDITIONS
-- ============================================================

local function matchOf(src)
    local o = Occupants[src]
    if not o then return nil end
    return Matches[o.key], o.arenaId, o.slot, o.key
end

local function occupantArena(src)
    local o = Occupants[src]
    return o and o.arenaId or nil
end

local function teamOf(match, key)
    for teamId, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            if m.key == key then return teamId, m end
        end
    end
    return nil
end

local function rosterPayload(match)
    local out = {}
    for teamId, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            out[#out + 1] = {
                id = m.src,
                name = m.name,
                team = teamId,
                dummy = m.dummy or false,
                alive = not (match.dead and match.dead[m.key]),
                kills = (match.kills and match.kills[m.key]) or 0,
                deaths = (match.deaths and match.deaths[m.key]) or 0
            }
        end
    end
    return out
end

local function pushScore(match, extra)
    local payload = {
        scoreA = match.scores.A,
        scoreB = match.scores.B,
        target = match.score,
        round = match.round or 1,
        rounds = match.rounds or 1,
        scoring = match.scoring or 'rounds',
        winsA = (match.roundWins or {}).A or 0,
        winsB = (match.roundWins or {}).B or 0,
        roster = rosterPayload(match)
    }
    if extra then
        for k, v in pairs(extra) do payload[k] = v end
    end

    for _, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:score', m.src, payload)
            end
        end
    end
end

local endMatch -- forward

-- How many of a team are still standing.
local function aliveOn(match, teamId)
    local n = 0
    for _, m in ipairs(match.teams[teamId] or {}) do
        if m.key and not match.dead[m.key] then n = n + 1 end
    end
    return n
end

-- Everyone back on their feet, on full health, on their own spawns. This is
-- what starts each round: a death costs your team the round, and then the
-- slate is wiped clean for the next one.
local function respawnEveryone(match, announce)
    local arena = Arenas[match.arenaId]
    if not arena then
        dbg('respawnEveryone: arena %s is gone', tostring(match.arenaId))
        return
    end

    match.dead = {}
    local sent, skipped = 0, 0

    for teamId, team in pairs(match.teams) do
        local points = (arena.spawns or {})[teamId] or {}

        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) and #points > 0 then
                local o = Occupants[m.src]
                if not o or o.key ~= match.key then
                    skipped = skipped + 1
                    dbg('respawnEveryone: skipping %s -- not in this instance',
                        GetPlayerName(m.src))
                end
                if o and o.key == match.key then
                    sent = sent + 1
                    TriggerClientEvent('naija-arena:client:respawn', m.src, {
                        spawn = points[math.random(#points)],
                        team = teamId,
                        weapons = match.weapons,
                        items = match.items,
                        protection = Config.Match.roundStartProtection or 3,
                        roundStart = announce and match.round or nil
                    })
                end
            end
        end
    end

    dbg('respawnEveryone: %s respawn(s) sent, %s skipped', sent, skipped)
end

-- ── respawn ──
local function scheduleRespawn(match, arenaId, src, key, teamId, slot)
    local delay = Config.Match.respawnDelay or 5

    -- No clamping needed any more. The revive happens inside the respawn's
    -- own black screen rather than on a timer that has to finish first, so
    -- this delay is purely how long the player lies there before it starts.

    -- The client does nothing with this beyond showing the card. Reviving and
    -- healing happen inside the respawn's black screen, not here.
    TriggerClientEvent('naija-arena:client:died', src, {
        seconds = delay
    })

    SetTimeout(delay * 1000, function()
        -- The match may have finished while they were down.
        if not match.key or Matches[match.key] ~= match then return end
        if not GetPlayerName(src) then return end

        local o = Occupants[src]
        if not o or o.key ~= match.key then return end

        local arena = Arenas[arenaId]
        local points = arena and (arena.spawns or {})[teamId] or {}
        if #points == 0 then return end

        local point = points[math.random(#points)]

        match.dead[key] = nil

        TriggerClientEvent('naija-arena:client:respawn', src, {
            spawn = point,
            team = teamId,
            weapons = match.weapons,
            protection = Config.Match.spawnProtection or 3
        })

        pushScore(match)
    end)
end

-- ── a kill ──
RegisterNetEvent('naija-arena:server:reportKill', function(killerServerId, cause)
    local victim = source
    local match, arenaId, slot, mKey = matchOf(victim)
    if not match or match.phase ~= 'live' then return end

    local vKey = playerKey(victim)
    if not vKey then return end

    local vTeam, vEntry = teamOf(match, vKey)
    if not vTeam then return end

    -- Already counted. Death can fire more than once for a single kill.
    if match.dead[vKey] then return end
    match.dead[vKey] = true

    match.deaths[vKey] = (match.deaths[vKey] or 0) + 1

    local killerKey, killerName, killerTeam

    if killerServerId and killerServerId > 0 and killerServerId ~= victim then
        -- The killer has to be in the SAME instance. Two matches can run at
        -- identical coordinates in different buckets, so an arena id alone is
        -- no longer enough to say they were in the same fight.
        local kOcc = Occupants[killerServerId]
        local kKey = (kOcc and kOcc.key == mKey) and playerKey(killerServerId) or nil

        if kKey then
            local kTeam = teamOf(match, kKey)
            if kTeam then
                killerKey, killerTeam = kKey, kTeam
                killerName = nameOf(killerServerId)
            end
        end
    end

    local rounds = (Config.Match.scoring or 'rounds') == 'rounds'
    local scoringTeam

    if killerKey and killerTeam ~= vTeam then
        -- A clean kill. Always credited to the player for the leaderboard.
        match.kills[killerKey] = (match.kills[killerKey] or 0) + 1
        scoringTeam = killerTeam
    elseif killerKey and killerTeam == vTeam then
        -- Team kill. The victim's own side loses the point rather than the
        -- other team being handed one they didn't earn.
        scoringTeam = nil
        if not rounds then
            match.scores[vTeam] = math.max(0, match.scores[vTeam] - 1)
        end
    elseif not Config.Match.worldDeathScoresNothing then
        scoringTeam = vTeam == 'A' and 'B' or 'A'
    end

    -- In ROUNDS mode a kill is not a point. The point comes from wiping the
    -- team, awarded further down. Scoring here as well was giving two points
    -- per kill -- in a 1v1, where one kill also wipes the team, every single
    -- kill counted twice.
    if scoringTeam and not rounds then
        match.scores[scoringTeam] = match.scores[scoringTeam] + 1
    end

    pushScore(match, {
        feed = {
            killer = killerName,
            victim = nameOf(victim) or (vEntry and vEntry.name),
            team = killerTeam,
            teamkill = killerKey and killerTeam == vTeam or false,
            cause = cause
        }
    })

    dbg('%s killed by %s (%s) -- %s %s : %s %s',
        GetPlayerName(victim) or vKey, killerName or 'the world',
        cause or 'shot', 'A', match.scores.A, 'B', match.scores.B)

    -- ── ROUNDS: a round ends when a whole team is down ──
    if rounds then
        local left = aliveOn(match, vTeam)

        if left > 0 then
            -- Team still has people up. The dead player stays out until the
            -- round is decided -- that is the point of the format.
            TriggerClientEvent('naija-arena:client:downed', victim, {
                teammatesLeft = left,
                team = vTeam
            })
            return
        end

        -- Whole team wiped. The other side takes the round.
        local roundWinner = vTeam == 'A' and 'B' or 'A'
        match.scores[roundWinner] = match.scores[roundWinner] + 1

        local target = match.score or 7

        if match.scores[roundWinner] >= target then
            endMatch(mKey, roundWinner, 'score')
            return
        end

        match.round = (match.round or 1) + 1

        pushScore(match, {
            roundOver = {
                winner = roundWinner,
                round = (match.round or 2) - 1,
                winsA = match.scores.A,
                winsB = match.scores.B,
                needed = target,
                nextIn = Config.Match.roundBreak or 6
            }
        })

        dbg('Round to team %s (%s-%s), round %s next',
            roundWinner, match.scores.A, match.scores.B, match.round)

        SetTimeout((Config.Match.roundBreak or 6) * 1000, function()
            if not match.key or Matches[match.key] ~= match then
                dbg('Round break finished but the match is gone -- no respawn sent')
                return
            end
            if match.phase ~= 'live' then
                dbg('Round break finished but the match is not live -- no respawn sent')
                return
            end

            dbg('Round break over, respawning everyone for round %s', match.round)
            respawnEveryone(match, true)
            pushScore(match, { roundStart = match.round })
        end)

        return
    end

    -- ── KILLS: straight deathmatch, the dead are back in a few seconds ──
    if scoringTeam and match.scores[scoringTeam] >= match.score then
        match.roundWins = match.roundWins or { A = 0, B = 0 }
        match.roundWins[scoringTeam] = match.roundWins[scoringTeam] + 1

        local needed = match.rounds or 1

        if match.roundWins[scoringTeam] >= needed then
            endMatch(mKey, scoringTeam, 'score')
            return
        end

        match.round = (match.round or 1) + 1
        match.scores = { A = 0, B = 0 }

        pushScore(match, {
            roundOver = {
                winner = scoringTeam,
                round = match.round - 1,
                winsA = match.roundWins.A,
                winsB = match.roundWins.B,
                needed = needed,
                nextIn = Config.Match.roundBreak or 6
            }
        })

        SetTimeout((Config.Match.roundBreak or 6) * 1000, function()
            if not match.key or Matches[match.key] ~= match then return end
            if match.phase ~= 'live' then return end
            respawnEveryone(match, true)
            pushScore(match, { roundStart = match.round })
        end)

        return
    end

    scheduleRespawn(match, arenaId, victim, vKey, vTeam, slot)
end)

--- War points for a finished match, from config.
---
--- Written as a function because the inline version -- a chain of and/or --
--- returns the win value on a loss: `false and X or 100` is 100, not the
--- loss value. Easy to write, hard to spot, wrong every single time somebody
--- lost a match.
local function matchPoints(won, kills)
    local p = Config.Match.points or {}
    local base = won and (p.win or 100) or (p.loss or 25)
    return base + (kills * (p.perKill or 10))
end

-- ── the end ──
local function writeStats(match, winner)
    local players = {}

    for teamId, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            if not m.dummy and m.key then
                local won = (teamId == winner)
                local kills = match.kills[m.key] or 0
                local deaths = match.deaths[m.key] or 0

                players[#players + 1] = {
                    name = m.name, team = teamId, kills = kills, deaths = deaths, won = won
                }

                MySQL.update.await([[
                    INSERT INTO tenx_arena_stats (identifier, name, wins, losses, kills, deaths, matches, points)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    ON DUPLICATE KEY UPDATE
                        name = VALUES(name),
                        wins = wins + VALUES(wins),
                        losses = losses + VALUES(losses),
                        kills = kills + VALUES(kills),
                        deaths = deaths + VALUES(deaths),
                        matches = matches + 1,
                        points = points + VALUES(points)
                ]], {
                    m.key, m.name,
                    won and 1 or 0,
                    won and 0 or 1,
                    kills, deaths,
                    matchPoints(won, kills)
                })

                -- Coins for the match, spent in the shop.
                -- Ranked pays its own, higher rate. Winning a rated game is
                -- worth more than winning a friendly and should feel like it.
                local pay = Config.Match.coins
                local bonus = match.ranked and Config.Ranked.coins or nil

                if pay and RzGiveCoins then
                    local earned = (kills * (pay.perKill or 0))
                                 + (won and (pay.win or 0) or (pay.loss or 0))
                                 + (bonus and (won and (bonus.win or 0) or (bonus.loss or 0)) or 0)

                    if earned > 0 then
                        RzGiveCoins(m.key, earned, won and 'match:win' or 'match:loss')

                        if m.src and GetPlayerName(m.src) then
                            TriggerClientEvent('naija-arena:client:coinsEarned', m.src, {
                                amount = earned,
                                reason = (match.ranked and 'Ranked ' or '')
                                    .. (won and 'match won' or 'match played'),
                                balance = RzCoins(m.key)
                            })

                            -- Straight into their grid, so the coins are
                            -- there when they look rather than next time
                            -- something happens to refresh it.
                            if RzSyncToMatch then RzSyncToMatch(m.src, m.key) end
                        end
                    end
                end
            end
        end
    end

    local arena = Arenas[match.arenaId]
    MySQL.insert.await(
        'INSERT INTO tenx_arena_matches (arena_id, arena_name, mode, score_a, score_b, winner, players, duration) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { match.arenaId, arena and arena.name, match.mode,
          match.scores.A, match.scores.B, winner,
          json.encode(players), os.time() - (match.startedAt or os.time()) })
end

function endMatch(matchKeyOrArena, winner, reason)
    -- Accepts either an instance key or a bare arena id, so older call sites
    -- keep working.
    local match = Matches[matchKeyOrArena]

    if not match then
        for k, m in pairs(Matches) do
            if m.arenaId == matchKeyOrArena then match = m break end
        end
    end

    if not match or match.phase == 'over' then return end

    match.phase = 'over'
    -- The boundary goes with the match.
    --
    -- Released only when the LAST instance of this arena finishes. Several
    -- matches can run in the same arena in different buckets, and releasing on
    -- the first one to end would drop the walls on the others.
    if ZoneLink and match.arenaId then
        local stillRunning = false
        for k, m in pairs(Matches) do
            if k ~= (match.key or matchKeyOrArena) and m.arenaId == match.arenaId then
                stillRunning = true
                break
            end
        end

        if stillRunning then
            -- Just this instance's bucket.
            if match.slot then
                ZoneLink.call('UnbindZoneFromBucket',
                    ZoneLink.zoneIdFor(match.arenaId),
                    bucketFor(match.arenaId, match.slot))
            end
        else
            ZoneLink.releaseMatch(match.arenaId)
        end
    end

    Matches[match.key or matchKeyOrArena] = nil

    -- The room that made this match is spent. Clearing it means everyone can
    -- make or join a new one straight away instead of being stuck in a lobby
    -- for a match that already finished.
    if match.roomCode and Rooms and Rooms[match.roomCode] then
        local room = Rooms[match.roomCode]

        -- Tell them it is gone.
        --
        -- Clearing it server-side without saying so left every player's panel
        -- showing a room that no longer existed -- the rail said "In Q53U"
        -- and every button came back "You are not in a room."
        for _, k in ipairs(room.order) do
            local m = room.members[k]
            if m and m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:room', m.src, nil, freeArenas())
            end
            RoomOf[k] = nil
        end

        Rooms[match.roomCode] = nil
    end

    -- Settle any pot before the stats, so a payout notification lands with
    -- the result rather than after it.
    if WagerSettle then WagerSettle(matchKeyOrArena, match, winner) end

    writeStats(match, winner)

    -- Ranked is scored separately, and only for the modes that count.
    if RankedRecord then
        CreateThread(function() RankedRecord(match, winner) end)
    end

    local roster = rosterPayload(match)

    for teamId, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                TriggerClientEvent('naija-arena:client:matchEnd', m.src, {
                    winner = winner,
                    won = teamId == winner,
                    scoreA = (match.rounds or 1) > 1 and (match.roundWins or {}).A or match.scores.A,
                    scoreB = (match.rounds or 1) > 1 and (match.roundWins or {}).B or match.scores.B,
                    rounds = match.rounds or 1,
                    reason = reason,
                    roster = roster,
                    seconds = Config.Match.endDelay or 10
                })
            end
        end
    end

    -- The board changes the moment stats are written, so refresh it now
    -- rather than waiting for the timer.
    if PushBillboard then
        CreateThread(function() Wait(1000) PushBillboard() end)
    end

    dbg('Match in arena %s instance %s over: team %s won %s-%s (%s)',
        match.arenaId, match.slot or 1, winner or 'nobody',
        match.scores.A, match.scores.B, reason or 'score')

    -- Send everyone home once they've seen the result.
    SetTimeout((Config.Match.endDelay or 10) * 1000, function()
        local lobby = Config.Meeting.returnToLobbyAfterMatch ~= false
        local c = Config.Meeting.coords

        for _, team in pairs(match.teams) do
            for _, m in ipairs(team) do
                if m.src and GetPlayerName(m.src) then
                    Player(m.src).state:set('arenaMatch', false, true)

                    -- Back to the lobby, not the city. They came to fight, so
                    -- put them where the next match starts.
                    if lobby then
                        removeFromArena(m.src, { x = c.x, y = c.y, z = c.z, w = c.w })
                        ReturnToLobby(m.src)
                    else
                        removeFromArena(m.src)
                    end
                end
            end
        end
        if pushPanel then pushPanel() end
    end)
end

-- Time limit, if one is set.
CreateThread(function()
    while true do
        Wait(5000)
        local limit = Config.Match.timeLimit or 0
        if limit > 0 then
            for key, match in pairs(Matches) do
                if match.phase == 'live' and (os.time() - (match.startedAt or os.time())) >= limit then
                    local winner
                    if match.scores.A > match.scores.B then winner = 'A'
                    elseif match.scores.B > match.scores.A then winner = 'B' end
                    endMatch(key, winner, 'time')
                end
            end
        end
    end
end)

-- Someone leaving mid-match forfeits for their side if it empties them out.
AddEventHandler('playerDropped', function()
    local src = source
    local match, arenaId, slot, mKey = matchOf(src)
    if not match or match.phase ~= 'live' then return end

    local key = playerKey(src)
    if not key then return end

    local team = teamOf(match, key)
    if not team then return end

    local left = 0
    for _, m in ipairs(match.teams[team]) do
        if m.src and m.src ~= src and GetPlayerName(m.src) then left = left + 1 end
    end

    if left == 0 then
        endMatch(mKey, team == 'A' and 'B' or 'A', 'forfeit')
    else
        pushScore(match)
    end
end)

-- ============================================================
--  ROOMS
-- ============================================================
-- A room is a lobby the host controls: weapons, items, rounds, kills, public
-- or private, and a start button. No matchmaking to wait on -- which is also
-- what makes the dummies usable, since there is now something to press.

Rooms = {}       -- [code] = room, declared at the top of the file
RoomOf = {}      -- [license] = code

local function roomCode()
    local chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    for _ = 1, 60 do
        local code = ''
        for _ = 1, (Config.Rooms.codeLength or 4) do
            local i = math.random(#chars)
            code = code .. chars:sub(i, i)
        end
        if not Rooms[code] then return code end
    end
    return tostring(math.random(1000, 9999))
end

local function roomMode(room)
    return modeById(room.mode)
end

-- Which side has room, so joiners are spread instead of piling onto one team.
local function lightestTeam(room)
    local a, b = 0, 0
    for _, m in pairs(room.members) do
        if m.team == 'A' then a = a + 1 else b = b + 1 end
    end
    if a <= b then return 'A' end
    return 'B'
end

local function roomPublic(room, viewerKey)
    if not room then return nil end

    local mode = roomMode(room)
    local members = {}

    for _, key in ipairs(room.order) do
        local m = room.members[key]
        if m then
            members[#members + 1] = {
                key = key,
                name = m.name,
                id = m.src,
                team = m.team,
                host = key == room.host,
                dummy = m.dummy or false
            }
        end
    end

    local a, b = 0, 0
    for _, m in ipairs(members) do
        if m.team == 'A' then a = a + 1 else b = b + 1 end
    end

    return {
        code = room.code,
        name = room.name,
        mode = room.mode,
        modeLabel = mode.label,
        perTeam = mode.perTeam,
        private = room.private,
        weapons = room.weapons,
        items = room.items,
        rounds = room.rounds,
        wager = room.wager or 0,
        kills = room.kills,
        arenaId = room.arenaId,
        members = members,
        countA = a,
        countB = b,
        size = #members,
        isHost = viewerKey ~= nil and viewerKey == room.host,
        canStart = #members >= (Config.Rooms.minPlayers or 2)
            and (Config.Rooms.allowUneven or (a == mode.perTeam and b == mode.perTeam))
            and a > 0 and b > 0
    }
end

local function refreshRoom(room)
    if not room then return end

    -- The arena list rides along, because the room panel lets you pick where
    -- you will fight -- and a push without it emptied the picker every time
    -- anything else in the room changed.
    local arenas = freeArenas()

    for _, key in ipairs(room.order) do
        local m = room.members[key]
        if m and m.src and GetPlayerName(m.src) then
            TriggerClientEvent('naija-arena:client:room', m.src, roomPublic(room, key), arenas)
        end
    end
end

local function leaveRoom(src, silent)
    local key = playerKey(src)
    local code = key and RoomOf[key]
    if not code then return false, 'You are not in a room.' end

    local room = Rooms[code]
    RoomOf[key] = nil
    if not room then return true, '' end

    room.members[key] = nil
    for i, k in ipairs(room.order) do
        if k == key then table.remove(room.order, i) break end
    end

    if room.host == key then
        -- Hand it to the next real player. A dummy cannot host.
        room.host = nil
        for _, k in ipairs(room.order) do
            if room.members[k] and not room.members[k].dummy then
                room.host = k
                break
            end
        end
    end

    if not room.host or #room.order == 0 then
        -- Nobody left who can run it. Clear any dummies with it.
        for _, k in ipairs(room.order) do
            RoomOf[k] = nil
        end
        Rooms[code] = nil
    else
        refreshRoom(room)
    end

    if GetPlayerName(src) then
        TriggerClientEvent('naija-arena:client:room', src, nil)
    end

    return true, silent and '' or 'You left the room.'
end

local function publicRooms()
    local out = {}
    for _, room in pairs(Rooms) do
        if not room.private and not room.started then
            local mode = roomMode(room)
            out[#out + 1] = {
                code = room.code,
                name = room.name,
                mode = room.mode,
                modeLabel = mode.label,
                size = #room.order,
                capacity = mode.perTeam * 2,
                rounds = room.rounds,
                kills = room.kills,
                host = (room.members[room.host] or {}).name or 'Unknown'
            }
        end
    end

    table.sort(out, function(x, y) return x.size > y.size end)

    local cap = Config.Rooms.maxPublic or 24
    while #out > cap do table.remove(out) end

    return out
end

-- ── starting a room ──
-- No queue, no ready check: the host presses start and everyone goes. This is
-- also the thing that makes dummies usable, since matchmaking could never
-- form a match out of them.
local function startRoom(src, room)
    local mode = roomMode(room)
    local pub = roomPublic(room, room.host)

    if not pub.canStart then
        return false, 'You need players on both sides first.'
    end

    -- Everyone has to be able to cover the stake before anyone moves. Told
    -- here, by name, rather than the match silently refusing to start.
    if WagerCheck then
        local canPay, why = WagerCheck(room)
        if not canPay then return false, why end
    end

    -- A free arena to put them in.
    local free = freeArenas()
    if #free == 0 then
        return false, 'No arena is free right now.'
    end

    local arenaId = room.arenaId
    local valid = false
    for _, a in ipairs(free) do
        if a.id == arenaId then valid = true break end
    end
    if not valid then
        arenaId = free[math.random(#free)].id
    end

    local arena = Arenas[arenaId]
    if not arena then return false, 'That arena is no longer available.' end

    -- Claim a free instance of it. Several matches can share one arena, each
    -- in its own bucket, so a busy arena is only busy when every instance is.
    local slot = freeSlot(arenaId)
    if not slot then
        return false, 'Every instance of that arena is in use.'
    end

    local teams = { A = {}, B = {} }
    for _, key in ipairs(room.order) do
        local m = room.members[key]
        if m then
            local side = m.team == 'B' and 'B' or 'A'
            teams[side][#teams[side] + 1] = {
                key = key, name = m.name, src = m.src, dummy = m.dummy
            }
        end
    end

    local match = {
        arenaId = arenaId,
        slot = slot,
        key = matchKey(arenaId, slot),
        roomCode = room.code,
        mode = room.mode,
        scoring = Config.Match.scoring or 'rounds',
        -- In 'rounds' this is rounds to win the match; in 'kills' it is kills
        -- to win a round.
        score = room.kills,
        rounds = room.rounds,
        roundWins = { A = 0, B = 0 },
        round = 1,
        scores = { A = 0, B = 0 },
        kills = {}, deaths = {}, dead = {},
        teams = teams,
        weapons = room.weapons,
        items = room.items,
        startedAt = os.time(),
        phase = 'live'
    }

    -- Take the stakes before anyone is moved. If somebody cannot cover it,
    -- the match does not start at all -- better than teleporting six people
    -- into an arena and then calling it off.
    if WagerCollect and not WagerCollect(match.key, match, room) then
        for _, k in ipairs(room.order) do
            local rm = room.members[k]
            if rm and rm.src and GetPlayerName(rm.src) then
                notify(rm.src, 'Someone could not cover the stake. Nothing was taken.', 'error')
            end
        end
        return
    end

    Matches[match.key] = match
    room.started = true

    -- Make sure everyone's stored name is current before the match writes
    -- stats against it.
    CreateThread(function()
        for _, team in pairs(teams) do
            for _, m in ipairs(team) do
                if m.src and not m.dummy then refreshStoredName(m.src) end
            end
        end
    end)

    local roster = {}
    for teamId, team in pairs(teams) do
        for _, m in ipairs(team) do
            roster[#roster + 1] = { id = m.src, name = m.name, team = teamId, dummy = m.dummy }
        end
    end

    for teamId, team in pairs(teams) do
        for _, m in ipairs(team) do
            if m.src and GetPlayerName(m.src) then
                -- Same as the queue path: out of the lobby in the table AND
                -- in the statebag, or the client keeps applying lobby rules
                -- to somebody in a match.
                InLobby[m.src] = nil
                Player(m.src).state:set('arenaLobby', false, true)

                Player(m.src).state:set('arenaMatch', true, true)
                Player(m.src).state:set('arenaTeam', teamId, true)

                sendToArena(m.src, arenaId, teamId, false, slot)

                if Config.MatchInventory and Config.MatchInventory.enabled
                   and buildMatchInventory then
                    buildMatchInventory(m.src, match)
                end

                TriggerClientEvent('naija-arena:client:matchBegin', m.src, {
                    arena = arena.name,
                    mode = match.mode,
                    score = match.score,
                    rounds = match.rounds,
                    scoring = match.scoring,
                    round = 1,
                    team = teamId,
                    weapons = match.weapons,
                    items = match.items,
                    roster = roster
                })
            end
        end
    end

    dbg('Room %s started in arena %s instance %s (%s, first to %s, best of %s)',
        room.code, arenaId, slot, match.mode, match.score, match.rounds)

    if pushPanel then pushPanel() end
    return true, ('Match started in %s.'):format(arena.name)
end

-- ── the room API ──
lib.callback.register('naija-arena:server:room', function(src, name, data)
    data = data or {}
    local key = playerKey(src)
    if not key then return { ok = false, message = 'Could not identify you.' } end

    local room = RoomOf[key] and Rooms[RoomOf[key]] or nil
    local isHost = room and room.host == key

    if name == 'state' then
        return { ok = true, room = roomPublic(room, key), rooms = publicRooms() }
    end

    if name == 'browse' then
        return { ok = true, rooms = publicRooms() }
    end

    if name == 'create' then
        if room then return { ok = false, message = 'Leave your room first.' } end

        local mode = modeById(data.mode or Config.DefaultMode)
        local code = roomCode()

        local items = {}
        for _, it in ipairs(Config.PickableItems or {}) do
            items[it.id] = it.default or 0
        end

        Rooms[code] = {
            code = code,
            name = (data.name ~= '' and data.name) or ('Room of %s'):format(nameOf(src)),
            host = key,
            mode = mode.id,
            private = data.private and true or (Config.Rooms.defaultPrivate and true or false),
            rounds = Config.Match.defaultRounds or 1,
            kills = Config.Match.defaultScore or 7,
            weapons = {
                primary = (Config.DefaultRoomWeapons or {}).primary
                          or defaultWeapon('primary'),
                sidearm = (Config.DefaultRoomWeapons or {}).sidearm
                          or defaultWeapon('sidearm')
            },
            items = items,
            members = { [key] = { name = nameOf(src), src = src, team = 'A' } },
            order = { key },
            started = false
        }

        RoomOf[key] = code
        refreshRoom(Rooms[code])
        return { ok = true, room = roomPublic(Rooms[code], key), rooms = publicRooms(),
                 message = ('Room %s created.'):format(code) }
    end

    if name == 'join' then
        if room then return { ok = false, message = 'Leave your room first.' } end

        local target = Rooms[(data.code or ''):upper()]
        if not target then return { ok = false, message = 'No room with that code.' } end
        if target.started then return { ok = false, message = 'That match has already started.' } end

        local mode = roomMode(target)
        if #target.order >= (mode.perTeam * 2) then
            return { ok = false, message = 'That room is full.' }
        end

        target.members[key] = {
            name = nameOf(src), src = src,
            team = Config.Rooms.autoBalance and lightestTeam(target) or 'A'
        }
        target.order[#target.order + 1] = key
        RoomOf[key] = target.code

        refreshRoom(target)
        return { ok = true, room = roomPublic(target, key), message = ('Joined %s.'):format(target.code) }
    end

    if name == 'leave' then
        local ok, msg = leaveRoom(src)
        return { ok = ok, room = nil, rooms = publicRooms(), message = msg }
    end

    -- ── host-only settings ──
    if not room then return { ok = false, message = 'You are not in a room.' } end

    if name ~= 'switchTeam' and name ~= 'invite' and not isHost then
        return { ok = false, message = 'Only the host can change that.' }
    end

    if name == 'setMode' then
        local mode = modeById(data.mode)
        room.mode = mode.id

        -- Shrinking the mode can leave the room over capacity.
        while #room.order > (mode.perTeam * 2) do
            local dropKey = room.order[#room.order]
            local dropped = room.members[dropKey]
            if dropped and dropped.src and not dropped.dummy then
                leaveRoom(dropped.src, true)
                notify(dropped.src, 'The room changed to a smaller mode and you were dropped.', 'error')
            else
                room.members[dropKey] = nil
                RoomOf[dropKey] = nil
                table.remove(room.order)
            end
        end

        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key), message = ('Mode set to %s.'):format(mode.label) }
    end

    if name == 'setWeapon' then
        local slot = data.slot == 'sidearm' and 'sidearm' or 'primary'

        -- "None" is stored as false rather than nil: nil removes the key
        -- entirely and the choice would quietly disappear on its way through
        -- JSON and the statebag.
        if data.weapon == 'none' or data.weapon == false or data.weapon == nil then
            room.weapons[slot] = false
        else
            room.weapons[slot] = data.weapon
        end

        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    if name == 'setItem' then
        local id = data.id
        local found
        for _, it in ipairs(Config.PickableItems or {}) do
            if it.id == id then found = it break end
        end
        if not found then return { ok = false, message = 'Unknown item.' } end

        room.items[id] = math.max(0, math.min(found.maxCharges or 3, tonumber(data.charges) or 0))
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    -- Both capped. math.max(1, ...) has no upper bound, so a first-to-9999
    -- was one crafted message away -- and a match nobody can finish is a
    -- match everybody leaves.
    if name == 'setRounds' then
        local most = Config.Match.maxRounds or 20
        room.rounds = math.max(1, math.min(most, math.floor(tonumber(data.rounds) or 1)))
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    if name == 'setKills' then
        room.kills = validScore(room.mode, data.kills, room.kills or 10)
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    if name == 'setWager' then
        if Config.Wager and Config.Wager.enabled == false then
            return { ok = false, message = 'Wagers are off on this server.' }
        end

        local want = math.floor(tonumber(data.wager) or 0)

        -- Only an amount from the list. A free-form number is a free-form
        -- way to stake a million.
        local allowed = false
        for _, a in ipairs((Config.Wager or {}).amounts or { 0 }) do
            if a == want then allowed = true break end
        end
        if not allowed then return { ok = false, message = 'Not a valid stake.' } end

        room.wager = want
        refreshRoom(room)

        return { ok = true, room = roomPublic(room, key),
                 message = want > 0
                    and ('Stake set to %s each.'):format(want)
                    or 'Wager off.' }
    end

    if name == 'setPrivate' then
        room.private = data.private and true or false
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key),
                 message = room.private and 'Room is private.' or 'Room is public.' }
    end

    if name == 'setArena' then
        room.arenaId = tonumber(data.arenaId)
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    if name == 'switchTeam' then
        local targetKey = data.key or key
        local m = room.members[targetKey]
        if not m then return { ok = false, message = 'Not in this room.' } end

        -- Move yourself freely; move others only as host.
        if targetKey ~= key and not isHost then
            return { ok = false, message = 'Only the host can move other people.' }
        end

        m.team = m.team == 'A' and 'B' or 'A'
        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key) }
    end

    if name == 'kick' then
        local targetKey = data.key
        local m = targetKey and room.members[targetKey]
        if not m then return { ok = false, message = 'Not in this room.' } end
        if targetKey == room.host then return { ok = false, message = 'You cannot remove yourself.' } end

        if m.dummy then
            room.members[targetKey] = nil
            RoomOf[targetKey] = nil
            for i, k in ipairs(room.order) do
                if k == targetKey then table.remove(room.order, i) break end
            end
        elseif m.src then
            leaveRoom(m.src, true)
            notify(m.src, 'The host removed you from the room.', 'error')
        end

        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key), message = 'Removed.' }
    end

    if name == 'invite' then
        local target = tonumber(data.player)
        if not target or not GetPlayerName(target) then
            return { ok = false, message = 'They are not online.' }
        end

        local tKey = playerKey(target)
        if not tKey then return { ok = false, message = 'Could not identify them.' } end
        if RoomOf[tKey] then return { ok = false, message = 'They are already in a room.' } end

        local mode = roomMode(room)
        if #room.order >= (mode.perTeam * 2) then
            return { ok = false, message = 'The room is full.' }
        end

        TriggerClientEvent('naija-arena:client:invite', target, {
            code = room.code,
            from = nameOf(src),
            mode = mode.label,
            room = true,
            seconds = Config.Party.inviteTimeout or 30
        })

        return { ok = true, message = ('Invite sent to %s.'):format(GetPlayerName(target)) }
    end

    -- ── dummies ──
    if name == 'addDummy' then
        if not Config.TestMode.enabled or not hasPermission(src) then
            return { ok = false, message = 'Test mode is off.' }
        end

        local mode = roomMode(room)
        if #room.order >= (mode.perTeam * 2) then
            return { ok = false, message = 'The room is full.' }
        end

        local n = 0
        for _ in pairs(room.members) do n = n + 1 end

        local dKey = ('dummy:%s'):format(math.random(100000, 999999))
        local dName = ('%s %s'):format(Config.TestMode.namePrefix or 'DUMMY', n)

        room.members[dKey] = {
            name = dName, src = nil, dummy = true,
            team = data.team or lightestTeam(room)
        }
        room.order[#room.order + 1] = dKey
        RoomOf[dKey] = room.code

        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key), message = ('%s added.'):format(dName) }
    end

    if name == 'fillDummies' then
        if not Config.TestMode.enabled or not hasPermission(src) then
            return { ok = false, message = 'Test mode is off.' }
        end

        local mode = roomMode(room)
        local added = 0

        while #room.order < (mode.perTeam * 2) do
            local n = 0
            for _ in pairs(room.members) do n = n + 1 end

            local dKey = ('dummy:%s'):format(math.random(100000, 999999))
            local dName = ('%s %s'):format(Config.TestMode.namePrefix or 'DUMMY', n)

            room.members[dKey] = { name = dName, src = nil, dummy = true, team = lightestTeam(room) }
            room.order[#room.order + 1] = dKey
            RoomOf[dKey] = room.code
            added = added + 1

            if added > 20 then break end
        end

        refreshRoom(room)
        return { ok = true, room = roomPublic(room, key),
                 message = ('Filled with %s dummies. Press start when ready.'):format(added) }
    end

    if name == 'start' then
        local ok, msg = startRoom(src, room)
        return { ok = ok, message = msg }
    end

    return { ok = false, message = 'Unknown action.' }
end)

RegisterNetEvent('naija-arena:server:acceptRoomInvite', function(code)
    local src = source
    local key = playerKey(src)
    if not key or RoomOf[key] then return end

    local room = Rooms[(code or ''):upper()]
    if not room then return notify(src, 'That room no longer exists.', 'error') end
    if room.started then return notify(src, 'That match already started.', 'error') end

    local mode = roomMode(room)
    if #room.order >= (mode.perTeam * 2) then
        return notify(src, 'That room filled up.', 'error')
    end

    room.members[key] = {
        name = nameOf(src), src = src,
        team = Config.Rooms.autoBalance and lightestTeam(room) or 'A'
    }
    room.order[#room.order + 1] = key
    RoomOf[key] = room.code

    refreshRoom(room)
    notify(src, ('Joined %s.'):format(room.code), 'success')
end)

AddEventHandler('playerDropped', function()
    local src = source
    local key = playerKey(src)
    if key and RoomOf[key] then leaveRoom(src, true) end
end)

-- ============================================================
--  THE MATCH INVENTORY
-- ============================================================
-- Server owns it. The client sends intent -- "move slot 3 to slot 7", "use
-- slot 2" -- and every one of those is validated here before anything moves.
-- A client that lies gets told no and re-synced with the truth.
--
-- Nothing here touches ox_inventory or a player's real belongings. The match
-- inventory is built fresh at the start and thrown away at the end, so there
-- is nothing that can be lost.

local Inv = {}   -- [src] = { [slot] = { name, count } }

--- How many of an item fit in one slot. 0 in config means unlimited, which
--- we express as a very large number rather than sprinkling "if stack == 0"
--- through every caller.
local function stackLimit(def)
    local n = (def or {}).stack
    if n == nil then return 1 end
    if n <= 0 then return math.huge end
    return n
end

local function itemDef(name)
    return (Config.Items or {})[name]
end

local function slotWeight(entry)
    if not entry then return 0 end
    local def = itemDef(entry.name)
    return (def and def.weight or 0) * (entry.count or 1)
end

local function invWeight(src)
    local total = 0
    for _, entry in pairs(Inv[src] or {}) do
        total = total + slotWeight(entry)
    end
    return total
end

local function invPayload(src)
    local cfg = Config.MatchInventory
    local slots = {}

    for i = 1, (cfg.slots or 20) do
        local entry = (Inv[src] or {})[i]
        if entry then
            local def = itemDef(entry.name) or {}
            slots[#slots + 1] = {
                slot = i,
                name = entry.name,
                count = entry.count,
                label = def.label or entry.name,
                image = def.image or entry.name,
                weight = slotWeight(entry),
                usable = def.usable or false,
                weapon = def.weapon or false,
                stack = def.stack or 1,
                unlimited = (def.stack or 1) <= 0
            }
        end
    end

    return {
        slots = slots,
        total = cfg.slots or 20,
        columns = cfg.columns or 5,
        hotbar = cfg.hotbarSlots or 5,
        weight = invWeight(src),
        maxWeight = cfg.maxWeight or 30000,
        oxPath = Config.OxImagePath,

        -- Whether this is a LOBBY kit, decided here rather than on the client.
        --
        -- The lobby hands weapons out with no ammunition, and the client used
        -- to work out for itself whether it was in the lobby by reading
        -- replicated state. That is a guess about something the server
        -- already knows for certain, and when the guess was wrong -- a flag
        -- that had not arrived, or one that never cleared -- a player spawned
        -- into a real match with an empty gun while everyone else was fine.
        --
        -- These two tables are the truth and they are read in the same tick
        -- as the grid is built, so the answer cannot disagree with the
        -- inventory it arrives with.
        -- isFighting is a local declared further down this file and is NOT
        -- in scope here -- calling it would read a nil global and error. The
        -- same question, asked of things that are in scope: InLobby and
        -- Occupants are both declared at the top, and ClaimedByOther is a
        -- global so it resolves at call time.
        lobby = (InLobby[src]
                 and not Occupants[src]
                 and not (ClaimedByOther and ClaimedByOther(src)))
                and true or false
    }
end

local function pushInv(src)
    if not GetPlayerName(src) then return end
    TriggerClientEvent('naija-arena:client:inventory', src, invPayload(src))
end

-- First free slot that this item can go into, merging into a partial stack
-- before taking a new slot.
local function findSlotFor(src, name, count)
    local cfg = Config.MatchInventory
    local def = itemDef(name) or {}
    local stack = stackLimit(def)
    local inv = Inv[src] or {}

    if stack > 1 then
        for i = 1, (cfg.slots or 20) do
            local e = inv[i]
            if e and e.name == name and (e.count + count) <= stack then
                return i, true
            end
        end
    end

    for i = 1, (cfg.slots or 20) do
        if not inv[i] then return i, false end
    end

    return nil
end

local function addItem(src, name, count)
    if not itemDef(name) then return false, 'Unknown item.' end

    count = count or 1
    Inv[src] = Inv[src] or {}

    local cfg = Config.MatchInventory
    local wouldWeigh = invWeight(src) + ((itemDef(name).weight or 0) * count)

    if wouldWeigh > (cfg.maxWeight or 30000) then
        return false, 'Too heavy to carry.'
    end

    local slot, merged = findSlotFor(src, name, count)
    if not slot then return false, 'No room.' end

    if merged then
        Inv[src][slot].count = Inv[src][slot].count + count
    else
        Inv[src][slot] = { name = name, count = count }
    end

    return true
end

-- Build the inventory a match starts you with.
function buildMatchInventory(src, match)
    -- Your own kit, if the server is set that way.
    --
    -- The same weapon costing coins in the shop and being free in a match
    -- made the shop pointless for anyone who only played matches. One
    -- inventory, everywhere.
    if Config.OwnWeapons and not match.rzLoadout then
        local key = playerKey(src)

        if key and RzSyncToMatch then
            -- The utilities the room picked still come as extras -- those are
            -- per-life supplies, not something you own.
            --
            -- Merged into stacks you already have wherever possible, so a bag
            -- you arranged deliberately comes back arranged. Only genuinely
            -- new items take a free slot, and they take the LAST one rather
            -- than the first, which leaves the front of the grid -- where the
            -- hotbar keys are -- exactly as you left it.
            for _, it in ipairs(Config.PickableItems or {}) do
                local charges = (match.items or {})[it.id] or 0
                if charges > 0 and itemDef(it.id) then
                    RzAddItem(key, it.id, charges, true)
                end
            end

            -- Nothing to fight with? The same starter the shop gives, so
            -- nobody is stuck watching.
            if not RzHasWeapon(key) and Config.Kit.starterWeapon then
                RzAddItem(key, Config.Kit.starterWeapon, 1)
            end

            RzSyncToMatch(src, key)
            return
        end
    end

    Inv[src] = {}

    local cfg = Config.MatchInventory
    local hotbar = cfg.hotbarSlots or 5
    local slot = 1

    -- Two shapes of loadout arrive here. A match carries weapons as a
    -- primary/sidearm pair; the shop carries a plain list. Rather than a
    -- second inventory system, both are flattened to the same thing.
    if match.rzLoadout then
        for _, w in ipairs(match.rzLoadout.weapons or {}) do
            if itemDef(w.name) and slot <= hotbar then
                Inv[src][slot] = { name = w.name, count = 1 }
                slot = slot + 1
            end
        end

        for _, it in ipairs(match.rzLoadout.items or {}) do
            if itemDef(it.name) then
                if slot <= hotbar then
                    Inv[src][slot] = { name = it.name, count = it.count or 1 }
                    slot = slot + 1
                else
                    addItem(src, it.name, it.count or 1)
                end
            end
        end

        pushInv(src)
        return
    end

    -- Weapons first, into the hotbar slots, so keys 1 and 2 are your guns.
    for _, key in ipairs({ 'primary', 'sidearm' }) do
        local id = match.weapons and match.weapons[key]
        if id and id ~= false and id ~= 'none' and itemDef(id) then
            Inv[src][slot] = { name = id, count = 1 }
            slot = slot + 1
        end
    end

    -- Then the utilities the room picked, filling the rest of the hotbar.
    for _, it in ipairs(Config.PickableItems or {}) do
        local charges = (match.items or {})[it.id] or 0
        if charges > 0 and itemDef(it.id) then
            if slot <= hotbar then
                Inv[src][slot] = { name = it.id, count = charges }
                slot = slot + 1
            else
                addItem(src, it.id, charges)
            end
        end
    end

    -- Ammo, if the weapons take items rather than being infinite.
    if not Config.Weapons.infiniteAmmo then
        addItem(src, Config.DefaultAmmo and Config.DefaultAmmo.name or 'ammo-9',
                Config.DefaultAmmo and Config.DefaultAmmo.count or 120)
    end

    pushInv(src)
end

-- ── moving things around ──
-- Anyone actually fighting: in a match, or in a fight. Both use the same
-- grid, so both have to be allowed to move things around in it.
--- Is this player somewhere the grid should work?
---
--- A match of ours, or a mode another resource has claimed them for. The
--- second matters: every inventory action -- moving, splitting, using,
--- dropping -- checks this, so without it a player in someone else's mode
--- gets a grid they can look at and not touch.
local function isFighting(src)
    if Player(src).state.arenaMatch == true then return true end
    return ClaimedByOther and ClaimedByOther(src) or false
end

--- Move part of a stack into an empty slot. Splitting into an occupied slot
--- is a merge, which invMove already does -- this is only for taking some of
--- a pile and putting it somewhere on its own.
RegisterNetEvent('naija-arena:server:invSplit', function(from, to, amount)
    local src = source
    if not isFighting(src) and not InLobby[src] then return end

    from, to, amount = tonumber(from), tonumber(to), tonumber(amount)
    if not (from and to and amount) or amount < 1 then return end

    local inv = Inv[src]
    local a = inv and inv[from]
    if not a then return end

    -- Taking the whole pile is just a move.
    if amount >= a.count then
        return TriggerEvent('naija-arena:server:invMove', from, to)
    end

    local b = inv[to]

    if b then
        -- Into an occupied slot: only if it is the same item and there is
        -- room, otherwise the amount has nowhere to land.
        if b.name ~= a.name then return end

        local limit = stackLimit(itemDef(a.name))
        local room = limit - b.count
        if room <= 0 then return end

        local moved = math.min(amount, room)
        b.count = b.count + moved
        a.count = a.count - moved
    else
        inv[to] = { name = a.name, count = amount, dur = a.dur }
        a.count = a.count - amount
    end

    if a.count <= 0 then inv[from] = nil end

    pushInv(src)

    if InLobby[src] and not isFighting(src) and RzSyncFromMatch then
        RzSyncFromMatch(src)
    end

    TriggerClientEvent('naija-arena:client:invChanged', src)
end)

RegisterNetEvent('naija-arena:server:invMove', function(from, to)
    local src = source
    if not isFighting(src) and not InLobby[src] then return end

    local cfg = Config.MatchInventory
    local max = cfg.slots or 20

    from, to = tonumber(from), tonumber(to)
    if not from or not to or from == to then return end
    if from < 1 or from > max or to < 1 or to > max then return end

    local inv = Inv[src]
    if not inv or not inv[from] then return pushInv(src) end

    local a, b = inv[from], inv[to]

    if b and b.name == a.name then
        -- Same item: merge up to the stack limit, leave the rest behind.
        local stack = stackLimit(itemDef(a.name))
        local room = stack - b.count

        if room > 0 then
            local moved = math.min(room, a.count)
            b.count = b.count + moved
            a.count = a.count - moved
            if a.count <= 0 then inv[from] = nil end
        else
            inv[from], inv[to] = b, a
        end
    else
        -- Different items, or an empty slot: straight swap.
        inv[from], inv[to] = b, a
    end

    pushInv(src)

    -- In the lobby the grid IS your kept inventory, so a rearrange has to be
    -- written back or it snaps into place again next time you open it.
    if InLobby[src] and not isFighting(src) and RzSyncFromMatch then
        RzSyncFromMatch(src)
    end

    -- The hotbar mirrors the first slots, so rearranging the grid rearranges
    -- your keys -- which means the weapons in your hands may have changed.
    TriggerClientEvent('naija-arena:client:invChanged', src)
end)


RegisterNetEvent('naija-arena:server:invUse', function(slot)
    local src = source

    -- Rearranging in the lobby is fine; using things there is not -- there is
    -- nothing to heal from and no reason to burn a medkit standing about.
    -- Coins are the exception, and they are handled below.
    if not isFighting(src) and not InLobby[src] then return end

    slot = tonumber(slot)
    if not slot then return end

    local inv = Inv[src]
    local entry = inv and inv[slot]
    if not entry then return end

    local def = itemDef(entry.name) or {}

    -- Coins are not used. They ARE the balance -- the shop counts what is in
    -- your bag and buying takes it out, so there is nothing to redeem.
    if (def.rz or {}).effect == 'coin' then
        return notify(src, ('You are carrying %s %s. Spend them at the shop.')
            :format(entry.count, Config.Coins.label), 'inform')
    end

    -- Everything else needs you to be fighting. Burning a medkit while
    -- standing in the lobby is only ever a misclick.
    if not isFighting(src) then return end
    if not def or not def.usable then return end

    -- The client runs the animation and applies the effect; the server owns
    -- the count, so a client cannot use one item ten times.
    entry.count = entry.count - 1
    if entry.count <= 0 then inv[slot] = nil end

    TriggerClientEvent('naija-arena:client:invUsed', src, entry.name, slot)
    pushInv(src)
end)

RegisterNetEvent('naija-arena:server:invRequest', function()
    local src = source

    -- The lobby counts. Asking for your inventory there sent nothing back,
    -- so the panel opened with no slots at all -- not even empty ones. People
    -- want to see what they own before they walk into anything.
    if isFighting(src) or InLobby[src] then
        -- In the lobby the grid IS your kept arena inventory, so load it
        -- rather than showing whatever a previous match left behind.
        if InLobby[src] and not isFighting(src) then
            local key = playerKey(src)
            if key and RzSyncToMatch then
                RzSyncToMatch(src, key)
                return
            end
        end

        pushInv(src)
    end
end)

-- Give something to a player mid-match, from anywhere.
function ArenaGiveItem(src, name, count)
    if not Inv[src] then return false end
    local ok, err = addItem(src, name, count or 1)
    if ok then pushInv(src) end
    return ok, err
end

exports('GiveMatchItem', ArenaGiveItem)

-- The live grid, exposed so the shop can push its kept inventory into it
-- and read the result back. One grid, two owners: a match builds it fresh and
-- throws it away, the shop loads yours and writes it back.
function SetLiveInventory(src, slots)
    Inv[src] = slots or {}
    pushInv(src)
end

function GetLiveInventory(src)
    return Inv[src]
end

function clearInventory(src)
    Inv[src] = nil
    if GetPlayerName(src) then
        TriggerClientEvent('naija-arena:client:inventory', src, false)
    end
end

AddEventHandler('playerDropped', function()
    Inv[source] = nil
end)

-- The server-side revive. Their script exposes one that takes a player id,
-- and it is more reliable than the client trigger because it runs through
-- their proper flow rather than depending on one client's state.
-- Fire a named event server-side on a player's behalf. Their ESX docs show
-- the server revive taking a player id, which is why this passes src.
RegisterNetEvent('naija-arena:server:fireAmbulance', function(ev)
    local src = source
    if type(ev) ~= 'string' or ev == '' then return end

    -- Only events belonging to the ambulance resource, so this cannot be used
    -- to fire arbitrary events from a client.
    local res = Config.Ambulance.resource or 'ak47_qb_ambulancejob'
    if not ev:find(res, 1, true) and not ev:find('ambulancejob', 1, true)
       and not ev:find('hospital', 1, true) then
        return
    end

    TriggerEvent(ev, src)
end)

-- ============================================================
--  DISPATCH SUPPRESSION
-- ============================================================
-- Routing buckets stop anyone WITNESSING an arena fight, which handles every
-- dispatch that works by witnesses. Two things they do not stop:
--
--   1. Self-reported alerts. ps-dispatch runs a loop on the SHOOTER's own
--      client checking IsPedShooting, then reports itself. The shooter is in
--      the bucket and so is the code reporting them, so the bucket is
--      irrelevant.
--   2. Server-side death hooks. Your ambulance script fires server events on
--      death regardless of bucket, so EMS still gets paged.
--
-- Neither can be fixed from outside the resource that owns it -- FiveM has no
-- way to unregister another resource's handler. These exports exist so the
-- guard you add over there is a single readable line.

--- Is this player currently in an arena match?
--- Use this in ps-dispatch and your EMS script to drop alerts from arena
--- players without touching the rest of the city.
--- @param src number server id
--- @return boolean
--- Is this player anywhere this resource is responsible for?
---
--- Used by the one-line dispatch guard in DISPATCH.md, so what it covers is
--- what stops paging police and EMS.
---
--- It used to answer for MATCHES ONLY -- Occupants, or the arenaMatch
--- statebag. Which meant every Red Zone gunshot, every Red Zone death and
--- everything in the lobby went straight to dispatch, and that is most of the
--- shooting on the server. GetArenaPlayers below already knew about the Red
--- Zone; this did not, so the list and the boolean disagreed and the boolean
--- is the one people call.
---
--- Four things now, in the order they are cheapest to check:
---
---   Occupants          inside a match instance
---   arenaMatch         the same thing via statebag, for the moment before
---                      the table catches up
---   InLobby            waiting in the lobby -- nothing should fire there,
---                      but a downed-player alert from some other script
---                      would, and a lobby page is noise either way
---   ClaimedByOther     any mode running on top of this resource
---
--- ClaimedByOther rather than naming the Red Zone: it is how a mode says "I
--- have this player", so anything written later inherits the suppression
--- without this function being edited again. Hardcoding a resource name here
--- is how the next mode ends up paging the police and nobody knows why.
function IsPlayerInArena(src)
    src = tonumber(src)
    if not src then return false end

    if Occupants[src] then return true end
    if InLobby[src] then return true end

    if Player(src).state.arenaMatch == true then return true end

    -- Global, so it resolves at call time -- the claim table is declared much
    -- further down this file and is not in scope here.
    if ClaimedByOther and ClaimedByOther(src) then return true end

    return false
end

exports('IsPlayerInArena', IsPlayerInArena)

--- Every player currently in an arena, as a set keyed by server id.
--- Handy if you'd rather filter a recipient list than drop the alert.
function GetArenaPlayers()
    local out = {}

    -- One rule, asked of every connected player, so this and IsPlayerInArena
    -- can never disagree.
    --
    -- It used to walk Occupants and then reach into tenx-redzone by name
    -- for its zone list -- two exports deep, and silently wrong for any mode
    -- that was not that one. Both now answer from the same four checks.
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and IsPlayerInArena(src) then out[src] = true end
    end

    return out
end

exports('GetArenaPlayers', GetArenaPlayers)

-- ============================================================
--  HEALTH SYNC
-- ============================================================
-- The server reads health straight off the entity, which is the value every
-- other client is working from. If a player's own client has drifted from it,
-- their screen is lying to them -- which is how you get "he was nearly dead
-- on my screen" arguments that neither player can win.
--
-- This does not fix GTA's hit registration. It fixes the disagreement about
-- what happened afterwards.
CreateThread(function()
    while true do
        Wait((Config.Fair and Config.Fair.healthSyncInterval) or 2000)

        if Config.Fair and Config.Fair.healthSync ~= false then
            for src, o in pairs(Occupants) do
                if GetPlayerName(src) then
                    local match = Matches[o.key]

                    -- Only during a live match, and not while they are down --
                    -- correcting the health of someone mid-revive would fight
                    -- the ambulance script.
                    if match and match.phase == 'live' then
                        local key = playerKey(src)
                        if key and not match.dead[key] then
                            local ped = GetPlayerPed(src)
                            if ped and ped ~= 0 then
                                local hp = GetEntityHealth(ped)
                                if hp > 0 then
                                    TriggerClientEvent('naija-arena:client:syncHealth', src, hp)
                                end
                            end
                        end
                    end
                else
                    Occupants[src] = nil
                end
            end
        end
    end
end)


-- ============================================================
--  THE LEADERBOARD BILLBOARD
-- ============================================================
-- The board reads the same stats table the panel does, ranked by war points.
-- Pushed on a slow timer and immediately whenever a match finishes, so it is
-- current without being queried constantly.

local boardCache = nil

--- One board's worth of rows.
---
--- A source we do not recognise is handed to whichever resource registered
--- it, so a mode living in another script appears on the wall without this
--- one knowing anything about it.
local function buildBoard(which)
    local n = (Config.Billboard and Config.Billboard.entries) or 10
    which = which or 'pvp'

    if which ~= 'pvp' and which ~= 'ranked' and which ~= 'info' then
        local fromProvider = ProviderBoard and ProviderBoard(which)
        if fromProvider then return fromProvider end
    end

    local ok, rows

    if which == 'ranked' then
        ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT name, elo, peak_elo, wins, losses, streak, placed
                FROM tenx_arena_ranked
                WHERE placed >= ?
                ORDER BY elo DESC
                LIMIT ?
            ]], { Config.Ranked.placementMatches or 10, n })
        end)

    else
        ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT name, wins, losses, kills, deaths, points
                FROM tenx_arena_stats
                ORDER BY points DESC, wins DESC, kills DESC
                LIMIT ?
            ]], { n })
        end)
    end

    if not ok then
        dbg('billboard: could not read the %s stats table', which)
        return { rows = {}, updated = os.time(), which = which }
    end

    local out = {}

    -- The ranked board is a different shape: rating and tier rather than
    -- kills and points, so it is built here rather than bent into the
    -- casual one.
    if which == 'ranked' then
        for i, r in ipairs(rows or {}) do
            local wins, losses = r.wins or 0, r.losses or 0
            local played = wins + losses
            local tier = RankedTierFor and RankedTierFor(r.elo or 0) or {}

            out[#out + 1] = {
                rank = i,
                name = r.name or 'Unknown',
                elo = r.elo or 0,
                peak = r.peak_elo or r.elo or 0,
                tierName = tier.name or 'Unranked',
                tierHue = tier.hue,
                tierAccent = tier.accent,
                tierShape = tier.tier or 1,
                wins = wins,
                losses = losses,
                streak = r.streak or 0,
                winRate = played > 0 and math.floor((wins / played) * 100) or 0
            }
        end

        return { rows = out, updated = os.time(), which = which }
    end

    for i, r in ipairs(rows or {}) do
        local kills, deaths = r.kills or 0, r.deaths or 0
        local wins, losses = r.wins or 0, r.losses or 0
        local points = r.points or 0

        -- A level off war points, so the board has the progression cue every
        -- leaderboard like this has. Square root so early levels come fast
        -- and later ones slow down, rather than a flat grind.
        local level = math.max(1, math.floor(math.sqrt(points / 40)) + 1)

        out[#out + 1] = {
            rank = i,
            name = r.name or 'Unknown',
            level = level,
            points = points,
            wins = wins,
            losses = losses,
            kills = kills,
            deaths = deaths,
            streak = r.best_streak or 0,
            kd = deaths > 0 and string.format('%.2f', kills / deaths)
                             or string.format('%.2f', kills),
            wl = losses > 0 and string.format('%.2f', wins / losses)
                             or string.format('%.2f', wins)
        }
    end

    return { rows = out, updated = os.time(), which = which }
end

-- What an info board shows: what is happening right now, rather than a
-- leaderboard. This replaced the floating text over the ped -- text drawn in
-- the world scales with distance and covers whatever is behind it.
local function buildInfo()
    local queue = {}
    for _, m in ipairs(Config.Modes or {}) do
        local n = 0
        for _, e in ipairs(Queue[m.id] or {}) do n = n + e.size end
        queue[#queue + 1] = { label = m.label, count = n }
    end

    local rooms = 0
    for _, r in pairs(Rooms or {}) do
        if not r.private and not r.started then rooms = rooms + 1 end
    end

    local zones = {}
    local counts = GlobalState.arenaRzCounts or {}
    for id, a in pairs(Arenas) do
        if a.enabled and a.bounds then
            zones[#zones + 1] = { name = a.name, players = counts[id] or 0 }
        end
    end

    local live = 0
    for _, m in pairs(Matches) do
        if m.phase == 'live' then live = live + 1 end
    end

    local lobby = 0
    for _ in pairs(InLobby) do lobby = lobby + 1 end

    return {
        which = 'info',
        queue = queue,
        rooms = rooms,
        zones = zones,
        liveMatches = live,
        lobby = lobby,
        updated = os.time()
    }
end

function PushBillboard(target, which)
    if not (Config.Billboard and Config.Billboard.enabled) then return end

    -- All three are sent every time, and each board picks the one it wants.
    --
    -- Every board's data, every push. Sending only one would starve any wall
    -- pinned to a different kind would sit empty forever.
    --
    -- Titles and footers still come from Config.Boards and ride along on each
    -- one, so branding stays a config edit rather than a change to the page.
    -- Titles are applied on the client, where it knows which of its sources
    -- a rotating board is currently showing.
    local payload = {
        pvp = buildBoard('pvp'),
        ranked = buildBoard('ranked'),

        -- Boards other resources registered, built alongside ours so a wall
        -- set to one is fed exactly the same way.
        providers = (function()
            local out = {}
            for _, p in ipairs(ProviderList and ProviderList() or {}) do
                out[p.id] = buildBoard(p.id)
            end
            return out
        end)(),
        info = buildInfo()
    }

    boardCache = payload

    if target then
        TriggerClientEvent('naija-arena:client:billboard', target, payload)
    else
        TriggerClientEvent('naija-arena:client:billboard', -1, payload)
    end
end

-- No rotation any more. Each board shows both of its halves at once, so
-- nobody has to stand and wait for the half they came to read.

-- ── where boards live ──
-- A file rather than another database table: you have enough SQL to run
-- already, and four corner points is not data that needs a schema.
local Boards = {}

local function loadBoards()
    Boards = {}

    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM tenx_arena_boards')
    end)

    if not ok then
        print('^1[arena] could not read tenx_arena_boards -- run the SQL^0')
        return
    end

    for _, r in ipairs(rows or {}) do
        local okc, corners = pcall(json.decode, r.corners)
        if okc and type(corners) == 'table' and #corners == 4 then
            Boards[#Boards + 1] = {
                -- Resolved on the way out, so an old kind in the database
                -- never reaches a client that would not know what to do
                -- with it.
                id = r.id, name = r.name, kind = boardKind(r.kind),
                corners = corners, by = r.created_by
            }
        end
    end

    -- Anything marked before this moved to the database comes across once.
    -- The old file lived in the resource folder, which is replaced on every
    -- re-upload -- which is exactly why it is not kept there any more.
    local raw = LoadResourceFile(GetCurrentResourceName(), 'boards.json')
    if raw and raw ~= '' and #Boards == 0 then
        local okj, old = pcall(json.decode, raw)
        if okj and type(old) == 'table' and #old > 0 then
            for _, b in ipairs(old) do
                if b.corners and #b.corners == 4 then
                    pcall(function()
                        MySQL.insert.await(
                            'INSERT IGNORE INTO tenx_arena_boards (id, name, corners, created_by) VALUES (?, ?, ?, ?)',
                            { b.id, b.name, json.encode(b.corners), b.by })
                    end)
                    Boards[#Boards + 1] = b
                end
            end
            print(('[arena] migrated %s board(s) out of boards.json into the database')
                :format(#Boards))
        end
    end

    print(('[arena] loaded %s leaderboard board(s)'):format(#Boards))
end

local function pushBoards()
    GlobalState.arenaBoards = Boards
end

CreateThread(function()
    Wait(1200)
    loadBoards()
    pushBoards()
end)

-- ── placed props ──
-- Billboards you spawn and position yourself, so a board does not have to sit
-- flat against a wall that is not flat.
local Props = {}

local function loadProps()
    Props = {}

    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM tenx_arena_props')
    end)

    if not ok then
        print('^1[arena] could not read tenx_arena_props -- run the SQL^0')
        return
    end

    for _, r in ipairs(rows or {}) do
        Props[#Props + 1] = {
            id = r.id, model = r.model,
            x = r.x, y = r.y, z = r.z,
            rx = r.rx, ry = r.ry, rz = r.rz,
            by = r.created_by
        }
    end

    -- Bring anything placed before this moved to the database across once.
    local raw = LoadResourceFile(GetCurrentResourceName(), 'props.json')
    if raw and raw ~= '' and #Props == 0 then
        local okj, old = pcall(json.decode, raw)
        if okj and type(old) == 'table' and #old > 0 then
            for _, pr in ipairs(old) do
                pcall(function()
                    MySQL.insert.await([[
                        INSERT IGNORE INTO tenx_arena_props
                        (id, model, x, y, z, rx, ry, rz, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ]], { pr.id, pr.model, pr.x, pr.y, pr.z,
                          pr.rx or 0, pr.ry or 0, pr.rz or 0, pr.by })
                end)
                Props[#Props + 1] = pr
            end
            print(('[arena] migrated %s prop(s) out of props.json into the database')
                :format(#Props))
        end
    end

    print(('[arena] loaded %s placed prop(s)'):format(#Props))
end

local function pushProps()
    GlobalState.arenaProps = Props
end

CreateThread(function()
    Wait(1300)
    loadProps()
    pushProps()
end)

RegisterNetEvent('naija-arena:server:saveProp', function(data)
    local src = source
    if not hasPermission(src) then return end
    if type(data) ~= 'table' or not data.model then return end

    local entry = {
        id = tostring(os.time()) .. '-' .. math.random(100, 999),
        model = data.model,
        x = data.x, y = data.y, z = data.z,
        rx = data.rx or 0.0, ry = data.ry or 0.0, rz = data.rz or 0.0,
        by = GetPlayerName(src)
    }

    local ok = pcall(function()
        MySQL.insert.await([[
            INSERT INTO tenx_arena_props (id, model, x, y, z, rx, ry, rz, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], { entry.id, entry.model, entry.x, entry.y, entry.z,
              entry.rx, entry.ry, entry.rz, entry.by })
    end)

    if not ok then
        return notify(src, 'Could not save the prop. Has the SQL been run?', 'error')
    end

    Props[#Props + 1] = entry
    pushProps()
    notify(src, ('Prop placed. %s in total.'):format(#Props), 'success')
end)

RegisterNetEvent('naija-arena:server:deleteProp', function(id)
    local src = source
    if not hasPermission(src) then return end

    for i, pr in ipairs(Props) do
        if pr.id == id then
            pcall(function()
                MySQL.update.await('DELETE FROM tenx_arena_props WHERE id = ?', { id })
            end)
            table.remove(Props, i)
            pushProps()
            notify(src, 'Prop removed.', 'success')
            return
        end
    end

    notify(src, 'No prop with that id.', 'error')
end)

RegisterNetEvent('naija-arena:server:listProps', function()
    TriggerClientEvent('naija-arena:client:propList', source, Props)
end)

-- What kinds exist comes from Config.Boards, so adding one there is all it
-- takes -- no list here to forget to update.
local function boardKinds()
    local out = {}
    for id in pairs(Config.Boards or {}) do out[id] = true end
    return out
end

RegisterNetEvent('naija-arena:server:saveBoard', function(corners, name, kind)
    local src = source
    if not hasPermission(src) then return end

    if type(corners) ~= 'table' or #corners ~= 4 then
        return notify(src, 'A board needs exactly four corners.', 'error')
    end

    kind = boardKinds()[kind] and kind or 'pvp'

    -- Refuse one that lands on top of another.
    --
    -- Two boards in the same space render through each other, and the result
    -- looks like one broken board rather than two working ones in the wrong
    -- place -- so it is worth stopping at the point it happens.
    local cx, cy, cz = 0.0, 0.0, 0.0
    for _, c in ipairs(corners) do
        cx, cy, cz = cx + c.x, cy + c.y, cz + c.z
    end
    cx, cy, cz = cx / 4, cy / 4, cz / 4

    local minGap = (Config.Billboard and Config.Billboard.minGap) or 4.0

    for _, b in ipairs(Boards) do
        local ox, oy, oz = 0.0, 0.0, 0.0
        for _, c in ipairs(b.corners or {}) do
            ox, oy, oz = ox + c.x, oy + c.y, oz + c.z
        end
        ox, oy, oz = ox / 4, oy / 4, oz / 4

        if math.sqrt((cx-ox)^2 + (cy-oy)^2 + (cz-oz)^2) < minGap then
            return notify(src, ('Too close to "%s" -- they would draw through each other. Delete that one, or mark this somewhere else.')
                :format(b.name or b.id), 'error')
        end
    end

    -- Lift it off the wall as it is created, rather than making every board
    -- a two-step job.
    local off = (Config.Billboard or {}).markOffset or 0
    if off ~= 0 then
        local ax, ay, az = corners[2].x - corners[1].x, corners[2].y - corners[1].y, corners[2].z - corners[1].z
        local bx, by, bz = corners[4].x - corners[1].x, corners[4].y - corners[1].y, corners[4].z - corners[1].z

        local nx = (ay * bz) - (az * by)
        local ny = (az * bx) - (ax * bz)
        local nz = (ax * by) - (ay * bx)
        local len = math.sqrt((nx * nx) + (ny * ny) + (nz * nz))

        if len > 0.0001 then
            nx, ny, nz = nx / len, ny / len, nz / len
            for i = 1, 4 do
                corners[i].x = corners[i].x + (nx * off)
                corners[i].y = corners[i].y + (ny * off)
                corners[i].z = corners[i].z + (nz * off)
            end
        end
    end

    local entry = {
        id = tostring(os.time()) .. '-' .. math.random(100, 999),
        name = (name ~= '' and name) or ('Board %s'):format(#Boards + 1),
        kind = kind,
        corners = corners,
        by = GetPlayerName(src)
    }

    local ok, err = pcall(function()
        MySQL.insert.await(
            'INSERT INTO tenx_arena_boards (id, name, kind, corners, created_by) VALUES (?, ?, ?, ?, ?)',
            { entry.id, entry.name, entry.kind, json.encode(entry.corners), entry.by })
    end)

    -- Say what actually failed. "Has the SQL been run?" is unhelpful when the
    -- SQL HAS been run and the real problem is a column that CREATE TABLE IF
    -- NOT EXISTS could never have added.
    if not ok then
        print(('^1[arena] saving a board failed: %s^0'):format(tostring(err)))
    end

    if not ok then
        return notify(src, 'Could not save the board -- the reason is in the server console.', 'error')
    end

    Boards[#Boards + 1] = entry
    pushBoards()
    notify(src, ('Board saved as %s. %s in total.'):format(entry.kind, #Boards), 'success')
    dbg('%s marked a leaderboard board', GetPlayerName(src))
end)

--- Nudge a board off the wall, or make it bigger.
---
--- A building face with ridges is not flat, so a board sitting exactly on the
--- marked points disappears into them. Pushing it out along its own normal
--- puts it in front of the ridges instead -- which is what you want anyway,
--- since a board is a sign hung on a wall, not paint.
RegisterNetEvent('naija-arena:server:adjustBoard', function(id, how, amount)
    local src = source
    if not hasPermission(src) then return end

    amount = tonumber(amount) or 0

    for _, b in ipairs(Boards) do
        if b.id == id then
            local c = b.corners

            -- The face's own normal: across the top, down the side, crossed.
            local ax, ay, az = c[2].x - c[1].x, c[2].y - c[1].y, c[2].z - c[1].z
            local bx, by, bz = c[4].x - c[1].x, c[4].y - c[1].y, c[4].z - c[1].z

            local nx = (ay * bz) - (az * by)
            local ny = (az * bx) - (ax * bz)
            local nz = (ax * by) - (ay * bx)

            local len = math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
            if len < 0.0001 then
                return notify(src, 'That board has no surface to work from.', 'error')
            end

            nx, ny, nz = nx / len, ny / len, nz / len

            if how == 'push' then
                for i = 1, 4 do
                    c[i].x = c[i].x + (nx * amount)
                    c[i].y = c[i].y + (ny * amount)
                    c[i].z = c[i].z + (nz * amount)
                end

            elseif how == 'scale' then
                -- Grown around its own middle, so it stays where you put it.
                local cx = (c[1].x + c[2].x + c[3].x + c[4].x) / 4
                local cy = (c[1].y + c[2].y + c[3].y + c[4].y) / 4
                local cz = (c[1].z + c[2].z + c[3].z + c[4].z) / 4

                for i = 1, 4 do
                    c[i].x = cx + ((c[i].x - cx) * amount)
                    c[i].y = cy + ((c[i].y - cy) * amount)
                    c[i].z = cz + ((c[i].z - cz) * amount)
                end

            elseif how == 'raise' then
                for i = 1, 4 do c[i].z = c[i].z + amount end

            else
                return notify(src, 'Unknown adjustment.', 'error')
            end

            local ok = pcall(function()
                MySQL.update.await(
                    'UPDATE tenx_arena_boards SET corners = ? WHERE id = ?',
                    { json.encode(c), b.id })
            end)

            if not ok then
                return notify(src, 'Could not save that -- check the console.', 'error')
            end

            pushBoards()
            return notify(src, ('%s adjusted.'):format(b.name or b.id), 'success')
        end
    end

    notify(src, 'No board with that id.', 'error')
end)

--- Save a board after it has been dragged about in game.
---
--- The whole shape at once: the client already has it on screen and knows
--- exactly where it ended up, so sending nudges one at a time would just be
--- the same edit done slowly and with more chances to disagree.
RegisterNetEvent('naija-arena:server:saveBoardShape', function(id, corners)
    local src = source
    if not hasPermission(src) then return end

    if type(corners) ~= 'table' or #corners ~= 4 then
        return notify(src, 'That is not a board shape.', 'error')
    end

    for _, c in ipairs(corners) do
        if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then
            return notify(src, 'That shape has a bad corner.', 'error')
        end
    end

    for _, b in ipairs(Boards) do
        if b.id == id then
            b.corners = corners

            local ok = pcall(function()
                MySQL.update.await(
                    'UPDATE tenx_arena_boards SET corners = ? WHERE id = ?',
                    { json.encode(corners), id })
            end)

            if not ok then
                return notify(src, 'Could not save it -- check the console.', 'error')
            end

            pushBoards()
            return notify(src, ('%s saved.'):format(b.name or id), 'success')
        end
    end

    notify(src, 'No board with that id.', 'error')
end)

RegisterNetEvent('naija-arena:server:deleteBoard', function(id)
    local src = source
    if not hasPermission(src) then return end

    for i, b in ipairs(Boards) do
        if b.id == id then
            pcall(function()
                MySQL.update.await('DELETE FROM tenx_arena_boards WHERE id = ?', { id })
            end)
            table.remove(Boards, i)
            pushBoards()
            notify(src, 'Board removed.', 'success')
            return
        end
    end

    notify(src, 'No board with that id.', 'error')
end)

RegisterNetEvent('naija-arena:server:listBoards', function()
    local src = source
    TriggerClientEvent('naija-arena:client:boardList', src, Boards)
end)

RegisterNetEvent('naija-arena:server:wantBillboard', function()
    local src = source
    if boardCache then
        TriggerClientEvent('naija-arena:client:billboard', src, boardCache)
    else
        PushBillboard(src)
    end
end)

CreateThread(function()
    Wait(3000)
    PushBillboard()

    while true do
        Wait(((Config.Billboard and Config.Billboard.refresh) or 60) * 1000)
        PushBillboard()
    end
end)

-- Always-on free-for-all in the arenas already built for PVP. No matchmaking
-- and no rooms: pick a zone, get placed just outside it with a fixed kit, walk
-- in, and it never stops.
--
-- One bucket per ARENA, shared by everyone in it -- unlike PVP where each
-- match gets its own instance. The whole point is that everyone in a fight
-- can find each other.

-- RZ is declared at the top of the file: exitrz and the eviction paths need
-- to clear it and they sit well above here.











-- ── coins, by hand ──
-- For testing, for putting right whatever the ledger says went wrong, and
-- for handing out prizes. Every one of these lands in the ledger like any
-- other movement, so a balance stays explainable.
-- Kept as an alias. Coins are items now, so this and rzcoins do the same
-- thing -- but anyone with the old command in a script or a habit still gets
-- what they expect.
RegisterCommand('rzcoinitem', function(src, args)
    local function say(msg, kind)
        if src == 0 then print('[arena] ' .. msg) else notify(src, msg, kind or 'inform') end
    end

    if src ~= 0 and not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    local target = tonumber(args[1])
    local amount = tonumber(args[2]) or 1

    if not target then
        return say('rzcoinitem <player id> <amount>   -- coins they can hand on')
    end
    if not GetPlayerName(target) then
        return say('That player is not online.', 'error')
    end
    if amount < 1 then
        return say('Amount has to be at least 1.', 'error')
    end

    local key = playerKey(target)
    if not key then return end

    local ok, err = RzAddItem(key, 'rz_coin', amount, true)
    if not ok then
        return say(('They cannot carry that: %s'):format(err or 'no room'), 'error')
    end

    if RzSyncToMatch then RzSyncToMatch(target, key) end

    notify(target, ('Received %s %s. Use them to add to your balance.')
        :format(amount, Config.Coins.label), 'success')
    say(('Gave %s %s x%s.'):format(GetPlayerName(target), Config.Coins.label, amount), 'success')
end, false)

RegisterCommand('rzcoins', function(src, args)
    if src ~= 0 and not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    -- Two ways to say it, because "rzcoins 4 -500" is easy to get wrong in a
    -- hurry and a mistyped minus sign is somebody's savings:
    --
    --   rzcoins add 4 500
    --   rzcoins remove 4 500
    --   rzcoins 4 500        -- still works, negative takes away
    local verb = (args[1] or ''):lower()
    local target, amount

    if verb == 'add' or verb == 'give' then
        target, amount = tonumber(args[2]), math.abs(tonumber(args[3]) or 0)
    elseif verb == 'remove' or verb == 'take' then
        target, amount = tonumber(args[2]), -math.abs(tonumber(args[3]) or 0)
    else
        target, amount = tonumber(args[1]), tonumber(args[2])
    end

    if not target or not amount or amount == 0 then
        local msg = 'rzcoins add|remove <player id> <amount>'
        if src == 0 then print('[arena] ' .. msg) else notify(src, msg, 'inform') end
        return
    end

    if not GetPlayerName(target) then
        local msg = 'That player is not online.'
        if src == 0 then print('[arena] ' .. msg) else notify(src, msg, 'error') end
        return
    end

    local key = playerKey(target)
    if not key then return end

    local by = src == 0 and 'console' or GetPlayerName(src)
    local balance

    if amount >= 0 then
        balance = RzGiveCoins(key, amount, 'admin:' .. by)
    else
        local ok
        ok, balance = RzTakeCoins(key, -amount, 'admin:' .. by)
        if not ok then
            local msg = ('%s only has %s.'):format(GetPlayerName(target), balance)
            if src == 0 then print('[arena] ' .. msg) else notify(src, msg, 'error') end
            return
        end
    end

    -- Show it straight away if they are looking at their grid.
    if RzSyncToMatch then RzSyncToMatch(target, key) end

    notify(target, ('%s %s %s.'):format(
        amount >= 0 and 'Received' or 'Lost',
        math.abs(amount), Config.Coins.label), amount >= 0 and 'success' or 'inform')

    local done = ('%s now has %s %s.'):format(GetPlayerName(target), balance, Config.Coins.short)
    if src == 0 then print('[arena] ' .. done) else notify(src, done, 'success') end

    dbg('%s adjusted %s coins by %s', by, GetPlayerName(target), amount)
end, false)

RegisterCommand('rzbalance', function(src, args)
    if src == 0 then return end

    local target = src
    if args[1] and hasPermission(src) then
        target = tonumber(args[1]) or src
    end

    local key = playerKey(target)
    if not key then return end

    notify(src, ('%s: %s %s'):format(
        target == src and 'You have' or (GetPlayerName(target) or '?') .. ' has',
        RzCoins(key), Config.Coins.short), 'inform')
end, false)









-- ============================================================
--  INVENTORY, COINS AND SHOP
-- ============================================================
-- Unlike a match inventory -- built fresh, thrown away -- this one is kept.
-- What you own survives logging out, which is the only thing that makes
-- buying a weapon worth doing.

local RzInv = {}    -- [license] = { slots = {}, coins = n, dirty = bool }

local function rzLoad(key)
    if RzInv[key] then return RzInv[key] end

    local ok, row = pcall(function()
        return MySQL.single.await(
            'SELECT slots, coins FROM tenx_arena_rz_inv WHERE identifier = ?', { key })
    end)

    local slots, coins = {}, 0

    if ok and row then
        coins = row.coins or 0
        local okj, decoded = pcall(json.decode, row.slots or '{}')
        if okj and type(decoded) == 'table' then
            -- JSON turns integer keys into strings on the way out.
            for k, v in pairs(decoded) do
                slots[tonumber(k) or k] = v
            end
        end
    end

    RzInv[key] = { slots = slots, coins = 0 }

    -- Coins used to be a number on the account, separate from the bag. They
    -- are items now, so an old balance is turned into coins you can hold --
    -- once, the first time this player loads after the change. Nobody loses
    -- what they earned.
    if coins > 0 then
        RzInv[key].dirty = true
        local def = (Config.Items or {})['rz_coin']

        if def then
            local placed = false
            for i = 1, (Config.MatchInventory.slots or 20) do
                if not slots[i] then
                    slots[i] = { name = 'rz_coin', count = coins }
                    placed = true
                    break
                end
            end

            if placed then
                print(('[arena] moved %s coins into %s\'s bag'):format(coins, key))
            else
                -- No room: keep the number so it is not silently destroyed.
                RzInv[key].coins = coins
                print(('^3[arena] %s has %s coins but no free slot -- kept for later^0')
                    :format(key, coins))
            end
        end
    end

    return RzInv[key]
end

rzSave = function(key)
    local inv = RzInv[key]
    if not inv then return end

    pcall(function()
        MySQL.update.await([[
            INSERT INTO tenx_arena_rz_inv (identifier, slots, coins)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE slots = VALUES(slots), coins = VALUES(coins)
        ]], { key, json.encode(inv.slots), inv.coins })
    end)

    inv.dirty = false
end

-- Saved on a slow loop rather than on every change. A player picking up
-- twenty items in a firefight should not be twenty writes.
CreateThread(function()
    while true do
        Wait(20000)
        for key, inv in pairs(RzInv) do
            if inv.dirty then rzSave(key) end
        end
    end
end)

local function rzTouch(key)
    if RzInv[key] then RzInv[key].dirty = true end
end

-- ── coins ──
local function coinLedger(key, amount, reason, balance)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO tenx_arena_rz_ledger (identifier, amount, reason, balance) VALUES (?, ?, ?, ?)',
            { key, amount, reason, balance })
    end)
end

--- How many coins you have.
---
--- The coins in your inventory ARE your balance -- there is no separate
--- number. Two places to look meant two places to disagree, and a shop
--- showing a balance you could not see in your bag is confusing in a way
--- nothing else here is.
function RzCoins(key)
    return RzCountItem(key, 'rz_coin')
end

--- Add coins to the bag. Every movement is written to the ledger, so a
--- balance can be explained rather than argued about.
function RzGiveCoins(key, amount, reason)
    if amount <= 0 then return RzCoins(key) end

    -- Straight into the inventory, because that is where coins live.
    RzAddItem(key, 'rz_coin', amount, true)

    local now = RzCoins(key)
    coinLedger(key, amount, reason or 'unknown', now)
    return now
end

function RzTakeCoins(key, amount, reason)
    local have = RzCoins(key)
    if have < amount then return false, have end

    RzRemoveItem(key, 'rz_coin', amount)

    local now = RzCoins(key)
    coinLedger(key, -amount, reason or 'unknown', now)
    return true, now
end

-- ── items in and out of the persistent inventory ──
local function rzSlotWeight(entry)
    if not entry then return 0 end
    local def = (Config.Items or {})[entry.name]
    return (def and def.weight or 0) * (entry.count or 1)
end

local function rzWeight(key)
    local total = 0
    for _, e in pairs(rzLoad(key).slots) do total = total + rzSlotWeight(e) end
    return total
end

--- Where something should go.
---
--- Merging into an existing stack always wins -- that changes nothing about
--- the arrangement. `fromBack` only affects where a genuinely new item lands:
--- at the end of the grid rather than the front, so match supplies stop
--- displacing the weapons you put on your number keys.
local function rzFindSlot(key, name, count, fromBack)
    local cfg = Config.MatchInventory
    local def = (Config.Items or {})[name] or {}
    local stack = stackLimit(def)
    local slots = rzLoad(key).slots
    local total = cfg.slots or 20

    if stack > 1 then
        for i = 1, total do
            local e = slots[i]
            if e and e.name == name and (e.count + count) <= stack then return i, true end
        end
    end

    if fromBack then
        -- Back to front, stopping ABOVE the hotbar.
        --
        -- The hotbar is the player's own arrangement and they should be able
        -- to trust it mid-fight. A payout taking the first free slot pushes
        -- their weapons along by one at the exact moment they are reaching
        -- for a number key. Searching from the back made that rare rather
        -- than impossible -- fill the back and it walks into the hotbar
        -- anyway. No fallback: if the rest is full, "no room" is honest.
        --
        -- Merging is unaffected and still happens anywhere, so ammo already
        -- on key three can still be topped up.
        local hotbar = cfg.hotbarSlots or 5
        for i = total, hotbar + 1, -1 do
            if not slots[i] then return i, false end
        end
        return nil
    end

    for i = 1, total do
        if not slots[i] then return i, false end
    end

    return nil
end

--- Put something in. Weapons carry their own durability from the moment they
--- are created, so a weapon in a slot always knows how much life it has left.
--- Add an item.
---
--- `fromBack` puts anything that needs a NEW slot at the end of the grid
--- instead of the front. Match supplies use it: the front of the grid is
--- where the hotbar number keys are, and having medkits appear there every
--- match means rearranging your weapons every match.
function RzAddItem(key, name, count, fromBack)
    local def = (Config.Items or {})[name]
    if not def then return false, 'Unknown item.' end

    count = count or 1
    local inv = rzLoad(key)

    local max = (Config.MatchInventory and Config.MatchInventory.maxWeight) or 30000
    if rzWeight(key) + ((def.weight or 0) * count) > max then
        return false, 'Too heavy to carry.'
    end

    local slot, merged = rzFindSlot(key, name, count, fromBack)
    if not slot then return false, 'No room.' end

    if merged then
        inv.slots[slot].count = inv.slots[slot].count + count
    else
        inv.slots[slot] = {
            name = name,
            count = count,
            dur = def.durability   -- nil for anything that cannot break
        }
    end

    inv.dirty = true

    -- Tell them it arrived.
    --
    -- Here rather than at any of the call sites, because EVERY route that
    -- gives a player something comes through this one function -- shop, admin
    -- give, wager payout, kill drop, kit charges. One place to announce it,
    -- and a mode written later gets it without knowing this exists.
    rzItemToast(key, name, count)

    return true
end

--- The "you received X" card.
---
--- Silent when the player is not connected: items can be added to a key
--- belonging to somebody offline, and there is nobody to tell.
function rzItemToast(key, name, count)
    local cfg = Config.ItemToast
    if not (cfg and cfg.enabled) then return end
    if cfg.ignore and cfg.ignore[name] then return end

    local src = srcForKey(key)
    if not src then return end

    local def = (Config.Items or {})[name] or {}

    TriggerClientEvent('naija-arena:client:itemToast', src, {
        item  = name,
        label = def.label or name,
        count = count or 1,
        image = def.image,
    })
end

function RzRemoveItem(key, name, count)
    local inv = rzLoad(key)
    count = count or 1

    for i, e in pairs(inv.slots) do
        if e.name == name then
            local take = math.min(count, e.count)
            e.count = e.count - take
            count = count - take
            if e.count <= 0 then inv.slots[i] = nil end
            if count <= 0 then break end
        end
    end

    inv.dirty = true
    return count <= 0
end

--- How many of something a player is carrying, across every slot.
function RzCountItem(key, name)
    local n = 0
    for _, e in pairs(rzLoad(key).slots) do
        if e.name == name then n = n + (e.count or 0) end
    end
    return n
end

--- Would this whole lot fit? Answered against a copy of the bag, so nothing
--- is committed until every line has somewhere to go.
---
--- Mirrors the rules in RzAddItem: stack limits decide whether a line merges
--- into an existing pile or needs its own slot, and the weight limit applies
--- to the total.
function RzWouldFit(key, trial, wanted)
    local cfg = Config.MatchInventory
    local slots = cfg.slots or 20
    local maxWeight = cfg.maxWeight or 30000

    local weight = 0
    for _, e in pairs(trial) do
        local d = (Config.Items or {})[e.name] or {}
        weight = weight + ((d.weight or 0) * (e.count or 1))
    end

    for _, w in ipairs(wanted) do
        local name = w.entry.item
        local total = (w.entry.count or 1) * w.qty
        local def = (Config.Items or {})[name] or {}
        local limit = stackLimit(def)

        weight = weight + ((def.weight or 0) * total)
        if weight > maxWeight then
            return false, ('Too heavy -- %s would put you over %skg.')
                :format(def.label or name, math.floor(maxWeight / 1000))
        end

        local left = total

        -- Merge into partial stacks first, same as adding one at a time.
        if limit > 1 then
            for i = 1, slots do
                local e = trial[i]
                if e and e.name == name and e.count < limit then
                    local room = limit - e.count
                    local take = math.min(room, left)
                    e.count = e.count + take
                    left = left - take
                    if left <= 0 then break end
                end
            end
        end

        -- Then new slots for whatever is left.
        while left > 0 do
            local free
            for i = 1, slots do
                if not trial[i] then free = i break end
            end

            if not free then
                return false, ('No room for %s -- your bag is full.')
                    :format(def.label or name)
            end

            local take = math.min(limit, left)
            trial[free] = { name = name, count = take }
            left = left - take
        end
    end

    return true
end

function RzHasWeapon(key)
    for _, e in pairs(rzLoad(key).slots) do
        local def = (Config.Items or {})[e.name]
        if def and def.weapon then return true, e.name end
    end
    return false
end

--- Wear every weapon down by one death. A weapon at zero breaks and is gone,
--- which is what sends someone back to the shop.
--- @return table names of anything that broke
rzWearWeapons = function(key)
    local inv = rzLoad(key)
    local loss = Config.Kit.durabilityLossPerDeath or 1
    local broke, low = {}, {}

    for i, e in pairs(inv.slots) do
        local def = (Config.Items or {})[e.name]
        if def and def.weapon and e.dur then
            e.dur = e.dur - loss

            if e.dur <= 0 then
                broke[#broke + 1] = def.label or e.name
                inv.slots[i] = nil
            elseif e.dur <= (Config.Kit.durabilityWarnAt or 3) then
                low[#low + 1] = { label = def.label or e.name, left = e.dur }
            end
        end
    end

    inv.dirty = true
    return broke, low
end

-- ── the shop ──
local function shopFind(itemName)
    for _, cat in ipairs((Config.Shop or {}).categories or {}) do
        for _, entry in ipairs(cat.items or {}) do
            if entry.item == itemName then return entry end
        end
    end
    return nil
end

local function shopState(src)
    local key = playerKey(src)
    if not key then return nil end

    local cats = {}

    for _, cat in ipairs((Config.Shop or {}).categories or {}) do
        local items = {}
        for _, e in ipairs(cat.items or {}) do
            local def = (Config.Items or {})[e.item] or {}
            items[#items + 1] = {
                item = e.item,
                label = e.label or def.label or e.item,
                price = e.price,
                count = e.count or 1,
                image = def.image or e.item,
                weapon = def.weapon or false,
                durability = def.durability,
                weight = def.weight or 0
            }
        end
        cats[#cats + 1] = { name = cat.name, items = items }
    end

    return {
        ok = true,
        -- Counted from the bag, so what the shop says you have is exactly
        -- what you can see in your inventory.
        coins = RzCoins(key),
        label = Config.Coins.label,
        short = Config.Coins.short,
        oxPath = Config.OxImagePath,
        categories = cats,
        convert = Config.Coins.convert
    }
end

RegisterNetEvent('naija-arena:server:openShop', function()
    local src = source
    if not InLobby[src] then
        return notify(src, 'The shop is in the lobby.', 'error')
    end

    local state = shopState(src)
    if not state then return notify(src, 'Could not identify you.', 'error') end

    TriggerClientEvent('naija-arena:client:openShop', src, state)
end)

lib.callback.register('naija-arena:server:shop', function(src, action, data)
    data = data or {}
    local key = playerKey(src)
    if not key then return { ok = false, message = 'Could not identify you.' } end

    if action == 'state' then
        return shopState(src) or { ok = false }
    end

    if action == 'buy' then
        local entry = shopFind(data.item)
        if not entry then return { ok = false, message = 'That is not for sale.' } end

        local price = entry.price or 0
        if RzCoins(key) < price then
            return { ok = false, message = ('Not enough %s.'):format(Config.Coins.label) }
        end

        -- Room checked BEFORE the coins are taken. Charging someone for
        -- something that then does not fit is the worst possible order.
        local ok, err = RzAddItem(key, entry.item, entry.count or 1)
        if not ok then return { ok = false, message = err } end

        RzTakeCoins(key, price, 'shop:' .. entry.item)

        -- Straight into the live grid: the thing you bought appears and the
        -- coins you paid with disappear, both visible in the same moment.
        -- Buying something and seeing nothing happen feels exactly like it
        -- failed.
        if RzSyncToMatch then RzSyncToMatch(src, key) end

        local def = (Config.Items or {})[entry.item] or {}
        return {
            ok = true,
            coins = RzCoins(key),
            message = ('Bought %s for %s %s.')
                :format(entry.label or def.label or entry.item, price, Config.Coins.short)
        }
    end

    if action == 'cart' then
        -- Buying several things at once.
        --
        -- All or nothing. Charging for five and delivering three because the
        -- bag filled up halfway is the worst outcome available here, so
        -- everything is checked before anything is taken -- the price, the
        -- weight, and a free slot for each line.
        local lines = data.lines
        if type(lines) ~= 'table' or #lines == 0 then
            return { ok = false, message = 'Nothing in the cart.' }
        end

        local total = 0
        local wanted = {}

        for _, line in ipairs(lines) do
            local entry = shopFind(line.item)
            if not entry then
                return { ok = false, message = ('%s is not for sale.'):format(line.item) }
            end

            local qty = math.floor(tonumber(line.qty) or 0)
            if qty < 1 or qty > 99 then
                return { ok = false, message = 'That is not a sensible amount.' }
            end

            total = total + (entry.price * qty)
            wanted[#wanted + 1] = { entry = entry, qty = qty }
        end

        if RzCoins(key) < total then
            return { ok = false,
                message = ('That comes to %s. You have %s.'):format(total, RzCoins(key)) }
        end

        -- Dry run against a copy: does the whole lot actually fit? Checking
        -- as we go would leave a half-bought cart behind on the first line
        -- that did not.
        local trial = {}
        for slot, e in pairs(rzLoad(key).slots) do
            trial[slot] = { name = e.name, count = e.count, dur = e.dur }
        end

        local ok, why = RzWouldFit(key, trial, wanted)
        if not ok then
            return { ok = false, message = why or 'That will not all fit.' }
        end

        -- Everything checked; now it happens.
        for _, w in ipairs(wanted) do
            RzAddItem(key, w.entry.item, (w.entry.count or 1) * w.qty)
        end

        RzTakeCoins(key, total, 'cart')
        if RzSyncToMatch then RzSyncToMatch(src, key) end

        local count = 0
        for _, w in ipairs(wanted) do count = count + w.qty end

        return {
            ok = true,
            coins = RzCoins(key),
            message = ('Bought %s item%s for %s %s.')
                :format(count, count == 1 and '' or 's', total, Config.Coins.short)
        }
    end

    if action == 'convert' then
        local cv = Config.Coins.convert or {}
        if not cv.enabled then return { ok = false, message = 'Conversion is switched off.' } end

        local amount = math.floor(tonumber(data.amount) or 0)
        if amount < (cv.minimum or 1) then
            return { ok = false,
                message = ('You need at least %s %s to convert.'):format(cv.minimum, Config.Coins.short) }
        end

        if RzCoins(key) < amount then
            return { ok = false, message = 'You do not have that many.' }
        end

        local gross = amount * (cv.rate or 1)
        local fee = math.floor(gross * (cv.fee or 0))
        local net = gross - fee

        -- Taken out of the bag, not off a separate number.
        local took = RzTakeCoins(key, amount, 'convert')
        if not took then return { ok = false, message = 'Could not take the coins.' } end

        if RzSyncToMatch then RzSyncToMatch(src, key) end

        -- Straight to the bank, not cash. Money appearing in a pocket during
        -- a firefight is money somebody will argue about later.
        local paid = pcall(function()
            local player = QBCore.Functions.GetPlayer(src)
            if player then player.Functions.AddMoney('bank', net, 'arena-conversion') end
        end)

        if not paid then
            -- Put them back rather than swallowing them.
            RzGiveCoins(key, amount, 'convert:refund')
            if RzSyncToMatch then RzSyncToMatch(src, key) end
            return { ok = false, message = 'The bank refused that. Your coins are untouched.' }
        end

        return {
            ok = true,
            coins = RzCoins(key),
            message = ('Converted %s %s to $%s in your bank%s.')
                :format(amount, Config.Coins.short, net,
                        fee > 0 and (' after a $' .. fee .. ' fee') or '')
        }
    end

    return { ok = false, message = 'Unknown action.' }
end)

lib.callback.register('naija-arena:server:rzWallet', function(src)
    local key = playerKey(src)
    if not key then return { coins = 0 } end
    return {
        coins = RzCoins(key),
        label = Config.Coins.label,
        short = Config.Coins.short,
        hasWeapon = (RzHasWeapon(key))
    }
end)

AddEventHandler('playerDropped', function()
    local key = playerKey(source)
    if key and RzInv[key] and RzInv[key].dirty then rzSave(key) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for key, inv in pairs(RzInv) do
        if inv.dirty then rzSave(key) end
    end
end)

-- The arena inventory IS the grid you see. Rather than two systems, the
-- kept inventory is pushed into the live one, and changes are written back.
function RzSyncToMatch(src, key)
    key = key or playerKey(src)
    if not key then return end

    local inv = rzLoad(key)

    -- Hand the live inventory a copy, so moving things around in the grid
    -- does not write straight to the database on every drag.
    local copy = {}
    for slot, e in pairs(inv.slots) do
        copy[slot] = { name = e.name, count = e.count, dur = e.dur }
    end

    SetLiveInventory(src, copy)
end

-- And back the other way, so what they rearranged is what they keep.
function RzSyncFromMatch(src, key)
    key = key or playerKey(src)
    if not key then return end

    local live = GetLiveInventory(src)
    if not live then return end

    local inv = rzLoad(key)
    inv.slots = {}

    for slot, e in pairs(live) do
        inv.slots[slot] = { name = e.name, count = e.count, dur = e.dur }
    end

    inv.dirty = true
end

-- ============================================================
--  BACK TO THE LOBBY
-- ============================================================
-- One way out from anywhere. What it costs depends on where you are:
--
--   In a match -- the other side gets the win. Walking out of a match you
--     are losing is the same as losing it, and it has to be, or every match
--     that turns bad ends with somebody quitting instead.
--   In the shop -- nothing. There is no match to hand over; you just
--     stop fighting.
--   Anywhere else -- straight to the lobby.
--
-- Deliberately not called forfeit. Most people using it are done for the
-- night, not conceding.

RegisterNetEvent('naija-arena:server:backToLobby', function()
    local src = source

    -- ── in a match ──
    local match, arenaId, slot, mKey = matchOf(src)

    if match and match.phase == 'live' then
        local key = playerKey(src)
        local team = key and teamOf(match, key)

        if team then
            -- Anyone left on their side?
            local remaining = 0
            for _, m in ipairs(match.teams[team] or {}) do
                if m.src and m.src ~= src and GetPlayerName(m.src) then
                    remaining = remaining + 1
                end
            end

            -- Take them out first, so the match end does not try to move
            -- someone who has already gone.
            Player(src).state:set('arenaMatch', false, true)
            removeFromArena(src)
            ReturnToLobby(src)

            if remaining == 0 then
                -- Last one on that side: the other team takes it.
                endMatch(mKey, team == 'A' and 'B' or 'A', 'left')
                notify(src, 'You left the match. The other side takes the win.', 'inform')
            else
                -- Teammates still in it, so the match carries on without them.
                for i, m in ipairs(match.teams[team]) do
                    if m.src == src then table.remove(match.teams[team], i) break end
                end

                if match.dead and key then match.dead[key] = nil end
                pushScore(match)
                notify(src, 'You left the match. Your team plays on.', 'inform')
            end

            return
        end
    end

    -- ── already out ──
    if InLobby[src] then
        return notify(src, 'You are already at the lobby.', 'inform')
    end

    if Occupants[src] then
        removeFromArena(src)
    end

    ReturnToLobby(src)
    notify(src, 'Back at the lobby.', 'success')
end)

-- ============================================================
--  RANKED
-- ============================================================
-- Elo rather than a win count, because a win count cannot tell the
-- difference between beating the best player on the server and beating
-- someone who joined an hour ago. Elo can, and that is the whole point of
-- having a separate ladder.

local function rankedRow(key)
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT * FROM tenx_arena_ranked WHERE identifier = ?', { key })
    end)

    if ok and row then return row end

    return {
        identifier = key,
        elo = Config.Ranked.startingElo or 1000,
        peak_elo = Config.Ranked.startingElo or 1000,
        wins = 0, losses = 0, placed = 0, streak = 0, best_streak = 0
    }
end

--- Which tier a rating sits in. Global, because the wall boards are built
--- near the top of the file and need it too -- one lookup rather than two
--- copies that drift apart the first time the ladder changes.
function RankedTierFor(elo)
    local found = (Config.Ranked.tiers or {})[1]
    for _, t in ipairs(Config.Ranked.tiers or {}) do
        if elo >= t.elo then found = t end
    end
    return found
end

local tierFor = RankedTierFor

--- The expected result, 0 to 1. A 400-point gap means the favourite is
--- expected to win about 10 times out of 11.
local function expected(a, b)
    return 1.0 / (1.0 + (10 ^ ((b - a) / 400)))
end

--- Apply one result and write the history line that explains it.
local function applyElo(key, name, oppElo, won, mode, oppName, score)
    local row = rankedRow(key)
    local before = row.elo or 1000

    local k = Config.Ranked.kFactor or 32

    -- Placement swings harder, so someone lands near where they belong
    -- rather than climbing out of a bad first night.
    if (row.placed or 0) < (Config.Ranked.placementMatches or 10) then
        k = k * (Config.Ranked.placementMultiplier or 2.0)
    end

    local exp = expected(before, oppElo)
    local after = math.floor(before + (k * ((won and 1 or 0) - exp)) + 0.5)

    after = math.max(Config.Ranked.floor or 100, after)

    local streak = row.streak or 0
    streak = won and (streak >= 0 and streak + 1 or 1)
                  or (streak <= 0 and streak - 1 or -1)

    pcall(function()
        MySQL.update.await([[
            INSERT INTO tenx_arena_ranked
                (identifier, name, elo, peak_elo, wins, losses, placed, streak, best_streak)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON DUPLICATE KEY UPDATE
                name = VALUES(name),
                elo = VALUES(elo),
                peak_elo = GREATEST(peak_elo, VALUES(elo)),
                wins = wins + VALUES(wins),
                losses = losses + VALUES(losses),
                placed = placed + 1,
                streak = VALUES(streak),
                best_streak = GREATEST(best_streak, VALUES(streak))
        ]], { key, name, after, after, won and 1 or 0, won and 0 or 1, streak, math.max(0, streak) })
    end)

    pcall(function()
        MySQL.insert.await([[
            INSERT INTO tenx_arena_ranked_history
                (identifier, mode, opponent, won, elo_before, elo_after, score)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]], { key, mode, oppName, won and 1 or 0, before, after, score })
    end)

    return before, after
end

--- Score a finished ranked match. Each player is rated against the average
--- of the other side, so a 2v2 works the same way a 1v1 does.
function RankedRecord(match, winner)
    if not (Config.Ranked and Config.Ranked.enabled) then return end
    if not winner then return end

    -- The match itself says whether it was ranked -- decided when the player
    -- queued, not by which mode they picked. The same 1v1 is ranked from the
    -- ranked panel and casual from the other one, and a mode list could
    -- never express that.
    if not match.ranked then return end

    -- Some modes still cannot be ranked at all, whatever panel you came from.
    if Config.Ranked.rankedModes and #Config.Ranked.rankedModes > 0 then
        local allowed = false
        for _, m in ipairs(Config.Ranked.rankedModes) do
            if m == match.mode then allowed = true break end
        end
        if not allowed then return end
    end

    -- Average rating per side.
    local avg, names = {}, {}

    for teamId, team in pairs(match.teams) do
        local total, n = 0, 0
        local list = {}

        for _, p in ipairs(team) do
            if p.key and not p.dummy then
                total = total + (rankedRow(p.key).elo or 1000)
                n = n + 1
                list[#list + 1] = p.name
            end
        end

        avg[teamId] = n > 0 and (total / n) or (Config.Ranked.startingElo or 1000)
        names[teamId] = table.concat(list, ', ')
    end

    local score = ('%s-%s'):format(match.scores.A or 0, match.scores.B or 0)

    for teamId, team in pairs(match.teams) do
        local other = teamId == 'A' and 'B' or 'A'

        for _, p in ipairs(team) do
            if p.key and not p.dummy then
                local before, after = applyElo(
                    p.key, p.name, avg[other], teamId == winner,
                    match.mode, names[other], score)

                if p.src and GetPlayerName(p.src) then
                    TriggerClientEvent('naija-arena:client:rankedResult', p.src, {
                        before = before,
                        after = after,
                        delta = after - before,
                        won = teamId == winner,
                        tier = tierFor(after)
                    })
                end
            end
        end
    end

    dbg('Ranked recorded: %s, team %s won', match.mode, winner)
end

lib.callback.register('naija-arena:server:ranked', function(src, action)
    local key = playerKey(src)
    if not key then return { ok = false } end

    if action == 'state' then
        return {
            ok = true,
            name = nameOf(src),
            you = rankedRow(key),
            tiers = Config.Ranked.tiers,
            placementMatches = Config.Ranked.placementMatches,
            placementMultiplier = Config.Ranked.placementMultiplier,
            kFactor = Config.Ranked.kFactor
        }
    end

    if action == 'top' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT name, elo, wins, losses FROM tenx_arena_ranked
                WHERE placed >= ?
                ORDER BY elo DESC LIMIT 25
            ]], { Config.Ranked.placementMatches or 10 })
        end)
        return { ok = true, rows = ok and (rows or {}) or {} }
    end

    if action == 'history' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT mode, opponent, won, elo_before, elo_after, score
                FROM tenx_arena_ranked_history
                WHERE identifier = ?
                ORDER BY played_at DESC LIMIT 20
            ]], { key })
        end)
        return { ok = true, rows = ok and (rows or {}) or {} }
    end

    return { ok = false }
end)

-- ── giving items by hand ──
-- For testing, for prizes, and for putting right whatever went wrong. Goes
-- into their KEPT inventory, so it survives a logout like anything they
-- earned -- and shows in their grid straight away if they are looking at it.
RegisterCommand('rzgive', function(src, args)
    local function say(msg, kind)
        if src == 0 then print('[arena] ' .. msg) else notify(src, msg, kind or 'inform') end
    end

    if src ~= 0 and not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    -- rzgive add|remove <id> <item> [n], or the short form without a verb.
    local verb = (args[1] or ''):lower()
    local target, item, amount

    if verb == 'add' or verb == 'give' then
        target, item, amount = tonumber(args[2]), args[3], math.abs(tonumber(args[4]) or 1)
    elseif verb == 'remove' or verb == 'take' then
        -- Handled here rather than handed to rztake: ExecuteCommand runs as
        -- console, so the admin who typed it would get no reply.
        target, item, amount = tonumber(args[2]), args[3], math.abs(tonumber(args[4]) or 1)

        if not target or not item then
            return say('rzgive remove <player id> <item> [amount]')
        end
        if not GetPlayerName(target) then
            return say('That player is not online.', 'error')
        end

        local resolved
        for id in pairs(Config.Items or {}) do
            if id:lower() == item:lower() then resolved = id break end
        end
        if not resolved then return say('No item by that name.', 'error') end

        local key = playerKey(target)
        if not key then return end

        local had = RzCountItem(key, resolved)
        if had < amount then
            return say(('They only have %s of those.'):format(had), 'error')
        end

        RzRemoveItem(key, resolved, amount)
        if RzSyncToMatch then RzSyncToMatch(target, key) end

        local def = (Config.Items or {})[resolved] or {}
        notify(target, ('Lost %s x%s.'):format(def.label or resolved, amount), 'inform')
        return say(('Took %s x%s from %s.')
            :format(def.label or resolved, amount, GetPlayerName(target)), 'success')
    else
        target, item, amount = tonumber(args[1]), args[2], tonumber(args[3]) or 1
    end

    if not target or not item then
        say('rzgive add|remove <player id> <item> [amount]   --  rzitems lists what exists')
        return
    end

    if not GetPlayerName(target) then
        return say('That player is not online.', 'error')
    end

    -- Case-insensitive, so nobody has to type WEAPON_ASSAULTRIFLE exactly.
    local def, resolved = nil, nil
    for id, d in pairs(Config.Items or {}) do
        if id:lower() == item:lower() then def, resolved = d, id break end
    end

    if not def then
        return say(('No item called "%s". Run rzitems to see what exists.'):format(item), 'error')
    end

    if amount < 1 then
        return say('Amount has to be at least 1.', 'error')
    end

    local key = playerKey(target)
    if not key then return say('Could not identify that player.', 'error') end

    local ok, err = RzAddItem(key, resolved, amount)
    if not ok then
        return say(('Could not give it: %s'):format(err or 'no room'), 'error')
    end

    -- Straight into their grid, rather than waiting for a respawn.
    if RzSyncToMatch then RzSyncToMatch(target, key) end

    notify(target, ('Received %s x%s.'):format(def.label or resolved, amount), 'success')
    say(('Gave %s x%s to %s.'):format(def.label or resolved, amount, GetPlayerName(target)), 'success')

    dbg('%s gave %s x%s to %s',
        src == 0 and 'console' or GetPlayerName(src), resolved, amount, GetPlayerName(target))
end, false)

RegisterCommand('rztake', function(src, args)
    local function say(msg, kind)
        if src == 0 then print('[arena] ' .. msg) else notify(src, msg, kind or 'inform') end
    end

    if src ~= 0 and not hasPermission(src) then
        return notify(src, Config.Text.no_permission, 'error')
    end

    local target = tonumber(args[1])
    local item = args[2]
    local amount = tonumber(args[3]) or 1

    if not target or not item then
        return say('rztake <player id> <item> [amount]')
    end

    if not GetPlayerName(target) then
        return say('That player is not online.', 'error')
    end

    local resolved
    for id in pairs(Config.Items or {}) do
        if id:lower() == item:lower() then resolved = id break end
    end
    if not resolved then return say('No item by that name.', 'error') end

    local key = playerKey(target)
    if not key then return end

    local had = RzCountItem(key, resolved)
    if had < amount then
        return say(('They only have %s of those.'):format(had), 'error')
    end

    RzRemoveItem(key, resolved, amount)
    if RzSyncToMatch then RzSyncToMatch(target, key) end

    say(('Took %s x%s from %s.'):format(resolved, amount, GetPlayerName(target)), 'success')
end, false)

-- What can be given, so nobody has to read the config to find out.
RegisterCommand('rzitems', function(src)
    local weapons, kit = {}, {}

    for id, d in pairs(Config.Items or {}) do
        local line = ('  %-24s %s'):format(id, d.label or '')
        if d.weapon then weapons[#weapons + 1] = line else kit[#kit + 1] = line end
    end

    table.sort(weapons)
    table.sort(kit)

    local out = { '^3======== ITEMS ========^0', 'WEAPONS' }
    for _, l in ipairs(weapons) do out[#out + 1] = l end
    out[#out + 1] = ''
    out[#out + 1] = 'EVERYTHING ELSE'
    for _, l in ipairs(kit) do out[#out + 1] = l end
    out[#out + 1] = '^3rzgive <id> <item> [amount]^0'
    out[#out + 1] = '^3=======================^0'

    if src == 0 then
        for _, l in ipairs(out) do print(l) end
    else
        TriggerClientEvent('naija-arena:client:printLines', src, out)
    end
end, false)

-- ── handing something to somebody ──
-- Player to player, in the world. The whole point of an inventory people can
-- rearrange is being able to pass things across, and doing it by hand beats
-- any amount of admin commands.

lib.callback.register('naija-arena:server:invNearby', function(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return { players = {} } end

    local here = GetEntityCoords(ped)
    local bucket = GetPlayerRoutingBucket(src)
    local range = (Config.MatchInventory and Config.MatchInventory.giveRange) or 4.0

    local out = {}

    for _, id in ipairs(GetPlayers()) do
        local other = tonumber(id)

        -- Same bucket only. Someone standing in the same coordinates in a
        -- different instance is not actually next to you.
        if other ~= src and GetPlayerRoutingBucket(other) == bucket then
            local op = GetPlayerPed(other)
            if op and op ~= 0 then
                local d = #(here - GetEntityCoords(op))
                if d <= range then
                    out[#out + 1] = {
                        id = other,
                        name = nameOf(other),
                        distance = string.format('%.1f', d)
                    }
                end
            end
        end
    end

    table.sort(out, function(a, b) return tonumber(a.distance) < tonumber(b.distance) end)
    return { players = out }
end)

RegisterNetEvent('naija-arena:server:invGive', function(slot, amount, target)
    local src = source
    slot, amount, target = tonumber(slot), tonumber(amount), tonumber(target)
    if not (slot and amount and target) or amount < 1 then return end

    if not isFighting(src) and not InLobby[src] then return end
    if not GetPlayerName(target) then
        return notify(src, 'They are not here any more.', 'error')
    end

    -- Checked again on the server rather than trusting the range the client
    -- showed. That list could be a minute old, or made up.
    local a, b = GetPlayerPed(src), GetPlayerPed(target)
    if not a or not b or a == 0 or b == 0 then return end

    local range = (Config.MatchInventory and Config.MatchInventory.giveRange) or 4.0
    if #(GetEntityCoords(a) - GetEntityCoords(b)) > range + 1.0 then
        return notify(src, 'Too far away.', 'error')
    end

    if GetPlayerRoutingBucket(src) ~= GetPlayerRoutingBucket(target) then
        return notify(src, 'They are not in the same place as you.', 'error')
    end

    local entry = (Inv[src] or {})[slot]
    if not entry then return end

    amount = math.min(amount, entry.count)
    local def = itemDef(entry.name) or {}

    -- A worn weapon carries its wear across; handing over a rifle with two
    -- lives left should not hand over a fresh one.
    local tKey = playerKey(target)
    if not tKey then return end

    local ok, err = RzAddItem(tKey, entry.name, amount)
    if not ok then
        return notify(src, ('They cannot carry that: %s'):format(err or 'no room'), 'error')
    end

    if def.weapon and entry.dur then
        for _, e in pairs(rzLoad(tKey).slots) do
            if e.name == entry.name and e.dur == def.durability then
                e.dur = entry.dur
                break
            end
        end
    end

    entry.count = entry.count - amount
    if entry.count <= 0 then Inv[src][slot] = nil end

    pushInv(src)

    if InLobby[src] and not isFighting(src) and RzSyncFromMatch then
        RzSyncFromMatch(src)
    end
    if RzSyncToMatch then RzSyncToMatch(target, tKey) end

    TriggerClientEvent('naija-arena:client:invChanged', src)

    notify(src, ('Gave %s x%s to %s.'):format(def.label or entry.name, amount, nameOf(target)), 'success')
    notify(target, ('%s gave you %s x%s.'):format(nameOf(src), def.label or entry.name, amount), 'inform')
end)

RegisterNetEvent('naija-arena:server:invDrop', function(slot, amount)
    local src = source
    slot, amount = tonumber(slot), tonumber(amount)
    if not (slot and amount) or amount < 1 then return end
    if not isFighting(src) and not InLobby[src] then return end

    local entry = (Inv[src] or {})[slot]
    if not entry then return end

    amount = math.min(amount, entry.count)
    local def = itemDef(entry.name) or {}

    -- On the ground, not deleted.
    local placed = ArenaDropItem and ArenaDropItem(src, entry.name, amount, entry.dur)

    entry.count = entry.count - amount
    if entry.count <= 0 then Inv[src][slot] = nil end

    pushInv(src)

    if InLobby[src] and not isFighting(src) and RzSyncFromMatch then
        RzSyncFromMatch(src)
    end

    TriggerClientEvent('naija-arena:client:invChanged', src)

    notify(src, placed
        and ('Dropped %s x%s. It is on the ground.'):format(def.label or entry.name, amount)
        or  ('Dropped %s x%s.'):format(def.label or entry.name, amount), 'inform')
end)

-- ============================================================
--  THINGS ON THE GROUND
-- ============================================================
-- A dropped item lands where you dropped it and anyone can pick it up.
--
-- The alternative -- deleting it -- is the fastest way to make people
-- distrust an inventory. Something vanishes, they assume it was eaten, and
-- they are usually right.
--
-- Piles are per bucket, so a drop in a fight is not lying on the floor of
-- the city at the same coordinates.

local Drops = {}      -- [id] = { x, y, z, bucket, name, count, dur, at, by }
local nextDropId = 1

local function dropList(bucket)
    local out = {}
    for id, d in pairs(Drops) do
        if d.bucket == bucket then
            local def = itemDef(d.name) or {}
            out[#out + 1] = {
                id = id, x = d.x, y = d.y, z = d.z,
                name = d.name, count = d.count,
                label = def.label or d.name,
                image = def.image or d.name
            }
        end
    end
    return out
end

local function pushDrops(bucket)
    for _, pid in ipairs(GetPlayers()) do
        local s = tonumber(pid)
        if GetPlayerRoutingBucket(s) == bucket then
            TriggerClientEvent('naija-arena:client:drops', s, dropList(bucket))
        end
    end
end

function ArenaDropItem(src, name, count, dur)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local cfg = Config.MatchInventory
    local bucket = GetPlayerRoutingBucket(src)

    -- Cap per bucket, oldest first, so a floor cannot be carpeted.
    local inBucket = 0
    local oldestId, oldestAt = nil, math.huge

    for id, d in pairs(Drops) do
        if d.bucket == bucket then
            inBucket = inBucket + 1
            if d.at < oldestAt then oldestId, oldestAt = id, d.at end
        end
    end

    if inBucket >= (cfg.dropMax or 40) and oldestId then
        Drops[oldestId] = nil
    end

    local c = GetEntityCoords(ped)
    local id = nextDropId
    nextDropId = nextDropId + 1

    Drops[id] = {
        x = c.x, y = c.y, z = c.z - 0.9,
        bucket = bucket,
        name = name, count = count, dur = dur,
        at = os.time(),
        by = nameOf(src)
    }

    pushDrops(bucket)
    return true
end

RegisterNetEvent('naija-arena:server:pickup', function(id)
    local src = source
    id = tonumber(id)

    local d = Drops[id]
    if not d then return end

    if GetPlayerRoutingBucket(src) ~= d.bucket then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local range = (Config.MatchInventory and Config.MatchInventory.dropRange) or 2.0
    if #(GetEntityCoords(ped) - vec3(d.x, d.y, d.z)) > range + 1.5 then
        return notify(src, 'Too far away.', 'error')
    end

    local key = playerKey(src)
    if not key then return end

    local ok, err = RzAddItem(key, d.name, d.count)
    if not ok then
        return notify(src, ('Cannot pick that up: %s'):format(err or 'no room'), 'error')
    end

    -- Wear travels with the weapon, so picking one up does not refurbish it.
    if d.dur then
        local def = itemDef(d.name) or {}
        for _, e in pairs(rzLoad(key).slots) do
            if e.name == d.name and e.dur == def.durability then
                e.dur = d.dur
                break
            end
        end
    end

    Drops[id] = nil

    if RzSyncToMatch then RzSyncToMatch(src, key) end
    pushDrops(d.bucket)

    local def = itemDef(d.name) or {}
    notify(src, ('Picked up %s x%s.'):format(def.label or d.name, d.count), 'success')
end)

RegisterNetEvent('naija-arena:server:wantDrops', function()
    local src = source
    TriggerClientEvent('naija-arena:client:drops', src, dropList(GetPlayerRoutingBucket(src)))
end)

-- Piles do not lie about forever.
CreateThread(function()
    while true do
        Wait(30000)

        local cfg = Config.MatchInventory
        local life = (cfg and cfg.dropExpiry) or 300
        local now = os.time()
        local touched = {}

        for id, d in pairs(Drops) do
            if now - d.at > life then
                Drops[id] = nil
                touched[d.bucket] = true
            end
        end

        for bucket in pairs(touched) do pushDrops(bucket) end
    end
end)

-- ============================================================
--  WAGERS
-- ============================================================
-- Both sides stake coins, the winners split the pot.
--
-- The coins are TAKEN when the match starts and held here until it ends. The
-- alternative -- checking a balance at the end -- lets someone stake 500,
-- spend it in the shop while the countdown runs, and win a pot they never
-- actually paid into.

local Pot = {}   -- [match key] = { stake = n, paid = { [key] = n }, total = n }

--- Can everyone in this room cover the stake?
--- Checked before the match forms, so nobody is teleported into an arena and
--- then told it is off.
function WagerCheck(room)
    local stake = tonumber(room.wager) or 0
    if stake <= 0 then return true end

    local short = {}

    for _, key in ipairs(room.order) do
        local m = room.members[key]
        if m and not m.dummy then
            local have = RzCoins(key)
            if have < stake then
                short[#short + 1] = ('%s (%s)'):format(m.name or '?', have)
            end
        end
    end

    if #short > 0 then
        return false, ('Cannot cover the %s stake: %s')
            :format(stake, table.concat(short, ', '))
    end

    return true
end

--- Take the stakes. Anything already taken is given back if someone cannot
--- pay, so a half-collected pot never exists.
function WagerCollect(matchKey, match, room)
    local stake = tonumber(room and room.wager) or 0
    if stake <= 0 then return true end

    local paid, total = {}, 0

    for _, team in pairs(match.teams) do
        for _, m in ipairs(team) do
            if m.key and not m.dummy then
                local ok = RzTakeCoins(m.key, stake, 'wager:' .. matchKey)

                if not ok then
                    -- Put back whatever was collected before this point.
                    for key, amount in pairs(paid) do
                        RzGiveCoins(key, amount, 'wager:refund')
                        if RzSyncToMatch then RzSyncToMatch(nil, key) end
                    end

                    dbg('wager: %s could not pay %s, refunded everyone', m.key, stake)
                    return false
                end

                paid[m.key] = stake
                total = total + stake

                if m.src and GetPlayerName(m.src) then
                    if RzSyncToMatch then RzSyncToMatch(m.src, m.key) end
                    notify(m.src, ('%s staked. Winner takes the pot.'):format(stake), 'inform')
                end
            end
        end
    end

    Pot[matchKey] = { stake = stake, paid = paid, total = total }
    return true
end

--- Pay out. A draw or an abandoned match refunds rather than paying anyone,
--- because there is no honest way to split a pot nobody won.
function WagerSettle(matchKey, match, winner)
    local pot = Pot[matchKey]
    if not pot then return end
    Pot[matchKey] = nil

    local winners = {}
    if winner and match.teams[winner] then
        for _, m in ipairs(match.teams[winner]) do
            if m.key and not m.dummy and pot.paid[m.key] then
                winners[#winners + 1] = m
            end
        end
    end

    -- Nobody won it, or the winners all left: everyone gets theirs back.
    if #winners == 0 then
        for key, amount in pairs(pot.paid) do
            RzGiveCoins(key, amount, 'wager:refund')
        end
        dbg('wager %s refunded: no winner to pay', matchKey)
        return
    end

    local cut = math.floor(pot.total * (Config.Wager.houseCut or 0))
    local prize = pot.total - cut
    local each = math.floor(prize / #winners)

    for _, m in ipairs(winners) do
        RzGiveCoins(m.key, each, 'wager:won')

        if m.src and GetPlayerName(m.src) then
            if RzSyncToMatch then RzSyncToMatch(m.src, m.key) end
            TriggerClientEvent('naija-arena:client:coinsEarned', m.src, {
                amount = each,
                reason = ('Won the %s pot'):format(pot.total),
                balance = RzCoins(m.key)
            })
        end
    end

    -- Rounding leftovers go to the first winner rather than vanishing.
    local spare = prize - (each * #winners)
    if spare > 0 and winners[1] then
        RzGiveCoins(winners[1].key, spare, 'wager:rounding')
    end

    dbg('wager %s: pot %s to %s winner(s), %s each', matchKey, pot.total, #winners, each)
end

--- Give everything back, for a match that never happened.
function WagerRefund(matchKey)
    local pot = Pot[matchKey]
    if not pot then return end
    Pot[matchKey] = nil

    for key, amount in pairs(pot.paid) do
        RzGiveCoins(key, amount, 'wager:cancelled')
    end
end

-- A restart mid-match would otherwise leave every stake in a table that no
-- longer exists. Coins people staked are coins they earned; losing them to a
-- resource restart is not something anyone should have to accept.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end

    for matchKey, pot in pairs(Pot) do
        for key, amount in pairs(pot.paid) do
            pcall(function()
                local inv = rzLoad(key)
                RzAddItem(key, 'rz_coin', amount, true)
                rzSave(key)
            end)
        end
        print(('[arena] refunded the %s pot on shutdown'):format(pot.total))
    end
end)

-- ============================================================
--  THE CONTROL PANEL
-- ============================================================
-- What is happening right now, and the handles to change it. Everything here
-- was previously a command typed blind -- and a command you type blind is one
-- you get wrong on the player id.

lib.callback.register('naija-arena:server:control', function(src, action, data)
    if not hasPermission(src) then
        return { ok = false, message = Config.Text.no_permission }
    end

    data = data or {}

    -- ── what is going on ──
    if action == 'state' then
        local matches = {}

        for matchKey, m in pairs(Matches) do
            local players = {}

            for teamId, team in pairs(m.teams) do
                for _, p in ipairs(team) do
                    if not p.dummy then
                        players[#players + 1] = {
                            name = p.name, team = teamId,
                            kills = m.kills[p.key] or 0,
                            deaths = m.deaths[p.key] or 0,
                            id = p.src
                        }
                    end
                end
            end

            local arena = Arenas[m.arenaId]
            matches[#matches + 1] = {
                key = matchKey,
                arena = arena and arena.name or ('#' .. tostring(m.arenaId)),
                arenaId = m.arenaId,
                mode = m.mode,
                ranked = m.ranked or false,
                scores = m.scores,
                target = m.score,
                phase = m.phase,
                started = m.startedAt and (os.time() - m.startedAt) or 0,
                players = players
            }
        end

        -- Any other mode that registered itself, asked rather than assumed.
        --
        -- The free-for-all lives in its own resource now. The control panel
        -- still shows what is happening in it, but by asking -- so this works
        -- whether that resource is running, stopped, or was never installed.
        local zones = {}

        if GetResourceState('tenx-redzone') == 'started' then
            local ok, list = pcall(function()
                return exports['tenx-redzone']:getZones()
            end)

            if ok and type(list) == 'table' then
                for _, z in ipairs(list) do
                    local players = {}
                    local ok2, inside = pcall(function()
                        return exports['tenx-redzone']:playersInZone(z.id)
                    end)
                    if ok2 and type(inside) == 'table' then players = inside end

                    zones[#zones + 1] = {
                        id = z.id, name = z.name,
                        ready = true, players = players,
                    }
                end
            end
        end

        -- Everyone this script currently knows about, and where they are.
        local people = {}
        for _, pid in ipairs(GetPlayers()) do
            local s = tonumber(pid)
            local key = playerKey(s)

            local where = 'city'
            if Occupants[s] then where = 'match'
            elseif InLobby[s] then where = 'lobby' end

            if where ~= 'city' or data.everyone then
                people[#people + 1] = {
                    id = s,
                    name = nameOf(s),
                    where = where,
                    coins = key and RzCoins(key) or 0
                }
            end
        end

        table.sort(people, function(a, b) return a.name < b.name end)

        local queued = 0
        for _, list in pairs(Queue) do
            for _, e in ipairs(list) do queued = queued + e.size end
        end

        local rooms = 0
        for _ in pairs(Rooms) do rooms = rooms + 1 end

        return {
            ok = true,
            matches = matches,
            zones = zones,
            people = people,
            totals = {
                queued = queued,
                rooms = rooms,
                lobby = (function() local n = 0 for _ in pairs(InLobby) do n = n + 1 end return n end)(),
                live = #matches
            }
        }
    end

    -- ── coins, without typing an id ──
    if action == 'coins' then
        local target = tonumber(data.id)
        local amount = math.floor(tonumber(data.amount) or 0)

        if not target or amount == 0 then
            return { ok = false, message = 'Pick a player and an amount.' }
        end
        if not GetPlayerName(target) then
            return { ok = false, message = 'They have gone offline.' }
        end

        local key = playerKey(target)
        if not key then return { ok = false, message = 'Could not identify them.' } end

        local by = GetPlayerName(src)
        local balance

        if amount > 0 then
            balance = RzGiveCoins(key, amount, 'admin:' .. by)
        else
            local took
            took, balance = RzTakeCoins(key, -amount, 'admin:' .. by)
            if not took then
                return { ok = false, message = ('They only have %s.'):format(balance) }
            end
        end

        if RzSyncToMatch then RzSyncToMatch(target, key) end

        notify(target, ('%s %s %s.'):format(
            amount > 0 and 'Received' or 'Lost', math.abs(amount), Config.Coins.label),
            amount > 0 and 'success' or 'inform')

        dbg('%s adjusted %s by %s coins', by, GetPlayerName(target), amount)

        return { ok = true, balance = balance,
                 message = ('%s now has %s.'):format(GetPlayerName(target), balance) }
    end

    -- ── ending a match early ──
    if action == 'endMatch' then
        local m = Matches[data.key]
        if not m then return { ok = false, message = 'That match is already over.' } end

        endMatch(data.key, data.winner, 'admin')
        return { ok = true, message = 'Match ended.' }
    end

    -- ── pulling one person out ──
    if action == 'pull' then
        local target = tonumber(data.id)
        if not target or not GetPlayerName(target) then
            return { ok = false, message = 'They have gone offline.' }
        end

        if Occupants[target] then removeFromArena(target) end

        ReturnToLobby(target)
        notify(target, 'An admin moved you back to the lobby.', 'inform')

        return { ok = true, message = ('%s moved to the lobby.'):format(GetPlayerName(target)) }
    end

    return { ok = false, message = 'Unknown action.' }
end)

-- ============================================================
--  EXPORTS
-- ============================================================
-- What another resource can use.
--
-- The free-for-all mode lives in its own resource now. It needs the same
-- inventory and the same coins as everything else -- a player who buys a
-- rifle should carry it into either mode -- so the storage stays here and is
-- reached through these.
--
-- Every one takes a licence identifier, not a server id: a player can drop
-- and reconnect on a different id, and their belongings should not.

--- What someone is carrying. A copy, so a caller cannot edit our state.
exports('getInventory', function(key)
    if not key then return nil end
    local inv = rzLoad(key)

    local out = {}
    for slot, e in pairs(inv.slots or {}) do
        out[slot] = { name = e.name, count = e.count, dur = e.dur }
    end
    return out
end)

--- Coins. These ARE the rz_coin items in the bag -- there is no separate
--- number, so this counts what they hold.
exports('getCoins', function(key)
    return key and RzCoins(key) or 0
end)

exports('giveCoins', function(key, amount, reason)
    if not key or not amount or amount <= 0 then return 0 end
    return RzGiveCoins(key, amount, reason or 'export')
end)

exports('takeCoins', function(key, amount, reason)
    if not key or not amount or amount <= 0 then return false, 0 end
    return RzTakeCoins(key, amount, reason or 'export')
end)

--- Add or remove an item. `fromBack` keeps new items out of the hotbar slots.
exports('addItem', function(key, name, count, fromBack)
    if not key or not name then return false, 'Nothing to add.' end
    return RzAddItem(key, name, count or 1, fromBack)
end)

exports('removeItem', function(key, name, count)
    if not key or not name then return false end
    return RzRemoveItem(key, name, count or 1)
end)

exports('countItem', function(key, name)
    if not key or not name then return 0 end
    return RzCountItem(key, name)
end)

exports('hasWeapon', function(key)
    return key and RzHasWeapon(key) or false
end)

--- Push the kept inventory into a player's live grid, and pull it back.
--- Anything running its own mode needs both: one to arm them on the way in,
--- one to save what happened on the way out.
exports('syncToPlayer', function(src, key)
    if not src or not key then return false end
    if RzSyncToMatch then RzSyncToMatch(src, key) end
    return true
end)

exports('syncFromPlayer', function(src, key)
    if not src or not key then return false end
    if RzSyncFromMatch then RzSyncFromMatch(src, key) end
    return true
end)

--- The item definitions, so another resource does not have to keep its own
--- copy in step with ours.
exports('getItems', function()
    return Config.Items
end)

--- Somebody's licence from their server id, using the same rules we do.
--- Without this every caller invents its own and they disagree the first time
--- a player connects with an unusual identifier set.
exports('getKey', function(src)
    return playerKey(src)
end)

--- Can this player use admin tools?
---
--- Exposed so another resource does not have to keep its own copy of the
--- permission rules, which is how one of them ends up letting the wrong
--- people through.
exports('isStaff', function(src)
    return src and hasPermission(src) or false
end)

--- Arenas, so another mode can use the same marked shapes rather than asking
--- you to mark everything twice.
--- Is this player physically inside the shape of arena N?
---
--- The arena owns the shapes and already has the polygon maths loaded, so it
--- answers rather than handing bounds out for somebody else to test against
--- with their own copy of the code. Two implementations of "inside" is how
--- one of them ends up disagreeing.
---
--- Height is checked too when the shape has a floor and ceiling: standing on
--- a roof above a zone is not being in it.
--- The arena's OWN in/out test, kept as the fallback.
---
--- ZoneLink.insideArena asks tenx-zones first when the handover is on, and
--- falls back to this when it is off or the call fails. It is a global so the
--- link file can reach it.
function ArenaInsideOwn(src, arenaId)
    if not src or not arenaId then return false end

    local a = Arenas[arenaId]
    if not (a and a.bounds and a.bounds.points) then return false end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local c = GetEntityCoords(ped)
    if not Poly.contains(a.bounds.points, c.x, c.y) then return false end

    local b = a.bounds
    if b.minZ and c.z < b.minZ - 2.0 then return false end
    if b.maxZ and c.z > b.maxZ + 2.0 then return false end

    return true
end

--- What everyone else calls. Routes to tenx-zones when the handover is on.
exports('insideArena', function(src, arenaId)
    if ZoneLink and ZoneLink.insideArena then
        return ZoneLink.insideArena(src, arenaId)
    end
    return ArenaInsideOwn(src, arenaId)
end)

exports('getArenas', function()
    local out = {}
    for id, a in pairs(Arenas) do
        if a.enabled and a.bounds then
            out[#out + 1] = {
                id = id,
                name = a.name,
                bounds = a.bounds,
                spawns = a.spawns,
            }
        end
    end
    return out
end)

--- Is this player busy with us? Another mode should not drag someone out of
--- a match it does not know about.
--- Is this player in something another mode must not interrupt?
---
--- A live MATCH only. Standing in the lobby is not being busy -- it is
--- standing in a menu, and refusing to let somebody walk from there into a
--- free-for-all is the kind of rule that makes two modes feel like two
--- servers.
exports('isBusy', function(src)
    if not src then return false end
    return Player(src).state.arenaMatch == true
end)

--- In the lobby, which another mode should pull them out of rather than
--- refuse. Separate from isBusy so the caller decides what to do about it.
exports('isInLobby', function(src)
    if not src then return false end
    return Player(src).state.arenaLobby == true
end)

-- ── another resource has this player ──
--
-- A mode living elsewhere needs the inventory to answer for its players, and
-- this resource has no way to know about them otherwise. So it says so.
--
-- Without this, the server refuses to send anyone their inventory unless it
-- can see them in a match or its own lobby -- which is a player holding a
-- weapon they own with an empty grid and no idea why.
local Claimed = {}

--- Mirrored to a statebag so the CLIENT can check the claim too.
---
--- The client tracks this locally as well, because it has to arm the kit the
--- instant the mode starts and a statebag has not replicated by then. But a
--- local boolean is something nothing can disprove: if the claiming resource
--- never releases -- it restarted, or the player left by one of the arena's
--- own exits -- the flag sticks true forever, the hotbar loop keeps the
--- inventory locked every frame and the stuck-lock watchdog cannot see past
--- it. Which is the exact failure the watchdog exists to catch.
---
--- So the server stays the authority and the local flag is only a bridge over
--- replication, the same way LobbyKit is.
local function setClaimState(src, on)
    if GetPlayerName(src) then
        Player(src).state:set('arenaClaimed', on and true or false, true)
    end
end

--- Drop a claim, wherever from. Global so the exits further up this file can
--- reach it -- Claimed itself is a local down here and not in their scope.
function ClearClaim(src)
    if not src then return end
    Claimed[src] = nil
    setClaimState(src, false)
end

exports('claimPlayer', function(src)
    if not src then return false end
    Claimed[src] = GetInvokingResource() or true
    setClaimState(src, true)
    return true
end)

exports('releasePlayer', function(src)
    if src then
        Claimed[src] = nil
        setClaimState(src, false)
    end
    return true
end)

--- Is somebody else running a mode for this player?
function ClaimedByOther(src)
    return Claimed[src] ~= nil
end

-- A resource that stops releases whoever it was holding, rather than leaving
-- them claimed by something that no longer exists.
AddEventHandler('onResourceStop', function(res)
    for src, by in pairs(Claimed) do
        if by == res then
            Claimed[src] = nil
            setClaimState(src, false)
        end
    end
end)

AddEventHandler('playerDropped', function()
    Claimed[source] = nil
end)

--- Move someone back to the normal world, our way, so buckets and inventory
--- are handled the same however they leave.
exports('returnToCity', function(src)
    if not src then return false end
    ReturnToLobby(src)
    return true
end)

-- ============================================================
--  OTHER RESOURCES PLUGGING IN
-- ============================================================
-- Another mode can register itself here and appear on the wall boards without
-- this resource knowing anything about it.
--
-- The alternative is hard-coding every mode into the board renderer, which
-- means the arena has to be edited every time somebody adds one -- and means
-- a board goes blank the day that other resource is stopped.
--
-- A provider gives us the NAME of an export to call, not a function.
--
-- Functions do not survive crossing a resource boundary -- what arrives on
-- this side is not callable, which is exactly what "has no fetch function"
-- meant. So a provider registers where to find its data instead:
--
--   id        what a board's `source` has to say to show it
--   export    the export on the registering resource that returns the rows
--   label     what the board is called
--   footer    the line along the bottom
--
-- Nothing is called unless a board is actually showing it, and a provider
-- that errors or goes away is skipped rather than taking the board with it.

local Providers = {}

exports('registerBoard', function(id, def)
    if type(id) ~= 'string' or type(def) ~= 'table' then
        print('^1[arena] a resource tried to register a board with no id^0')
        return false
    end

    local from = def.resource or GetInvokingResource()

    if type(def.export) ~= 'string' or not from then
        print(('^1[arena] board provider "%s" needs an export name and a resource^0')
            :format(id))
        print('^1        e.g. { export = "getLeaderboard", label = "..." }^0')
        return false
    end

    Providers[id] = {
        id = id,
        label = def.label or id,
        footer = def.footer,
        accent = def.accent,
        columns = def.columns,
        export = def.export,
        from = from,
    }

    print(('[arena] %s registered the "%s" board'):format(Providers[id].from, id))

    -- Any wall already set to this kind was showing nothing. Now it can.
    if PushBillboard then PushBillboard() end
    return true
end)

exports('unregisterBoard', function(id)
    if Providers[id] then
        print(('[arena] "%s" board unregistered'):format(id))
        Providers[id] = nil
        if PushBillboard then PushBillboard() end
    end
    return true
end)

--- What a registered provider currently has. Errors are swallowed: a mode
--- with a broken leaderboard should not stop the wall showing the others.
function ProviderBoard(id)
    local p = Providers[id]
    if not p then return nil end

    -- The resource may have stopped since it registered.
    if GetResourceState(p.from) ~= 'started' then return nil end

    local ok, res = pcall(function()
        return exports[p.from][p.export](nil)
    end)

    if not ok then
        print(('^1[arena] the "%s" board provider errored: %s^0'):format(id, tostring(res)))
        return nil
    end

    if type(res) ~= 'table' then return nil end

    res.title = res.title or p.label
    res.footer = res.footer or p.footer
    res.which = id
    return res
end

--- Which providers exist, so the builder can offer them as board kinds.
function ProviderList()
    local out = {}
    for id, p in pairs(Providers) do
        out[#out + 1] = { id = id, label = p.label, from = p.from }
    end
    return out
end

-- A resource that stops takes its board with it, rather than leaving a wall
-- calling into something that is no longer there.
AddEventHandler('onResourceStop', function(res)
    for id, p in pairs(Providers) do
        if p.from == res then
            Providers[id] = nil
            print(('[arena] "%s" board went away with %s'):format(id, res))
        end
    end
end)

-- ============================================================
--  THE PODIUM
-- ============================================================
-- The top three ranked players, for the peds standing in the lobby.
--
-- Cached, because this is asked for by every client that walks into the
-- lobby and the answer is the same for all of them. Ratings do not move
-- between two people arriving thirty seconds apart.

local podiumCache = nil
local podiumAt = 0

local function podiumRows()
    local now = os.time()
    if podiumCache and (now - podiumAt) < 60 then return podiumCache end

    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT name, elo, wins, losses, appearance FROM tenx_arena_ranked
            WHERE placed >= ?
            ORDER BY elo DESC LIMIT 3
        ]], { Config.Ranked and Config.Ranked.placementMatches or 10 })
    end)

    podiumCache = ok and (rows or {}) or {}
    podiumAt = now
    return podiumCache
end

RegisterNetEvent('naija-arena:server:wantPodium', function()
    local src = source
    if not GetPlayerName(src) then return end
    TriggerClientEvent('naija-arena:client:podium', src, podiumRows())
end)

-- ============================================================
--  WHAT zones_server.lua NEEDS
-- ============================================================
-- Arenas, Matches and bucketFor are locals in this file, so a separate script
-- file cannot see them -- it would read nil globals and quietly do nothing,
-- with no error. These are the deliberate, named openings rather than making
-- that file guess.
--
-- All three go away with the handover in step 5.

function ArenaZoneState()
    return Arenas, Matches
end

function ArenaBucketFor(arenaId, slot)
    return bucketFor(arenaId, slot)
end

--- Write one arena back to the database.
---
--- The migration sets a.zoneId in memory; without this it would be lost on
--- the next restart and the migration would look like it had not run.
function ArenaPersistZone(arenaId)
    local a = Arenas[arenaId]
    if not a then return false end

    MySQL.update.await('UPDATE tenx_arena_zones SET data = ? WHERE id = ?',
        { arenaToData(a), arenaId })

    return true
end

-- ============================================================
--  THE AMBULANCE SCRIPT'S EVENTS, SERVER SIDE
-- ============================================================
-- ak47_qb_ambulancejob documents both a client and a server trigger for each
-- of onPlayerDown, onPlayerDeath and onPlayerRevive. The client half was
-- already handled -- but a script that only fires the SERVER one leaves the
-- client half silent, and the arena then believes a player lying on an
-- incapacitated screen is perfectly fine.
--
-- That is exactly what /rztestrevive reported: "their state: up, down: false,
-- health: 200" while the player was staring at INCAPACITATED. Every check the
-- arena had was a client-side one, and their script had told the server
-- instead.
--
-- So both halves are listened for now, and whichever arrives is relayed to
-- the client so ArenaBodyState is right either way.

local function relayBody(src, state)
    if not GetPlayerName(src) then return end
    TriggerClientEvent('naija-arena:client:bodyState', src, state)
end

for _, def in ipairs({
    { event = (Config.Ambulance or {}).downEvent,   state = 'knocked' },
    { event = (Config.Ambulance or {}).deathEvent,  state = 'dead' },
    { event = (Config.Ambulance or {}).reviveEvent, state = 'up' },
}) do
    if def.event then
        RegisterNetEvent(def.event)
        AddEventHandler(def.event, function(target)
            -- Their script may name the player or rely on source. Both.
            local src = tonumber(target) or source
            if src and src > 0 then relayBody(src, def.state) end
        end)
    end
end

-- ============================================================
--  THE PODIUM'S FACES
-- ============================================================
-- Keeping a player's look so the podium can show the real character rather
-- than a stand-in.
--
-- It has to be CACHED. Every clothing script's "get appearance" takes a
-- connected player, and a leaderboard is mostly people who are offline. So it
-- is captured at the one moment we know somebody is both online and worth
-- putting on a podium: when their ranked result is written.
--
-- Filling in over time is the trade. Anyone who has not played a ranked match
-- since this shipped falls back to a stand-in model, and gets their own face
-- the next time they play one.

--- Grab a player's appearance as JSON, or nil.
---
--- nil is a normal answer -- no clothing script, an older one, a player whose
--- look has never been saved. The caller keeps whatever was already stored
--- rather than overwriting it with nothing.
function CaptureAppearance(src)
    local cfg = Config.Podium
    if not (cfg and cfg.realFaces) then return nil end

    src = tonumber(src)
    if not src or not GetPlayerName(src) then return nil end

    for _, c in ipairs(cfg.appearanceGet or {}) do
        if GetResourceState(c.resource) == 'started' then
            local ok, look = pcall(function()
                return exports[c.resource][c.export](nil, src)
            end)

            if ok and type(look) == 'table' then
                local encoded = json.encode(look)

                -- A sanity bound. An appearance is a few kilobytes; anything
                -- enormous is a different shape than expected and does not
                -- belong in a column that is read on every podium refresh.
                if encoded and #encoded < 60000 then
                    return encoded
                end

                print(('^3[arena] %s returned an appearance of %s bytes -- ignored^0')
                    :format(c.resource, encoded and #encoded or '?'))
                return nil
            end
        end
    end

    return nil
end

--- Add the column on boot.
---
--- CREATE TABLE IF NOT EXISTS does nothing to a table that already exists, so
--- this never appears from re-running the schema file on a live server.
CreateThread(function()
    Wait(3000)
    if not (Config.Podium and Config.Podium.realFaces) then return end

    pcall(function()
        MySQL.query.await(
            'ALTER TABLE tenx_arena_ranked ADD COLUMN `appearance` LONGTEXT NULL')
    end)
end)
