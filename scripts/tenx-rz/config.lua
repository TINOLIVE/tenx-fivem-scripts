Config = {}

-- ============================================================
--  STAFF ACCESS
-- ============================================================
-- Anyone listed here can run the FFA commands AND is skipped by the
-- confiscation sweep, so you can stand in your own arena and spectate
-- without losing your inventory.
--
-- Get a player's license with:  /ffawhoami   (run it in game yourself)
-- Paste the full string including the "license:" prefix.
Config.Staff = {
    ['license:PUT_YOUR_LICENSE_IDENTIFIER_HERE'] = 'Tino',
    -- ['license:1111111111111111111111111111111111111111'] = 'Duel',
}

-- Optional: also allow anyone with this ace permission to run the commands.
-- Leave as false to rely on the Config.Staff list only.
Config.AcePermission = 'tx.ffa' -- set to false to disable

-- Should staff on the list be skipped by the sweep?
-- true  = staff can stand in the arena and spectate untouched
-- false = staff get swept like everyone else
--
-- This only ever applies to being caught INCIDENTALLY. A staff member who
-- signs up at the ped or joins the queue has said they want to play, and is
-- treated as a player from that point regardless of what this is set to.
Config.StaffImmune = false

-- Staff who join the queue play the round properly: swept in, given the
-- loadout, dropped with everyone else, counted in the alive total, eligible
-- to win. Being an admin should not mean never getting to play.
Config.StaffCanPlay = true

-- ============================================================
--  THE QUEUE PED
-- ============================================================
-- A ped standing somewhere public with floating text over its head. Players
-- walk up, join the queue, and carry on with whatever they were doing --
-- anywhere in the city. When you start a round, everyone queued is swept and
-- dropped into the arena wherever they happen to be standing.
Config.Queue = {
    enabled = true,

    ped = {
        model = 's_m_y_blackops_01',
        coords = vec4(4440.90, -4464.63, 4.33, 196.61),
        scenario = 'WORLD_HUMAN_GUARD_STAND',
        freeze = true,
        invincible = true,
    },

    -- Floating text over the ped's head.
    label = 'Join Battle Royale',
    sublabel = 'Red Zone',

    -- Use ox_target instead of a press-E prompt.
    useTarget = false,
    interactDistance = 2.5,
    drawDistance = 25.0,

    -- Cap so a start can't sweep more people than you meant to.
    maxQueue = 64,

    -- Seconds of warning before queued players are pulled in.
    -- 0 pulls them the instant you press start.
    warning = 5,

    -- Map blip for the ped.
    blip = {
        enabled = true,
        sprite = 313,
        colour = 2,
        scale = 0.8,
        shortRange = true,
        label = 'Red Zone Sign-up',
    },
}

-- ============================================================
--  NO-SPAWN AREAS
-- ============================================================
-- Places the drop-in and the loot scatter will never use.
Config.NoSpawn = {
    -- Water is checked automatically on the client before anyone is placed,
    -- which covers the sea and every lake without you marking a thing.
    -- Leave this on; the zones below are for everything else.
    avoidWater = true,

    -- How many times to look for a clear point before giving up on one.
    attempts = 40,

    -- Marked areas. Add them in the panel by standing somewhere and pressing
    -- "Mark where I'm standing" -- no need to type coordinates.
    zones = {
        -- { x = 4900.0, y = -5200.0, radius = 60.0, label = 'Airstrip' },
    },
}

-- ============================================================
--  THE LOBBY
-- ============================================================
-- Where players gather BEFORE a round. When you run /ffastart, everyone
-- standing inside this radius is swept and thrown into the arena.
-- This is the pickup point, not the play area.
-- Legacy pickup method: sweep whoever is standing in a radius. Leave this off
-- when the queue ped is doing the job, or turn it on to use both.
Config.Lobby = {
    enabled = false,
    coords = vec3(4443.00, -4469.78, 4.33),
    radius = 50.0,
}

-- ============================================================
--  THE ARENA
-- ============================================================
-- Fixed centre for the play area. Set to false to use wherever you're
-- standing when you type /ffastart.
--
-- Worth setting: if you start the round from the lobby, the arena ends up
-- centred on the lobby, which is also where dead players get sent. Pinning
-- the centre somewhere else keeps the three apart.
Config.ArenaCentre = false -- e.g. vec3(4800.0, -5000.0, 20.0)

