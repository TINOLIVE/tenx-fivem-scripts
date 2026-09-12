Config = {}

-- ===== Interaction =====
Config.RobDistance       = 2.5    -- ox_target reach for the "Rob Player" option
Config.ServerMaxDistance = 5.0    -- server-side anti-cheat distance (must be near to rob)

-- ===== Loot =====
Config.ItemsAlive = 3             -- items taken from a hands-up (alive) player
Config.ItemsDead  = 6             -- items taken from a downed/dead player
Config.DurationAlive = 10000       -- progress bar ms (alive)
Config.DurationDead  = 20000       -- progress bar ms (dead)

-- ============================================================
--  ANTI-ABUSE RULESET (v3)
-- ============================================================

-- ===== 1. PROXIMITY REQUIREMENT =====
-- You must have been near the victim, CONTINUOUSLY, while they were ALIVE,
-- for this long before you may rob them. Walking away resets the timer to zero.
--
-- ⚠️ radius 20 + required 120 is moderately strict. Twenty metres is ~four car lengths.
-- A normal firefight happens at 30-60m, which earns ZERO time. If your players
-- report they can never rob anyone, this is why — raise radius first (25-30),
-- then lower required.
Config.Proximity = {
    enabled  = true,
    radius   = 30.0,   -- metres. must be within this to accrue time
    required = 10,    -- seconds of unbroken proximity needed (120 = 2 min)
    grace    = 5,
    tick     = 1000,
}

-- ===== 2. ONE LOOT PER DEATH =====
-- Once a body has been looted, that death is spent. They cannot be looted again
-- until they die a NEW time. Not a timer — a hard once-per-death lock.
-- (Applies to ANY robber, not just the one who looted them.)
Config.RobOncePerDeath = true

-- ===== 3. PAIR COOLDOWN =====
-- The same robber cannot rob the same victim again until this many seconds pass.
Config.PairCooldown = 900         -- 15 minutes

-- ===== 4. SCENE LIMIT =====
-- A robber may rob this many DIFFERENT people, then is locked out completely.
-- Covers the 3v1 case: rob all three, then nobody at all until the window ends.
Config.SceneLimit = {
    count  = 3,       -- robberies allowed before lockout. 0 = off
    window = 600,     -- seconds of total lockout after hitting the cap (15 min)
}

-- ===== 5. WITNESS AT DEATH =====
-- To loot a BODY you must have been within Proximity.radius at the exact moment
-- they died. Turn up after the fight is over and the body is not yours to loot.
Config.RequireWitnessAtDeath = false

-- ===== 6. VEHICLE KILLS ARE NOT ROBBABLE =====
-- Ran over / rammed = no loot. Kills the "car them down then loot" pattern.
Config.BlockVehicleKills = true
-- Death causes counted as vehicle kills. The script ALSO checks whether the
-- source entity was a vehicle, which catches cases these hashes miss.
Config.VehicleDeathWeapons = {
    'WEAPON_RUN_OVER_BY_CAR',
    'WEAPON_RAMMED_BY_CAR',
    'WEAPON_RUN_OVER_BY_BOAT',
    'WEAPON_HELI_CRASH',
}

-- ===== 7. MINIGAME =====
-- ox_lib skill check. A table = several checks in a row, all must pass.
-- Difficulties: 'easy' | 'medium' | 'hard' | { areaSize = n, speedMultiplier = n }
Config.SkillCheck = {
    enabled = true,
    alive   = { 'easy', 'medium' },            -- hands-up rob
    dead    = { 'easy', 'easy', 'medium' },    -- body loot: longer, you're exposed
    keys    = { 'w', 'a', 's', 'd' },
}

