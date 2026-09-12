local QBCore = exports['qb-core']:GetCoreObject()

-- ============================================================
--  STATE
-- ============================================================
-- prox[victimCid][robberCid] = { since = unix, last = unix }
--   Continuous proximity. `since` is when the unbroken window started, `last`
--   is the most recent tick they were in radius. Time earned = last - since.
--   Break it (out of radius longer than grace) and `since` resets to now.
local prox = {}

-- deaths[cid] = { id, time, vehicleKill, witnesses = { [robberCid] = seconds }, looted }
--   Snapshot taken at the MOMENT of death. Frozen — nobody can earn their way
--   onto the witness list after the fact.
local deaths = {}
local deathCounter = {}

-- pairCd[robberCid][victimCid] = unix of last successful rob
local pairCd = {}

-- scene[robberCid] = { count = n, blockedUntil = unix }
local scene = {}

-- victim total-rob tracking (legacy)
local robCounts = {}

-- token -> log payload waiting on a screenshot to come back
local pendingShots = {}

local function notify(src, desc, type)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Robbery', description = desc, type = type or 'inform' })
end

local function fmtTime(secs)
    secs = math.max(0, math.floor(secs))
    return ('%d:%02d'):format(math.floor(secs / 60), secs % 60)
end

-- ============================================================
--  PROXIMITY TRACKER
--  Runs every Config.Proximity.tick. O(n²) over online players — at 64 players
--  that's ~2000 distance checks a second, which is nothing. Only ALIVE pairs
--  accrue: you cannot earn proximity standing over a corpse.
-- ============================================================
local function touch(victimCid, robberCid, now)
    local grace = Config.Proximity.grace or 5
    prox[victimCid] = prox[victimCid] or {}
    local e = prox[victimCid][robberCid]

    if not e or (now - e.last) > grace then
        -- first contact, or the chain was broken -> start over from zero
        prox[victimCid][robberCid] = { since = now, last = now }
    else
        e.last = now
    end
end

-- seconds of UNBROKEN proximity robber has on victim right now (0 if broken)
local function earned(victimCid, robberCid, now)
    local e = prox[victimCid] and prox[victimCid][robberCid]
    if not e then return 0 end
    if (now - e.last) > (Config.Proximity.grace or 5) then return 0 end
    return e.last - e.since
end

CreateThread(function()
    if not (Config.Proximity and Config.Proximity.enabled) then return end

    while true do
        Wait(Config.Proximity.tick or 1000)

        local now = os.time()
        local list = {}

        for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
            local P = QBCore.Functions.GetPlayer(pid)
            if P then
                local ped = GetPlayerPed(pid)
                if ped and ped ~= 0 then
                    local md = P.PlayerData.metadata or {}
                    list[#list + 1] = {
                        cid    = P.PlayerData.citizenid,
                        coords = GetEntityCoords(ped),
                        alive  = not (md.isdead or md.inlaststand),
                    }
                end
            end
        end

        local radius = Config.Proximity.radius or 10.0

        for i = 1, #list do
            for j = i + 1, #list do
                local a, b = list[i], list[j]
                -- both must be ALIVE — time only counts while the victim is up
                if a.alive and b.alive and #(a.coords - b.coords) <= radius then
                    touch(a.cid, b.cid, now)
                    touch(b.cid, a.cid, now)
                end
            end
        end
    end
end)

-- ============================================================
--  DEATH SNAPSHOT
--  Fired by the victim's own client the instant they go down. Freezes who was
--  standing there and how much proximity each of them had earned.
-- ============================================================
RegisterNetEvent('playerrob:server:reportDeath', function(byVehicle, causeHash)
    local src = source
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return end

    local cid = P.PlayerData.citizenid
    local now = os.time()

    -- don't overwrite a snapshot that's already live for this death
    if deaths[cid] and (now - deaths[cid].time) < 5 then return end

    local witnesses = {}
    local grace = Config.Proximity.grace or 5

    for robberCid, e in pairs(prox[cid] or {}) do
        if (now - e.last) <= grace then
            witnesses[robberCid] = e.last - e.since
        end
    end

    deathCounter[cid] = (deathCounter[cid] or 0) + 1
    deaths[cid] = {
        id          = deathCounter[cid],
        time        = now,
        vehicleKill = byVehicle and true or false,
        cause       = causeHash,
        witnesses   = witnesses,
        looted      = false,
    }
end)