-- Default radius in metres if you type /ffastart with no number.
Config.DefaultRadius = 1000.0

-- Hard cap so a typo like /ffastart 5000 can't strip half the server.
Config.MaxRadius = 1000.0

-- Show a confirmation dialog with the head count before anything is taken.
-- Strongly recommended. Set false only if you know what you're doing.
Config.ConfirmBeforeStart = true

-- ============================================================
--  THE LOADOUT
-- ============================================================
-- What every player gets handed when they're swept into the arena.
-- Item names must exist in ox_inventory (weapons in data/weapons.lua).
Config.Loadout = {
    { name = 'WEAPON_COMBATPISTOL', count = 1 },
    { name = 'cookies',             count = 5 },
    { name = 'firstaid',            count = 1 },
}

-- The weapon infinite ammo applies to. Must match one of the entries above.
Config.PrimaryWeapon = 'WEAPON_COMBATPISTOL'

-- Ammo handling for the primary weapon. Pick ONE:
--   'infinite' = never runs dry, no reloading fuss
--   'fixed'    = weapon spawns loaded with Config.FixedAmmo rounds, no refills
--   'items'    = also gives ammo items so they can reload
Config.AmmoMode = 'items'

Config.FixedAmmo = 60      -- used by 'fixed' and as the starting magazine for 'items'
Config.AmmoItem = 'ammo-9' -- used by 'items' only
Config.AmmoItemCount = 120 -- used by 'items' only

-- ============================================================
--  GROUND LOOT
-- ============================================================
-- Item piles scattered around the arena floor for players to find.
Config.Loot = {
    enabled = true,

    -- Each entry drops `piles` separate piles, each containing `count` of the item.
    -- So the pistol line below puts 5 pistols on the ground, one per pile.
    items = {
        { name = 'WEAPON_APPISTOL', count = 1,   piles = 5,  metadata = { ammo = 0 } },
        { name = 'ammo-9',              count = 200, piles = 10 },
        { name = 'cookies',             count = 3,   piles = 15 },
        { name = 'firstaid',            count = 1,   piles = 8  },
        { name = 'bandage',             count = 2,   piles = 12 },
    },

    -- Don't bunch everything at the middle. Fraction of the radius kept clear
    -- around the centre point.
    minDistanceFactor = 0.10,

    -- Keep loot away from the very edge too, so nothing spawns in the sea or
    -- somewhere the ring is about to make lethal.
    maxDistanceFactor = 0.90,

    -- Drop a fresh batch periodically so long rounds don't run dry.
    -- Replenished loot always spawns inside the CURRENT ring, not the original.
    respawn = true,
    respawnInterval = 120,  -- seconds
    respawnFraction = 0.4,  -- fraction of the normal batch size per replenish

    -- How close you have to be for the [E] prompt to appear.
    collectDistance = 2.0,

    -- How far away piles are drawn. Blips still show from any distance.
    drawDistance = 80.0,

    -- Each pile draws a flat circle on the ground sized to collectDistance,
    -- so the pickup area is exactly what you see, plus a cone above it.
    marker = {
        scale = 0.5,        -- cone size
        height = 1.2,       -- cone height above the ground
        cone = true,        -- set false for the ground circle only
        r = 90, g = 220, b = 120,
        a = 180,            -- cone opacity
        circleAlpha = 90,   -- ground circle opacity
    },

    -- Map blips so players can find the piles from a distance.
    blip = {
        enabled = true,
        sprite = 478,       -- package icon. Change if you'd prefer another.
        colour = 2,         -- 2 = green
        scale = 0.7,
        shortRange = true,  -- only shows when nearby, keeps the world map clean
        label = 'Supplies',
    },

}

