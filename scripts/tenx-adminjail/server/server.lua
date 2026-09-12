-- tenx-adminjail/server/main.lua
-- NAIJA 2046 — Admin Punishment System (server framework)
-- Server-authoritative: the client only ever sends INTENT. The server decides,
-- validates, writes to the DB, and pushes effects. Nothing trusts the client.
--
-- PERSISTENCE MODEL — the DB row is the single source of truth:
--   * status = 'active'  -> the punishment is live, full stop.
--   * time_served        -> jail seconds already accrued (online-only).
--   * data.done          -> community service jobs already completed.
-- Effects are re-pushed from that row on THREE triggers:
--   1. Player logs in            (QBCore:Server:PlayerLoaded)
--   2. Resource (re)starts       (onResourceStart sweep — was the missing one)
--   3. Admin applies it live     (applyPunishment)
-- So restarting the script no longer wipes anyone's sentence.

local QBCore = exports['qb-core']:GetCoreObject()

-- ============================================================
--  PERMISSIONS
-- ============================================================
local function GetLicense(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return nil
end

local function IsAllowed(src)
    if src == 0 then return true end            -- server console
    local lic = GetLicense(src)
    if not lic then return false end
    return Config.Admins[lic] ~= nil
end

-- ============================================================
--  LOGGING (Discord + public chat). The in-menu "Logs" panel reads the DB.
-- ============================================================
local function SendDiscord(title, description, evidence, color)
    if not Config.Webhook or Config.Webhook == '' then return end
    local embed = {
        {
            title = title,
            description = description,
            color = color or 16711680,
            footer = { text = ('NAIJA 2046 • %s'):format(os.date('%Y-%m-%d %H:%M:%S')) },
        }
    }
    if evidence and evidence ~= '' then
        embed[1].image = { url = evidence }
    end
    PerformHttpRequest(Config.Webhook, function() end, 'POST', json.encode({
        username = 'NAIJA 2046 Admin',
        embeds = embed,
    }), { ['Content-Type'] = 'application/json' })
end

local function Broadcast(message)
    if not Config.PublicBroadcast then return end
    TriggerClientEvent('chat:addMessage', -1, {
        color = Config.BroadcastColor,
        multiline = true,
        args = { Config.BroadcastTag, message },
    })
end

-- ============================================================
--  HELPERS
-- ============================================================
local function GetSourceByCitizen(cid)
    for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
        local P = QBCore.Functions.GetPlayer(pid)
        if P and P.PlayerData.citizenid == cid then return pid end
    end
    return nil
end

local function CitizenExists(cid)
    if GetSourceByCitizen(cid) then return true end
    local row = MySQL.scalar.await('SELECT 1 FROM players WHERE citizenid = ?', { cid })
    return row ~= nil
end

local function GetReleaseCoords()
    local row = MySQL.single.await(
        "SELECT coords FROM tenx_admin_locations WHERE category = 'release' ORDER BY id DESC LIMIT 1"
    )
    if row and row.coords then
        local ok, c = pcall(json.decode, row.coords)
        if ok then return c end
    end
    return nil
end

-- ============================================================
--  PUNISHMENT TYPE REGISTRY (modular)
--  Each type: applyLive(src, record, resync)  removeLive(src, record)
--  `resync` = true when we're re-pushing after a restart/relog rather than a
--  fresh punishment — the client uses it to skip the flash + "you got jailed"
--  notify and just quietly rebuild the effect.
-- ============================================================
local PunishmentTypes = {}

PunishmentTypes['cuff'] = {
    label = 'Hard Cuff',
    hasTimer = false,
    applyLive = function(src, record, resync)
        TriggerClientEvent('tenx-adminjail:client:applyCuff', src, {
            id     = record.id,
            reason = record.reason,
            resync = resync or false,
        })
    end,
    removeLive = function(src, _record)
        local coords = Config.TeleportOnRelease and GetReleaseCoords() or nil
        TriggerClientEvent('tenx-adminjail:client:removeCuff', src, coords)
    end,
}

PunishmentTypes['jail'] = {
    label = 'Admin Jail',
    hasTimer = true,
    applyLive = function(src, record, resync)
        local d = {}
        if record.data then local ok, parsed = pcall(json.decode, record.data) if ok then d = parsed end end
        TriggerClientEvent('tenx-adminjail:client:applyJail', src, {
            id         = record.id,
            reason     = record.reason,
            coords     = d.coords,
            radius     = d.radius or Config.Jail.defaultRadius,
            duration   = record.duration,           -- seconds, or nil = infinite
            timeServed = record.time_served or 0,   -- seconds already served -> resumes here
            resync     = resync or false,
        })
    end,
    removeLive = function(src, _record)
        local coords = Config.TeleportOnRelease and GetReleaseCoords() or nil
        TriggerClientEvent('tenx-adminjail:client:removeJail', src, coords)
    end,
}

PunishmentTypes['community'] = {
    label = 'Community Service',
    hasTimer = false,
    applyLive = function(src, record, resync)
        local d = {}
        if record.data then local ok, p = pcall(json.decode, record.data) if ok then d = p end end
        local spots = MySQL.query.await("SELECT id, coords, job_type FROM tenx_admin_locations WHERE category = 'cleaning'")
        local list = {}
        for _, s in ipairs(spots or {}) do
            local ok, c = pcall(json.decode, s.coords)
            if ok then list[#list + 1] = { id = s.id, coords = c, job = s.job_type } end
        end
        TriggerClientEvent('tenx-adminjail:client:applyCommunity', src, {
            id       = record.id,
            reason   = record.reason,
            required = d.required or Config.CommunityService.defaultJobs,
            done     = d.done or 0,                 -- resumes at the saved count
            spots    = list,
            resync   = resync or false,
        })
    end,
    removeLive = function(src, _record)
        local coords = Config.TeleportOnRelease and GetReleaseCoords() or nil
        TriggerClientEvent('tenx-adminjail:client:removeCommunity', src, coords)
    end,
}

-- ============================================================
--  REGISTRY EXPOSURE
--  PunishmentTypes is local to this file, so add-on modules (server/moon.lua)
--  can't reach it. This hands them a reference so they can register their own
--  type and inherit the resync sweep, the relog re-apply and the release board.
--  Modules read this at load — they MUST be listed after this file in
--  fxmanifest.lua's server_scripts.
-- ============================================================
_G.NaijaPunishmentTypes = PunishmentTypes

-- Re-apply any active punishments to a player. Used by BOTH the login path and
-- the restart sweep. Returns how many were pushed.
local function ApplyActiveToPlayer(src, cid, resync)
    local rows = MySQL.query.await(
        "SELECT * FROM tenx_admin_punishments WHERE citizenid = ? AND status = 'active'",
        { cid }
    )
    local n = 0
    for _, record in ipairs(rows or {}) do
        local t = PunishmentTypes[record.type]
        if t and t.applyLive then
            t.applyLive(src, record, resync)
            n = n + 1
        end
    end
    return n
end

-- Trigger 1: player logs in (covers offline-queued punishments + relog persistence).
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local cid = Player.PlayerData.citizenid
    -- small delay so the client is fully in before we push effects
    SetTimeout(3000, function()
        if GetPlayerName(src) then
            ApplyActiveToPlayer(src, cid, true)
        end
    end)
end)

-- ============================================================
--  Trigger 2: RESTART RESYNC
--  On `restart tenx-adminjail` / `ensure tenx-adminjail`, nobody reconnects — so
--  PlayerLoaded never fires and every live effect silently dies while the DB
--  row stays 'active'. That's the inconsistency: the menu still lists them but
--  the player walks free (cuff anim stuck on, freeze gone with the dead thread).
--  This sweep walks every online player and re-pushes their active rows.
-- ============================================================
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        -- let qb-core, oxmysql and the freshly-restarted client script settle
        Wait(Config.RestartResyncDelay or 3000)

        local players = QBCore.Functions.GetPlayers()
        local restored, touched = 0, 0

        for _, pid in ipairs(players) do
            local P = QBCore.Functions.GetPlayer(pid)
            if P then
                local n = ApplyActiveToPlayer(pid, P.PlayerData.citizenid, true)
                if n > 0 then
                    restored = restored + n
                    touched  = touched + 1
                end
            end
        end

        if Config.RestartResyncLog then
            print(('[tenx-adminjail] restart resync: %d punishment(s) re-applied across %d player(s) (%d online).')
                :format(restored, touched, #players))
        end
    end)
end)

-- ============================================================
--  CALLBACKS (request/response) — every one re-checks permission
-- ============================================================

-- Can this player open the menu? (keeps the allowlist server-side)
lib.callback.register('tenx-adminjail:canOpen', function(src)
    return IsAllowed(src)
end)

-- Live player search: online (live) + offline (players table). Name autocomplete.
lib.callback.register('tenx-adminjail:searchPlayers', function(src, query)
    if not IsAllowed(src) then return {} end
    query = tostring(query or ''):lower()
    if #query < 2 then return {} end

    local results, seen = {}, {}

    -- online
    for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
        local P = QBCore.Functions.GetPlayer(pid)
        if P then
            local ci = P.PlayerData.charinfo
            local name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
            if name:lower():find(query, 1, true) then
                seen[P.PlayerData.citizenid] = true
                results[#results + 1] = {
                    citizenid = P.PlayerData.citizenid,
                    name = name,
                    online = true,
                }
            end
        end
    end

    -- offline (skip anyone already matched online)
    local like = '%' .. query .. '%'
    local rows = MySQL.query.await([[
        SELECT citizenid, charinfo FROM players
        WHERE LOWER(JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.firstname'))) LIKE ?
           OR LOWER(JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.lastname')))  LIKE ?
        LIMIT 25
    ]], { like, like })

    for _, row in ipairs(rows or {}) do
        if not seen[row.citizenid] then
            local ok, ci = pcall(json.decode, row.charinfo)
            local name = ok and ('%s %s'):format(ci.firstname or '', ci.lastname or '') or row.citizenid
            results[#results + 1] = {
                citizenid = row.citizenid,
                name = name,
                online = false,
            }
        end
    end

    return results
end)

-- Apply a punishment. Client sends citizenid + type + reason + evidence only.
lib.callback.register('tenx-adminjail:applyPunishment', function(src, data)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end

    local cid      = tostring(data.citizenid or '')
    local ptype    = tostring(data.type or '')
    local reason   = tostring(data.reason or ''):sub(1, 500)
    local evidence = data.evidence and tostring(data.evidence):sub(1, 255) or nil

    if not PunishmentTypes[ptype] then return { ok = false, msg = 'Unknown punishment type.' } end
    if cid == '' or not CitizenExists(cid) then return { ok = false, msg = 'Player not found.' } end
    if #reason < 3 then return { ok = false, msg = 'A reason is required.' } end

    -- Prevent stacking the same active type on the same player.
    local dup = MySQL.scalar.await(
        "SELECT id FROM tenx_admin_punishments WHERE citizenid = ? AND type = ? AND status = 'active' LIMIT 1",
        { cid, ptype }
    )
    if dup then return { ok = false, msg = 'That player already has an active ' .. ptype .. '.' } end

    -- Type-specific extras: duration (seconds, nil = infinite) and data (JSON).
    local duration, extraData = nil, nil

    if ptype == 'jail' then
        -- Server looks up the chosen jail location itself (never trusts client coords).
        local jailId = tonumber(data.jailId)
        local jrow = jailId and MySQL.single.await(
            "SELECT coords, radius FROM tenx_admin_locations WHERE id = ? AND category = 'jail'", { jailId })
        if not jrow then return { ok = false, msg = 'Pick a valid jail location first.' } end
        local ok, jc = pcall(json.decode, jrow.coords)
        if not ok then return { ok = false, msg = 'Jail location is corrupt.' } end
        extraData = json.encode({ coords = jc, radius = jrow.radius or Config.Jail.defaultRadius, jailId = jailId })
        if not data.infinite then
            local mins = tonumber(data.minutes)
            if not mins or mins < 1 then return { ok = false, msg = 'Enter minutes, or tick Infinite.' } end
            duration = math.floor(mins * 60)
        end
    end

    if ptype == 'community' then
        local count = MySQL.scalar.await("SELECT COUNT(*) FROM tenx_admin_locations WHERE category = 'cleaning'")
        if not count or count == 0 then return { ok = false, msg = 'No cleaning spots saved. Add some first.' } end
        local jobs = tonumber(data.jobs) or Config.CommunityService.defaultJobs
        if jobs < 1 then jobs = Config.CommunityService.defaultJobs end
        extraData = json.encode({ required = jobs, done = 0 })
    end

    local adminLic  = GetLicense(src) or 'console'
    local adminName = (src == 0) and 'Console' or (Config.Admins[adminLic] or GetPlayerName(src))
    local targetName = tostring(data.name or cid)

    local insertId = MySQL.insert.await([[
        INSERT INTO tenx_admin_punishments
            (citizenid, player_name, type, reason, evidence, duration, data, status, issued_by, issued_by_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
    ]], { cid, targetName, ptype, reason, evidence, duration, extraData, adminLic, adminName })

    if not insertId then return { ok = false, msg = 'Database error.' } end

    local record = { id = insertId, citizenid = cid, type = ptype, reason = reason,
                     evidence = evidence, duration = duration, data = extraData, time_served = 0 }

    -- Apply live if the target is online right now; otherwise it waits in the DB
    -- and fires from ApplyActiveToPlayer the moment they next spawn in.
    local tgt = GetSourceByCitizen(cid)
    local applied = false
    if tgt then
        PunishmentTypes[ptype].applyLive(tgt, record, false)
        applied = true
    end

    local label = PunishmentTypes[ptype].label
    local durText = ''
    if ptype == 'jail' then
        durText = duration and (' (' .. math.floor(duration / 60) .. ' min)') or ' (Infinite)'
    elseif ptype == 'community' then
        local ok, d = pcall(json.decode, extraData)
        if ok and d.required then durText = (' (' .. d.required .. ' jobs)') end
    end
    SendDiscord(
        ('%s applied'):format(label),
        ('**Player:** %s%s\n**Reason:** %s\n**By:** %s\n**Status:** %s')
            :format(targetName, durText, reason, adminName, applied and 'Applied (online)' or 'Queued (offline)'),
        evidence, 16711680
    )
    Broadcast(('%s has been placed on %s%s by staff. Reason: %s'):format(targetName, label, durText, reason))

    return { ok = true, msg = applied and (label .. ' applied.') or (label .. ' queued — applies on next login.') }
end)

-- Everyone currently serving (the "Currently Serving" list + release board).
lib.callback.register('tenx-adminjail:getActive', function(src)
    if not IsAllowed(src) then return {} end
    local rows = MySQL.query.await(
        "SELECT id, citizenid, player_name, type, reason, issued_by_name, created_at FROM tenx_admin_punishments WHERE status = 'active' ORDER BY id DESC"
    )
    for _, r in ipairs(rows or {}) do
        r.online = GetSourceByCitizen(r.citizenid) ~= nil
    end
    return rows or {}
end)

-- Release / cancel a punishment (menu-only — there is no /uncuff command).
lib.callback.register('tenx-adminjail:release', function(src, punishmentId)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    punishmentId = tonumber(punishmentId)
    if not punishmentId then return { ok = false, msg = 'Bad request.' } end

    local record = MySQL.single.await(
        "SELECT * FROM tenx_admin_punishments WHERE id = ? AND status = 'active'",
        { punishmentId }
    )
    if not record then return { ok = false, msg = 'Not found or already released.' } end

    MySQL.update.await(
        "UPDATE tenx_admin_punishments SET status = 'completed', released_at = NOW() WHERE id = ?",
        { punishmentId }
    )

    local tgt = GetSourceByCitizen(record.citizenid)
    if tgt and PunishmentTypes[record.type] and PunishmentTypes[record.type].removeLive then
        PunishmentTypes[record.type].removeLive(tgt, record)
    end

    local adminName = (src == 0) and 'Console' or (Config.Admins[GetLicense(src)] or GetPlayerName(src))
    SendDiscord('Punishment released',
        ('**Player:** %s\n**Type:** %s\n**By:** %s'):format(record.player_name or record.citizenid, record.type, adminName),
        nil, 3066993)
    Broadcast(('%s has been released by staff.'):format(record.player_name or record.citizenid))

    return { ok = true, msg = 'Released.' }
end)

-- Recent log entries for the in-menu Logs panel.
lib.callback.register('tenx-adminjail:getLogs', function(src)
    if not IsAllowed(src) then return {} end
    return MySQL.query.await(
        "SELECT player_name, type, reason, status, issued_by_name, created_at FROM tenx_admin_punishments ORDER BY id DESC LIMIT 25"
    ) or {}
end)

-- ---- Saved locations (release / jail / cleaning) ----
lib.callback.register('tenx-adminjail:saveLocation', function(src, data)
    if not IsAllowed(src) then return { ok = false, msg = 'No permission.' } end
    if type(data) ~= 'table' then return { ok = false, msg = 'Bad request.' } end

    local category = tostring(data.category or '')
    local label    = tostring(data.label or ''):sub(1, 100)
    local coords   = data.coords
    if category ~= 'release' and category ~= 'jail' and category ~= 'cleaning' then
        return { ok = false, msg = 'Bad category.' }
    end
    if label == '' then return { ok = false, msg = 'Label required.' } end
    if type(coords) ~= 'table' or not coords.x then return { ok = false, msg = 'Bad coords.' } end

    MySQL.insert.await(
        'INSERT INTO tenx_admin_locations (category, label, coords, radius, job_type) VALUES (?, ?, ?, ?, ?)',
        { category, label, json.encode(coords), data.radius or Config.Jail.defaultRadius, data.job_type }
    )
    return { ok = true, msg = 'Saved "' .. label .. '".' }
end)

lib.callback.register('tenx-adminjail:getLocations', function(src, category)
    if not IsAllowed(src) then return {} end
    if category then
        return MySQL.query.await('SELECT * FROM tenx_admin_locations WHERE category = ? ORDER BY id DESC', { category }) or {}
    end
    return MySQL.query.await('SELECT * FROM tenx_admin_locations ORDER BY category, id DESC') or {}
end)

lib.callback.register('tenx-adminjail:deleteLocation', function(src, id)
    if not IsAllowed(src) then return { ok = false } end
    id = tonumber(id)
    if not id then return { ok = false } end
    MySQL.update.await('DELETE FROM tenx_admin_locations WHERE id = ?', { id })
    return { ok = true }
end)

-- ============================================================
--  COMMUNITY SERVICE — job completion (server validates proximity)
--  Every completed job is written to the DB immediately, so a restart between
--  job 3 and job 4 resumes at 3/5, not 0/5.
-- ============================================================
lib.callback.register('tenx-adminjail:community:jobDone', function(src, spotId)
    if not GetPlayerName(src) then return { ok = false } end
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return { ok = false } end
    local cid = P.PlayerData.citizenid

    local rec = MySQL.single.await(
        "SELECT * FROM tenx_admin_punishments WHERE citizenid = ? AND type = 'community' AND status = 'active' LIMIT 1", { cid })
    if not rec then return { ok = false } end

    local spot = MySQL.single.await(
        "SELECT coords FROM tenx_admin_locations WHERE id = ? AND category = 'cleaning'", { tonumber(spotId) })
    if not spot then return { ok = false } end
    local ok, sc = pcall(json.decode, spot.coords)
    if not ok then return { ok = false } end

    -- proximity check (anti-spoof): player must actually be at the spot
    local pc = GetEntityCoords(GetPlayerPed(src))
    if #(pc - vector3(sc.x + 0.0, sc.y + 0.0, sc.z + 0.0)) > 6.0 then
        return { ok = false, msg = 'Too far from the job.' }
    end

    local d = {}
    if rec.data then local o, p = pcall(json.decode, rec.data) if o then d = p end end
    d.required = d.required or Config.CommunityService.defaultJobs
    d.done = (d.done or 0) + 1

    if d.done >= d.required then
        MySQL.update.await("UPDATE tenx_admin_punishments SET status = 'completed', released_at = NOW(), data = ? WHERE id = ?", { json.encode(d), rec.id })
        local coords = Config.TeleportOnRelease and GetReleaseCoords() or nil
        TriggerClientEvent('tenx-adminjail:client:removeCommunity', src, coords)
        Broadcast(('%s has completed their community service.'):format(rec.player_name or cid))
        return { ok = true, complete = true, done = d.done, required = d.required }
    else
        MySQL.update.await("UPDATE tenx_admin_punishments SET data = ? WHERE id = ?", { json.encode(d), rec.id })
        return { ok = true, complete = false, done = d.done, required = d.required }
    end
end)

-- Fallback skin restore: only used if neither restoreSkinEvent nor
-- restoreSkinExport is set in config. Reloads the player's stored QBCore skin.
RegisterNetEvent('tenx-adminjail:community:reloadSkin', function()
    local src = source
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return end
    TriggerClientEvent('qb-clothing:client:loadPlayerClothing', src) -- best-effort default
end)

-- ============================================================
--  JAIL TIMER (online-only accrual + auto-release)
--  Time only counts while the player is in the city. Offline = clock paused.
--  time_served is written every tick, so a restart resumes to the second.
-- ============================================================
CreateThread(function()
    local step = Config.Jail.tickSeconds
    while true do
        Wait(step * 1000)
        local rows = MySQL.query.await(
            "SELECT id, citizenid, player_name, duration, time_served FROM tenx_admin_punishments WHERE type = 'jail' AND status = 'active' AND duration IS NOT NULL"
        )
        for _, r in ipairs(rows or {}) do
            local tgt = GetSourceByCitizen(r.citizenid)
            if tgt then                                   -- online → clock ticks
                local served = (r.time_served or 0) + step
                if served >= r.duration then
                    MySQL.update.await("UPDATE tenx_admin_punishments SET status = 'completed', released_at = NOW(), time_served = ? WHERE id = ?", { r.duration, r.id })
                    local coords = Config.TeleportOnRelease and GetReleaseCoords() or nil
                    TriggerClientEvent('tenx-adminjail:client:removeJail', tgt, coords)
                    Broadcast(('%s has finished their Admin Jail sentence.'):format(r.player_name or r.citizenid))
                else
                    MySQL.update.await("UPDATE tenx_admin_punishments SET time_served = ? WHERE id = ?", { served, r.id })
                    TriggerClientEvent('tenx-adminjail:client:jailSync', tgt, { remaining = r.duration - served })
                end
            end
        end
    end
end)

-- ============================================================
--  EXPORTS / INTEGRATION HOOKS
-- ============================================================
exports('isPlayerLocked', function(playerSrc)
    local P = QBCore.Functions.GetPlayer(playerSrc)
    if not P then return false end
    local row = MySQL.scalar.await(
        "SELECT id FROM tenx_admin_punishments WHERE citizenid = ? AND status = 'active' LIMIT 1",
        { P.PlayerData.citizenid }
    )
    return row ~= nil
end)
