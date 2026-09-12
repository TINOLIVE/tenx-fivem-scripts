-- tenx-adminjail/server/recovery.lua
-- NAIJA 2046 — Recovery tools (server side)
--
--   1. HEAL ZONES — any player who dies inside a zone is revived on the spot,
--      no exceptions (moon, jail-on-moon, visitor — all the same).
--   2. /rescue [id] — console-only. Clears punishments, revives, TPs to Legion.
--
-- LOAD ORDER: after server/server.lua (_G.NaijaPunishmentTypes) and after
-- server/moon.lua (the 'moon' type must exist before rescue can clear it).

local Rec = Config.Recovery
local QBCore = exports['qb-core']:GetCoreObject()

-- Optional — only used by /rescue's punishment clearing. Degrades gracefully.
local PunishmentTypes = _G.NaijaPunishmentTypes

local function online(src)
    return src and src ~= 0 and GetPlayerName(src) ~= nil
end

-- ============================================================
--  1. HEAL ZONES
--  Hooks the ambulance script's own death event (many resources can listen to
--  one event, so no patching). On death we read where the body is and, if it's
--  inside any zone, revive them there.
-- ============================================================
local healCd = {}   -- src -> os.time() of last auto-revive (anti-loop)

local function zoneAt(coords)
    for _, z in ipairs(Rec.HealZones or {}) do
        if z.centre and #(coords - z.centre) <= (z.radius or 60.0) then
            return z
        end
    end
    return nil
end

-- Shared handler for BOTH the downed (bleeding out) and fully-dead events, so a
-- player is picked up the instant they go down inside a zone — they never have
-- to wait to fully bleed out first.
local function handleGoDown(src)
    if not online(src) then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local zone = zoneAt(GetEntityCoords(ped))
    if not zone then return end   -- went down outside every zone: normal, no heal

    -- anti-loop cooldown
    local now = os.time()
    if healCd[src] and (now - healCd[src]) < (Rec.healCooldown or 5) then return end
    healCd[src] = now

    SetTimeout(Rec.healReviveDelay or 1500, function()
        if online(src) then
            TriggerClientEvent('tenx-adminjail:client:revive', src)   -- revive in place, no teleport
        end
    end)
end

-- Downed / bleeding out
RegisterNetEvent('ak47_qb_ambulancejob:onPlayerDown', function()
    handleGoDown(source)
end)

-- Fully dead (covers instant kills that skip the down state — headshots, etc.)
RegisterNetEvent('ak47_qb_ambulancejob:onPlayerDeath', function()
    handleGoDown(source)
end)

-- ============================================================
--  2. /rescue [id]  — CONSOLE ONLY
-- ============================================================
local function clearPunishments(src, cid)
    local cleared = {}
    if not (Rec.rescueClearsPunishments and cid) then return cleared end

    local rows = MySQL.query.await(
        "SELECT * FROM tenx_admin_punishments WHERE citizenid = ? AND status = 'active'", { cid })

    for _, rec in ipairs(rows or {}) do
        MySQL.update.await(
            "UPDATE tenx_admin_punishments SET status = 'completed', released_at = NOW() WHERE id = ?", { rec.id })
        -- removeLive stops the client-side loop/leash. It also teleports them
        -- (jail->release, moon->return) — harmless; our Legion TP lands last.
        if PunishmentTypes and PunishmentTypes[rec.type] and PunishmentTypes[rec.type].removeLive then
            pcall(function() PunishmentTypes[rec.type].removeLive(src, rec) end)
        end
        cleared[#cleared + 1] = rec.type
    end
    return cleared
end

RegisterCommand(Rec.rescueCommand or 'rescue', function(src, args)
    if src ~= 0 then return end   -- console only

    local target = tonumber(args[1])
    if not target then
        print(('^3[tenx-adminjail]^7 usage: %s [serverId]'):format(Rec.rescueCommand or 'rescue'))
        return
    end
    if not online(target) then
        print(('^1[tenx-adminjail]^7 rescue: player %s is not online.'):format(target))
        return
    end

    local P = QBCore.Functions.GetPlayer(target)
    local cid = P and P.PlayerData.citizenid
    local name = P and ('%s %s'):format(P.PlayerData.charinfo.firstname or '?', P.PlayerData.charinfo.lastname or '?')
        or GetPlayerName(target)

    local cleared = clearPunishments(target, cid)

    local legion = Rec.legion
    local legionTbl = { x = legion.x, y = legion.y, z = legion.z, h = legion.w }

    -- revive first (may TP to hospital), place at Legion LAST so it wins
    if Rec.rescueRevives then
        SetTimeout(1200, function()
            if online(target) then TriggerClientEvent('tenx-adminjail:client:revive', target) end
        end)
        SetTimeout(1200 + (Rec.ambulance.settleDelay or 1800), function()
            if online(target) then TriggerClientEvent('tenx-adminjail:client:rescueTP', target, legionTbl) end
        end)
    else
        SetTimeout(1200, function()
            if online(target) then TriggerClientEvent('tenx-adminjail:client:rescueTP', target, legionTbl) end
        end)
    end

    print(('^2[tenx-adminjail]^7 rescue: %s (%s) -> Legion Square%s%s')
        :format(name, target,
            Rec.rescueRevives and ' + revive' or '',
            #cleared > 0 and (' | cleared: ' .. table.concat(cleared, ', ')) or ''))
end, true)   -- restricted = true

-- ============================================================
--  CLEANUP
-- ============================================================
AddEventHandler('playerDropped', function()
    healCd[source] = nil
end)

-- ============================================================
--  EXPORTS
-- ============================================================
exports('rescueToLegion', function(targetSrc)
    if not online(targetSrc) then return false end
    local P = QBCore.Functions.GetPlayer(targetSrc)
    clearPunishments(targetSrc, P and P.PlayerData.citizenid)
    local legion = Rec.legion
    local legionTbl = { x = legion.x, y = legion.y, z = legion.z, h = legion.w }
    if Rec.rescueRevives then
        SetTimeout(1200, function() if online(targetSrc) then TriggerClientEvent('tenx-adminjail:client:revive', targetSrc) end end)
        SetTimeout(1200 + (Rec.ambulance.settleDelay or 1800), function() if online(targetSrc) then TriggerClientEvent('tenx-adminjail:client:rescueTP', targetSrc, legionTbl) end end)
    else
        SetTimeout(1200, function() if online(targetSrc) then TriggerClientEvent('tenx-adminjail:client:rescueTP', targetSrc, legionTbl) end end)
    end
    return true
end)

exports('revivePlayer', function(targetSrc)
    if not online(targetSrc) then return false end
    TriggerClientEvent('tenx-adminjail:client:revive', targetSrc)
    return true
end)