-- tenx-adminjail/server/moon.lua
-- NAIJA 2046 — "Send to Moon" (crisis parking)
--
-- Server-authoritative, same as the rest of the system. Stores itself in
-- tenx_admin_punishments as type = 'moon' so it inherits, for free:
--   * the restart resync sweep (onResourceStart in server/main.lua)
--   * the relog re-apply (QBCore:Server:PlayerLoaded)
--   * the "Currently Serving" release board in the menu
--
-- The row's data column holds BOTH the moon coords and the player's exact
-- position + heading at the moment they were taken, so /unmoon is precise and
-- survives restarts, relogs and a week of downtime.
--
-- LOAD ORDER: this file MUST load AFTER server/main.lua (see fxmanifest).

local Moon = Config.Moon

-- ============================================================
--  REGISTRY HOOK
--  server/main.lua keeps PunishmentTypes local. It exposes it with one line:
--      _G.NaijaPunishmentTypes = PunishmentTypes
--  Without that, release-from-menu would mark the row completed but never
--  actually teleport the player home. Fail loud rather than half-work.
-- ============================================================
local PunishmentTypes = _G.NaijaPunishmentTypes
if not PunishmentTypes then
    print('[tenx-adminjail] ^1moon: PunishmentTypes registry not found.^7')
    print('[tenx-adminjail] ^1Add `_G.NaijaPunishmentTypes = PunishmentTypes` to server/main.lua and make sure moon.lua loads after it.^7')
    return
end

