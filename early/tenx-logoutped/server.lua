-- tenx-logoutped/server.lua
-- NAIJA 2046 — Logout Ped
--
-- The server is the source of truth for every logout ped. Clients only render
-- what it tells them, so a player can't hide their own ped by modding.

local QBCore = exports['qb-core']:GetCoreObject()

-- src -> { snapshot, coords, heading, name, cid }
local cache = {}

-- id -> data (everything currently standing in the world)
local active = {}
local nextId = 0

-- ============================================================
--  DROP REASON
--  ⚠️ READ THIS BEFORE YOU BAN ANYONE OFF IT.
--  FiveM gives one string and it is NOT proof of intent:
--    * Pulling your ethernet cable  -> "timed out"
--    * Router genuinely dying       -> "timed out"      (identical)
--    * Task-manager kill            -> often "timed out" too
--    * Alt-F4 / F8 quit             -> usually "Exiting"/"Disconnected"
--    * Real crash                   -> sometimes "crash", sometimes a timeout
--  A combat logger and a guy in Ibadan with bad NEPA look the same here.
--  Use this to know WHO left mid-scene — that part is reliable — and let the
--  reason inform your question, not answer it.
-- ============================================================
local function classify(reason)
    local r = tostring(reason or ''):lower()

    if r:find('timed out') or r:find('timeout') then return 'TIMED OUT' end
    if r:find('crash') then return 'CRASHED' end
    if r:find('exiting') or r:find('quit') or r:find('disconnected by user') then return 'QUIT' end
    if r:find('kick') then return 'KICKED' end
    if r:find('ban') then return 'BANNED' end

    return 'DISCONNECTED'
end

-- ============================================================
--  CACHE
-- ============================================================
RegisterNetEvent('tenx-logoutped:snapshot', function(snap)
    local src = source
    if type(snap) ~= 'table' then return end

    local P = QBCore.Functions.GetPlayer(src)
    if not P then return end

    cache[src] = cache[src] or {}
    cache[src].snapshot = snap
    cache[src].cid = P.PlayerData.citizenid
    local ci = P.PlayerData.charinfo
    cache[src].name = ('%s %s'):format(ci.firstname or '?', ci.lastname or '?')
end)

-- Poll positions. playerDropped USUALLY still has a valid ped, but not always —
-- on a hard timeout the entity can already be gone. This is the fallback so the
-- ped never spawns at 0,0,0.
CreateThread(function()
    while true do
        Wait(3000)
        for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
            local ped = GetPlayerPed(pid)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                if c and c.x and c.x ~= 0.0 then
                    cache[pid] = cache[pid] or {}
                    cache[pid].coords  = { x = c.x, y = c.y, z = c.z }
                    cache[pid].heading = GetEntityHeading(ped)
                end
            end
        end
    end
end)

-- ============================================================
--  LOGGING
-- ============================================================
local function log(data)
    if Config.LogToConsole then
        print(('^3[logoutped]^7 %s (ID %s) dropped — ^1%s^7 | raw: %s | %.1f, %.1f, %.1f')
            :format(data.name, data.serverId, data.reason, data.rawReason,
                data.coords.x, data.coords.y, data.coords.z))
    end

    if Config.Webhook and Config.Webhook ~= '' then
        PerformHttpRequest(Config.Webhook, function() end, 'POST', json.encode({
            username = 'NAIJA 2046 | Logout',
            embeds = { {
                title = ('%s — %s'):format(data.name, data.reason),
                description = ('**Server ID:** `%s`\n**CitizenID:** `%s`\n**Raw reason:** `%s`\n**Location:** `%.1f, %.1f, %.1f`\n**Ped stands for:** %d min')
                    :format(data.serverId, data.cid or '?', data.rawReason,
                        data.coords.x, data.coords.y, data.coords.z,
                        math.floor((Config.Duration or 600) / 60)),
                color = 15158332,
                footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
            } },
        }), { ['Content-Type'] = 'application/json' })
    end
end

-- ============================================================
--  THE DROP
-- ============================================================
AddEventHandler('playerDropped', function(reason)
    local src = source
    local c = cache[src]

    -- never loaded a character (still on the spawn screen) -> nothing to show
    if not c or not c.cid then
        cache[src] = nil
        return
    end

    -- Try the live ped first — it's accurate to the metre. Fall back to the
    -- last poll if the entity is already gone.
    local coords, heading = c.coords, c.heading
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local live = GetEntityCoords(ped)
        if live and live.x and live.x ~= 0.0 then
            coords  = { x = live.x, y = live.y, z = live.z }
            heading = GetEntityHeading(ped)
        end
    end

    if not coords then
        cache[src] = nil
        return
    end

    nextId = nextId + 1
    local id = nextId

    local data = {
        id        = id,
        serverId  = src,
        name      = c.name or GetPlayerName(src) or 'Unknown',
        cid       = c.cid,
        reason    = classify(reason),
        rawReason = tostring(reason or 'unknown'),
        coords    = coords,
        heading   = heading or 0.0,
        snapshot  = c.snapshot,
        expiresAt = os.time() + (Config.Duration or 600),
    }

    active[id] = data
    cache[src] = nil

    TriggerClientEvent('tenx-logoutped:spawn', -1, data)
    log(data)

    SetTimeout((Config.Duration or 600) * 1000, function()
        if active[id] then
            active[id] = nil
            TriggerClientEvent('tenx-logoutped:remove', -1, id)
        end
    end)
end)

-- ============================================================
--  SYNC
--  A player joining now, or the resource restarting, must still see every ped
--  already standing — otherwise only the people who were online at the moment
--  of the drop can see it, which is exactly the staff who just came on shift.
-- ============================================================
local function sendActive(target)
    local list = {}
    for _, data in pairs(active) do
        list[#list + 1] = data
    end
    if #list > 0 then
        TriggerClientEvent('tenx-logoutped:sync', target, list)
    end
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    SetTimeout(5000, function()
        if GetPlayerName(src) then sendActive(src) end
    end)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- active is empty on a fresh start; this only matters if you ever persist it
    SetTimeout(3000, function() sendActive(-1) end)
end)

-- ============================================================
--  ADMIN
-- ============================================================
-- /logouts — list everyone currently standing, with time left
RegisterCommand('logouts', function(src)
    if src ~= 0 then
        -- console only; wire this to your admin check if you want it in-game
        return
    end
    local now = os.time()
    local n = 0
    print('^2[logoutped]^7 ===== ACTIVE LOGOUT PEDS =====')
    for id, d in pairs(active) do
        n = n + 1
        print(('  #%d  %s (ID %s) — %s — %ds left — %.1f, %.1f, %.1f')
            :format(id, d.name, d.serverId, d.reason, d.expiresAt - now,
                d.coords.x, d.coords.y, d.coords.z))
    end
    if n == 0 then print('  none') end
    print('^2[logoutped]^7 ==============================')
end, true)

-- /clearlogouts — wipe them all early
RegisterCommand('clearlogouts', function(src)
    if src ~= 0 then return end
    for id in pairs(active) do
        TriggerClientEvent('tenx-logoutped:remove', -1, id)
    end
    active = {}
    print('^2[logoutped]^7 all logout peds cleared.')
end, true)

exports('getActiveLogouts', function()
    return active
end)