-- ============================================================
--  RULE ENGINE
--  Single source of truth. Called by the pre-flight callback AND again on the
--  real rob event — the callback result is never trusted on its own, because a
--  modded client can just skip straight to the rob event.
--  returns ok:boolean, reason:string, state:'dead'|'handsup'
-- ============================================================
local function checkRules(src, targetId)
    if not targetId or src == targetId then return false, 'Invalid target' end

    local Robber = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Robber or not Target then return false, 'Player not found' end

    -- robber must be alive
    local rmd = Robber.PlayerData.metadata or {}
    if rmd.isdead or rmd.inlaststand then return false, 'You are not in a state to rob' end

    local robberPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if robberPed == 0 or targetPed == 0 then return false, 'Player not found' end

    -- server-side distance (blocks remote / teleport robbing)
    local dist = #(GetEntityCoords(robberPed) - GetEntityCoords(targetPed))
    if dist > Config.ServerMaxDistance then return false, 'Too far away' end

    -- confirm the victim is actually robbable
    local robbable
    if Config.UseRobbableState then
        robbable = Player(targetId).state.robbable
        if not robbable then return false, 'This player is not robbable right now' end
    else
        robbable = (GetEntityHealth(targetPed) <= Config.DeadHealth) and 'dead' or 'handsup'
    end

    local cid       = Target.PlayerData.citizenid
    local robberCid = Robber.PlayerData.citizenid
    local now       = os.time()

    -- ===== SCENE LIMIT — locked out entirely? =====
    if Config.SceneLimit and Config.SceneLimit.count > 0 then
        local s = scene[robberCid]
        if s and s.blockedUntil and now < s.blockedUntil then
            return false, ('You need to lay low — %s left'):format(fmtTime(s.blockedUntil - now))
        end
    end

    -- ===== PAIR COOLDOWN — same robber, same victim =====
    if Config.PairCooldown and Config.PairCooldown > 0 then
        local last = pairCd[robberCid] and pairCd[robberCid][cid]
        if last and (now - last) < Config.PairCooldown then
            return false, ('You already robbed this person — %s left'):format(fmtTime(Config.PairCooldown - (now - last)))
        end
    end

    -- ===== VICTIM TOTAL ROB CAP =====
    if Config.MaxRobsPerVictim and Config.MaxRobsPerVictim > 0 then
        local rc = robCounts[cid]
        if rc and Config.MaxRobsResetTime > 0 and (now - rc.first) >= Config.MaxRobsResetTime then
            robCounts[cid] = nil
            rc = nil
        end
        if rc and rc.count >= Config.MaxRobsPerVictim then
            return false, 'This player has already been cleaned out'
        end
    end

    -- ============================================================
    --  BODY LOOT RULES
    -- ============================================================
    if robbable == 'dead' then
        local d = deaths[cid]

        if not d then
            -- no snapshot: they died before the script started, or their client
            -- never reported. Fail closed — no snapshot, no loot.
            return false, 'You did not see this person go down'
        end

        -- 6. vehicle kills are not robbable
        if Config.BlockVehicleKills and d.vehicleKill then
            return false, 'This person was killed by a vehicle — nothing to take'
        end

        -- 2. one loot per death
        if Config.RobOncePerDeath and d.looted then
            return false, 'This body has already been looted'
        end

        -- 5. witness at death + proximity earned BEFORE they died
        if Config.RequireWitnessAtDeath then
            local w = d.witnesses[robberCid]
            if not w then
                return false, 'You were not there when this person went down'
            end
            if Config.Proximity.enabled and w < Config.Proximity.required then
                return false, ('You were only around them %s of the required %s'):format(
                    fmtTime(w), fmtTime(Config.Proximity.required))
            end
        end

        return true, nil, robbable
    end

    -- ============================================================
    --  HANDS-UP RULES (victim alive)
    -- ============================================================
    if Config.Proximity and Config.Proximity.enabled then
        local e = earned(cid, robberCid, now)
        if e < Config.Proximity.required then
            return false, ('You have not been around this person long enough — %s / %s'):format(
                fmtTime(e), fmtTime(Config.Proximity.required))
        end
    end

    return true, nil, robbable
