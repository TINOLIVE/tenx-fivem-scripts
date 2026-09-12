--[[
    tenx-zones :: server (v2)

    The server owns the truth. It holds every zone, decides who a zone
    applies to, and runs a slow backstop sweep.

    It is authoritative on MEMBERSHIP -- who counts as inside for
    scoring and binding -- and it is a slack safety net for someone who
    has ended up well outside. It does NOT reposition anyone at frame
    rate and it never competes with the client clamp. An earlier draft
    called this "server-authoritative in/out", which was the wrong
    phrase: two clamps at different latencies is the jitter this whole
    split exists to remove.

    Nothing here trusts a client. Every write re-checks the ACE
    permission on arrival, is rate limited, and is validated field by
    field before it goes near the database.
]]

local Zones          = {}   -- [id] = zone
local ZoneCount      = 0
local ByImportKey    = {}   -- [importKey] = id
local ByTag          = {}   -- [tag] = { [zoneId] = true }

local BucketBinds    = {}   -- [bucket] = { [zoneId] = { armOnEntry = bool } }
local PlayerBinds    = {}   -- [src]    = { [zoneId] = { armOnEntry = bool } }
local ActiveZones    = {}   -- [src]    = { zoneId, ... }  resolved
local LastBucket     = {}   -- [src]    = bucket
local Watched        = {}   -- [src]    = true, has >=1 zone that blocks them
local Inside         = {}   -- [src]    = { [zoneId] = true }
local Armed          = {}   -- [src]    = { [zoneId] = true }
local Suspends       = {}   -- [src]    = { [reason] = expiresAt | false }
local LastLocalClaim = {}   -- [src]    = ms
local Violations     = {}   -- [src]    = count
local LastWrite      = {}   -- [src]    = ms
local Ready          = {}   -- [src]    = true, client has handshaked

local json_encode, json_decode = json.encode, json.decode

local updateZone            -- forward declared, createZone calls it


-- ============================================================
--  HELPERS
-- ============================================================

-- Built once at start. A linear walk of the config list on every
-- write would be fine at this size, but a set lookup is free and
-- this is on the path of every create, edit and delete.
local AdminSet = {}
CreateThread(function()
    for i = 1, #(Config.Admins or {}) do
        local id = Config.Admins[i]
        if type(id) == 'string' and id ~= '' then
            AdminSet[id:lower()] = true
        end
    end
end)

local function isAdmin(src)
    if src == 0 then return true end          -- console

    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        -- ip: is not an identity, it is a network address. It moves,
        -- it is shared behind NAT, and it is trivially changed, so
        -- it is never accepted here even if someone pastes one in.
        if not id:match('^ip:') and AdminSet[id:lower()] then
            return true
        end
    end

    if Config.UseAce and IsPlayerAceAllowed(src, Config.AdminAce) then
        return true
    end

    return false
end

