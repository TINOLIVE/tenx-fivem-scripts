-- ============================================================
--  NAIJA 2046 — RED ZONE  (server)
-- ============================================================
-- Always-on free-for-all.
--
-- This resource owns the MODE: who is in which zone, kills, streaks, drops,
-- and its own leaderboard.
--
-- It owns nothing a player carries. Inventories, coins, item definitions and
-- the arena shapes all live in tenx-arena and are reached through its
-- exports -- so a rifle bought in the shop is the same rifle in here, and a
-- coin earned in here spends in the same shop.

local ARENA = Config.RZ.arena

--- Everything we ask the arena for goes through here.
---
--- Wrapped for one reason: if that resource is stopped, restarting, or has
--- been renamed, a bare exports call throws and takes whatever was happening
--- with it. This returns nil instead, and every caller is written to cope.
local warnedAbout = {}

local function arena(fn, ...)
    if GetResourceState(ARENA) ~= 'started' then return nil end

    local ok, res, extra = pcall(function(...)
        return exports[ARENA][fn](nil, ...)
    end, ...)

    if not ok then
        local msg = tostring(res)

        -- "No such export" means one specific thing: the arena that is
        -- running is older than this resource. Saying so once, plainly, beats
        -- repeating a stack trace every time somebody walks past a board.
        if msg:find('No such export') then
            if not warnedAbout[fn] then
                warnedAbout[fn] = true
                print(('^1[redzone] %s has no "%s" export.^0'):format(ARENA, fn))
                print('^1           The arena resource needs updating -- this version^0')
                print('^1           of the Red Zone needs the one that ships with it.^0')
            end
        else
            print(('^1[redzone] %s.%s failed: %s^0'):format(ARENA, fn, msg))
        end

        return nil
    end

    return res, extra
end

