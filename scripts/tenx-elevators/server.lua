local QBCore = exports['qb-core']:GetCoreObject()
local uses = {} -- elevatorId -> daily use count (in-memory)

-- ================= Admin check =================
local function isAdmin(src)
    if not src or src == 0 then return false end
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        for _, allow in ipairs(Config.AdminIdentifiers) do
            if id == allow then return true end
        end
    end
    for _, group in ipairs(Config.AdminGroups) do
        if QBCore.Functions.HasPermission(src, group) then return true end
    end
    return false
end

RegisterCommand('myid', function(src)
    if src == 0 then return end
    TriggerClientEvent('aec:printIds', src, GetPlayerIdentifiers(src))
end, false)

-- ================= Data =================
local function loadElevators()
    local rows = MySQL.query.await('SELECT id, name, floors, access, created_by FROM tenx_elevators ORDER BY id ASC') or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            id = r.id,
            name = r.name,
            floors = json.decode(r.floors) or {},
            access = json.decode(r.access) or { public = true },
            uses = uses[r.id] or 0,
        }
    end
    return out
end

lib.callback.register('aec:getData', function(src)
    return { isAdmin = isAdmin(src), brand = Config.Brand, elevators = loadElevators() }
end)

-- players (all) need the elevator list too, to build interaction points
lib.callback.register('aec:getElevators', function(src)
    return loadElevators()
end)

local function broadcastRefresh()
    TriggerClientEvent('aec:refresh', -1)
end

-- ================= Save / delete (admin) =================
RegisterNetEvent('aec:save', function(payload)
    local src = source
    if not isAdmin(src) then return end
    if type(payload) ~= 'table' then return end

    local name = tostring(payload.name or ''):sub(1, 64)
    if name == '' then return end

    local floors = payload.floors or {}
    if type(floors) ~= 'table' or #floors < 1 then return end

    local access = payload.access or { public = true }
    -- sanitize access
    access = {
        public = access.public and true or false,
        jobs = access.jobs or {},
        items = access.items or {},
        passcode = (access.passcode and tostring(access.passcode) ~= '') and tostring(access.passcode) or false,
        allowVehicles = access.allowVehicles and true or false,
    }

    local fJson = json.encode(floors)
    local aJson = json.encode(access)

    if payload.id then
        MySQL.update.await('UPDATE tenx_elevators SET name=?, floors=?, access=? WHERE id=?',
            { name, fJson, aJson, payload.id })
    else
        MySQL.insert.await('INSERT INTO tenx_elevators (name, floors, access, created_by) VALUES (?,?,?,?)',
            { name, fJson, aJson, GetPlayerName(src) })
    end
    broadcastRefresh()
end)

RegisterNetEvent('aec:delete', function(id)
    local src = source
    if not isAdmin(src) then return end
    if not id then return end
    MySQL.update.await('DELETE FROM tenx_elevators WHERE id=?', { tonumber(id) })
    uses[tonumber(id)] = nil
    broadcastRefresh()
end)

-- ================= Access validation =================
local function hasAnyItem(src, items)
    if not items then return false end
    for _, item in ipairs(items) do
        local n = exports.ox_inventory:Search(src, 'count', item)
        if (n or 0) > 0 then return true end
    end
    return false
end

lib.callback.register('aec:checkAccess', function(src, elevId, passcode)
    local row = MySQL.single.await('SELECT access FROM tenx_elevators WHERE id=?', { elevId })
    if not row then return 'Unknown elevator.' end
    local a = json.decode(row.access) or {}

    if a.public then return true end

    if a.jobs and #a.jobs > 0 then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            local job = Player.PlayerData.job and Player.PlayerData.job.name
            for _, j in ipairs(a.jobs) do if j == job then return true end end
        end
    end

    if hasAnyItem(src, a.items) then return true end

    if a.passcode and a.passcode ~= false then
        if passcode == nil then return 'passcode' end
        if tostring(passcode) == tostring(a.passcode) then return true end
        return 'Wrong passcode.'
    end

    return 'You do not have access to this elevator.'
end)

RegisterNetEvent('aec:logUse', function(elevId)
    elevId = tonumber(elevId)
    if not elevId then return end
    uses[elevId] = (uses[elevId] or 0) + 1
end)

-- reset daily uses every 24h
CreateThread(function()
    while true do
        Wait(24 * 60 * 60 * 1000)
        uses = {}
    end
end)
