Config = {}

-- =====================================================================
--  tenx-plates | NAIJA 2046
--  Nigerian-themed city plates + item-based plate customization.
--  Almost everything you'd want to tweak lives in THIS file.
-- =====================================================================

-- ---------- THE ITEM (this is the "cost") ----------
-- Player must be HOLDING this item. It is CONSUMED on a successful change.
-- >>> Add this item to your ox_inventory data/items.lua (see README). <<<
Config.Item = 'plate_kit'

-- ---------- CUSTOMIZATION RULES ----------
Config.MaxPlateLength = 8            -- GTA hard limit. Do NOT exceed.
Config.AllowSpaces    = true         -- spaces allowed INSIDE the plate
Config.BlockFullyBlank = true        -- a plate that is ONLY spaces is rejected
Config.ForceNigerianFormatOnCustom = false
-- ^ false = players may type any valid plate (vanity plates).
--   true  = custom plates must match the Nigerian pattern (LLL DDD LL)
--           AND start with a real LGA code from Config.PlatePrefixes below.

-- Nigerian pattern used for CITY DEFAULT + traffic + migration:
-- 3 letters, 3 numbers, 2 letters  ->  e.g. LAG245KJ
-- (Real plates show a dash "LAG-245KJ" but GTA caps at 8 chars, no dash.)

-- ---------- PLATE DESIGNS (native styles) ----------
-- 0 Blue on White 1 | 1 Yellow on Black | 2 Yellow on Blue
-- 3 Blue on White 2 | 4 Blue on White 3 | 5 North Yankton
-- >>> DEV: when you add a custom NAIJA plate texture, add its index here. <<<
Config.Designs = {
    { label = 'White Plate',   index = 0 },
    { label = 'Black Plate',   index = 1 },
    { label = 'Blue Plate',    index = 2 },
    { label = 'Classic White', index = 3 },
    -- { label = 'NAIJA Green', index = 6 },  -- <- custom streamed texture goes here
}

-- ---------- STATES: texture index <-> prefixes, kept in sync ----------
-- plateIndex shifted down by 1 to correct the index->slot offset on this build:
-- the game shows slot plate0(N+1) for index N, so index 0 -> plate01 (Lagos), etc.
Config.States = {
    { key = 'lagos', label = 'Lagos',          plateIndex = 0,
      prefixes = { 'APP','KJA','IKJ','MUS','LSR','EKY','SMK','FST','AAA','GGE','KSF','JJJ' } },
    { key = 'benin', label = 'Benin (Edo)',    plateIndex = 1,
      prefixes = { 'BEN','AKG','UBM','EKM' } },
    { key = 'abuja', label = 'Abuja (FCT)',    plateIndex = 2,
      prefixes = { 'ABJ','ABC','BWR','GWG','KUJ' } },
    { key = 'kwara', label = 'Kwara (Ilorin)', plateIndex = 3,
      prefixes = { 'ILR','OMU','KWR','JBB' } },
    { key = 'ogun',  label = 'Ogun',           plateIndex = 4,
      prefixes = { 'ABE','IJE','SAG','OTA' } },
}
 
Config.DefaultState = 'lagos'
Config.PoliceJobs   = { 'police', 'lspd', 'sheriff' }

-- ---------- WHOLE-CITY NIGERIAN PLATES ----------
Config.Traffic = {
    enabled      = false,     -- NPC/AI traffic cars get Nigerian plates (cosmetic)
    scanRadius   = 90.0,     -- not strictly used; kept for future tuning
    scanInterval = 1500,     -- ms between scans
    -- >>> DEV WIRING #2: if your garage sets a statebag flag on OWNED cars,
    --     put its key here so traffic plates never overwrite owned vehicles.
    ownedStateFlag = 'owned',
}

-- ---------- SAFETY ----------
Config.ChangeCooldown = 5000   -- ms between SUCCESSFUL changes per player (anti-spam)

-- ---------- PERMISSIONS ----------
-- add to server.cfg:  add_ace group.admin tenx-plates.admin allow
Config.AdminAce = 'tenx-plates.admin'