-- ============================================================
--  AIRDROP
-- ============================================================
-- A single high-value crate that lands partway through the round at a random
-- spot inside the CURRENT ring. Marked with a big red beam and a map blip
-- everyone can see, so the whole lobby converges on it.
Config.Airdrop = {
    enabled = true,

    -- Seconds after the round starts. 150 is roughly halfway through a
    -- 5 minute round. Set a table like { 90, 210 } for multiple drops.
    spawnAfter = 150,

    -- Big centre-screen announcement and a notification when it lands.
    announce = true,

    -- Everything in the crate goes to whoever opens it.
    -- NOTE: WEAPON_DUELX must match the item name in your ox_inventory
    -- weapons.lua exactly, including case. Check it before you run this.
    items = {
        { name = 'WEAPON_certifiedtweakerz', count = 1 },
        { name = 'cookies',      count = 20 },
        { name = 'firstaid',     count = 10 },
    },

    label = 'Airdrop',
    collectDistance = 3.0,  -- bigger than normal loot, it's a crate

    -- The big red box. Drawn much larger than a supply pile.
    marker = {
        scale = 3.0,        -- width of the beam
        height = 4.0,       -- how tall it stands
        r = 235, g = 45, b = 45,
        a = 130,
        circleAlpha = 110,
    },

    -- Red, larger, and NOT short range, so it shows on the map from anywhere.
    blip = {
        enabled = true,
        sprite = 478,
        colour = 1,         -- 1 = red
        scale = 1.1,
        shortRange = false,
        label = 'Airdrop',
    },
}

-- ============================================================
--  THE DROP
-- ============================================================
-- Instead of appearing on the ground, players are dropped in from height with
-- a parachute and glide down to wherever they fancy. It solves the spawn
-- problem on its own: nobody lands on top of anybody, and people pick their
-- own landing spot.
Config.Drop = {
    enabled = true,

    -- Metres above the ground they start falling from.
    height = 320.0,

    -- Auto-open if they are still falling this low. Someone who has never
    -- used a parachute would otherwise hit the ground and die before the
    -- round has begun, which is a bad first thirty seconds.
    autoOpenAt = 90.0,

    -- No fall damage during the drop, however badly it goes.
    protectUntilLanded = true,

    -- On-screen instructions while they're in the air.
    showControls = true,

    -- Seconds the control prompt stays up.
    controlsDuration = 12,
}

-- ============================================================
--  START SCATTER
-- ============================================================
-- When the event starts, everyone swept in gets thrown to a random spot
-- inside the ring so the round doesn't begin with everyone bunched together.
-- This fires ONCE, on start only. Players who walk in mid-round stay where
-- they entered, and it never touches the death-to-holding-area teleport.
Config.StartScatter = {
    enabled = true,

    -- Metres to try and keep between players. Best effort, not guaranteed.
    minSpacing = 40.0,

    -- Where in the ring people land, as a fraction of the radius.
    -- Kept well inside so nobody starts 900m out on a 1000m arena with
    -- a five minute clock. Raise maxDistanceFactor for a more spread start.
    minDistanceFactor = 0.05,
    maxDistanceFactor = 0.45,

    -- How many times to retry for a well-spaced point before accepting one.
    attempts = 30,

    -- Maximum seconds to wait for terrain to stream in before placing someone.
    -- This is a ceiling, not a fixed wait: fast machines land almost instantly,
    -- slow ones get as long as they need. Players are frozen and invincible
    -- for the whole wait, so nobody takes fall damage regardless of hardware.
    settleTime = 20,
}

-- ============================================================
--  DEATH & ELIMINATION
-- ============================================================
-- Die in the arena and you're OUT for the round. Rather than leaving you face
-- down on the floor for ten minutes, you get revived, healed, and moved to a
-- holding area to wait out the rest of the event in comfort.
Config.Respawn = {
    enabled = true,

    -- Holding area. Deliberately well outside the arena.
    coords = vec4(4442.50, -4465.63, 4.33, 203.09),

    -- Land them at a random point within this many metres of the coord above,
    -- so twenty dead players don't end up stacked on one pixel.
    -- Set to 0 to put everyone on the exact spot.
    spread = 50.0,

    -- Seconds on the floor before they get picked up and moved.
    delay = 3,

    health = 200,   -- QBCore max health is 200
    armour = 50,

    -- Clear everything off them when eliminated. Their real inventory is
    -- already safe in the database, so this costs nothing and stops the
    -- holding area turning into its own deathmatch with looted pistols.
    disarm = true,

    -- Make eliminated players unkillable while they wait. Also recommended,
    -- for the same reason.
    godmode = true,

    -- When the event ends, pull the survivors to the holding area too, so
    -- everyone finishes in the same place and gets their inventory there.
    gatherSurvivorsOnEnd = true,
}

