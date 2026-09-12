-- tenx-adminjail/config.lua
-- SHARED settings (runs on client + server). No secrets here.
-- The admin allowlist lives in server/permissions.lua so player licenses are
-- NEVER shipped to clients (security standard: no secrets in client files).

Config = {}

-- Command that opens the admin punishment menu in-city.
Config.Command = 'adminjail'

-- Optional keybind to open the menu. Set to a key name (e.g. 'F7') or nil to disable.
-- Players can rebind it in GTA settings > Key Bindings > FiveM.
Config.OpenKeybind = nil

-- ============================================================
--  LOGGING
-- ============================================================
-- Discord webhook URL for punishment logs. Leave '' to disable Discord logging.
Config.Webhook = ''

-- Broadcast punishments to public city chat (the "public shaming" layer).
Config.PublicBroadcast = true
Config.BroadcastTag    = 'ADMIN'
Config.BroadcastColor  = { 255, 60, 60 }  -- RGB

-- ============================================================
--  RESOURCES ON YOUR SERVER
-- ============================================================
Config.TargetResource    = 'ox_target'
Config.InventoryResource = 'ox_inventory'

-- ============================================================
--  RESTART / RESYNC
-- ============================================================
-- On resource start, the server sweeps every online player and re-applies any
-- punishment still marked 'active' in the DB. Timers resume from time_served,
-- community service resumes from its saved job count.
-- Delay before that sweep runs (ms) — gives qb-core/oxmysql/the client time to load.
Config.RestartResyncDelay = 3000
-- Print a line to the server console listing who got re-applied on restart.
Config.RestartResyncLog   = true

-- ============================================================
--  LOCATION CAPTURE (shared save tool: jails / cleaning / release point)
-- ============================================================
Config.SaveKey   = 38  -- E
Config.CancelKey = 73  -- X

-- ============================================================
--  PROPS — GLOBAL NOTE
-- ============================================================
-- Every prop below is validated with IsModelValid() before it spawns. A bad
-- model name will NOT crash anything — it just gets skipped and prints a warning
-- to the client console (F8). So swapping models is safe: change the string,
-- restart, check F8.
--   bone   : ped bone index to attach to. 28422 = PH_R_Hand (right hand),
--            60309 = PH_L_Hand (left hand), 24818 = SKEL_R_Forearm.
--   pos/rot: attachment offset. THESE ALWAYS NEED EYEBALLING per prop.
--   ground : mess props only. true = drop to floor, false = leave at exact
--            offset height (use false for wall props).

