-- =====================================================================
--  Shared plate helpers (state-aware generation / validation)
--  Runs on BOTH client and server.
--  Reads Config.States -> config.lua must load (shared_script) BEFORE this.
-- =====================================================================
Plates = {}

local LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
local DIGITS  = '0123456789'

local function pick(str)
    local i = math.random(#str)
    return str:sub(i, i)
end

-- Deterministic seed from a string so all clients derive the SAME plate
-- for the same traffic car.
local function seedFromString(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

-- ---------------- STATE HELPERS ----------------

function Plates.GetState(key)
    for _, s in ipairs(Config.States or {}) do
        if s.key == key then return s end
    end
    return nil
end

-- Which state owns a given plate index (texture slot)?
function Plates.GetStateByIndex(index)
    for _, s in ipairs(Config.States or {}) do
        if s.plateIndex == index then return s end
    end
    return nil
end

-- Flat set of every valid prefix across all states (for validation).
function Plates.AllPrefixes()
    local out = {}
    for _, s in ipairs(Config.States or {}) do
        for _, p in ipairs(s.prefixes or {}) do out[p] = true end
    end
    return out
end

-- ---------------- GENERATION ----------------

-- Generate a plate for a SPECIFIC state.
-- Returns: plate string, plateIndex to set so the texture matches.
function Plates.GenerateForState(stateKey, seedStr)
    if seedStr then math.randomseed(seedFromString(seedStr)) end
    local state = Plates.GetState(stateKey)
        or Plates.GetState(Config.DefaultState)
        or Config.States[1]
    local prefix = state.prefixes[math.random(#state.prefixes)]
    local p = prefix
    for _ = 1, 3 do p = p .. pick(DIGITS)  end
    for _ = 1, 2 do p = p .. pick(LETTERS) end
    return p, state.plateIndex
end

-- Back-compat: default-state plate (used by traffic, migrate, dealership).
-- Returns just the plate string.
function Plates.GenerateNigerian(seedStr)
    local plate = Plates.GenerateForState(Config.DefaultState, seedStr)
    return plate
end

-- ---------------- NORMALIZE / VALIDATE ----------------

function Plates.Normalize(text)
    if not text then return '' end
    text = text:upper():gsub('^%s+', ''):gsub('%s+$', '')
    return text:sub(1, 8)
end

-- Validate a player's custom (vanity) plate.
-- Returns: ok(boolean), cleanPlate(string) OR reasonKey(string)
function Plates.ValidateCustom(text, cfg)
    text = Plates.Normalize(text)

    if #text == 0 then return false, 'blank' end
    if cfg.BlockFullyBlank and text:gsub('%s', '') == '' then return false, 'blank' end
    if #text > (cfg.MaxPlateLength or 8) then return false, 'tooLong' end

    local pattern = cfg.AllowSpaces and '[^A-Z0-9 ]' or '[^A-Z0-9]'
    if text:find(pattern) then return false, 'blocked' end

    -- Only enforced if you turn ForceNigerianFormatOnCustom on. Left off,
    -- players keep full vanity-plate freedom (feature #2 you asked for).
    if cfg.ForceNigerianFormatOnCustom then
        if not text:match('^%u%u%u%d%d%d%u%u$') then return false, 'blocked' end
        if not Plates.AllPrefixes()[text:sub(1, 3)] then return false, 'blocked' end
    end

    return true, text
end