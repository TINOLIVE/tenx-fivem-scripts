local QBCore = exports['qb-core']:GetCoreObject()

-- ============================================================
--  CONFIG
-- ============================================================
local ALLOWED_PERMS = { 'admin', 'god' }   -- QBCore permission levels allowed to open the menu
local COMMAND       = 'spawnmenu'          -- chat command to open

-- ---- Fivemanage (optional): host car photos on a CDN instead of local files ----
local USE_FIVEMANAGE  = false
local FIVEMANAGE_TOKEN = ''  -- your Fivemanage API token
-- ============================================================

local VehicleList = {}
local ItemList    = {}
local ImportList  = {}   -- user-pasted spawn codes (persisted via KVP)

local KVP_KEY    = 'spawn_menu:imports'
local CAP_KEY    = 'spawn_menu:captured'
local URL_KEY    = 'spawn_menu:imageurls'
local LABEL_KEY  = 'spawn_menu:labels'   -- NEW v2: model -> custom label overrides

local CapturedSet     = {}   -- model -> true, persisted; used to resume capture
local ImageUrls       = {}   -- model -> hosted url (when using Fivemanage)
local LabelOverrides  = {}   -- NEW v2: model -> custom display name (persisted)

local function saveImports()
    SetResourceKvp(KVP_KEY, json.encode(ImportList))
end

local function loadImports()
    local raw = GetResourceKvpString(KVP_KEY)
    if raw then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then ImportList = decoded end
    end
end