end

-- Pre-flight: lets the client explain WHY before wasting the player's time on
-- a minigame. Advisory only — the real gate is inside robPlayer.
lib.callback.register('playerrob:canRob', function(src, targetId)
    local ok, reason = checkRules(src, tonumber(targetId))
    return ok, reason
end)

-- ============================================================
--  DISPATCH
--  Fires on the raw click. Deliberately runs BEFORE checkRules — an attempted
--  robbery is still a crime scene, and cops shouldn't only hear about the ones
--  that succeed.
--
--  What it does NOT skip: rate limiting. Because this fires on the click, the
--  eye can be spam-clicked. The cooldown is per robber and enforced here, on
--  the server, where a modded client can't touch it.
-- ============================================================
local dispatchCd = {}   -- robberCid -> unix of last alert

RegisterNetEvent('playerrob:server:dispatchNow', function(targetId, dead)
    local src = source
    targetId = tonumber(targetId)

    if not (Config.Dispatch and Config.Dispatch.enabled) then return end
    if not targetId or targetId == src then return end

    if dead and not Config.Dispatch.onDead then return end
    if not dead and not Config.Dispatch.onAlive then return end

    local Robber = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Robber or not Target then return end

    -- robber must actually be next to the victim: stops someone triggering
    -- alerts across the map by firing this event directly
    local robberPed, targetPed = GetPlayerPed(src), GetPlayerPed(targetId)
    if robberPed == 0 or targetPed == 0 then return end

    local targetCoords = GetEntityCoords(targetPed)
    if #(GetEntityCoords(robberPed) - targetCoords) > Config.ServerMaxDistance then return end

    -- rate limit
    local robberCid = Robber.PlayerData.citizenid
    local now = os.time()
    local cd = Config.Dispatch.cooldown or 30
    if cd > 0 and dispatchCd[robberCid] and (now - dispatchCd[robberCid]) < cd then return end
    dispatchCd[robberCid] = now

    -- exact location = the VICTIM's real position, read server-side
    TriggerClientEvent('playerrob:client:sendDispatch', src, {
        x = targetCoords.x, y = targetCoords.y, z = targetCoords.z
    }, dead)
end)

-- ============================================================
--  Discord logging
-- ============================================================
local function getIdentifiers(src)
    local out = { license = nil, discord = nil, steam = nil, fivem = nil }
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        local head8 = id:sub(1, 8)
        if head8 == 'license:' then
            out.license = id:sub(9)
        elseif head8 == 'discord:' then
            out.discord = id:sub(9)
        elseif id:sub(1, 6) == 'steam:' then
            out.steam = id:sub(7)
        elseif id:sub(1, 6) == 'fivem:' then
            out.fivem = id:sub(7)
        end
    end
    return out
end

local function itemLabel(name)
    local ok, data = pcall(function() return exports.ox_inventory:Items(name) end)
    if ok and type(data) == 'table' and data.label then return data.label end
    return name
end