--- Prints a player their own identifiers so they can paste one into
--- Config.Admins. Deliberately shows only your own, never anyone
--- else's, and is not gated -- knowing your own identifier grants
--- nothing on its own.
RegisterCommand('zonesid', function(src)
    if src == 0 then return end

    local lines = { '[tenx-zones] your identifiers:' }
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if not id:match('^ip:') then
            lines[#lines + 1] = '  ' .. id
        end
    end
    lines[#lines + 1] = "paste one into Config.Admins (license: is the stable one)"

    TriggerClientEvent('chat:addMessage', src, {
        color = { 120, 200, 255 },
        multiline = true,
        args = { 'tenx-zones', table.concat(lines, '\n') },
    })
    print(table.concat(lines, '\n'))
end, false)

local function rateLimited(src)
    local now  = GetGameTimer()
    local last = LastWrite[src] or 0
    if now - last < Config.Security.writeCooldown then return true end
    LastWrite[src] = now
    return false
end

local function optsFor(src, zoneId)
    local explicit = PlayerBinds[src]
    if explicit and explicit[zoneId] then return explicit[zoneId] end

    local byBucket = BucketBinds[LastBucket[src] or 0]
    if byBucket and byBucket[zoneId] then return byBucket[zoneId] end

    return nil
end

--- A zone blocks a player when it is solid AND, if it was bound with
--- armOnEntry, that player has walked in at least once. Until then it
--- is passable for them -- which is what lets a Red Zone player spawn
--- outside the wall and walk in under their own power.
local function blocksPlayer(src, zone, opts)
    if not zone.solid then return false end
    if opts and opts.armOnEntry then
        local a = Armed[src]
        return a ~= nil and a[zone.id] == true
    end
    return true
end

local function isSuspended(src)
    local s = Suspends[src]
    if not s then return false end

    local now = GetGameTimer()
    local any = false

    for reason, expires in pairs(s) do
        if expires and now > expires then
            -- A client raised claim that outlived its bound. Enforcement
            -- comes back whether or not anyone released it.
            s[reason] = nil
            if Config.Security.onViolation then
                Config.Security.onViolation(src, nil, 0, reason, os.time())
            end
        else
            any = true
        end
    end

    if not any then Suspends[src] = nil end
    return any
end


-- ============================================================
--  RESOLUTION
--  Rebuilds "what applies to this player". Runs on binding changes
--  and bucket moves -- never per frame, never per tick.
-- ============================================================

local function payloadFor(src, list)
    local out = {}
    for i = 1, #list do
        local id   = list[i]
        local zone = Zones[id]
        local opts = optsFor(src, id)

        -- The client gets a flat solid flag it can act on directly, so
        -- the clamp never has to reason about arming.
        local copy = {}
        for k, v in pairs(zone) do copy[k] = v end
        copy.solid      = blocksPlayer(src, zone, opts)
        copy.armOnEntry = (opts and opts.armOnEntry) or false

        out[i] = copy
    end
    return out
end

local function resolvePlayer(src)
    if not GetPlayerName(src) then return end

    local bucket = GetPlayerRoutingBucket(src)
    LastBucket[src] = bucket

    local list, seen, hasSolid = {}, {}, false

    local byBucket = BucketBinds[bucket]
    if byBucket then
        for id, opts in pairs(byBucket) do
            local z = Zones[id]
            if z and not seen[id] then
                seen[id] = true
                list[#list + 1] = id
                if blocksPlayer(src, z, opts) then hasSolid = true end
            end
        end
    end

    local explicit = PlayerBinds[src]
    if explicit then
        for id, opts in pairs(explicit) do
            local z = Zones[id]
            if z and not seen[id] then
                seen[id] = true
                list[#list + 1] = id
                if blocksPlayer(src, z, opts) then hasSolid = true end
            end
        end
    end

    ActiveZones[src] = list
    Watched[src]     = hasSolid or nil

    if Ready[src] then
        TriggerClientEvent('tenx-zones:sync', src, payloadFor(src, list))
    end
end

local function resolveZoneAudience(zoneId)
    for _, s in ipairs(GetPlayers()) do
        local src  = tonumber(s)
        local list = ActiveZones[src]
        if list then
            for i = 1, #list do
                if list[i] == zoneId then resolvePlayer(src) break end
            end
        end
    end
end

local function resolveAll()
    for _, s in ipairs(GetPlayers()) do resolvePlayer(tonumber(s)) end
end

--- Fires once when a player stops being in a zone, whatever the cause.
local function fireLeft(src, zoneId, reason, claim)
    local set = Inside[src]
    if not set or not set[zoneId] then return end
    set[zoneId] = nil
    TriggerEvent('tenx-zones:server:left', src, zoneId, reason, claim)
end


-- ============================================================
--  PERSISTENCE
-- ============================================================

local function splitTags(s)
    local out = {}
    for t in tostring(s or ''):gmatch('[^,]+') do
        t = t:match('^%s*(.-)%s*$'):lower()
        if t ~= '' then out[#out + 1] = t end
    end
    return out
end

--- oxmysql returns TINYINT(1) as a BOOLEAN, not a number. The old code
--- did `row.solid == 1`, and in Lua `true == 1` is false -- so every
--- zone loaded as passable and hidden no matter what was stored.
--- Writes were fine, which is why toggling worked until a restart.
---
--- Accept every shape a driver might hand back rather than betting on
--- one: boolean, number, or string.
local function truthy(v)
    return v == true or v == 1 or v == '1'
end

local function rowToZone(row)
    local data = json_decode(row.data) or {}

    local zone = {
        id        = row.id,
        name      = row.name,
        kind      = row.kind,
        solid     = truthy(row.solid),
        visible   = truthy(row.visible),
        importKey = row.import_key,
        tags      = splitTags(row.tags),
        color     = data.color or Config.Defaults.solidColor,
    }

    if row.kind == 'sphere' then
        zone.center = data.center
        zone.radius = data.radius + 0.0
    else
        zone.points = data.points
        zone.minZ   = data.minZ + 0.0
        zone.maxZ   = data.maxZ + 0.0
    end

    return TenxShapes.computeBounds(zone)
end

local function zoneToData(zone)
    if zone.kind == 'sphere' then
        return json_encode({ center = zone.center, radius = zone.radius, color = zone.color })
    end
    return json_encode({ points = zone.points, minZ = zone.minZ,
                         maxZ = zone.maxZ, color = zone.color })
end

local function loadZones()
    -- `deleted = 0` only. Deleted rows STAY in the table on purpose --
    -- see deleteZone for why the id must never be freed.
    local rows = MySQL.query.await('SELECT * FROM tenx_zones WHERE deleted = 0') or {}

    Zones, ZoneCount, ByImportKey, ByTag = {}, 0, {}, {}
    for i = 1, #rows do
        local ok, zone = pcall(rowToZone, rows[i])
        if ok and zone then
            Zones[zone.id] = zone
            ZoneCount = ZoneCount + 1
            if zone.importKey then ByImportKey[zone.importKey] = zone.id end
            for _, t in ipairs(zone.tags) do
                ByTag[t] = ByTag[t] or {}
                ByTag[t][zone.id] = true
            end
        else
            print(('[tenx-zones] skipped malformed row id=%s'):format(rows[i].id))
        end
    end

    print(('[tenx-zones] loaded %d zone(s)'):format(ZoneCount))
end

CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `tenx_zones` (
            `id`         INT AUTO_INCREMENT PRIMARY KEY,
            `name`       VARCHAR(48) NOT NULL,
            `kind`       VARCHAR(8)  NOT NULL,
            `data`       LONGTEXT    NOT NULL,
            `solid`      TINYINT(1)  NOT NULL DEFAULT 1,
            `visible`    TINYINT(1)  NOT NULL DEFAULT 1,
            `import_key` VARCHAR(64) NULL UNIQUE,
            `tags`       VARCHAR(255) NOT NULL DEFAULT '',
            `deleted`    TINYINT(1)  NOT NULL DEFAULT 0,
            `created_by` VARCHAR(64) DEFAULT NULL,
            `created_at` TIMESTAMP   DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Additive columns for older installs, so upgrading is a restart.
    local function ensureColumn(name, ddl)
        local col = MySQL.query.await([[
            SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_NAME = 'tenx_zones' AND COLUMN_NAME = ?
              AND TABLE_SCHEMA = DATABASE()
        ]], { name })
        if not col or #col == 0 then
            MySQL.query.await(('ALTER TABLE tenx_zones ADD COLUMN %s'):format(ddl))
            print(('[tenx-zones] added %s column'):format(name))
        end
    end

    ensureColumn('import_key', '`import_key` VARCHAR(64) NULL UNIQUE')
    ensureColumn('tags',       "`tags` VARCHAR(255) NOT NULL DEFAULT ''")
    ensureColumn('deleted',    '`deleted` TINYINT(1) NOT NULL DEFAULT 0')

    loadZones()
    resolveAll()

    -- Anyone already running re-binds from this. On a COLD boot it
    -- fires before arena and redzone exist and nobody hears it, which
    -- is harmless -- a cold boot has no live matches. It is NOT a
    -- general "state is available now" signal, so consumers should
    -- also reconcile via GetBindings() on their own start.
    local ids = {}
    for id in pairs(Zones) do ids[#ids + 1] = id end
    TriggerEvent('tenx-zones:server:ready', TenxContract.version, ids)
    print(('[tenx-zones] v%s ready'):format(TenxContract.version))
end)


-- ============================================================
--  WRITES
-- ============================================================

local function createZone(zone, byName)
    -- Idempotent on importKey. Re-running a half failed migration
    -- converges instead of duplicating, and the id an arena points at
    -- never moves. Deliberately NOT keyed on name: two zones should be
    -- free to share a display name, and a rename must never silently
    -- merge one shape into another.
    if zone.importKey then
        local existing = ByImportKey[zone.importKey]
        if existing then
            local ok, err = updateZone(existing, zone)
            if not ok then return nil, err end
            return existing
        end
    end

    if ZoneCount >= Config.Security.maxZones then
        return nil, ('zone limit reached (%d)'):format(Config.Security.maxZones)
    end

    local ok, err = TenxShapes.validate(zone, Config.Build)
    if not ok then return nil, err end

    zone.tags = zone.tags or {}
    local tagStr = table.concat(zone.tags, ',')
    if #tagStr > 255 then return nil, 'too many tags' end

    local id = MySQL.insert.await(
        'INSERT INTO tenx_zones (name, kind, data, solid, visible, import_key, tags, created_by) '
        .. 'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { zone.name, zone.kind, zoneToData(zone), zone.solid and 1 or 0,
          zone.visible and 1 or 0, zone.importKey, tagStr, byName }
    )
    if not id then return nil, 'database refused the insert' end

    zone.id   = id
    Zones[id] = TenxShapes.computeBounds(zone)
    ZoneCount = ZoneCount + 1
    if zone.importKey then ByImportKey[zone.importKey] = id end
    for _, t in ipairs(zone.tags) do
        ByTag[t] = ByTag[t] or {}
        ByTag[t][id] = true
    end

    return id
end

updateZone = function(id, patch)
    local zone = Zones[id]
    if not zone then return false, 'no such zone' end

    local merged = {
        id        = id,
        name      = patch.name   or zone.name,
        kind      = patch.kind   or zone.kind,
        solid     = zone.solid,
        visible   = zone.visible,
        importKey = zone.importKey,
        tags      = patch.tags   or zone.tags or {},
        color     = patch.color  or zone.color,
        center    = patch.center or zone.center,
        radius    = patch.radius or zone.radius,
        points    = patch.points or zone.points,
        minZ      = patch.minZ   or zone.minZ,
        maxZ      = patch.maxZ   or zone.maxZ,
    }

    -- `x ~= nil and x or y` silently drops a literal false, so the two
    -- booleans are written out longhand on purpose.
    if patch.solid   ~= nil then merged.solid   = patch.solid   and true or false end
    if patch.visible ~= nil then merged.visible = patch.visible and true or false end

    local ok, err = TenxShapes.validate(merged, Config.Build)
    if not ok then return false, err end

    local tagStr = table.concat(merged.tags, ',')
    if #tagStr > 255 then return false, 'too many tags' end

    MySQL.update.await(
        'UPDATE tenx_zones SET name = ?, kind = ?, data = ?, solid = ?, visible = ?, tags = ? WHERE id = ?',
        { merged.name, merged.kind, zoneToData(merged),
          merged.solid and 1 or 0, merged.visible and 1 or 0, tagStr, id }
    )

    -- Drop this zone out of every tag bucket, then re-add. Cheaper and
    -- less error prone than diffing old tags against new.
    for _, set in pairs(ByTag) do set[id] = nil end
    for _, t in ipairs(merged.tags) do
        ByTag[t] = ByTag[t] or {}
        ByTag[t][id] = true
    end

    Zones[id] = TenxShapes.computeBounds(merged)
    resolveZoneAudience(id)

    return true
end

local function zoneIsBound(id)
    for bucket, set in pairs(BucketBinds) do
        if set[id] then return true, ('bound to bucket %s'):format(bucket) end
    end
    for src, set in pairs(PlayerBinds) do
        if set[id] then return true, ('bound to player %s'):format(src) end
    end
    return false
end

local function deleteZone(id, force)
    local zone = Zones[id]
    if not zone then return false, 'no such zone' end

    -- Deleting a bound zone silently makes an arena unmatchable, so it
    -- is refused unless forced. Either way an event fires so a panel
    -- can react rather than quietly dropping the arena from a list.
    local bound, why = zoneIsBound(id)
    if bound and not force then
        return false, ('zone is %s -- pass force to delete anyway'):format(why)
    end

    -- SOFT delete. The row stays and the id is never freed.
    --
    -- This is not tidiness, it is correctness. `id` is AUTO_INCREMENT,
    -- and AUTO_INCREMENT is NOT stable across a restart on MariaDB --
    -- which is what most FiveM servers run. The counter is recomputed
    -- as MAX(id)+1 at startup, so deleting the highest numbered zone
    -- and restarting hands that id straight back to the next zone
    -- created.
    --
    -- Anything keyed on a zone id off in another resource -- Red Zone
    -- spawn points, an arena's zoneId column -- would then silently
    -- re-point at a completely different shape somewhere else on the
    -- map, with nothing saying why. Keeping the row makes MAX(id)
    -- monotonic and the reuse impossible.
    -- import_key is UNIQUE, so a retired row holding one would block
    -- ever re-importing that key. The key is released; the id is not.
    MySQL.update.await(
        'UPDATE tenx_zones SET deleted = 1, import_key = NULL WHERE id = ?', { id })

    if zone.importKey then ByImportKey[zone.importKey] = nil end
    for _, t in ipairs(zone.tags or {}) do
        if ByTag[t] then ByTag[t][id] = nil end
    end
    Zones[id] = nil
    ZoneCount = ZoneCount - 1

    for _, set in pairs(BucketBinds) do set[id] = nil end
    for _, set in pairs(PlayerBinds) do set[id] = nil end

    for _, s in ipairs(GetPlayers()) do fireLeft(tonumber(s), id, 'deleted') end

    TriggerEvent('tenx-zones:server:zoneDeleted', id)
    TriggerEvent('tenx-zones:server:zoneUnavailable', id, 'deleted')

    resolveAll()
    return true
end


-- ============================================================
--  CLIENT EVENTS
-- ============================================================

RegisterNetEvent('tenx-zones:ready', function()
    local src = source
    Ready[src] = true
    resolvePlayer(src)
end)

RegisterNetEvent('tenx-zones:open', function()
    local src = source
    if not isAdmin(src) then return end

    local all = {}
    for _, z in pairs(Zones) do all[#all + 1] = z end
    TriggerClientEvent('tenx-zones:openBuilder', src, all)
end)

--- Tags now come from the panel, so they are user input and get
--- cleaned before they go anywhere near the database: lowercased,
--- trimmed, no commas (the storage separator), length capped,
--- deduplicated, and a hard limit on how many.
local function cleanTags(raw)
    if type(raw) ~= 'table' then return {} end

    local out, seen = {}, {}
    for i = 1, #raw do
        if #out >= 8 then break end
        local t = tostring(raw[i] or ''):match('^%s*(.-)%s*$'):lower()
        t = t:gsub('[^%w%-_]', '')
        if t ~= '' and #t <= 24 and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    return out
end

RegisterNetEvent('tenx-zones:create', function(zone)
    local src = source
    if not isAdmin(src) or rateLimited(src) then return end
    if type(zone) ~= 'table' then return end

    zone.importKey = nil   -- panel created zones never carry one
    zone.tags      = cleanTags(zone.tags)

    local id, err = createZone(zone, GetPlayerName(src))
    if not id then
        TriggerClientEvent('tenx-zones:result', src, false, err)
        return
    end

    TriggerClientEvent('tenx-zones:result', src, true, 'Zone saved', Zones[id])
    resolveAll()
end)

RegisterNetEvent('tenx-zones:update', function(id, patch)
    local src = source
    if not isAdmin(src) or rateLimited(src) then return end
    if type(id) ~= 'number' or type(patch) ~= 'table' then return end

    patch.importKey = nil
    if patch.tags ~= nil then patch.tags = cleanTags(patch.tags) end

    local ok, err = updateZone(id, patch)
    TriggerClientEvent('tenx-zones:result', src, ok, ok and 'Zone updated' or err, Zones[id])
end)

RegisterNetEvent('tenx-zones:delete', function(id)
    local src = source
    if not isAdmin(src) or rateLimited(src) then return end
    if type(id) ~= 'number' then return end

    local ok, err = deleteZone(id, false)
    TriggerClientEvent('tenx-zones:result', src, ok, ok and 'Zone deleted' or err)
end)

--- The client crossed in. Arming is server state, so this is where a
--- zone becomes solid for that player.
RegisterNetEvent('tenx-zones:entered', function(id)
    local src = source
    if type(id) ~= 'number' or not Zones[id] then return end

    Inside[src] = Inside[src] or {}
    if Inside[src][id] then return end
    Inside[src][id] = true

    local opts = optsFor(src, id)
    if opts and opts.armOnEntry then
        Armed[src] = Armed[src] or {}
        if not Armed[src][id] then
            Armed[src][id] = true
            resolvePlayer(src)        -- the zone is now solid for them
        end
    end

    TriggerEvent('tenx-zones:server:entered', src, id)
end)

RegisterNetEvent('tenx-zones:left', function(id)
    local src = source
    if type(id) ~= 'number' then return end
    fireLeft(src, id, 'walked')
end)

--- Client reports it clamped someone. Informational only; the sweep is
--- what enforces. Throttled client side to once a second.
RegisterNetEvent('tenx-zones:clamped', function(id)
    local src = source
    if type(id) ~= 'number' or not Zones[id] then return end
    Violations[src] = nil
end)

--- An unexplained position jump. Policy lives here, not on the client.
RegisterNetEvent('tenx-zones:displaced', function(id, distance)
    local src = source
    if type(id) ~= 'number' or not Zones[id] then return end
    distance = tonumber(distance) or 0

    if Config.Security.trustDisplacement then
        if Armed[src] then Armed[src][id] = nil end
        fireLeft(src, id, 'displaced')
        resolvePlayer(src)
    elseif Config.Security.onViolation then
        Config.Security.onViolation(src, id, distance, nil, os.time())
    end
end)

--- Client raised suspend claim. This stops the sweep as well as the
--- clamp, which is what makes a client side teleport safe. Bounded,
--- because anyone with client code execution can raise one.
RegisterNetEvent('tenx-zones:claim', function(reason, release)
    local src = source
    if type(reason) ~= 'string' or #reason > 48 then return end

    if release then
        if Suspends[src] then
            Suspends[src][reason] = nil
            if next(Suspends[src]) == nil then Suspends[src] = nil end
        end
        return
    end

    Suspends[src] = Suspends[src] or {}

    local now = GetGameTimer()
    if Suspends[src][reason] == nil
       and now - (LastLocalClaim[src] or 0) < Config.Security.localClaimCooldown then
        return   -- claim spam
    end
    LastLocalClaim[src] = now

    Suspends[src][reason] = now + Config.Security.maxLocalClaim
end)

--- Console/admin listing. This is what you read alongside the arena's
--- migration dry run to confirm each stored zoneId is still its own
--- shape.
RegisterCommand('zoneaudit', function(src)
    if not isAdmin(src) then return end

    local ids = {}
    for id in pairs(Zones) do ids[#ids + 1] = id end
    table.sort(ids)

    local out = { ('[tenx-zones] %d live zone(s)'):format(#ids) }
    for _, id in ipairs(ids) do
        local z = Zones[id]
        out[#out + 1] = ('  %-4d %-24s %-7s %-9s %-8s key=%-28s tags=%s')
            :format(id, z.name, z.kind,
                    z.solid and 'solid' or 'passable',
                    z.visible and 'visible' or 'HIDDEN',
                    z.importKey or '(none)',
                    #(z.tags or {}) > 0 and table.concat(z.tags, ',') or '-')
    end

    local retired = MySQL.query.await(
        'SELECT id, name FROM tenx_zones WHERE deleted = 1 ORDER BY id') or {}
    if #retired > 0 then
        out[#out + 1] = ('  -- %d retired id(s), never reissued:'):format(#retired)
        for _, r in ipairs(retired) do
            out[#out + 1] = ('     %-4d %s'):format(r.id, r.name)
        end
    end

    print(table.concat(out, '\n'))
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, {
            color = { 120, 200, 255 }, multiline = true,
            args = { 'tenx-zones', 'Audit printed to server console' },
        })
    end
end, false)

--- Tagging from the console, so a zone can be marked without a config
--- edit or a restart.
RegisterCommand('zonetag', function(src, args)
    if not isAdmin(src) then return end

    local id, tag = tonumber(args[1]), args[2]
    if not id or not tag then
        print('[tenx-zones] usage: zonetag <id> <tag>   (e.g. zonetag 12 redzone)')
        return
    end

    local z = Zones[id]
    if not z then print('[tenx-zones] no zone ' .. id) return end

    tag = tag:lower()
    local tags = {}
    for _, t in ipairs(z.tags or {}) do
        if t ~= tag then tags[#tags + 1] = t end
    end
    tags[#tags + 1] = tag

    local ok, err = updateZone(id, { tags = tags })
    print(ok and ('[tenx-zones] zone %d "%s" tagged: %s')
                   :format(id, z.name, table.concat(tags, ','))
             or  ('[tenx-zones] ' .. tostring(err)))
end, false)

RegisterCommand('zoneuntag', function(src, args)
    if not isAdmin(src) then return end

    local id, tag = tonumber(args[1]), args[2]
    if not id or not tag then
        print('[tenx-zones] usage: zoneuntag <id> <tag>')
        return
    end

    local z = Zones[id]
    if not z then print('[tenx-zones] no zone ' .. id) return end

    tag = tag:lower()
    local tags = {}
    for _, t in ipairs(z.tags or {}) do
        if t ~= tag then tags[#tags + 1] = t end
    end

    local ok, err = updateZone(id, { tags = tags })
    print(ok and ('[tenx-zones] zone %d untagged %s'):format(id, tag)
             or  ('[tenx-zones] ' .. tostring(err)))
end, false)

--- Server half of /zonedebug. Prints what the server thinks applies to
--- this player, so an empty client list can be traced to either "never
--- bound" or "bound but never sent".
RegisterNetEvent('tenx-zones:debug', function()
    local src = source
    local out = {}
    local function add(s) out[#out + 1] = s end

    add(('===== tenx-zones server debug for %s (%s) ====='):format(
        GetPlayerName(src) or '?', src))
    add(('routing bucket : %s   (last seen %s)'):format(
        GetPlayerRoutingBucket(src), tostring(LastBucket[src])))
    add(('handshake done : %s   <- if no, no sync is ever sent'):format(
        Ready[src] and 'yes' or 'NO'))

    local list = ActiveZones[src] or {}
    add(('zones resolved : %d'):format(#list))
    for i = 1, #list do
        local z    = Zones[list[i]]
        local opts = optsFor(src, list[i])
        add(('   [%d] %s  solid=%s  armOnEntry=%s  blocksYou=%s'):format(
            list[i], z and z.name or '?',
            z and tostring(z.solid) or '?',
            tostring(opts and opts.armOnEntry or false),
            z and tostring(blocksPlayer(src, z, opts)) or '?'))
    end

    add('bucket bindings:')
    local anyBind = false
    for bucket, set in pairs(BucketBinds) do
        for id in pairs(set) do
            anyBind = true
            add(('   zone %d -> bucket %s%s'):format(
                id, bucket,
                bucket == GetPlayerRoutingBucket(src) and '   <- your bucket' or ''))
        end
    end
    if not anyBind then
        add('   NONE. Nothing has called BindZoneToBucket.')
        add('   That is the consuming script, not tenx-zones.')
    end

    for s, set in pairs(PlayerBinds) do
        for id in pairs(set) do
            add(('   zone %d -> player %s'):format(id, s))
        end
    end

    add(('suspend claims : %s'):format(
        Suspends[src] and 'HELD (shell hidden, clamp off)' or 'none'))
    add('==============================================')

    print(table.concat(out, '\n'))
end)

--- A zone can be visible but passable, or solid but invisible. They
--- are independent flags, and until now there was no way to set
--- visibility from in game at all -- so a zone stored with visible=0
--- was invisible with no way to fix it short of editing the database.
RegisterCommand('zoneshow', function(src, args)
    if not isAdmin(src) then return end
    local id = tonumber(args[1])
    if not id then print('[tenx-zones] usage: zoneshow <id>') return end

    local ok, err = updateZone(id, { visible = true })
    print(ok and ('[tenx-zones] zone %d is now VISIBLE'):format(id)
             or  ('[tenx-zones] ' .. tostring(err)))
end, false)

RegisterCommand('zonehide', function(src, args)
    if not isAdmin(src) then return end
    local id = tonumber(args[1])
    if not id then print('[tenx-zones] usage: zonehide <id>') return end

    local ok, err = updateZone(id, { visible = false })
    print(ok and ('[tenx-zones] zone %d is now HIDDEN'):format(id)
             or  ('[tenx-zones] ' .. tostring(err)))
end, false)

RegisterCommand(Config.Command, function(src)
    if src == 0 then return end
    if not isAdmin(src) then
        TriggerClientEvent('tenx-zones:result', src, false, 'Not allowed')
        return
    end
    TriggerClientEvent('tenx-zones:requestOpen', src)
end, false)


-- ============================================================
--  BUCKET POLL
--  RefreshPlayer being forgotten at one call site is a silent bug.
--  v1 only compared buckets for players ALREADY bound to a solid
--  zone, so a player moving INTO a zoned bucket was never checked and
--  the zone quietly did not apply. This walks everyone.
-- ============================================================

CreateThread(function()
    while true do
        Wait(Config.Tick.bucketPoll)

        for _, s in ipairs(GetPlayers()) do
            local src = tonumber(s)
            if GetPlayerRoutingBucket(src) ~= LastBucket[src] then
                for _, id in ipairs(ActiveZones[src] or {}) do
                    fireLeft(src, id, 'bucket')
                end
                Armed[src] = nil
                resolvePlayer(src)
            end
        end
    end
end)


-- ============================================================
--  BACKSTOP SWEEP
--  Slow, generous, and only walks players bound to something that
--  currently blocks them. A safety net, not a second clamp.
-- ============================================================

CreateThread(function()
    while true do
        Wait(Config.Security.sweepInterval)

        local tol = Config.Security.sweepTolerance

        for src in pairs(Watched) do
            local ped = GetPlayerPed(src)

            if ped == 0 or not GetPlayerName(src) then
                Watched[src], ActiveZones[src] = nil, nil
                PlayerBinds[src], Violations[src] = nil, nil
                Inside[src], Armed[src], Suspends[src] = nil, nil, nil

            elseif not isSuspended(src) then
                local list = ActiveZones[src]
                if list and #list > 0 then
                    local c = GetEntityCoords(ped)
                    local px, py, pz = c.x, c.y, c.z

                    for i = 1, #list do
                        local zone = Zones[list[i]]
                        local opts = zone and optsFor(src, zone.id)

                        if zone and blocksPlayer(src, zone, opts) then
                            local depth = TenxShapes.depth(zone, px, py, pz)

                            if depth < -tol then
                                local n = (Violations[src] or 0) + 1
                                Violations[src] = n

                                if n >= Config.Security.violationsBeforeSnap then
                                    local nx, ny, nz = TenxShapes.clamp(
                                        zone, px, py, pz, Config.Boundary.margin)
                                    TriggerClientEvent('tenx-zones:forcePosition',
                                        src, nx, ny, nz, zone.id)
                                end

                                if n >= Config.Security.violationsBeforeLog then
                                    Violations[src] = 0
                                    if Config.Security.onViolation then
                                        Config.Security.onViolation(
                                            src, zone.id, -depth, nil, os.time())
                                    end
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end)


-- ============================================================
--  LIFECYCLE
-- ============================================================

AddEventHandler('playerDropped', function()
    local src = source
    for _, id in ipairs(ActiveZones[src] or {}) do fireLeft(src, id, 'dropped') end

    ActiveZones[src], PlayerBinds[src] = nil, nil
    Watched[src], Violations[src], LastWrite[src], LastBucket[src] = nil, nil, nil, nil
    Inside[src], Armed[src], Suspends[src] = nil, nil, nil
    LastLocalClaim[src], Ready[src] = nil, nil
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- Release everyone unconditionally. A stop handler that only
    -- releases players in one of two states leaves the rest held by a
    -- resource that is no longer running.
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        Suspends[src], Armed[src] = nil, nil
    end
end)


-- ============================================================
--  EXPORTS -- frozen for v2
-- ============================================================

local SELF = GetCurrentResourceName()

local function copyOf(z)
    if not z then return nil end
    return json_decode(json_encode(z))
end

exports('GetVersion', function() return TenxContract.version end)

exports('GetExports', function()
    local out = {}
    for i = 1, #TenxContract.server do out[i] = TenxContract.server[i] end
    return out
end)

exports('HasExport', function(name)
    return TenxContract.has(TenxContract.server, name)
end)

--- Every zone carrying a tag. This is what the /rz picker lists, so a
--- new Red Zone is "draw a sphere, tag it redzone" -- no config edit,
--- no restart, and no zone that exists in the world but cannot be
--- picked because someone forgot to add its id somewhere.
exports('GetZonesByTag', function(tag)
    if type(tag) ~= 'string' then return {} end
    local out = {}
    for id in pairs(ByTag[tag:lower()] or {}) do
        if Zones[id] then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end)

exports('GetZoneTags', function(id)
    local z = Zones[id]
    if not z then return {} end
    local out = {}
    for i = 1, #(z.tags or {}) do out[i] = z.tags[i] end
    return out
end)

exports('ZoneHasTag', function(id, tag)
    local z = Zones[id]
    if not z or type(tag) ~= 'string' then return false end
    tag = tag:lower()
    for _, t in ipairs(z.tags or {}) do
        if t == tag then return true end
    end
    return false
end)

exports('SetZoneTags', function(id, tags)
    if type(tags) ~= 'table' then return false, 'tags must be a table' end
    local clean = {}
    for i = 1, #tags do
        local t = tostring(tags[i]):match('^%s*(.-)%s*$'):lower()
        if t ~= '' and not t:find(',') then clean[#clean + 1] = t end
    end
    return updateZone(id, { tags = clean })
end)

--- Reverse of importKey. Lets a consumer confirm the id it stored is
--- still the shape it imported, rather than eyeballing names.
exports('GetZoneByImportKey', function(key)
    if type(key) ~= 'string' then return nil end
    local id = ByImportKey[key]
    return (id and Zones[id]) and id or nil
end)

--- The audit the arena side asked for.
---
--- Arena zones were imported before deletes became soft, so in that
--- window a delete could free an id and a later zone could take it --
--- leaving an arena pointing at a different shape with no error.
---
--- Pass what you have stored and this says whether it still holds:
---   verify(5, 'tenx:arena:5')
--- Returns ok, why, actualId
exports('VerifyZoneMapping', function(zoneId, expectedKey)
    local z = Zones[zoneId]
    if not z then
        local actual = ByImportKey[expectedKey]
        return false, 'stored zone id no longer exists', actual
    end

    if not z.importKey then
        return false, ('zone %d ("%s") has no import key -- drawn by hand, not imported')
            :format(zoneId, z.name), nil
    end

    if z.importKey ~= expectedKey then
        return false, ('zone %d is "%s" (%s), expected %s')
            :format(zoneId, z.name, z.importKey, expectedKey), ByImportKey[expectedKey]
    end

    return true, nil, zoneId
end)

exports('GetZone',    function(id) return copyOf(Zones[id]) end)
exports('ZoneExists', function(id) return Zones[id] ~= nil end)

exports('GetZones', function()
    local out = {}
    for id, z in pairs(Zones) do out[id] = copyOf(z) end
    return out
end)

--- Guaranteed INSIDE the shape. Use for teleports and blips.
--- On a concave polygon the centroid can land outside the zone, which
--- would fly an admin into a wall, so this is not the centroid.
exports('GetZoneCentre', function(id)
    local z = Zones[id]
    if not z then return nil end
    return z.interior.x, z.interior.y, z.interior.z
end)

--- Raw average of the corners. May be outside a concave shape.
--- Panel readouts only.
exports('GetZoneCentroid', function(id)
    local z = Zones[id]
    if not z then return nil end
    return z.centroid.x, z.centroid.y, z.centroid.z
end)

exports('GetZoneArea', function(id)
    local z = Zones[id]
    return z and z.areaM2 or nil
end)

exports('GetZoneBounds', function(id)
    local z = Zones[id]
    if not z then return nil end
    return z.aabb.minX, z.aabb.minY, z.aabb.maxX, z.aabb.maxY
end)

exports('GetZoneDepth', function(id, coords)
    local z = Zones[id]
    if not z then return nil end
    return TenxShapes.depth(z, coords.x, coords.y, coords.z)
end)

exports('IsPointInZone', function(id, coords, tolerance)
    local z = Zones[id]
    if not z then return false end
    return TenxShapes.contains(z, coords.x, coords.y, coords.z, tolerance) and true or false
end)

--- Synchronous, and never nil for a live player. A nil here would read
--- as "outside" at a kill and silently score nothing.
exports('IsPlayerInZone', function(src, id)
    local z = Zones[id]
    if not z then return false end
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    local c = GetEntityCoords(ped)
    return TenxShapes.contains(z, c.x, c.y, c.z) and true or false
end)

exports('GetPlayersInZone', function(id)
    local z = Zones[id]
    if not z then return {} end

    local out = {}
    for _, s in ipairs(GetPlayers()) do
        local src  = tonumber(s)
        local list = ActiveZones[src]
        if list then
            for i = 1, #list do
                if list[i] == id then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 then
                        local c = GetEntityCoords(ped)
                        if TenxShapes.contains(z, c.x, c.y, c.z) then
                            out[#out + 1] = src
                        end
                    end
                    break
                end
            end
        end
    end
    return out
end)

--- Spawn validation, both directions.
---   want = 'inside'  -> in the shape, at least `tolerance` clear of the edge
---   want = 'outside' -> OUT of it, within `tolerance` of the edge
--- Returns ok, why, depth (signed, positive inside).
exports('ValidateSpawn', function(id, coords, tolerance, want)
    local z = Zones[id]
    if not z then return false, 'zone does not exist', 0 end

    local depth = TenxShapes.depth(z, coords.x, coords.y, coords.z)

    if want == 'outside' then
        if depth > 0 then return false, 'inside_zone', depth end
        local maxOut = tolerance or 25.0
        if -depth > maxOut then return false, 'too_far', depth end
        return true, nil, depth
    end

    if depth <= 0 then
        return false, ('spawn is %.1fm outside the zone'):format(-depth), depth
    end

    local clearance = tolerance or (Config.Boundary.margin * 2)
    if depth < clearance then
        return false, ('spawn is only %.1fm from the edge, needs %.1fm')
            :format(depth, clearance), depth
    end

    return true, nil, depth
end)

exports('ClampToZone', function(id, coords, margin)
    local z = Zones[id]
    if not z then return nil end
    local x, y, zc = TenxShapes.clamp(z, coords.x, coords.y, coords.z,
        margin or Config.Boundary.margin)
    return vector3(x, y, zc)
end)

exports('PushOutsideZone', function(id, coords, distance)
    local z = Zones[id]
    if not z then return nil end
    local x, y, zc = TenxShapes.pushOutside(z, coords.x, coords.y, coords.z, distance)
    return vector3(x, y, zc)
end)

-- ---------- binding ----------

local function warnIfTrap(id, opts)
    local z = Zones[id]
    if z and z.solid and not (opts and opts.armOnEntry) then
        print(('[tenx-zones] note: zone %d bound SOLID without armOnEntry. '
            .. 'Any spawn outside it will clamp players straight back in.'):format(id))
    end
end

exports('BindZoneToBucket', function(id, bucket, opts)
    if not Zones[id] then return false end
    warnIfTrap(id, opts)
    BucketBinds[bucket] = BucketBinds[bucket] or {}
    BucketBinds[bucket][id] = { armOnEntry = (opts and opts.armOnEntry) or false }
    resolveAll()
    return true
end)

exports('UnbindZoneFromBucket', function(id, bucket)
    if BucketBinds[bucket] then BucketBinds[bucket][id] = nil end
    for _, s in ipairs(GetPlayers()) do fireLeft(tonumber(s), id, 'unbound') end
    TriggerEvent('tenx-zones:server:zoneUnavailable', id, 'unbound')
    resolveAll()
    return true
end)

exports('BindZoneToPlayers', function(id, players, opts)
    if not Zones[id] then return false end
    warnIfTrap(id, opts)
    for i = 1, #players do
        local src = players[i]
        PlayerBinds[src] = PlayerBinds[src] or {}
        PlayerBinds[src][id] = { armOnEntry = (opts and opts.armOnEntry) or false }
        resolvePlayer(src)
    end
    return true
end)

exports('UnbindZoneFromPlayers', function(id, players)
    for i = 1, #players do
        local src = players[i]
        if PlayerBinds[src] then PlayerBinds[src][id] = nil end
        if Armed[src] then Armed[src][id] = nil end
        fireLeft(src, id, 'unbound')
        resolvePlayer(src)
    end
    return true
end)

exports('ReleaseZone', function(id)
    for _, set in pairs(BucketBinds) do set[id] = nil end
    for _, set in pairs(PlayerBinds) do set[id] = nil end
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        if Armed[src] then Armed[src][id] = nil end
        fireLeft(src, id, 'unbound')
    end
    TriggerEvent('tenx-zones:server:zoneUnavailable', id, 'released')
    resolveAll()
    return true
end)

exports('RefreshPlayer', function(src) resolvePlayer(src) end)

exports('GetBindings', function()
    local out = {}
    for bucket, set in pairs(BucketBinds) do
        for id in pairs(set) do
            out[id] = out[id] or { buckets = {}, players = {} }
            table.insert(out[id].buckets, bucket)
        end
    end
    for src, set in pairs(PlayerBinds) do
        for id in pairs(set) do
            out[id] = out[id] or { buckets = {}, players = {} }
            table.insert(out[id].players, src)
        end
    end
    return out
end)

exports('GetBindingsFor', function(id)
    local buckets, players = {}, {}
    for bucket, set in pairs(BucketBinds) do
        if set[id] then buckets[#buckets + 1] = bucket end
    end
    for src, set in pairs(PlayerBinds) do
        if set[id] then players[#players + 1] = src end
    end
    return buckets, players
end)

-- ---------- arming ----------

exports('RearmZone', function(src, id)
    Armed[src] = Armed[src] or {}
    Armed[src][id] = true
    resolvePlayer(src)
    return true
end)

exports('DisarmZone', function(src, id)
    if Armed[src] then Armed[src][id] = nil end
    resolvePlayer(src)
    return true
end)

exports('IsZoneArmed', function(src, id)
    return Armed[src] ~= nil and Armed[src][id] == true
end)

-- ---------- suspends ----------

local function doResume(src, reason)
    if Suspends[src] then
        Suspends[src][reason] = nil
        if next(Suspends[src]) == nil then Suspends[src] = nil end
    end

    -- Leaving under a claim DISARMS, so an armOnEntry zone lets them
    -- walk back in rather than clamping them straight back. This is
    -- what makes a Red Zone death loop work: down -> claim -> teleport
    -- outside -> resume -> walk in again.
    local ped = GetPlayerPed(src)
    if ped ~= 0 then
        local c = GetEntityCoords(ped)
        for _, id in ipairs(ActiveZones[src] or {}) do
            local z = Zones[id]
            if z and not TenxShapes.contains(z, c.x, c.y, c.z) then
                if Armed[src] then Armed[src][id] = nil end
                fireLeft(src, id, 'teleported', reason)
            end
        end
    end

    TriggerClientEvent('tenx-zones:suspend', src, reason, true)
    resolvePlayer(src)
    return true
end

exports('SuspendZone', function(src, reason)
    if type(reason) ~= 'string' then return false end
    Suspends[src] = Suspends[src] or {}
    Suspends[src][reason] = false      -- false = server raised, never expires
    TriggerClientEvent('tenx-zones:suspend', src, reason, false)
    return true
end)

exports('ResumeZone', function(src, reason) return doResume(src, reason) end)

exports('ClearSuspends', function(src)
    Suspends[src] = nil
    TriggerClientEvent('tenx-zones:clearSuspends', src)
    resolvePlayer(src)
    return true
end)

exports('GetSuspends', function(src)
    local out = {}
    for reason in pairs(Suspends[src] or {}) do out[#out + 1] = reason end
    return out
end)

-- ---------- movement ----------

--- Server side teleport that holds a claim across the move, for
--- callers with no client sequence of their own.
---
--- Arena should NOT use this. Wrap safeTeleport in SuspendLocal
--- instead and keep your own fade, collision wait and ground probe --
--- this does a competent version of all three but it is not trying to
--- match yours.
exports('TeleportPlayer', function(src, coords, reason, cb)
    reason = reason or 'tenx:teleport'

    Suspends[src] = Suspends[src] or {}
    Suspends[src][reason] = false

    TriggerClientEvent('tenx-zones:doTeleport', src,
        coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, reason)

    CreateThread(function()
        local waited = 0
        while waited < 20000 do
            Wait(250)
            waited = waited + 250
            if not (Suspends[src] and Suspends[src][reason] ~= nil) then
                if cb then cb(true) end
                return
            end
        end
        -- Never acknowledged. Release rather than hold forever.
        doResume(src, reason)
        if cb then cb(false, 'teleport not acknowledged') end
    end)

    return true
end)

RegisterNetEvent('tenx-zones:teleportDone', function(reason)
    local src = source
    if type(reason) ~= 'string' then return end
    doResume(src, reason)
end)

-- ---------- writes ----------

exports('CreateZone', function(zone)
    zone.solid   = zone.solid   ~= false
    zone.visible = zone.visible ~= false
    zone.color   = zone.color or (zone.solid and Config.Defaults.solidColor
                                              or Config.Defaults.passableColor)

    local id, err = createZone(zone, 'script')
    if id then resolveAll() end
    return id, err
end)

exports('DeleteZone', function(id, force) return deleteZone(id, force == true) end)

exports('SetZoneSolid',   function(id, solid)   return updateZone(id, { solid   = solid   and true or false }) end)
exports('SetZoneVisible', function(id, visible) return updateZone(id, { visible = visible and true or false }) end)