local function saveCaptured()
    local arr = {}
    for m in pairs(CapturedSet) do arr[#arr + 1] = m end
    SetResourceKvp(CAP_KEY, json.encode(arr))
end

local function loadCaptured()
    local raw = GetResourceKvpString(CAP_KEY)
    if raw then
        local ok, d = pcall(json.decode, raw)
        if ok and type(d) == 'table' then
            for _, m in ipairs(d) do CapturedSet[m] = true end
        end
    end
end

local function saveImageUrls()
    SetResourceKvp(URL_KEY, json.encode(ImageUrls))
end

local function loadImageUrls()
    local raw = GetResourceKvpString(URL_KEY)
    if raw then
        local ok, d = pcall(json.decode, raw)
        if ok and type(d) == 'table' then ImageUrls = d end
    end
end

-- NEW v2: label override persistence
local function saveLabelOverrides()
    SetResourceKvp(LABEL_KEY, json.encode(LabelOverrides))
end

local function loadLabelOverrides()
    local raw = GetResourceKvpString(LABEL_KEY)
    if raw then
        local ok, d = pcall(json.decode, raw)
        if ok and type(d) == 'table' then LabelOverrides = d end
    end
end

local function hasPerm(src)
    for _, p in ipairs(ALLOWED_PERMS) do
        if QBCore.Functions.HasPermission(src, p) then return true end
    end
    return IsPlayerAceAllowed(src, 'command') -- server console / ace admins
end

-- Scan started resources for addon vehicle spawn codes from vehicles.meta
local function scanAddonVehicles(existing)
    local found = {}
    local commonPaths = {
        'vehicles.meta', 'data/vehicles.meta', 'stream/vehicles.meta',
        'meta/vehicles.meta', 'dlc/vehicles.meta', 'vehicles/vehicles.meta',
        'data/vehicle.meta'
    }

    local function extractModels(content, res)
        for model in content:gmatch('<modelName>(.-)</modelName>') do
            model = model:lower():gsub('%s', '')
            if model ~= '' and not existing[model] and not found[model] then
                found[model] = res
            end
        end
    end

    local num = GetNumResources()
    for i = 0, num - 1 do
        local res = GetResourceByFindIndex(i)
        if res and GetResourceState(res) == 'started' then
            local triedPaths = {}

            -- Pass 1: fixed common paths (cheap, catches the simple/flat packs)
            for _, path in ipairs(commonPaths) do
                triedPaths[path] = true
                local content = LoadResourceFile(res, path)
                if content then extractModels(content, res) end
            end

            -- Pass 2 (NEW): read the resource's OWN manifest to find its real
            -- vehicles.meta path(s), however deeply nested. Multi-car packs
            -- often use one subfolder per vehicle (e.g. data/fsf90xx/vehicles.meta)
            -- which no fixed guess-list could ever fully predict.
            local manifest = LoadResourceFile(res, 'fxmanifest.lua') or LoadResourceFile(res, '__resource.lua')
            if manifest then
                for path in manifest:gmatch("['\"]([%w_%-%./]-[Vv]ehicles?%.meta)['\"]") do
                    if not triedPaths[path] then
                        triedPaths[path] = true
                        local content = LoadResourceFile(res, path)
                        if content then extractModels(content, res) end
                    end
                end
            end
        end
    end
    return found
end

local function buildVehicleList()
    VehicleList = {}
    local seen = {}

    -- 1) QBCore-registered vehicles (reliable: spawn code + label + category)
    for k, v in pairs(QBCore.Shared.Vehicles or {}) do
        local model = (v.model or k)
        if type(model) == 'string' then
            model = model:lower()
            if not seen[model] then
                seen[model] = true
                local baseLabel = v.name or v.label or model
                VehicleList[#VehicleList + 1] = {
                    label       = LabelOverrides[model] or baseLabel,  -- v2: apply override
                    defaultLabel = baseLabel,                          -- v2: keep original for "reset" reference
                    model       = model,
                    category    = (v.category or 'unknown'),
                    vanilla     = QBVanillaVehicles[model] == true,
                    renamed     = LabelOverrides[model] ~= nil          -- v2: flag so UI can show a badge
                }
            end
        end
    end

    -- 2) Addon vehicles scanned from resource vehicles.meta (not in vehicles.lua)
    local addons = scanAddonVehicles(seen)
    for model, res in pairs(addons) do
        VehicleList[#VehicleList + 1] = {
            label       = LabelOverrides[model] or model,  -- v2: apply override, fallback to spawn code
            defaultLabel = model,
            model       = model,
            category    = 'addon:' .. res,
            vanilla     = false,
            renamed     = LabelOverrides[model] ~= nil
        }
    end

    table.sort(VehicleList, function(a, b) return a.label:lower() < b.label:lower() end)
    print(('[spawn_menu] Loaded %d vehicles (incl. scanned addons, %d renamed)'):format(#VehicleList, (function()
        local c = 0
        for _ in pairs(LabelOverrides) do c = c + 1 end
        return c
    end)()))
end