-- ============================================================
--  LOCAL HELPERS (mirrors of server/main.lua's — kept local so this module
--  stays self-contained and main.lua needs no other edits)
-- ============================================================
local function GetLicense(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return nil
end

local function IsAllowed(src)
    if src == 0 then return true end
    local lic = GetLicense(src)
    if not lic then return false end
    return Config.Admins[lic] ~= nil
end

local function AdminName(src)
    if src == 0 then return 'Console' end
    return Config.Admins[GetLicense(src) or ''] or GetPlayerName(src) or 'Unknown'
end

local function Notify(src, ntype, msg)
    if src == 0 then
        print(('[tenx-adminjail] %s'):format(msg))
        return
    end
    TriggerClientEvent('ox_lib:notify', src, { type = ntype, description = msg })
end

local function MoonDiscord(title, description)
    if not Moon.logToDiscord then return end
    if not Config.Webhook or Config.Webhook == '' then return end
    PerformHttpRequest(Config.Webhook, function() end, 'POST', json.encode({
        username = 'NAIJA 2046 Admin',
        embeds = { {
            title = title,
            description = description,
            color = 10181046, -- purple: crisis tool, not a punishment
            footer = { text = ('NAIJA 2046 • %s'):format(os.date('%Y-%m-%d %H:%M:%S')) },
        } },
    }), { ['Content-Type'] = 'application/json' })
end

local function decode(str)
    if not str then return {} end
    local ok, out = pcall(json.decode, str)
    return ok and out or {}
end

-- ============================================================
--  MOON POINT
-- ============================================================
local function GetMoonCoords()
    -- 1. hardcoded config coords (vec4 or a plain table both work)
    local c = Moon.coords
    if c then
        if type(c) == 'vector4' then
            return { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, h = c.w + 0.0 }
        elseif type(c) == 'vector3' then
            return { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, h = 0.0 }
        elseif type(c) == 'table' and c.x then
            return { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, h = (c.h or c.w or 0.0) + 0.0 }
        end
        print('[tenx-adminjail] ^3moon: Config.Moon.coords is set but unreadable — falling back to the DB.^7')
    end

    -- 2. saved via /setmoon
    local row = MySQL.single.await(
        "SELECT coords FROM tenx_admin_locations WHERE category = 'moon' ORDER BY id DESC LIMIT 1")

    -- 3. newest admin jail
    if not row and Moon.fallbackToJail then
        row = MySQL.single.await(
            "SELECT coords FROM tenx_admin_locations WHERE category = 'jail' ORDER BY id DESC LIMIT 1")
    end

    if not row or not row.coords then return nil end
    local d = decode(row.coords)
    if not d.x then return nil end
    return d
end

-- ============================================================
--  PUNISHMENT TYPE
-- ============================================================
PunishmentTypes['moon'] = {
    label    = 'Moon',
    hasTimer = false,
    applyLive = function(src, record, resync)
        local d = decode(record.data)
        TriggerClientEvent('tenx-adminjail:client:applyMoon', src, {
            id     = record.id,
            reason = record.reason,
            coords = d.coords,
            resync = resync or false,
        })
    end,
    removeLive = function(src, record)
        local d = decode(record.data)
        -- NOTE: moon deliberately ignores Config.TeleportOnRelease / the release
        -- point. The whole point is the exact spot they were taken from.
        TriggerClientEvent('tenx-adminjail:client:removeMoon', src, d.returnCoords)
    end,
}

-- ============================================================
--  CORE ACTIONS
-- ============================================================
local function DoMoon(adminSrc, targetSrc, reason)
    if not IsAllowed(adminSrc) then return false, 'No permission.' end

    targetSrc = tonumber(targetSrc)
    if not targetSrc or not GetPlayerName(targetSrc) then return false, 'Player not online.' end
    if targetSrc == adminSrc then return false, 'You cannot moon yourself.' end

    local QBCore = exports['qb-core']:GetCoreObject()
    local P = QBCore.Functions.GetPlayer(targetSrc)
    if not P then return false, 'Player not loaded.' end
    local cid = P.PlayerData.citizenid

    -- Already up there?
    local dup = MySQL.scalar.await(
        "SELECT id FROM tenx_admin_punishments WHERE citizenid = ? AND type = 'moon' AND status = 'active' LIMIT 1", { cid })
    if dup then return false, 'They are already on the moon. Use /' .. (Moon.releaseCommand or 'unmoon') .. '.' end

    -- Conflict guard: a jailed player's leash thread would instantly snap them
    -- back off the moon, and a cuffed player is frozen. Release them first.
    local clash = MySQL.single.await(
        "SELECT type FROM tenx_admin_punishments WHERE citizenid = ? AND status = 'active' AND type IN ('cuff','jail','community') LIMIT 1", { cid })
    if clash then
        return false, ('They have an active %s — release that first.'):format(clash.type)
    end

    local moonCoords = GetMoonCoords()
    if not moonCoords then
        return false, 'No moon point. Set Config.Moon.coords, or stand on the spot and run /' .. (Moon.setPointCommand or 'setmoon') .. '.'
    end

    -- Capture where they are RIGHT NOW — this is the return ticket.
    local ped = GetPlayerPed(targetSrc)
    local c = GetEntityCoords(ped)
    local returnCoords = { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, h = GetEntityHeading(ped) + 0.0 }

    reason = tostring(reason or Moon.defaultReason or 'Crisis resolution'):sub(1, 500)

    local ci = P.PlayerData.charinfo
    local targetName = ('%s %s'):format(ci.firstname or '', ci.lastname or '')

    local insertId = MySQL.insert.await([[
        INSERT INTO tenx_admin_punishments
            (citizenid, player_name, type, reason, evidence, duration, data, status, issued_by, issued_by_name)
        VALUES (?, ?, 'moon', ?, NULL, NULL, ?, 'active', ?, ?)
    ]], {
        cid, targetName, reason,
        json.encode({ coords = moonCoords, returnCoords = returnCoords }),
        GetLicense(adminSrc) or 'console', AdminName(adminSrc),
    })

    if not insertId then return false, 'Database error.' end

    PunishmentTypes['moon'].applyLive(targetSrc, {
        id = insertId, reason = reason,
        data = json.encode({ coords = moonCoords, returnCoords = returnCoords }),
    }, false)

    MoonDiscord('Sent to Moon', ('**Player:** %s (%s)\n**Reason:** %s\n**By:** %s'):format(
        targetName, cid, reason, AdminName(adminSrc)))

    return true, ('%s sent to the moon.'):format(targetName)
end

local function DoUnmoon(adminSrc, targetSrc)
    if not IsAllowed(adminSrc) then return false, 'No permission.' end

    targetSrc = tonumber(targetSrc)
    if not targetSrc or not GetPlayerName(targetSrc) then return false, 'Player not online.' end

    local QBCore = exports['qb-core']:GetCoreObject()
    local P = QBCore.Functions.GetPlayer(targetSrc)
    if not P then return false, 'Player not loaded.' end
    local cid = P.PlayerData.citizenid

    local record = MySQL.single.await(
        "SELECT * FROM tenx_admin_punishments WHERE citizenid = ? AND type = 'moon' AND status = 'active' ORDER BY id DESC LIMIT 1", { cid })
    if not record then return false, 'They are not on the moon.' end

    MySQL.update.await(
        "UPDATE tenx_admin_punishments SET status = 'completed', released_at = NOW() WHERE id = ?", { record.id })

    PunishmentTypes['moon'].removeLive(targetSrc, record)

    MoonDiscord('Returned from Moon', ('**Player:** %s (%s)\n**By:** %s'):format(
        record.player_name or cid, cid, AdminName(adminSrc)))

    return true, ('%s brought back.'):format(record.player_name or cid)
end

-- ============================================================
--  COMMANDS (permission enforced here, server-side)
-- ============================================================
RegisterCommand(Moon.command or 'moon', function(src, args)
    if not IsAllowed(src) then
        Notify(src, 'error', 'You are not permitted to use this.')
        return
    end
    if not args[1] then
        Notify(src, 'error', ('Usage: /%s [id] [reason]'):format(Moon.command or 'moon'))
        return
    end
    local id = table.remove(args, 1)
    local reason = #args > 0 and table.concat(args, ' ') or nil
    local ok, msg = DoMoon(src, id, reason)
    Notify(src, ok and 'success' or 'error', msg)
end, false)

RegisterCommand(Moon.releaseCommand or 'unmoon', function(src, args)
    if not IsAllowed(src) then
        Notify(src, 'error', 'You are not permitted to use this.')
        return
    end
    if not args[1] then
        Notify(src, 'error', ('Usage: /%s [id]'):format(Moon.releaseCommand or 'unmoon'))
        return
    end
    local ok, msg = DoUnmoon(src, args[1])
    Notify(src, ok and 'success' or 'error', msg)
end, false)

-- ============================================================
--  CALLBACKS (target eye + /setmoon)
-- ============================================================
lib.callback.register('tenx-adminjail:moon:send', function(src, data)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end
    local ok, msg = DoMoon(src, data.target, data.reason)
    return { ok = ok, msg = msg }
end)

lib.callback.register('tenx-adminjail:moon:unsend', function(src, data)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end
    local ok, msg = DoUnmoon(src, data.target)
    return { ok = ok, msg = msg }
end)

lib.callback.register('tenx-adminjail:moon:savePoint', function(src, data)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end
    local label = tostring(data.label or ''):sub(1, 100)
    local coords = data.coords
    if label == '' then return { ok = false, msg = 'Label required.' } end
    if type(coords) ~= 'table' or not coords.x then return { ok = false, msg = 'Bad coords.' } end

    MySQL.insert.await(
        'INSERT INTO tenx_admin_locations (category, label, coords, radius, job_type) VALUES (?, ?, ?, NULL, NULL)',
        { 'moon', label, json.encode(coords) })

    return { ok = true, msg = 'Moon point saved as "' .. label .. '". It is now the newest one used.' }
end)

-- ============================================================
--  EXPORTS
-- ============================================================
exports('isPlayerMooned', function(playerSrc)
    local QBCore = exports['qb-core']:GetCoreObject()
    local P = QBCore.Functions.GetPlayer(playerSrc)
    if not P then return false end
    return MySQL.scalar.await(
        "SELECT id FROM tenx_admin_punishments WHERE citizenid = ? AND type = 'moon' AND status = 'active' LIMIT 1",
        { P.PlayerData.citizenid }) ~= nil
end)

exports('moonPlayer',   function(adminSrc, targetSrc, reason) return DoMoon(adminSrc or 0, targetSrc, reason) end)
exports('unmoonPlayer', function(adminSrc, targetSrc)         return DoUnmoon(adminSrc or 0, targetSrc) end)