local function fmtPlayerBlock(p)
    local cfg = ConfigServer.Discord
    local lines = {}

    lines[#lines + 1] = ('**%s**  ·  server id `%d`'):format(p.name, p.src)
    lines[#lines + 1] = ('**CitizenID:** `%s`'):format(p.cid or 'unknown')
    lines[#lines + 1] = ('**License:** `%s`'):format(p.ids.license or 'unknown')

    if p.ids.discord then
        if cfg.MentionDiscordIds then
            lines[#lines + 1] = ('**Discord:** <@%s>  `%s`'):format(p.ids.discord, p.ids.discord)
        else
            lines[#lines + 1] = ('**Discord:** `%s`'):format(p.ids.discord)
        end
    else
        lines[#lines + 1] = '**Discord:** `not linked`'
    end

    return table.concat(lines, '\n')
end

-- Discord caps an embed field value at 1024 chars. Trim rather than get a 400.
local function clamp(str, max)
    max = max or 1024
    if #str <= max then return str end
    return str:sub(1, max - 4) .. ' ...'
end

local function postLog(payload, imageUrl)
    local cfg = ConfigServer.Discord
    if not cfg.Enabled or not cfg.Webhook or cfg.Webhook == '' then return end

    local itemLines = {}
    for i = 1, #payload.items do
        local it = payload.items[i]
        itemLines[#itemLines + 1] = ('`%dx` **%s**  `%s`'):format(it.count, it.label, it.name)
    end
    local itemText = #itemLines > 0 and table.concat(itemLines, '\n') or '*nothing*'

    local embed = {
        title = payload.dead and 'Body Looted' or 'Player Robbed',
        color = payload.dead and cfg.ColorLooted or cfg.ColorRobbed,
        fields = {
            {
                -- <t:unix:F> renders in each viewer's OWN timezone.
                name = 'Time',
                value = ('<t:%d:F>\n<t:%d:R>'):format(payload.time, payload.time),
                inline = true
            },
            {
                name = 'Location',
                value = ('```%.1f, %.1f, %.1f```'):format(payload.coords.x, payload.coords.y, payload.coords.z),
                inline = true
            },
            {
                name = 'Type',
                value = payload.dead and '`Body loot (dead)`' or '`Hands up (alive)`',
                inline = true
            },
            {
                -- proof the rules were met, so staff reviewing a report can see
                -- at a glance this wasn't a drive-by loot
                name = 'Proximity',
                value = ('`%s together`  ·  scene rob `%d/%d`'):format(
                    fmtTime(payload.proximity or 0),
                    payload.sceneCount or 0,
                    (Config.SceneLimit and Config.SceneLimit.count) or 0),
                inline = false
            },
            {
                name = 'ROBBER',
                value = clamp(fmtPlayerBlock(payload.robber)),
                inline = false
            },
            {
                name = 'VICTIM',
                value = clamp(fmtPlayerBlock(payload.victim)),
                inline = false
            },
            {
                name = ('Items Taken (%d)'):format(#payload.items),
                value = clamp(itemText),
                inline = false
            },
        },
        footer = { text = cfg.Footer or 'player_rob' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', payload.time),
    }

    if imageUrl then
        embed.image = { url = imageUrl }
    end

    local body = {
        username = cfg.BotName,
        embeds = { embed }
    }
    if cfg.Avatar and cfg.Avatar ~= '' then body.avatar_url = cfg.Avatar end

    PerformHttpRequest(cfg.Webhook, function(code, _, _, err)
        if code ~= 200 and code ~= 204 then
            print(('^1[player_rob]^7 Discord webhook failed (HTTP %s) %s'):format(tostring(code), tostring(err)))
        end
    end, 'POST', json.encode(body), { ['Content-Type'] = 'application/json' })

    if cfg.ConsoleLog then
        local names = {}
        for i = 1, #payload.items do
            names[#names + 1] = ('%dx %s'):format(payload.items[i].count, payload.items[i].name)
        end
        print(('^3[player_rob]^7 %s (%s) robbed %s (%s) — %s [%s]'):format(
            payload.robber.name, payload.robber.cid,
            payload.victim.name, payload.victim.cid,
            #names > 0 and table.concat(names, ', ') or 'nothing',
            payload.dead and 'body' or 'handsup'
        ))
    end
end

-- Fire the screenshot request, then log. If the shot never comes back we still
-- log after Timeout ms — just without an image. The log always lands.
local function logRobbery(payload)
    local cfg = ConfigServer.Discord
    if not cfg.Enabled then return end

    local shotHook = cfg.ScreenshotWebhook
    local wantShot = Config.Screenshot and Config.Screenshot.Enabled
        and type(shotHook) == 'string' and shotHook ~= ''

    if not wantShot then
        return postLog(payload, nil)
    end

    local token = ('%d:%d:%d'):format(payload.robber.src, os.time(), math.random(100000, 999999))
    pendingShots[token] = { payload = payload, src = payload.robber.src, done = false }

    TriggerClientEvent('playerrob:client:takeShot', payload.robber.src, token, shotHook)

    SetTimeout(Config.Screenshot.Timeout or 10000, function()
        local p = pendingShots[token]
        if p and not p.done then
            pendingShots[token] = nil
            postLog(p.payload, nil)
        end
    end)
end

RegisterNetEvent('playerrob:server:shotDone', function(token, url)
    local src = source
    local p = pendingShots[token]

    if not p or p.done then return end
    if p.src ~= src then return end

    p.done = true
    pendingShots[token] = nil

    -- Only trust real Discord CDN links. Stops a modded client handing us an
    -- arbitrary url to embed in the staff channel.
    if type(url) ~= 'string'
        or not (url:find('^https://cdn%.discordapp%.com/')
             or url:find('^https://media%.discordapp%.net/')) then
        url = nil
    end

    postLog(p.payload, url)
end)

-- ============================================================
--  Loot ordering
-- ============================================================
local function buildLootOrder(validItems)
    local priority, normal = {}, {}

    for i = 1, #validItems do
        local it = validItems[i]
        local weight = Config.PriorityItems[it.name]
        if weight then
            priority[#priority + 1] = { item = it, weight = weight }
        else
            normal[#normal + 1] = it
        end
    end

    table.sort(priority, function(a, b) return a.weight > b.weight end)

    for i = #normal, 2, -1 do
        local j = math.random(i)
        normal[i], normal[j] = normal[j], normal[i]
    end

    local ordered = {}
    for i = 1, #priority do ordered[#ordered + 1] = priority[i].item end
    for i = 1, #normal   do ordered[#ordered + 1] = normal[i]        end
    return ordered
end

-- ============================================================
--  Robbery
-- ============================================================
RegisterNetEvent('playerrob:server:robPlayer', function(targetId)
    local src = source
    targetId = tonumber(targetId)

    -- Full re-check. The pre-flight callback proves nothing — this event is
    -- what a cheat would call directly.
    local ok, reason, robbable = checkRules(src, targetId)
    if not ok then
        return notify(src, reason or 'You cannot rob this player', 'error')
    end

    local Robber = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Robber or not Target then return end

    local cid         = Target.PlayerData.citizenid
    local robberCid   = Robber.PlayerData.citizenid
    local now         = os.time()
    local robberCoords = GetEntityCoords(GetPlayerPed(src))

    -- how long they were together (for the log)
    local together
    if robbable == 'dead' then
        together = (deaths[cid] and deaths[cid].witnesses[robberCid]) or 0
    else
        together = earned(cid, robberCid, now)
    end

    -- gather robbable items (skip blacklist + empty)
    local inventory = exports.ox_inventory:GetInventoryItems(targetId)
    local validItems = {}

    if inventory then
        for _, item in pairs(inventory) do
            if item and item.name and item.count and item.count > 0 and not Config.Blacklist[item.name] then
                validItems[#validItems + 1] = item
            end
        end
    end

    if #validItems == 0 then
        return notify(src, 'Player has nothing worth robbing', 'error')
    end

    local ordered = buildLootOrder(validItems)
    local itemsToTake = (robbable == 'dead') and Config.ItemsDead or Config.ItemsAlive
    local robbedCount = 0
    local takenItems = {}

    for i = 1, itemsToTake do
        local item = ordered[i]
        if not item then break end

        local removed = exports.ox_inventory:RemoveItem(targetId, item.name, item.count, item.metadata, item.slot)
        if removed then
            exports.ox_inventory:AddItem(src, item.name, item.count, item.metadata)
            robbedCount += 1
            takenItems[#takenItems + 1] = {
                name  = item.name,
                count = item.count,
                label = itemLabel(item.name)
            }
        end
    end

    if robbedCount == 0 then
        return notify(src, 'Failed to rob player', 'error')
    end

    -- ===== BURN THE RIGHTS =====
    -- Everything below only runs on a rob that actually moved items.

    -- one loot per death
    if robbable == 'dead' and deaths[cid] then
        deaths[cid].looted = true
    end

    -- pair cooldown
    pairCd[robberCid] = pairCd[robberCid] or {}
    pairCd[robberCid][cid] = now

    -- scene limit: hit the cap -> locked out of robbing ANYONE for the window
    local sceneCount = 0
    if Config.SceneLimit and Config.SceneLimit.count > 0 then
        local s = scene[robberCid]
        if not s then s = { count = 0 }; scene[robberCid] = s end
        s.count = s.count + 1
        sceneCount = s.count

        if s.count >= Config.SceneLimit.count then
            s.blockedUntil = now + Config.SceneLimit.window
            s.count = 0
            notify(src, ('That is %d. You cannot rob anyone for %s'):format(
                Config.SceneLimit.count, fmtTime(Config.SceneLimit.window)), 'inform')
        end
    end

    -- victim rob counter
    if Config.MaxRobsPerVictim and Config.MaxRobsPerVictim > 0 then
        local rc = robCounts[cid]
        if not rc then rc = { count = 0, first = now }; robCounts[cid] = rc end
        rc.count += 1
    end

    notify(src, ('You stole %s item(s)'):format(robbedCount), 'success')
    notify(targetId, 'You were robbed', 'error')

    logRobbery({
        time       = now,
        dead       = robbable == 'dead',
        coords     = robberCoords,
        items      = takenItems,
        proximity  = together,
        sceneCount = sceneCount,
        robber = {
            src  = src,
            name = ('%s %s'):format(Robber.PlayerData.charinfo.firstname, Robber.PlayerData.charinfo.lastname),
            cid  = robberCid,
            ids  = getIdentifiers(src),
        },
        victim = {
            src  = targetId,
            name = ('%s %s'):format(Target.PlayerData.charinfo.firstname, Target.PlayerData.charinfo.lastname),
            cid  = cid,
            ids  = getIdentifiers(targetId),
        },
    })
end)

-- ============================================================
--  CLEANUP
-- ============================================================
AddEventHandler('playerDropped', function()
    local src = source
    local ply = QBCore.Functions.GetPlayer(src)

    if ply then
        local pcid = ply.PlayerData.citizenid

        -- Wipe proximity BOTH ways: their row, and their entry in everyone
        -- else's row. Miss the second and a disconnect leaves stale time that
        -- someone could cash in on later.
        prox[pcid] = nil
        for _, row in pairs(prox) do
            row[pcid] = nil
        end

        deaths[pcid]       = nil
        deathCounter[pcid] = nil
        robCounts[pcid]    = nil
        scene[pcid]        = nil
        dispatchCd[pcid]   = nil
        pairCd[pcid]       = nil
        for _, row in pairs(pairCd) do
            row[pcid] = nil
        end
    end

    -- drop any screenshot we're still waiting on from this player
    for token, p in pairs(pendingShots) do
        if p.src == src and not p.done then
            p.done = true
            pendingShots[token] = nil
            postLog(p.payload, nil)
        end
    end
end)