local function buildItemList()
    ItemList = {}
    local ok, items = pcall(function() return exports.ox_inventory:Items() end)
    if not ok or not items then
        print('[spawn_menu] ^1Could not read ox_inventory items^0')
        return
    end
    for name, data in pairs(items) do
        if tostring(name):upper():sub(1, 7) == 'WEAPON_' then  -- weapons only
            ItemList[#ItemList + 1] = {
                name   = name,
                label  = data.label or name,
                weapon = true
            }
        end
    end
    table.sort(ItemList, function(a, b) return a.label:lower() < b.label:lower() end)
    print(('[spawn_menu] Loaded %d weapons'):format(#ItemList))
end

-- Apply the current label overrides onto the Import list too (imports default label = model)
local function applyOverridesToImports()
    for _, v in ipairs(ImportList) do
        if LabelOverrides[v.model] then
            v.label = LabelOverrides[v.model]
            v.renamed = true
        end
    end
end

CreateThread(function()
    Wait(2000) -- let qb-core & ox_inventory finish loading
    loadImports()
    loadCaptured()
    loadImageUrls()
    loadLabelOverrides()   -- v2: load saved renames before building lists
    buildVehicleList()
    buildItemList()
    applyOverridesToImports()
end)

-- Open the menu (push data to the client)
RegisterCommand(COMMAND, function(source)
    local src = source
    if src == 0 then return end
    if not hasPerm(src) then
        TriggerClientEvent('QBCore:Notify', src, 'You do not have permission for that.', 'error')
        return
    end
    TriggerClientEvent('spawn_menu:open', src, VehicleList, ItemList, ImportList, CapturedSet, ImageUrls)
end, false)

-- Give item / weapon via ox_inventory
RegisterNetEvent('spawn_menu:giveItem', function(name, amount)
    local src = source
    if not hasPerm(src) then return end
    amount = math.max(1, tonumber(amount) or 1)
    exports.ox_inventory:AddItem(src, name, amount)
    TriggerClientEvent('QBCore:Notify', src, ('Received %dx %s'):format(amount, name), 'success')
end)

-- ============================================================
--  NEW v2: RENAME VEHICLE (persistent, works on QBCore + addon cars)
-- ============================================================
RegisterNetEvent('spawn_menu:renameVehicle', function(model, newLabel)
    local src = source
    if not hasPerm(src) then return end
    if type(model) ~= 'string' or type(newLabel) ~= 'string' then return end

    model = model:lower():gsub('%s', '')
    newLabel = newLabel:gsub('^%s+', ''):gsub('%s+$', '') -- trim
    if newLabel == '' or #newLabel > 60 then
        TriggerClientEvent('QBCore:Notify', src, 'Name must be 1-60 characters', 'error')
        return
    end

    -- confirm this model actually exists in the current list (no renaming garbage entries)
    local found = false
    for _, v in ipairs(VehicleList) do
        if v.model == model then found = true break end
    end
    if not found then
        TriggerClientEvent('QBCore:Notify', src, 'Unknown vehicle model: ' .. model, 'error')
        return
    end

    LabelOverrides[model] = newLabel
    saveLabelOverrides()

    -- update in-memory list immediately (no rebuild/rescan needed)
    for _, v in ipairs(VehicleList) do
        if v.model == model then
            v.label = newLabel
            v.renamed = true
        end
    end
    for _, v in ipairs(ImportList) do
        if v.model == model then
            v.label = newLabel
            v.renamed = true
        end
    end
    saveImports()

    -- push the updated lists to whichever admin triggered this (their menu refreshes live)
    TriggerClientEvent('spawn_menu:updateVehicles', src, VehicleList, ImportList)
    TriggerClientEvent('QBCore:Notify', src, ('Renamed %s -> %s (saved)'):format(model, newLabel), 'success')
end)

-- NEW v2: reset a single vehicle back to its original/default name
RegisterNetEvent('spawn_menu:resetVehicleName', function(model)
    local src = source
    if not hasPerm(src) then return end
    if type(model) ~= 'string' then return end
    model = model:lower():gsub('%s', '')

    if LabelOverrides[model] == nil then return end
    LabelOverrides[model] = nil
    saveLabelOverrides()

    for _, v in ipairs(VehicleList) do
        if v.model == model then
            v.label = v.defaultLabel or model
            v.renamed = false
        end
    end
    for _, v in ipairs(ImportList) do
        if v.model == model then
            v.label = model
            v.renamed = false
        end
    end
    saveImports()

    TriggerClientEvent('spawn_menu:updateVehicles', src, VehicleList, ImportList)
    TriggerClientEvent('QBCore:Notify', src, 'Name reset to default: ' .. model, 'success')
end)

-- ============================================================
--  IMPORT LIST (paste spawn codes)
-- ============================================================
local function existsInImports(model)
    for _, v in ipairs(ImportList) do
        if v.model == model then return true end
    end
    return false
end

RegisterNetEvent('spawn_menu:addImports', function(text)
    local src = source
    if not hasPerm(src) then return end
    if type(text) ~= 'string' then return end

    local added = 0
    for token in text:gmatch('[^%s,;]+') do
        local model = token:lower():gsub('%s', '')
        if model ~= '' and not existsInImports(model) then
            ImportList[#ImportList + 1] = {
                label   = LabelOverrides[model] or model,  -- v2: apply saved override if it exists
                model   = model,
                category = 'import',
                renamed = LabelOverrides[model] ~= nil
            }
            added = added + 1
        end
    end

    table.sort(ImportList, function(a, b) return a.model < b.model end)
    saveImports()
    TriggerClientEvent('spawn_menu:updateImports', src, ImportList)
    TriggerClientEvent('QBCore:Notify', src, ('Added %d spawn code(s) to Import'):format(added), 'success')
end)

RegisterNetEvent('spawn_menu:removeImport', function(model)
    local src = source
    if not hasPerm(src) then return end
    for i = #ImportList, 1, -1 do
        if ImportList[i].model == model then table.remove(ImportList, i) end
    end
    saveImports()
    TriggerClientEvent('spawn_menu:updateImports', src, ImportList)
end)

RegisterNetEvent('spawn_menu:clearImports', function()
    local src = source
    if not hasPerm(src) then return end
    ImportList = {}
    saveImports()
    TriggerClientEvent('spawn_menu:updateImports', src, ImportList)
    TriggerClientEvent('QBCore:Notify', src, 'Import list cleared', 'success')
end)

-- ============================================================
--  CAR PHOTO SAVE (from screenshot-basic, base64 -> png file)
-- ============================================================
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64decode(data)
    data = tostring(data):gsub('[^' .. b64chars .. '=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b64chars:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

local function uploadFivemanage(model, dataUri)
    PerformHttpRequest('https://api.fivemanage.com/api/v3/file/base64', function(status, text)
        if (status == 200 or status == 201) and text then
            local ok, j = pcall(json.decode, text)
            local url = ok and j and ((j.data and j.data.url) or j.url)
            if url then
                ImageUrls[model] = url
                saveImageUrls()
                CapturedSet[model] = true
                saveCaptured()
            else
                print('[spawn_menu] ^3Fivemanage: no url in response for ' .. model)
            end
        else
            print(('[spawn_menu] ^1Fivemanage upload failed for %s (status %s)^0'):format(model, tostring(status)))
        end
    end, 'POST', json.encode({ base64 = dataUri, filename = model .. '.png' }), {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = FIVEMANAGE_TOKEN
    })
end

RegisterNetEvent('spawn_menu:saveShot', function(model, dataUri)
    local src = source
    if not hasPerm(src) then return end
    if type(model) ~= 'string' or type(dataUri) ~= 'string' then return end
    model = model:lower():gsub('[^%w_%-]', '')
    if model == '' then return end

    if USE_FIVEMANAGE and FIVEMANAGE_TOKEN ~= '' then
        uploadFivemanage(model, dataUri)
    else
        local b64 = dataUri:gsub('^data:image/%a+;base64,', '')
        local bin = b64decode(b64)
        if #bin > 0 then
            SaveResourceFile(GetCurrentResourceName(), 'images/' .. model .. '.png', bin, #bin)
            CapturedSet[model] = true
            saveCaptured()
        end
    end
end)

RegisterNetEvent('spawn_menu:resetPhotos', function()
    local src = source
    if not hasPerm(src) then return end
    CapturedSet = {}
    ImageUrls = {}
    saveCaptured()
    saveImageUrls()
    TriggerClientEvent('spawn_menu:captured', src, CapturedSet)
    TriggerClientEvent('QBCore:Notify', src, 'Photo progress reset — Take Pictures will redo all', 'success')
end)

RegisterCommand('spawnmenu_refresh', function(source)
    if source ~= 0 and not hasPerm(source) then return end
    buildVehicleList()
    buildItemList()
    applyOverridesToImports()
    if source ~= 0 then TriggerClientEvent('QBCore:Notify', source, 'Spawn menu lists refreshed', 'success') end
end, true)