--- Is the arena new enough to talk to?
---
--- Checked once at startup rather than discovered one broken feature at a
--- time. Everything here was added for this resource; an arena without them
--- is the old combined version.
local function arenaIsCompatible()
    local needed = {
        'getKey', 'getArenas', 'getCoins', 'giveCoins',
        'addItem', 'countItem', 'hasWeapon',
        'syncToPlayer', 'syncFromPlayer',
        'isBusy', 'isInLobby', 'returnToCity', 'registerBoard',
        'claimPlayer', 'releasePlayer',

        -- Required, not optional. The wrapper returns nil when a call fails,
        -- and nil reads as "not inside" -- so against an arena without this
        -- export every kill would silently score nothing at all. Far better
        -- to refuse to start and say which export is missing.
        'insideArena',
    }

    -- isDown and revivePlayer are CLIENT exports on the arena, so they cannot
    -- be checked from here. The client wrapper handles their absence by doing
    -- nothing, which on an older arena means death detection falls back to
    -- being late rather than the mode refusing to start.

    local missing = {}
    for _, fn in ipairs(needed) do
        local ok = pcall(function() return exports[ARENA][fn] end)
        if not ok or exports[ARENA][fn] == nil then
            missing[#missing + 1] = fn
        end
    end

    return #missing == 0, missing
end

-- ── state ──
local RZ = {}          -- [src] = { arenaId, kills, streak, key, name }
local Zones = {}       -- the arena's shapes, refreshed on demand

-- Declared here because refreshZones reads it and the loading code that fills
-- it sits much further down.
local Spawns = {}      -- [arenaId] = { {x,y,z,w}, ... }

-- Same: leave() is used by the spawn-clearing path above its definition.
local leave

-- And loadSpawns, which the startup thread calls but which is defined with
-- the rest of the spawn handling much further down.
local loadSpawns

local function dbg(fmt, ...)
    if Config.RZ.debug then print(('[redzone] ' .. fmt):format(...)) end
end

local function notify(src, msg, kind)
    TriggerClientEvent('ox_lib:notify', src, {
        title = 'Red Zone',
        description = msg,
        type = kind or 'inform',
        position = 'top-center'
    })
end

local function nameOf(src)
    return (GetPlayerName(src) or 'Unknown'):sub(1, 32)
end

--- Is this player standing in the main city?
---
--- Same rule and the same reasoning as the arena's copy: the Red Zone must
--- not be an escape hatch out of an RP scene. Duplicated rather than
--- exported because a security check that depends on another resource
--- answering is a security check that fails open when that resource is
--- restarted.
---
--- Nothing legitimate is lost. The Red Zone ped lives in the arena's lobby
--- bucket, so the honest route -- city, lobby ped, then in -- is untouched.
--- Switching zones from inside works too, since that is bucket 2100.
---
--- On by default with no config entry needed. Set
---     Config.RZ.lobbyOnly = false
--- in config.lua to switch it off.
local function inMainCity(src)
    if Config.RZ.lobbyOnly == false then return false end

    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then return false end   -- unreadable bucket blocks nobody

    return (tonumber(bucket) or 0) == 0
end

--- The arena's licence for a player. Ours has to match theirs exactly or the
--- two resources would file the same person under different names.
local function keyOf(src)
    return arena('getKey', src)
end

--- Which bucket a Red Zone player belongs in.
---
--- ONE bucket for the whole mode once the handover is on. The Red Zone is a
--- place, not an instance -- everyone shares a world, which is what makes a
--- free-for-all work. The old per-zone buckets split a thin player base seven
--- ways for no gain, since the zones are at different map locations anyway.
---
--- The arenaId argument is kept so every call site stays unchanged, and is
--- simply ignored in the new mode.
local function bucketFor(arenaId)
    if RzZones and RzZones.active() then
        return (Config.RZ.zones or {}).bucket or 2100
    end

    return Config.RZ.bucketBase + arenaId
end

-- ============================================================
--  THE ZONES
-- ============================================================
-- Borrowed from the arena, not marked again here. Marking the same shape
-- twice is how the two end up disagreeing about where the wall is.

local function refreshZones()
    -- Zones come from tenx-zones by tag once the handover is on.
    --
    -- Drawing a sphere and tagging it is the whole job -- it appears in the
    -- next /rz with no config edit and no restart. The arena is not asked at
    -- all in this mode, because Red Zone spheres and arena polygons are
    -- different shapes on the same patches of map and the arena knows nothing
    -- about the spheres.
    if RzZones and RzZones.active() then
        return RzZones.refreshZones()
    end

    local list = arena('getArenas')
    if not list then
        Zones = {}
        return false
    end

    Zones = {}
    for _, a in ipairs(list) do
        local allowed = #Config.RZ.onlyZones == 0
        for _, n in ipairs(Config.RZ.onlyZones) do
            if n == a.name then allowed = true break end
        end

        -- A zone needs somewhere to put people, and those are ours. Without
        -- any it is not offered at all -- better than computing a point that
        -- knows nothing about what is actually there and dropping somebody
        -- on a roof or in the sea.
        if allowed and Spawns[a.id] and #Spawns[a.id] > 0 then
            a.spawnPoints = Spawns[a.id]
            Zones[a.id] = a
        end
    end

    return true
end

local function zoneCount(arenaId)
    local n = 0
    for _, d in pairs(RZ) do
        if d.arenaId == arenaId then n = n + 1 end
    end
    return n
end

local function zoneList()
    refreshZones()

    local out = {}
    for id, a in pairs(Zones) do
        out[#out + 1] = { id = id, name = a.name, players = zoneCount(id) }
    end

    table.sort(out, function(x, y) return x.name < y.name end)
    return out
end

local function pushCounts()
    local list = zoneList()
    for src in pairs(RZ) do
        if GetPlayerName(src) then
            TriggerClientEvent('naija-rz:client:zones', src, list)
        end
    end
    GlobalState.rzZoneCounts = list
end

-- ============================================================
--  THE RECORD
-- ============================================================
-- This mode's own leaderboard. Deliberately separate from the arena's: a
-- free-for-all kill and a match win are not the same achievement, and one
-- number covering both would flatter whoever spends longest in here.

local function loadStats(key)
    local row = MySQL.single.await(
        'SELECT * FROM tenx_rz_stats WHERE identifier = ?', { key })
    return row or { kills = 0, deaths = 0, points = 0, streak = 0, best_streak = 0 }
end

local function writeKill(key, name, points, streak)
    MySQL.insert.await([[
        INSERT INTO tenx_rz_stats (identifier, name, kills, points, streak, best_streak)
        VALUES (?, ?, 1, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            name = VALUES(name),
            kills = kills + 1,
            points = points + VALUES(points),
            streak = VALUES(streak),
            best_streak = GREATEST(best_streak, VALUES(streak))
    ]], { key, name, points, streak, streak })
end

local function writeDeath(key, name)
    MySQL.insert.await([[
        INSERT INTO tenx_rz_stats (identifier, name, deaths, streak)
        VALUES (?, ?, 1, 0)
        ON DUPLICATE KEY UPDATE
            name = VALUES(name), deaths = deaths + 1, streak = 0
    ]], { key, name })
end

--- The board, as the arena wants it.
local function boardRows(n)
    local rows = MySQL.query.await([[
        SELECT name, kills, deaths, points, best_streak
        FROM tenx_rz_stats
        WHERE kills > 0 OR deaths > 0
        ORDER BY points DESC, kills DESC
        LIMIT ?
    ]], { n or 8 }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        local k, d = r.kills or 0, r.deaths or 0
        out[#out + 1] = {
            rank = i,
            name = r.name or 'Unknown',
            kills = k,
            deaths = d,
            kd = ('%.2f'):format(d > 0 and (k / d) or k),
            streak = r.best_streak or 0,
            points = r.points or 0,
            level = math.max(1, math.floor(math.sqrt((r.points or 0) / 40)) + 1),
        }
    end
    return out
end

-- ============================================================
--  PLUGGING INTO THE ARENA'S WALL BOARDS
-- ============================================================
-- The arena draws the boards. It has no idea this mode exists -- it just
-- asks whoever registered the name a board is set to.
--
-- Registered on start, dropped on stop. A wall set to this kind while this
-- resource is off shows nothing rather than an error.

CreateThread(function()
    print(('[redzone] v%s starting'):format(GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'))

    -- The arena has to be up first. It usually is, but a server that starts
    -- resources in a different order should not silently lose the board.
    local tries = 0
    while GetResourceState(ARENA) ~= 'started' and tries < 40 do
        Wait(250)
        tries = tries + 1
    end

    if GetResourceState(ARENA) ~= 'started' then
        print(('^1[redzone] %s never started. This mode cannot run without it.^0'):format(ARENA))
        return
    end

    -- One clear message at startup, rather than finding out feature by
    -- feature as players hit each broken thing.
    local compatible, missing = arenaIsCompatible()
    if not compatible then
        print('^1========================================================^0')
        print(('^1[redzone] %s is too old for this resource.^0'):format(ARENA))
        print('^1^0')
        print(('^1  Missing exports: %s^0'):format(table.concat(missing, ', ')))
        print('^1^0')
        print('^1  Install the tenx-arena that shipped alongside this^0')
        print('^1  resource. The Red Zone will not start until you do --^0')
        print('^1  half-working would be worse than not running.^0')
        print('^1========================================================^0')
        return
    end

    local b = Config.RZ.board

    -- The NAME of our export, not a function.
    --
    -- A function passed across a resource boundary does not arrive as
    -- something the other side can call. So we tell the arena where to find
    -- the data and it calls back when it needs it.
    local ok = arena('registerBoard', b.id, {
        resource = GetCurrentResourceName(),
        export = 'getBoardRows',
        label = b.label,
        footer = b.footer,
        accent = b.accent,
    })

    if ok then
        print(('[redzone] the "%s" board is registered with %s'):format(b.id, ARENA))
    end

    -- Spawns FIRST. refreshZones only offers a zone that has them, so
    -- loading them after would leave every zone unusable until something
    -- else happened to refresh -- which is exactly the bug that made /rz
    -- refuse everything with spawns sitting in the database.
    loadSpawns()

    refreshZones()
    pushCounts()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- Take the board with us, and put everyone back where they came from.
    arena('unregisterBoard', Config.RZ.board.id)

    for src in pairs(RZ) do
        if GetPlayerName(src) then
            local key = keyOf(src)
            if key then arena('syncFromPlayer', src, key) end
            arena('releasePlayer', src)
            -- Every claim goes with them. A claim outliving a player's time in
            -- the zone is a boundary held open for nobody until it times out.
            if RzZones then RzZones.call('ClearSuspends', src) end
            arena('returnToCity', src)

            -- And make sure they actually got out.
            --
            -- returnToCity goes through the arena, so it does nothing at all
            -- if the arena is stopped -- which is exactly the case when both
            -- are restarted together. The player is then left in one of this
            -- resource's buckets with nothing running that knows how to take
            -- them out, and needs an admin to come and find them.
            --
            -- Only our own bucket range is touched. Somebody the arena has
            -- already moved somewhere is not ours to move again.
            local b = GetPlayerRoutingBucket(src)
            local base = Config.RZ.bucketBase or 2100

            if b >= base and b < base + 200 then
                SetPlayerRoutingBucket(src, 0)
            end
        end
    end
end)

-- ============================================================
--  IN AND OUT
-- ============================================================

--- Put someone in a zone.
---
--- Their inventory is the arena's. We ask it to push what they own into their
--- live grid rather than handing out a kit -- you fight with what you bought.
--- Why can this player not get in?
---
--- Every refusal below names the actual reason. "Nothing is working" is what
--- you get when five different failures share one vague message, and it costs
--- more time than the fix ever does.
local function enter(src, arenaId)
    local key = keyOf(src)
    if not key then
        return false, ('Could not read your licence from %s. Is it running?')
            :format(ARENA)
    end

    -- A live match is the only thing that blocks.
    --
    -- Dragging somebody out of a 3v3 because they clicked the wrong thing is
    -- worse than making them leave it first. The lobby is different: that is
    -- a menu, not a commitment, so we take them out of it rather than
    -- refusing -- otherwise walking from one mode to the other means backing
    -- out through a door first, which nobody should have to think about.
    if arena('isBusy', src) then
        return false, Config.RZ.text.busy
    end

    if arena('isInLobby', src) then
        arena('returnToCity', src)
        Wait(200)   -- let the bucket change land before we set our own
    end

    refreshZones()

    local zone = Zones[arenaId]
    if not zone then
        -- Say WHICH of the several reasons it is.
        local all = arena('getArenas') or {}
        local exists = false
        for _, a in ipairs(all) do
            if a.id == arenaId then exists = true break end
        end

        if #all == 0 then
            return false, ('%s returned no arenas. Are any marked and enabled?')
                :format(ARENA)
        end
        if not exists then
            return false, ('There is no arena with id %s.'):format(tostring(arenaId))
        end
        if not Spawns[arenaId] or #Spawns[arenaId] == 0 then
            return false, ('That zone has no spawns. Stand outside it and run /rzspawn add %s.')
                :format(arenaId)
        end
        return false, 'That zone is not available right now.'
    end

    local spawn = zone.spawnPoints[math.random(#zone.spawnPoints)]
    if not spawn then
        return false, ('That zone has no spawns. /rzspawn add %s where you want players to appear.')
            :format(arenaId)
    end

    -- Save whatever they were carrying before we move them, so nothing is
    -- lost if this is a zone switch rather than a fresh entry.
    if RZ[src] then arena('syncFromPlayer', src, key) end

    RZ[src] = {
        arenaId = arenaId,
        key = key,
        name = nameOf(src),
        kills = RZ[src] and RZ[src].kills or 0,
        streak = 0,      -- switching zones resets the run, keeps the kills
    }

    -- Tell the arena we have this player.
    --
    -- Its inventory refuses to answer for somebody it cannot see in one of
    -- its own modes -- which is a grid you can look at and not touch, and a
    -- weapon you own but cannot hold.
    arena('claimPlayer', src)

    -- Nothing is bound here. Every tagged zone is bound to the one standing
    -- bucket at startup and stays bound -- the Red Zone is a place, not an
    -- instance, so there is no per-entry boundary to raise.
    SetPlayerRoutingBucket(src, bucketFor(arenaId))
    if RzZones then RzZones.refresh(src) end
    Player(src).state:set('rzZone', arenaId, true)

    TriggerClientEvent('naija-rz:client:enter', src, {
        arenaId = arenaId,
        name = zone.name,
        x = spawn.x, y = spawn.y, z = spawn.z, heading = spawn.w,
        protection = Config.RZ.spawnProtection,
    })

    -- Nothing to fight with at all? The arena hands out the starter, so it
    -- lands in the same inventory as everything else.
    if not arena('hasWeapon', key) and Config.RZ.starterWeapon then
        arena('addItem', key, Config.RZ.starterWeapon, 1)
    end

    arena('syncToPlayer', src, key)
    pushCounts()

    dbg('%s entered zone %s', nameOf(src), zone.name)
    return true, Config.RZ.text.entered
end

leave = function(src, quiet)
    local d = RZ[src]
    if not d then return false, 'You are not in a zone.' end

    -- Their bag goes back to the arena before we let go of them.
    if d.key then arena('syncFromPlayer', src, d.key) end

    RZ[src] = nil
    Player(src).state:set('rzZone', nil, true)

    -- Hand them back.
    arena('releasePlayer', src)
    -- Every claim goes with them. A claim outliving a player's time in
    -- the zone is a boundary held open for nobody until it times out.
    if RzZones then RzZones.call('ClearSuspends', src) end

    TriggerClientEvent('naija-rz:client:leave', src)
    arena('returnToCity', src)

    pushCounts()

    if not quiet then dbg('%s left', nameOf(src)) end
    return true, Config.RZ.text.left
end

RegisterNetEvent('naija-rz:server:enter', function(arenaId)
    local src = source

    -- The real gate. The panel refusing to open is a courtesy; this is the
    -- line an executor firing the event by hand runs into.
    if inMainCity(src) then
        notify(src, 'Get to the lobby first. The Red Zone is not a way out of the city.', 'error')
        return
    end

    local ok, msg = enter(src, tonumber(arenaId))
    notify(src, msg, ok and 'success' or 'error')
end)

RegisterNetEvent('naija-rz:server:leave', function()
    local src = source
    local ok, msg = leave(src)
    notify(src, msg, ok and 'success' or 'error')
end)



AddEventHandler('playerDropped', function()
    local src = source
    if RZ[src] then
        -- Save what they were carrying. Someone who disconnects mid-fight
        -- should not come back to an empty bag.
        if RZ[src].key then arena('syncFromPlayer', src, RZ[src].key) end
        arena('releasePlayer', src)
        -- Every claim goes with them. A claim outliving a player's time in
        -- the zone is a boundary held open for nobody until it times out.
        if RzZones then RzZones.call('ClearSuspends', src) end
        RZ[src] = nil
        pushCounts()
    end
end)

-- ============================================================
--  A KILL
-- ============================================================

--- One item from the weighted table, or nothing.
---
--- "nothing" is a real entry and the likeliest one. A drop that always
--- happens is not a drop, it is a payment, and it fills bags with medkits.
--- How many of something a drop gives.
---
--- Accepts a plain number for a fixed amount, or { low, high } for a range
--- rolled per kill -- count = { 10, 20 } gives somewhere between ten and
--- twenty. Also accepts { min = , max = } if that reads better to you.
---
--- A missing count is one, so an entry can leave it out entirely.
local function rollCount(count)
    if type(count) == 'number' then return math.floor(count) end

    if type(count) == 'table' then
        local lo = count.min or count[1]
        local hi = count.max or count[2]

        if lo and hi then
            lo, hi = math.floor(lo), math.floor(hi)
            if hi < lo then lo, hi = hi, lo end
            return math.random(lo, hi)
        end

        if lo then return math.floor(lo) end
    end

    return 1
end

local function rollDrop(key)
    local cfg = Config.RZ.killReward
    local total = 0
    for _, d in ipairs(cfg.drops) do total = total + (d.weight or 0) end
    if total <= 0 then return nil end

    local roll = math.random(total)
    for _, d in ipairs(cfg.drops) do
        roll = roll - (d.weight or 0)
        if roll <= 0 then
            if not d.item then return nil end

            -- No cap on how much of a thing you can hold. What you can carry
            -- is decided by the bag -- the arena's weight and slot limits --
            -- not by a number here, so ammunition stacks the way ammunition
            -- should.
            --
            -- There used to be a maxOfOneItem check that compared the count
            -- CARRIED against 5. One 60-round ammo drop put you at 60, and
            -- ammo never dropped again for the rest of that life. Worse, it
            -- returned nothing rather than re-rolling, so blocked items
            -- quietly became extra "nothing" and the real drop rate was well
            -- below what the weights said.
            return d.item, rollCount(d.count)
        end
    end
    return nil
end

--- A death, reported BY THE VICTIM.
---
--- The victim's client sends this, naming whoever killed them -- see the
--- death watcher in client.lua. The killer's client is the one with something
--- to gain from lying, so it is never the one asked.
---
--- This read the arguments the other way round: source treated as the killer
--- and the argument as the victim. Since the client sends the opposite, every
--- kill was credited to the person who died and the death screen went to the
--- person who did the killing. The names of the two variables were the only
--- thing that was ever right.
RegisterNetEvent('naija-rz:server:kill', function(killerId, cause)
    local victim = source
    local vd = RZ[victim]
    if not vd then return end

    local killer = tonumber(killerId)
    local kd = killer and killer ~= victim and RZ[killer] or nil

    -- Same zone only. A report naming somebody in another bucket is either
    -- confused or crafted, and neither should score.
    if kd and kd.arenaId ~= vd.arenaId then kd = nil end

    -- And both of them actually INSIDE the shape.
    --
    -- Players are dropped outside the boundary on purpose and walk in, so
    -- being assigned to a zone is not the same as being in it. Without this,
    -- the spawn area is a free hunting ground: camp the entrance, kill people
    -- who have not started yet, and collect the coins and the streak for it.
    --
    -- The arena is asked rather than tested here, because it owns the shapes
    -- and already has the polygon maths. A second copy of "inside" living in
    -- this resource is a second copy that can disagree.
    -- Guarded even though zones_server.lua is loaded by the time a kill can
    -- happen. An unguarded call to a table from another file is one manifest
    -- reorder away from a nil index on the path that decides whether a kill
    -- pays -- and it would throw, not fail quietly.
    -- BOTH of them, in the SAME sphere.
    --
    -- Same, not merely both inside something: the domes are scattered across
    -- the map and two people in different ones are not fighting each other.
    --
    -- And inside at all, because entry spawns sit outside the boundary on
    -- purpose. Without this the spawn area is a free hunting ground -- camp
    -- one entrance, kill people who have not started yet, and collect the
    -- coins and the streak for it.
    if RzZones and RzZones.active() then
        local ok, zoneId = RzZones.sameZone(killer, victim)

        if kd and not ok then
            dbg('%s and %s were not in the same zone -- no reward', kd.name, vd.name)
            kd = nil
        end

        -- Remembered so the respawn knows which dome to place them outside
        -- of. Nobody picks a zone on entry any more, so this is the only
        -- record of where they were fighting.
        --
        -- `kd` is tested separately rather than assumed. This was one branch
        -- -- `elseif zoneId then ... kd.lastZone = zoneId` -- which indexes a
        -- nil `kd` the moment sameZone answers true for a killer who is not
        -- in this mode: a bystander standing in the dome, or anyone at all
        -- once a report can name nobody. It never fired before because a
        -- killerless report never reached here; it would now.
        if zoneId then
            vd.lastZone = zoneId
            if kd then kd.lastZone = zoneId end
        end

    else
        local insideOk = function(s2, a2)
            return RzArenaCall('insideArena', s2, a2) and true or false
        end

        if kd and not insideOk(killer, kd.arenaId) then
            dbg('%s killed %s from outside the zone -- no reward', kd.name, vd.name)
            kd = nil
        end

        if kd and not insideOk(victim, vd.arenaId) then
            dbg('%s was killed before entering the zone -- no reward', vd.name)
            kd = nil
        end
    end

    -- No creditable killer -- they left, they are in another zone, or the
    -- report was nonsense. The DEATH still has to be processed, or the victim
    -- sits on the death screen forever waiting for a respawn that is never
    -- sent. Nobody scores; they still get picked up.
    if not kd then
        vd.streak = 0
        writeDeath(vd.key, vd.name)

        -- Claim the whole time they are down.
        --
        -- The ambulance script moves downed players on its own schedule and
        -- cannot be patched. Inside this claim its teleports read as a
        -- deliberate move rather than someone escaping, so the boundary
        -- neither fights it nor counts a violation. Released when they are
        -- placed at a spawn.
        if RzZones then RzZones.claimDown(victim) end

        TriggerClientEvent('naija-rz:client:died', victim, {
            killer = nil,
            respawn = (Config.RZ.down or {}).delay or Config.RZ.respawnDelay,
        })

        dbg('%s died with no creditable killer', vd.name)
        return
    end

    local cfg = Config.RZ.killReward

    kd.kills = kd.kills + 1
    kd.streak = kd.streak + 1

    local coins = math.random(cfg.coinsMin, cfg.coinsMax)
    local points = cfg.points or 10
    local streakMsg

    local bonus = Config.RZ.streaks[kd.streak]
    if bonus then
        coins = coins + (bonus.coins or 0)
        points = points + (bonus.points or 0)
        streakMsg = bonus.message
    end

    -- Coins are the arena's, spent in the arena's shop.
    arena('giveCoins', kd.key, coins, 'redzone:kill')

    local dropItem, dropCount = rollDrop(kd.key)
    if dropItem then
        arena('addItem', kd.key, dropItem, dropCount, true)
    end

    -- Straight into their grid, so it is in their hands now.
    arena('syncToPlayer', killer, kd.key)

    writeKill(kd.key, kd.name, points, kd.streak)

    TriggerClientEvent('naija-rz:client:killed', killer, {
        kills = kd.kills,
        streak = kd.streak,
        coins = coins,
        points = points,
        victim = vd.name,
        streakMessage = streakMsg,
        drop = dropItem,
        dropCount = dropCount,
    })

    -- The victim.
    vd.streak = 0
    writeDeath(vd.key, vd.name)

    -- Weapons wear. Handled by the arena, since it owns durability.
    TriggerClientEvent('naija-rz:client:died', victim, {
        killer = kd.name,
        respawn = (Config.RZ.down or {}).delay or Config.RZ.respawnDelay,
    })

    -- Everyone else in the zone sees it happen. The killer and victim are
    -- skipped: they already got their own line, and sending this as well gave
    -- the killer two entries for the same kill.
    for s, d in pairs(RZ) do
        if d.arenaId == kd.arenaId and s ~= killer and s ~= victim
           and GetPlayerName(s) then
            TriggerClientEvent('naija-rz:client:feed', s, {
                killer = kd.name, victim = vd.name, streak = kd.streak,
            })
        end
    end

    dbg('%s killed %s (streak %s)', kd.name, vd.name, kd.streak)
end)

--- Put a dead player back outside the zone with their kit.
RegisterNetEvent('naija-rz:server:respawn', function()
    local src = source
    local d = RZ[src]
    if not d then return end

    refreshZones()

    -- Put them back at the dome they were actually fighting in.
    --
    -- Nobody picks a zone on entry any more -- they pick a destination once
    -- and can walk between domes afterwards -- so d.arenaId is where they
    -- STARTED, not where they died. lastZone is set from the same membership
    -- check that decided the kill, so it is where they actually were.
    --
    -- Falling back to where they entered is the right failure: a death with no
    -- creditable killer never sets lastZone, and putting somebody back where
    -- they came in is better than refusing to respawn them at all.
    local zoneKey = d.lastZone or d.arenaId
    local zone = Zones[zoneKey] or Zones[d.arenaId]

    -- Killed outside every sphere.
    --
    -- The domes are passable, so a player can be shot on the road between
    -- them. That pays nobody -- the both-inside rule already saw to that --
    -- but they still need somewhere to come back to, and neither the sphere
    -- they were in nor the one they entered by may still be offered.
    --
    -- Any zone with spawns beats returning them to the lobby: they chose to
    -- be here, and a death on the way to a fight should not end the session.
    if not zone then
        for _, z in pairs(Zones) do
            if z.spawnPoints and #z.spawnPoints > 0 then
                zone = z
                break
            end
        end
    end

    -- Genuinely nothing left -- every zone untagged or stripped of spawns
    -- while they were dead. The lobby is the honest answer then.
    if not zone then return leave(src) end

    local spawn = zone.spawnPoints[math.random(#zone.spawnPoints)]
    if not spawn then return leave(src) end

    TriggerClientEvent('naija-rz:client:enter', src, {
        arenaId = zone.id or d.arenaId,
        name = zone.name,
        x = spawn.x, y = spawn.y, z = spawn.z, heading = spawn.w,
        protection = Config.RZ.spawnProtection,
        respawn = true,
    })

    -- Back on their feet at a spawn: the death window is over.
    --
    -- Released here rather than on the client, because the claim was taken
    -- here and a claim released from the side that did not take it is how the
    -- two ends drift apart.
    if RzZones then RzZones.releaseDown(src) end

    arena('syncToPlayer', src, d.key)
end)

RegisterCommand(Config.RZ.exitCommand, function(src)
    if src == 0 then return end
    if not RZ[src] then return notify(src, 'You are not in a zone.', 'error') end
    local ok, msg = leave(src)
    notify(src, msg, ok and 'success' or 'error')
end, false)

-- ============================================================
--  WHAT THIS RESOURCE OFFERS OTHERS
-- ============================================================
-- The other direction: the arena, or anything else, can ask us.

exports('getLeaderboard', function(n)
    return boardRows(n or 8)
end)

--- What the arena's wall boards call.
---
--- Separate from getLeaderboard because it returns the shape the board
--- expects rather than a bare list -- and because a name the arena depends on
--- should not change every time somebody tidies the other one.
exports('getBoardRows', function()
    return { rows = boardRows(Config.RZ.board.entries or 8) }
end)

exports('getStats', function(key)
    return key and loadStats(key) or nil
end)

exports('getZones', function()
    return zoneList()
end)

exports('isInZone', function(src)
    return src and RZ[src] ~= nil or false
end)

exports('playersInZone', function(arenaId)
    local out = {}
    for s, d in pairs(RZ) do
        if d.arenaId == arenaId then
            out[#out + 1] = { id = s, name = d.name, kills = d.kills, streak = d.streak }
        end
    end
    return out
end)

--- Pull someone out, for an admin panel in another resource.
exports('removePlayer', function(src, reason)
    if not RZ[src] then return false end
    local ok = leave(src)
    if ok and reason then notify(src, reason, 'inform') end
    return ok
end)

-- ============================================================
--  SPAWN POINTS
-- ============================================================
-- Where people stand when they enter a zone.
--
-- Marked here, not in the arena. The arena owns the SHAPE; where somebody
-- stands when they walk into it is this mode's business. Asking the arena to
-- store settings for a mode it knows nothing about is how two resources end
-- up tangled together.
--
-- Stand OUTSIDE the zone and mark it: players arrive with their kit and walk
-- in, rather than being dropped into the middle of a fight they did not see.

--- Which column identifies a spawn's zone.
---
--- arena_id in the old mode, zone_id once the handover is on. Both columns
--- exist so the flag can be flipped back without losing anything -- spawns
--- marked under one mode stay where they are and the other simply does not
--- see them.
local function spawnKeyColumn()
    if RzZones and RzZones.active() then return 'zone_id' end
    return 'arena_id'
end

loadSpawns = function()
    Spawns = {}

    local col = spawnKeyColumn()
    local rows = MySQL.query.await('SELECT * FROM tenx_rz_spawns') or {}

    for _, r in ipairs(rows) do
        local key = r[col]
        if key then
        Spawns[key] = Spawns[key] or {}
        table.insert(Spawns[key], {
            id = r.id, x = r.x, y = r.y, z = r.z, w = r.heading
        })
        end
    end

    local n = 0
    for _ in pairs(Spawns) do n = n + 1 end
    print(('[redzone] loaded spawns for %s zone(s), keyed on %s'):format(n, col))
end

local function hasPermission(src)
    if src == 0 then return true end
    if GetResourceState(ARENA) == 'started' then
        local ok, res = pcall(function()
            return exports[ARENA]:isStaff(src)
        end)
        if ok and res ~= nil then return res end
    end
    -- Falls back to the ace, so this still works if the arena has no such
    -- export rather than letting anybody mark spawns.
    return IsPlayerAceAllowed(src, 'naija.arena')
end

RegisterNetEvent('naija-rz:server:addSpawn', function(arenaId, x, y, z, w)
    local src = source
    if not hasPermission(src) then
        return notify(src, 'You cannot do that.', 'error')
    end

    arenaId = tonumber(arenaId)
    if not arenaId then return end

    -- Validated against the shape before it is written.
    --
    -- 'outside', not 'inside' -- the opposite of the arena's team spawns, and
    -- the reason ValidateSpawn takes a direction at all. A spawn inside the
    -- dome drops a player into a fight they never saw; one 200 metres away is
    -- a hike. Both are rejected with the reason said out loud.
    if RzZones and RzZones.active() then
        local ok, why = RzZones.validateEntrySpawn(arenaId, vec3(x, y, z))
        if ok == false then
            return notify(src, why or 'That spot will not work as a spawn.', 'error')
        end
    end

    local col = spawnKeyColumn()

    local id = MySQL.insert.await(
        ('INSERT INTO tenx_rz_spawns (%s, x, y, z, heading, added_by) VALUES (?, ?, ?, ?, ?, ?)')
            :format(col),
        { arenaId, x, y, z, w or 0.0, GetPlayerName(src) })

    Spawns[arenaId] = Spawns[arenaId] or {}
    table.insert(Spawns[arenaId], { id = id, x = x, y = y, z = z, w = w or 0.0 })

    notify(src, ('Spawn %s added and saved.'):format(#Spawns[arenaId]), 'success')
    pushCounts()
end)

RegisterNetEvent('naija-rz:server:clearSpawns', function(arenaId)
    local src = source
    if not hasPermission(src) then
        return notify(src, 'You cannot do that.', 'error')
    end

    arenaId = tonumber(arenaId)
    if not arenaId then return end

    MySQL.update.await(
        ('DELETE FROM tenx_rz_spawns WHERE %s = ?'):format(spawnKeyColumn()),
        { arenaId })
    Spawns[arenaId] = nil

    -- Anyone still in it has nowhere to respawn now.
    for s, d in pairs(RZ) do
        if d.arenaId == arenaId then
            leave(s)
            notify(s, 'That zone lost its spawns and is closed.', 'inform')
        end
    end

    notify(src, 'Spawns cleared. That zone is no longer offered.', 'success')
    pushCounts()
end)


exports('getSpawns', function(arenaId)
    return Spawns[arenaId] or {}
end)


-- ============================================================
--  CALLBACKS
-- ============================================================
-- Registered from inside a thread, after checking ox_lib is actually there.
--
-- At file scope these run the instant the script loads. If ox_lib has not
-- finished loading -- a manifest that lists it as a dependency but never
-- loads it, an unusual start order, a server under load -- `lib` is nil and
-- the whole file dies on the first line that touches it, taking every export
-- and event handler below it with it.
--
-- A few hundred milliseconds of patience here costs nothing and removes that
-- entire class of failure.

CreateThread(function()
    local tries = 0
    while not (lib and lib.callback) and tries < 100 do
        Wait(50)
        tries = tries + 1
    end

    if not (lib and lib.callback) then
        print('^1[redzone] ox_lib never loaded.^0')
        print('^1          Check that fxmanifest.lua has @ox_lib/init.lua in^0')
        print('^1          shared_scripts -- listing it under dependencies only^0')
        print('^1          sets the start order, it does not load anything.^0')
        return
    end

    lib.callback.register('naija-rz:server:zones', function(src)
        -- /rz is registered client-side, so the command itself cannot be
        -- taken away from a city player without editing client.lua. It can
        -- be given nothing to show: the panel opens empty with the reason
        -- notified, rather than offering a picker whose every button would
        -- be refused by the enter gate below.
        if inMainCity(src) then
            notify(src, 'Get to the lobby first. The Red Zone is not a way out of the city.', 'error')
            return { zones = {}, inZone = nil, blocked = true }
        end

        return { zones = zoneList(), inZone = RZ[src] and RZ[src].arenaId or nil }
    end)

    lib.callback.register('naija-rz:server:board', function(src)
        local key = keyOf(src)
        return {
            rows = boardRows(20),
            you = key and loadStats(key) or nil,
        }
    end)

    lib.callback.register('naija-rz:server:spawnList', function(src)
        if not hasPermission(src) then return {} end
    
        local out = {}
        local list = arena('getArenas') or {}
    
        for _, a in ipairs(list) do
            out[#out + 1] = {
                id = a.id,
                name = a.name,
                spawns = #(Spawns[a.id] or {}),
            }
        end
    
        table.sort(out, function(x, y) return x.name < y.name end)
        return out
    end)
end)

-- ============================================================
--  WHY WON'T IT LET ME IN
-- ============================================================
-- Prints everything that decides whether you can enter, in one go.
--
-- Worth having permanently: this reports what is actually true rather than
-- what should be, and the gap between those two is where the time goes.

RegisterCommand('rzcheck', function(src)
    local function say(fmt, ...)
        local line = select('#', ...) > 0 and fmt:format(...) or fmt
        if src == 0 then print(line) else
            print(line)
            TriggerClientEvent('chat:addMessage', src, { args = { 'RZ', line } })
        end
    end

    say('^3=== red zone check ===^0')

    -- 1. the arena
    local state = GetResourceState(ARENA)
    say('  %s is %s', ARENA, state)
    if state ~= 'started' then
        say('^1  -> nothing else can work until it is started^0')
        return
    end

    -- 2. can we talk to it
    local key = keyOf(src)
    say('  your licence: %s', key or '^1COULD NOT READ^0')

    local ok, missing = arenaIsCompatible()
    if not ok then
        say('^1  missing exports: %s^0', table.concat(missing, ', '))
        say('^1  -> the arena needs updating^0')
        return
    end
    say('  all exports present')

    -- 3. what state does the arena think you are in
    if src ~= 0 then
        say('  in a match : %s', tostring(arena('isBusy', src)))
        say('  in the lobby: %s', tostring(arena('isInLobby', src)))
        say('  in a zone  : %s', tostring(RZ[src] ~= nil))
    end

    -- 4. the arenas themselves
    local all = arena('getArenas') or {}
    say('  arenas from %s: %s', ARENA, #all)

    if #all == 0 then
        say('^1  -> none marked, or none enabled. Check /arena^0')
        return
    end

    -- 5. spawns, per arena
    say('  ')
    say('  zone                       spawns   usable')
    local usable = 0

    for _, a in ipairs(all) do
        local n = #(Spawns[a.id] or {})
        local allowed = #Config.RZ.onlyZones == 0
        for _, nm in ipairs(Config.RZ.onlyZones) do
            if nm == a.name then allowed = true end
        end

        local ready = n > 0 and allowed
        if ready then usable = usable + 1 end

        say('  %s%-3s %-22s %3s      %s^0',
            ready and '^2' or '^1', a.id, a.name, n,
            ready and 'yes' or (n == 0 and 'no spawns' or 'excluded by onlyZones'))
    end

    say('  ')
    if usable == 0 then
        say('^1  -> no zone is usable. Stand OUTSIDE a zone and run:^0')
        say('^1     /rzspawn add <id>^0')
    else
        say('^2  -> %s zone(s) ready. /rz should work.^0', usable)
    end
end, false)

-- ============================================================
--  WHAT zones_server.lua NEEDS
-- ============================================================
-- RZ, arena() and bucketFor are locals in this file. A separate script file
-- reading them would get nil globals and silently do nothing, so these are
-- the named openings. Both go away with the handover in step 5.

function RzZoneState()
    return RZ
end

function RzArenaCall(fn, ...)
    return arena(fn, ...)
end

function RzBucketFor(arenaId)
    return bucketFor(arenaId)
end

--- Zones and Spawns are locals in this file, so zones_server.lua cannot see
--- them -- it would read nil globals and quietly do nothing, with no error.
--- These are the named openings.
function RzZoneTables()
    return Zones, Spawns
end

function RzSetZones(t)
    Zones = t or {}
end

function RzReloadSpawns()
    if loadSpawns then loadSpawns() end
end
