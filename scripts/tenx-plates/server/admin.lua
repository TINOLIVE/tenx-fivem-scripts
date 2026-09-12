-- =====================================================================
--  tenx-plates | admin: migrate existing cars, override, manage blocklist
-- =====================================================================
local function isAdmin(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.AdminAce)
end

local function notify(src, msg, kind)
    if src == 0 then print('[tenx-plates] ' .. msg)
    else TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary') end
end

-- Uses the single cascade from server/main.lua (keys hook lives there too).
local function cascade(oldPlate, newPlate)
    exports['tenx-plates']:CascadePlate(oldPlate, newPlate)
end

-- Keep the stored props JSON in sync with the plate column, so the SPAWNED
-- car shows the new plate (otherwise applying mods stamps the old one back).
local function syncPropsPlate(plate)
    local mods = MySQL.scalar.await(
        'SELECT mods FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not mods then return end
    local props = json.decode(mods)
    if not props then return end
    props.plate = plate
    MySQL.update.await('UPDATE player_vehicles SET mods = ? WHERE plate = ?',
        { json.encode(props), plate })
end

local function uniqueNigerian()
    for _ = 1, 25 do
        local p = Plates.GenerateNigerian(tostring(math.random()) .. os.time())
        local taken = MySQL.scalar.await(
            'SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1', { p })
        if not taken then return p end
    end
    return nil
end

-- /naijaplates_migrate  ->  convert EVERY existing owned car to a Nigerian plate.
-- Run ONCE. Cars already in Nigerian format are skipped.
RegisterCommand('naijaplates_migrate', function(src)
    if not isAdmin(src) then return end

    local rows = MySQL.query.await('SELECT plate FROM player_vehicles') or {}
    local changed, skipped = 0, 0

    for _, row in ipairs(rows) do
        local old = Plates.Normalize(row.plate)
        if old:match('^%u%u%u%d%d%d%u%u$') then
            skipped = skipped + 1
        else
            local newP = uniqueNigerian()
            if newP then
                cascade(old, newP)
                syncPropsPlate(newP)   -- <- keep the JSON plate in sync too
                changed = changed + 1
            else
                skipped = skipped + 1
            end
        end
    end

    notify(src, ('Migration done. Changed %d, skipped %d.'):format(changed, skipped), 'success')
end, true)

-- /naijaplates_syncprops  ->  REPAIR pass for cars whose props JSON still holds
-- the OLD plate (i.e. migrated before this fix). Safe to run multiple times.
-- Only rewrites rows where the JSON plate differs from the plate column.
RegisterCommand('naijaplates_syncprops', function(src)
    if not isAdmin(src) then return end

    local function norm(p) return (tostring(p or '')):gsub('%s+$', ''):upper() end

    local rows = MySQL.query.await('SELECT plate, mods FROM player_vehicles') or {}
    local fixed, checked = 0, 0

    for _, row in ipairs(rows) do
        if row.mods then
            checked = checked + 1
            local props = json.decode(row.mods)
            if props and props.plate and norm(props.plate) ~= norm(row.plate) then
                props.plate = row.plate
                MySQL.update.await('UPDATE player_vehicles SET mods = ? WHERE plate = ?',
                    { json.encode(props), row.plate })
                fixed = fixed + 1
            end
        end
    end

    notify(src, ('Props sync done. Fixed %d of %d checked.'):format(fixed, checked), 'success')
end, true)

-- /plateoverride <oldPlate> <newPlate>  ->  admin force-set any plate.
RegisterCommand('plateoverride', function(src, args)
    if not isAdmin(src) then return end
    local old = Plates.Normalize(args[1] or '')
    local new = Plates.Normalize(args[2] or '')
    if old == '' or new == '' then
        return notify(src, 'Usage: /plateoverride <oldPlate> <newPlate>', 'error')
    end
    cascade(old, new)
    syncPropsPlate(new)   -- <- keep the JSON plate in sync too
    notify(src, ('Plate %s -> %s'):format(old, new), 'success')
end, true)

-- /plateblock add|remove <word>  ->  manage banned words live.
RegisterCommand('plateblock', function(src, args)
    if not isAdmin(src) then return end
    local action = (args[1] or ''):lower()
    local word   = (args[2] or ''):upper()
    if word == '' then
        return notify(src, 'Usage: /plateblock add|remove <word>', 'error')
    end

    if action == 'add' then
        MySQL.insert.await('INSERT IGNORE INTO tenx_plates_blocked (word) VALUES (?)', { word })
        notify(src, ('Blocked: %s'):format(word), 'success')
    elseif action == 'remove' then
        MySQL.update.await('DELETE FROM tenx_plates_blocked WHERE word = ?', { word })
        notify(src, ('Unblocked: %s'):format(word), 'success')
    else
        notify(src, 'Usage: /plateblock add|remove <word>', 'error')
    end
end, true)