-- ---------- VEHICLE KEYS (ak47_qb_vehiclekeys) ----------
-- When a plate changes, keys are tied to the plate string, so we re-issue them:
-- the old plate's key is removed and a key for the new plate is granted to the
-- player who made the change. Runs inside the DB cascade (server-side).
Config.VehicleKeys = {
    enabled      = true,
    resource     = 'ak47_qb_vehiclekeys',  -- export resource name
    localVehicle = false,                  -- GiveKey/RemoveKey 3rd arg: true = no owner, false = owned
}

-- ---------- BANNED WORDS (starter list) ----------
-- Extend live in-game with: /plateblock add <word>
Config.BannedWords = {
    'FUCK', 'SHIT', 'RAPE', 'NAZI', 'KKK',
    -- add more here, or use /plateblock add <word> in-city
}

-- =====================================================================
--  >>> DEV WIRING #1: PLATE CASCADE TABLES <<<
--  The plate is a DB identity. EVERY table that stores a plate must be
--  listed here, so one plate change updates everywhere at once.
--  Add/remove rows to match YOUR server: { table = '...', column = '...' }
-- =====================================================================
Config.PlateTables = {
    { table = 'player_vehicles',   column = 'plate' },
    -- { table = 'vehicle_insurance', column = 'plate' },
    -- { table = 'player_boats',      column = 'plate' },
    -- { table = 'okokgarage',        column = 'plate' },
    -- ...list every plate-storing table on YOUR server
}


-- =====================================================================
--  JOB VEHICLES  (both blocks are required together)
-- =====================================================================

-- ---------- WHICH MODELS ARE JOB CARS ----------
-- On-duty members entering one of these models get a key + fleet plate.
-- Pulled from your ak47 job garage config. Models are matched by hash.
Config.JobVehicles = {
    police = {
        'ccpanto','pcycle','ccmanch','DBsou_chargerpd','tb_buffalo','ccvstr',
        'tb_polregent','tb_bisonxl','pdhakucho','cccomni','ccballer7','DBRocket900PD',
        'ccshin','ccballer8','cctenf2','tb_dominator','cccomet6','CCTURISMO3',
        'tb_polcara','cccade3','protopolice',
        'md902','polval','dinghy',
    },
    ambulance = {
        'dlissiamb','emsnspeedo','emsraiden','ccshin','tb_bisonxl','ccballer8',
        'rolaemsvstr','rolaemsvigero','rolaemsturismo','rolaemstenf','rolaemscomet',
        'rolaemscinquemila','rolaemscavalcade','rolaemscaracara','rolaemsbuffalo',
        'rolaemsballer2','dlswift',
    },
    mechanic = {
        'flatbed','towtruck','minivan','blista',
    },
}

-- Require the player to be clocked IN (onduty) to get the key + plate?
-- true  = must be on duty.  false = having the job is enough.
Config.JobVehiclesRequireOnDuty = true

-- ---------- FLEET PLATE TEXT PER JOB ----------
-- Every car of this job shows this exact plate (NCPD / NCMS).
-- Jobs not listed keep their normal plate but still get keys.
Config.JobPlatePrefix = {
    police    = 'NCPD',
    ambulance = 'NCMS',
    -- mechanic = 'NCMC',
}


-- ---------- NIGERIAN PIDGIN TEXT ----------
Config.Text = {
    notInVehicle = 'You must dey inside the motor wey you own.',
    notOwner     = 'Na who own this motor? No be your own.',
    noItem       = 'You no get plate kit for hand.',
    taken        = 'Person don take that plate. Try another one.',
    blocked      = 'That plate no dey allowed. Choose another.',
    blank        = 'Plate no fit empty. Put something.',
    tooLong      = 'Plate too long. Max na 8 character.',
    success      = 'Your new plate don set. Enjoy am!',
    cooldown     = 'Chill small before you try again.',
    menuTitle    = 'Plate Customization',
    inputText    = 'Enter your plate',
    inputDesign  = 'Choose plate design',
    confirmTitle = 'Confirm this plate?',
}