-- ===== 8. DISPATCH (ps-dispatch) =====
-- Fires THE MOMENT "Rob Player" is clicked — before the eligibility check,
-- before the minigame, before the progress bar. Cops are called even if the
-- robbery then fails, is cancelled, or the player was never allowed to rob.
--
-- Coords come from the SERVER (the victim's real position), not the robber's
-- client, so a modded client cannot send police to a fake location.
--
-- ⚠️ Because it fires on the literal click, someone CAN spam the eye to spam
-- dispatch. Cooldown below is the only thing standing between your police and
-- a griefer. Do not set it to 0.
Config.Dispatch = {
    enabled  = true,
    cooldown = 30,    -- seconds per robber between alerts. anti-spam. keep > 0

    -- alert on which robs
    onAlive  = true,  -- hands-up rob
    onDead   = true,  -- body loot

    jobs     = { 'police' },   -- who receives it

    alive = {
        code        = '10-31',
        message     = 'Robbery in Progress',
        description = 'Person being robbed',
        sprite      = 51,
        color       = 1,
        scale       = 1.0,
        length      = 3,
    },
    dead = {
        code        = '10-15',
        message     = 'Body Being Looted',
        description = 'Suspect looting a body',
        sprite      = 51,
        color       = 1,
        scale       = 1.0,
        length      = 3,
    },
}


-- ============================================================
--  LEGACY RULES (still active)
-- ============================================================
Config.AllowRobInVehicle = false  -- can you rob someone sitting in a car?
Config.AllowRobCuffed    = true   -- treat cuffed players as a hands-up rob (3 items)

-- 6-item loot only applies when the victim is FLAT DEAD (QB isdead).
-- true = also loot players still bleeding out (laststand).
Config.RobWhileDowned    = false

-- How many separate robberies ONE victim can suffer in the window. 0 = unlimited.
Config.MaxRobsPerVictim = 3
Config.MaxRobsResetTime = 600     -- seconds until a victim's rob count resets

-- ===== Anti-cheat =====
Config.UseRobbableState = true
Config.StatePoll        = 600     -- ms between robbable-state checks
Config.DeadHealth       = 125     -- fallback "dead" health threshold

-- items that can NEVER be robbed (ids, phone, etc). add item names as needed.
Config.Blacklist = {
    ['phone']          = true,
    ['WEAPON_PDNAIJA']         = true,
    ['key']                    = true,
    ['gpstracker']             = true,
    ['armour']                 = true,
    ['uvlight']                = true,
    ['policepouches']          = true,
    ['drugtestkit']            = true,
    ['fingerprint_scanner']    = true,
    ['breathalyzer']           = true,
    ['barrier']                = true,
    ['worklight']              = true,
    ['dash_cam']               = true,
    ['WEAPON_FLASHLIGHT']      = true,
    ['spike_strips']           = true,
    ['anklemonitor']           = true,
    ['policepouches1']         = true,
    ['metal_riot_shield']      = true,
    ['glass_riot_shield']      = true,
    ['night_vision_goggles']   = true,
    ['thermal_vision_goggles'] = true,
    ['cone']                   = true,
    ['bodycam']                = true,
    ['WEAPON_ASPBATON']        = true,
    ['WEAPON_TASERX']          = true,
    ['WEAPON_GTASERX']         = true,
    ['WEAPON_PDGLOCK17']       = true,
    ['WEAPON_GLOCK20']         = true,
    ['WEAPON_SWMP9L']          = true,
    ['WEAPON_SIG_SAUCER']      = true,
    ['WEAPON_BEANBAG']         = true,
    ['WEAPON_BEANBAG2']        = true,
    ['WEAPON_AR15']            = true,
    ['WEAPON_M4A1CD']          = true,
    ['WEAPON_HK416']           = true,
    ['WEAPON_KS1']             = true,
    ['WEAPON_M870']            = true,
    ['WEAPON_PDPT700']         = true,
    ['WEAPON_LESSLAUNCHER']    = true,
    ['ammo-9pd']               = true,
    ['ammo-beanbag']           = true,
    ['ammo-riflepd']           = true,
    ['ammo-shotgun']           = true,
    ['ammo-sniperpd']          = true,
    ['ammo-40mm']              = true,

    -- EMS / medical items (ambulancejob) — never robbable
    ['armbrace']     = true,
    ['bandage']      = true,
    ['bodybandage']  = true,
    ['legbrace']     = true,
    ['lucas3']       = true,
    ['medicalbag']   = true,
    ['medicinebox']  = true,
    ['morphine10']   = true,
    ['morphine30']   = true,
    ['neckbrace']    = true,
    ['saline']       = true,
    ['stretcher']    = true,
    ['syringe']      = true,
    ['wheelchair']   = true,
    ['xray']         = true,
}

-- ===== Loot priority =====
-- Items here are ALWAYS grabbed FIRST. Higher number = taken earlier.
Config.PriorityItems = {
    ['money']        = 50,
    ['stolen_money'] = 100,
    ['black_money']  = 100,
    ['gold_bar']     = 90,
}

-- ===== Hands-up animations =====
Config.HandsUpAnims = {
    { dict = 'missminuteman_1ig_2',  clip = 'handsup_base' },
    { dict = 'missminuteman_1ig_2',  clip = 'handsup_enter' },
    { dict = 'random@mugging3',      clip = 'handsup_standing_base' },
    { dict = 'random@arrests',       clip = 'idle_2_hands_up' },
    { dict = 'random@arrests@busted',clip = 'idle_a' },
    { dict = 'anim@gangops@hostage@',clip = 'perp_idle' },
}

-- ===== Discord screenshot (client-visible settings only) =====
-- WEBHOOK URLS LIVE IN config_server.lua. Do not move them here.
Config.Screenshot = {
    Enabled = true,
    Quality = 0.75,
    Timeout = 10000,
}