-- ============================================================
--  HARD CUFF (Type #1)
-- ============================================================
Config.Cuff = {
    animDict = 'mp_arresting',
    animName = 'idle',
    -- If a cuffed player is dragged/carried beyond this many metres from where
    -- they were cuffed, they are snapped back (server + client enforced).
    leashDistance = 2.5,
    -- Handcuff prop on the wrists. Set to {} to disable entirely.
    -- Offsets below are a starting point — tune pos/rot until it sits right.
    props = {
        { model = 'p_cs_cuffs_02', bone = 60309,
          pos = { x = 0.0, y = 0.03, z = 0.0 },
          rot = { x = 0.0, y = 0.0,  z = 0.0 } },
    },
}

-- ============================================================
--  RELEASE (shared lifecycle: every punishment ends the same way)
-- ============================================================
Config.TeleportOnRelease = true

-- ============================================================
--  ADMIN JAIL (Type #2)
-- ============================================================
Config.Jail = {
    defaultRadius   = 30.0,          -- default leash radius when you save a jail
    tickSeconds     = 15,            -- server timer granularity (online-only accrual)
    overlayText     = 'ADMIN JAIL',  -- flashing text at the moment of jailing
    overlayDuration = 4000,          -- ms the flash stays on screen
    disabledControls = { 38 },       -- 38 = E
}

-- ============================================================
--  COMMUNITY SERVICE (Type #3)
-- ============================================================
Config.CommunityService = {
    defaultJobs      = 5,        -- jobs to complete if the admin doesn't specify
    disabledControls = { 38 },   -- E (outfit-protection)
    cleanRadius      = 2.5,      -- how close to a spot before cleaning auto-starts
    cleanDuration    = 8000,     -- ms per cleaning action
    vehicleModel     = 'rhapsody',
    vehiclePlate     = 'CSERVICE',

    -- Vehicle keys. Set to nil to disable. Called client-side right after spawn:
    --   exports[resource][method](plate)
    vehicleKeys = { resource = 'ak47_qb_vehiclekeys', method = 'GiveVirtualKey' },

    -- Uniform applied while serving (natives — works on ANY appearance system).
    -- Components: 11 = tops, 3 = arms, 8 = undershirt, 4 = legs, 6 = shoes.
    uniform = {
        male = {
            { component = 11, drawable = 53, texture = 1 },
            { component = 3,  drawable = 1,  texture = 0 },
            { component = 8,  drawable = 15, texture = 0 },
            { component = 4,  drawable = 35, texture = 0 },
            { component = 6,  drawable = 25, texture = 0 },
        },
        female = {
            { component = 11, drawable = 56, texture = 1 },
            { component = 3,  drawable = 1,  texture = 0 },
            { component = 8,  drawable = 17, texture = 0 },
            { component = 4,  drawable = 37, texture = 0 },
            { component = 6,  drawable = 25, texture = 0 },
        },
    },

    -- RESTORE on release: set ONE of these to how your server reloads a player's
    -- real outfit. If both nil, falls back to the server's qb-clothing reload.
    restoreSkinEvent  = nil,  -- e.g. 'qb-clothing:client:loadOutfit'
    restoreSkinExport = nil,  -- e.g. { resource = 'illenium-appearance', method = 'reloadSkin' }

    -- ========================================================
    --  JOB TYPES  (replaces the old `anims` table)
    -- ========================================================
    -- Each job type defines:
    --   anim      : the emote played during the progress bar
    --   handProps : props attached to the player WHILE cleaning (deleted after)
    --   messProps : the "mess" spawned at the spot, deleted when the job is done.
    --               Offsets are relative to the saved spot's coords + heading,
    --               so +y = the direction the admin was facing when they saved it.
    --               (Face the wall when saving a scrub_wall spot.)
    -- These props are LOCAL to the punished player (not networked) — nobody else
    -- sees them, and they can never leak into the world if the script dies.
    jobs = {
        mop = {
            label = 'Mop the floor',
            anim = { dict = 'amb@world_human_janitor@male@idle_a', name = 'idle_a' },
            handProps = {
                { model = 'prop_tool_mop', bone = 28422,
                  pos = { x = 0.0, y = 0.0, z = 0.0 },
                  rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            messProps = {
                -- GTA has no puddle prop, so mopping = bucket + spilled junk.
                { model = 'prop_bucket_01a',   offset = { x = 0.9,  y = 0.3, z = 0.0 }, heading = 0.0,  ground = true },
                { model = 'prop_rub_flotsam_03', offset = { x = -0.3, y = 0.4, z = 0.0 }, heading = 40.0, ground = true },
            },
        },
        sweep = {
            label = 'Sweep the floor',
            anim = { dict = 'amb@world_human_janitor@male@idle_a', name = 'idle_a' },
            handProps = {
                { model = 'prop_tool_broom', bone = 28422,
                  pos = { x = 0.0, y = 0.0, z = 0.0 },
                  rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            messProps = {
                { model = 'prop_rub_flotsam_03',  offset = { x = 0.4,  y = 0.2, z = 0.0 }, heading = 0.0,   ground = true },
                { model = 'prop_cs_rub_flyers_01', offset = { x = -0.5, y = 0.5, z = 0.0 }, heading = 90.0,  ground = true },
                { model = 'prop_rub_cardpile_01', offset = { x = 0.1,  y = 0.8, z = 0.0 }, heading = 200.0, ground = true },
            },
        },
        scrub_wall = {
            label = 'Scrub the wall',
            anim = { dict = 'amb@prop_human_bum_bin@base', name = 'base' },
            handProps = {
                { model = 'prop_rag_01', bone = 28422,
                  pos = { x = 0.0, y = 0.0, z = 0.0 },
                  rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            messProps = {
                -- Vanilla GTA has no "dirty wall" prop. Best vanilla stand-in is
                -- junk at the base of the wall. If you want actual grime/graffiti,
                -- stream a graffiti prop and put its model name here with
                -- ground = false so it stays at wall height.
                { model = 'prop_rub_flotsam_03', offset = { x = 0.0,  y = 0.6, z = 0.0 }, heading = 0.0,  ground = true },
                { model = 'prop_rub_binbag_01',  offset = { x = 0.7,  y = 0.5, z = 0.0 }, heading = 30.0, ground = true },
            },
        },
        trash = {
            label = 'Pick up trash',
            anim = { dict = 'anim@amb@drug_field_workers@rake@male_a@base', name = 'base' },
            handProps = {
                { model = 'prop_cs_rub_binbag_01', bone = 28422,
                  pos = { x = 0.0, y = 0.0, z = 0.0 },
                  rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            messProps = {
                { model = 'prop_rub_binbag_01',   offset = { x = 0.5,  y = 0.3, z = 0.0 }, heading = 0.0,   ground = true },
                { model = 'prop_rub_binbag_01',   offset = { x = -0.6, y = 0.6, z = 0.0 }, heading = 120.0, ground = true },
                { model = 'prop_rub_flotsam_03',  offset = { x = 0.0,  y = 0.9, z = 0.0 }, heading = 60.0,  ground = true },
            },
        },
    },
}