-- ============================================================
--  THE ZONE
-- ============================================================
-- Built the way Call of Duty actually does it, which is not what a plain
-- shrinking circle does.
--
-- THE CIRCLE MOVES. Each new safe zone is a smaller circle placed at a NEW
-- position inside the current one, not concentric with it. That is the whole
-- game: you can see where the next circle will be during the wait, and you
-- have to rotate to it. A circle that always shrinks toward the same point
-- means nobody ever has to move, which is why the old version felt flat.
--
-- Each phase has two parts, same as Warzone: a WAIT where the next circle is
-- announced and drawn on your map but nothing moves, then a CLOSE where the
-- ring travels to its new centre and shrinks at the same time.
--
-- You still set one number for the whole thing.
Config.Shrink = {
    enabled = true,

    -- Total time from full size to fully closed.
    totalDuration = 30 * 60,

    -- Seconds before the first circle is even announced. Comes out of the total.
    startDelay = 90,

    -- How far the next circle is allowed to move from the current centre.
    --   1.0 = anywhere it still fits fully inside the current circle
    --   0.5 = drifts, but stays fairly central
    --   0.0 = concentric, never moves (the old behaviour)
    drift = 1.0,

    -- radius: what it shrinks TO, as a fraction of the starting radius.
    -- damage: health per second taken while that phase is the current one.
    --
    -- Warzone's gas is a flat 8.5 a second the whole match -- about 12 seconds
    -- to die. These escalate instead, as you asked, but they're calibrated
    -- around that number so the middle of the match feels like the real thing
    -- rather than a scratch at the start and instant death at the end.
    --
    --   damage 2    -> 50s to die       damage 12  -> 8s
    --   damage 4    -> 25s              damage 18  -> 5.5s
    --   damage 6    -> 17s              damage 25  -> 4s
    --   damage 8.5  -> 12s  (Warzone)
    phases = {
        { radius = 0.72, damage = 2    },
        { radius = 0.52, damage = 4    },
        { radius = 0.36, damage = 6    },
        { radius = 0.22, damage = 8.5  },
        { radius = 0.11, damage = 12   },
        { radius = 0.04, damage = 18   },
        { radius = 0.00, damage = 25   },   -- fully closed, whole map lethal
    },

    -- Of each phase's time, how much is the wait before the ring starts
    -- moving. 0.6 means 60% announced-and-still, 40% travelling.
    holdFraction = 0.6,
}

-- ============================================================
--  THE ZONE WALL
-- ============================================================
-- The visible barrier at the ring's edge, so players can see exactly where
-- the boundary is and watch it come in.
Config.ZoneWall = {
    enabled = true,

    -- 'wall'   = a curved wall along the boundary nearest you. The right
    --            choice for a big arena: you see the edge when it matters and
    --            it costs nothing when you're nowhere near it.
    -- 'sphere' = one dome over the whole zone. Reads well once the ring is
    --            small; on a 1000m arena the far side is beyond draw distance
    --            so you mostly see the near wall of it anyway.
    style = 'sphere',

    colour = { r = 30, g = 30, b = 30 },   -- black wall (Naija palette)
    alpha = 120,

    height = 12.0,      -- how tall the wall stands
    segments = 34,      -- pieces across the visible arc; more = smoother
    arc = 90.0,         -- degrees of the ring drawn either side of you
    drawWithin = 220.0, -- only drawn when you're this close to the edge

    -- The wall pulses while a close is running, so the warning is something
    -- you feel rather than something you have to read.
    pulse = true,

    -- Only players in the round see it. This is an RP city -- someone driving
    -- past Cayo should not find a black wall across the road.
    showToEveryone = false,
}

