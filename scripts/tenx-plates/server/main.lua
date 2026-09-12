-- =====================================================================
--  tenx-plates | server: validation, item consume, DB cascade, sync
--  Server-authoritative: the client only REQUESTS; the server decides.
-- =====================================================================
local QBCore = exports['qb-core']:GetCoreObject()
local cooldowns = {}

-- Does this plate already exist on ANY cascade table? (uniqueness)
local function plateExists(plate)
    for _, t in ipairs(Config.PlateTables) do
        local row = MySQL.scalar.await(
            ('SELECT 1 FROM `%s` WHERE `%s` = ? LIMIT 1'):format(t.table, t.column),
            { plate })
        if row then return true end
    end
    return false
end

-- Guaranteed-unique Nigerian plate (used by new-car hook + admin migrate).
local function uniqueNigerian()
    for _ = 1, 25 do
        local p = Plates.GenerateNigerian(tostring(math.random()) .. os.time())
        if not plateExists(p) then return p end
    end
    return Plates.GenerateNigerian(tostring(os.clock()))
end

-- Banned words: config list + live DB list.
local function isBlocked(plate)
    local clean = plate:gsub('%s', '')
    for _, w in ipairs(Config.BannedWords or {}) do
        if clean:find(w:upper(), 1, true) then return true end
    end
    local hit = MySQL.scalar.await(
        'SELECT 1 FROM tenx_plates_blocked WHERE INSTR(?, word) > 0 LIMIT 1',
        { clean })
    return hit ~= nil
end

-- ---------------------------------------------------------------------
--  VEHICLE KEYS: keys are tied to the plate string, so on a plate change
--  we revoke the old plate's key and grant one for the new plate.
--  src is optional: offline/admin migrations pass nil and are skipped.
-- ---------------------------------------------------------------------
local function reissueKeys(src, oldPlate, newPlate)
    if not src then return end
    local vk = Config.VehicleKeys
    if not vk or not vk.enabled then return end
    local res = vk.resource
    local lv  = vk.localVehicle and true or false
    pcall(function()
        if oldPlate and oldPlate ~= newPlate then
            exports[res]:RemoveKey(src, oldPlate, lv)
        end
        exports[res]:GiveKey(src, newPlate, lv)
    end)
end

-- ---------------------------------------------------------------------
--  THE CASCADE: change a plate EVERYWHERE at once.
--  Pass src when a player triggered it, so keys can be re-issued to them.
-- ---------------------------------------------------------------------
local function cascadePlate(oldPlate, newPlate, src)
    for _, t in ipairs(Config.PlateTables) do
        MySQL.update.await(
            ('UPDATE `%s` SET `%s` = ? WHERE `%s` = ?'):format(t.table, t.column, t.column),
            { newPlate, oldPlate })
    end

    -- >>> DEV WIRING #3: VEHICLE KEYS (ak47_qb_vehiclekeys) <<<
    -- Re-issue keys for the NEW plate (and drop the OLD one).
    reissueKeys(src, oldPlate, newPlate)
end
exports('CascadePlate', cascadePlate)      -- used by server/admin.lua

-- Brand-new owned car? Call this from your vehicleshop to birth it Nigerian.
--   >>> DEV WIRING #4: exports['tenx-plates']:GenerateNewPlate() <<<
exports('GenerateNewPlate', function()
    return uniqueNigerian()
end)

-- ---------------------------------------------------------------------
--  Item used -> open the customizer.
-- ---------------------------------------------------------------------
QBCore.Functions.CreateUseableItem(Config.Item, function(source)
    TriggerClientEvent('tenx-plates:client:open', source)
end)
-- NOTE (ox_inventory): also register the item in data/items.lua (README).

-- ---------------------------------------------------------------------
--  Apply a custom plate.
-- ---------------------------------------------------------------------
RegisterNetEvent('tenx-plates:server:apply', function(netId, oldPlate, oldIndex, newPlate, newIndex)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    oldPlate = Plates.Normalize(oldPlate)
    oldIndex = tonumber(oldIndex) or 0

    local function fail(key)
        TriggerClientEvent('QBCore:Notify', src, Config.Text[key] or Config.Text.blocked, 'error')
        TriggerClientEvent('tenx-plates:client:revert', src, netId, oldPlate, oldIndex)
    end

    -- anti-spam: block only if a SUCCESSFUL change happened recently.
    -- (Cooldown is set at the END, so typos/mistakes never lock the player out.)
    local now = GetGameTimer()
    if cooldowns[src] and now - cooldowns[src] < Config.ChangeCooldown then
        return fail('cooldown')
    end

    -- validate the requested text
    local ok, cleanOrReason = Plates.ValidateCustom(newPlate, Config)
    if not ok then return fail(cleanOrReason) end
    newPlate = cleanOrReason
    newIndex = tonumber(newIndex) or 0

    -- must actually OWN the car with oldPlate
    local owns = MySQL.scalar.await(
        'SELECT 1 FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1',
        { oldPlate, Player.PlayerData.citizenid })
    if not owns then return fail('notOwner') end

    -- must be HOLDING the item
    local item = Player.Functions.GetItemByName(Config.Item)
    if not item or item.amount < 1 then return fail('noItem') end

    -- banned words
    if isBlocked(newPlate) then return fail('blocked') end

    -- uniqueness (skip check if plate is unchanged)
    if newPlate ~= oldPlate and plateExists(newPlate) then return fail('taken') end

    -- CONSUME the item (the cost)
    if not Player.Functions.RemoveItem(Config.Item, 1) then return fail('noItem') end
    -- ox_inventory alt: exports.ox_inventory:RemoveItem(src, Config.Item, 1)

    -- update the plate everywhere (and re-issue keys to this player)
    cascadePlate(oldPlate, newPlate, src)

    -- persist the design index into the stored vehicle props
    local mods = MySQL.scalar.await(
        'SELECT mods FROM player_vehicles WHERE plate = ? LIMIT 1', { newPlate })
    if mods then
        local props = json.decode(mods) or {}
        props.plate = newPlate
        props.plateIndex = newIndex
        MySQL.update.await('UPDATE player_vehicles SET mods = ? WHERE plate = ?',
            { json.encode(props), newPlate })
    end

    -- change SUCCEEDED -> arm the cooldown now.
    cooldowns[src] = now

    -- push the live plate to everyone in the city
    TriggerClientEvent('tenx-plates:client:sync', -1, netId, newPlate, newIndex)
    TriggerClientEvent('QBCore:Notify', src, Config.Text.success, 'success')
end)

AddEventHandler('playerDropped', function()
    cooldowns[source] = nil
end)