-- ============================================================
--  RING DAMAGE
-- ============================================================
-- Damage now comes from whichever phase the ring is CURRENTLY in, not from
-- where you happen to be standing. Once phase four starts, everyone outside
-- the ring takes phase four's damage no matter how far out they are -- so
-- running back to where the first ring used to be buys you nothing.
Config.RingDamage = {
    enabled = true,
    tickInterval = 1000,   -- ms between damage ticks
    lethal = true,         -- can the ring finish someone off
    warn = true,           -- on-screen warning while outside
}
-- ============================================================
--  AMBULANCE INTEGRATION
-- ============================================================
-- Your ambulance resource. Used to build the revive/skellyfix trigger names.
Config.AmbulanceResource = 'ak47_qb_ambulancejob'

-- Clear skelly (limb) damage when reviving.
-- Leave this ON. ak47's skelly damage survives a plain revive, so without it
-- players accumulate limb injuries and walk out of the arena with driving
-- penalties they'd have to pay a doctor to fix.
Config.FixSkellyOnRevive = true

-- Milliseconds to WAIT before firing their revive. This is the important one.
--
-- Their death screen takes a while to come up. Revive too early and it lands
-- before the screen exists -- the screen then appears anyway, with nothing
-- left to dismiss it, and sits on the player while they walk around alive.
--
-- So: let their screen finish appearing, THEN revive, and the revive has
-- something to close. Raise it if the screen still sticks.
Config.ReviveDelay = 1500

-- Fire the revive once more a beat later, in case their screen came up later
-- than usual. Reviving an already-alive player does nothing.
Config.ReviveRetry = true
Config.ReviveRetryDelay = 2000

-- Milliseconds to wait after the revive before clearing limb damage.
--
-- Their revive takes a moment to settle, and a skellyfix fired too early
-- lands on a revive that hasn't finished -- it does nothing, and the injuries
-- survive. If players are still leaving rounds with damaged limbs, raise
-- this. 400 is a guess at their timing, not a measurement.
Config.SkellyDelay = 400

-- Fire it once more a beat later, in case the first landed early. Costs one
-- extra event and nothing else.
Config.SkellyRetry = true
Config.SkellyRetryDelay = 1500

-- Auto-end the event when only one player is left standing.
-- Now that death means elimination, this actually works, and it's the thing
-- that stops eliminated players sitting in the holding area waiting on you.
Config.AutoEndLastManStanding = true

-- Seconds to wait after the last man is standing before auto-ending.
-- Gives the winner a moment instead of yanking them instantly.
Config.AutoEndDelay = 10

-- ============================================================
--  SAFETY NET
-- ============================================================
-- If an item somehow can't be put back (weight edge cases, e.g. a backpack
-- that raised max weight was itself in the inventory), it goes into a
-- personal recovery stash instead of vanishing. Open it with /ffarecover <id>.
Config.RecoveryStashSlots = 100
Config.RecoveryStashWeight = 1000000

-- Print every take and every restore to the server console.
Config.Debug = true

-- ============================================================
--  NOTIFICATIONS
-- ============================================================
-- Where ox_lib notifications appear. ox_lib has no true dead-centre option.
-- Valid: 'top' 'top-right' 'top-left' 'bottom' 'bottom-right' 'bottom-left'
--        'center-right' 'center-left'
Config.NotifyPosition = 'center-right'

-- The alive counter, kill feed and the drop-down banner are real interface
-- elements now, laid out in html/style.css rather than drawn on the screen.
-- Move or restyle them there; only the timing lives here.
Config.Hud = {
    enabled = true,
    feedLength = 5,    -- how many kill lines to keep on screen
    feedDuration = 8,  -- seconds each line stays
}

Config.Text = {
    stripped      = 'Your inventory has been stored. Fight.',
    restored      = 'Your inventory has been returned in full.',
    entered       = 'You entered the arena.',
    no_permission = 'You are not allowed to do that.',
    already_live  = 'An FFA event is already running. End it first.',
    not_live      = 'No FFA event is running.',
    event_started = 'FFA started. %s players swept, %sm radius.',
    event_ended   = 'FFA ended. %s players restored.',
    take_failed   = 'Could not store your inventory safely, so it was left alone. Tell an admin.',
}
