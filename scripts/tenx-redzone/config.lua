Config = Config or {}

-- ============================================================
--  NAIJA 2046 — RED ZONE
-- ============================================================
-- Always-on free-for-all. You pick a zone, get dropped just outside it with
-- whatever you own, and walk in. No matchmaking, no rooms, no waiting.
--
-- This is its own resource. It borrows the arena's shapes, inventory and
-- coins rather than keeping copies -- see ARENA below.

Config.RZ = {
    -- The resource this talks to. Everything about what a player owns lives
    -- there: change this only if you renamed it.
    arena = 'tenx-arena',

    -- Routing buckets. Kept clear of the arena's own range (2046, 4200+) so
    -- the two can never collide.
    bucketBase = 2100,

    -- Which of the arena's zones can be used, by name. Empty means all of
    -- them that have Red Zone spawns marked.
    --
    -- Only read when Config.RZ.zones.useExternal is OFF. With the handover on,
    -- the set of zones is whatever carries the tag, and filtering by name on
    -- top of that would be a second place to look when a zone does not appear.
    onlyZones = {},

    -- SUPERSEDED by Config.RZ.down.delay below.
    --
    -- Kept only so an older config or anything still reading this name keeps
    -- working. Change the one below; this is ignored when it exists.
    respawnDelay = 10.0,



    -- Untouchable for this long after being placed, so nobody can be camped
    -- at a spawn while their screen is still fading in.
    spawnProtection = 4,

    -- Rounds handed out on arrival and on each respawn. Weapons come from
    -- your own inventory; this just feeds them.
    ammoOnSpawn = 250,

    -- Given only to someone carrying nothing, so a new player is not stuck
    -- watching.
    starterWeapon = 'WEAPON_PISTOL',

    -- Weapons wear out. Deaths survived, not shots fired.
    durabilityLossPerDeath = 1,
    durabilityWarnAt = 3,

    exitCommand = 'exitred',
}

-- ── what a kill is worth ──
--
-- Coins are the arena's, spent in the arena's shop. Points are this mode's
-- own record and mean nothing anywhere else.
Config.RZ.killReward = {
    coinsMin = 15,
    coinsMax = 40,
    points = 10,

    -- Weighted. "nothing" is a real outcome and deliberately the likeliest:
    -- a drop that always happens is not a drop, it is a payment.
    --
    -- WEIGHT is relative, not a percentage -- they do not have to add up to
    -- anything. An entry on 14 against a total of 100 comes up roughly one
    -- kill in seven. Raise one number and everything else gets rarer.
    --
    -- COUNT can be either:
    --     count = 60            exactly sixty, every time
    --     count = { 10, 20 }    somewhere between ten and twenty, rolled per
    --                           kill
    --     count = { min = 10, max = 20 }    the same thing, spelled out
    --
    -- Leave count off entirely and it is one.
    --
    -- There is no cap on how much of a thing anyone can hold. What fits is
    -- decided by the bag -- the arena's weight and slot limits -- so ammo
    -- stacks like ammo. (An older maxOfOneItem setting compared the amount
    -- CARRIED against 5, which meant one 60-round drop stopped ammo dropping
    -- for the rest of that life. It is gone.)
    -- Every entry has to exist in the ARENA's Config.Items. The arena owns
    -- item definitions; naming something here that it does not define means
    -- addItem quietly does nothing and the kill pays out air.
    drops = {
        { item = nil,             weight = 45 },   -- nothing
        { item = 'ammo-9',        weight = 32, count = { 30, 60 } },
        { item = 'naija_slurpy',  weight = 15, count = 1 },
        { item = 'n46_gummies',   weight = 8,  count = 1 },
    },
}

-- Extra for a run of kills without dying.
Config.RZ.streaks = {
    [3]  = { coins = 30,  points = 15, message = 'Three in a row' },
    [5]  = { coins = 75,  points = 40, message = 'Five in a row' },
    [10] = { coins = 200, points = 100, message = 'Ten in a row' },
}

-- ── the wall board ──
--
-- Registered with the arena on startup, so /rzboard redzone shows this
-- mode's leaderboard on a wall the arena draws. The arena knows nothing
-- about this mode -- it just asks whoever registered that name.
Config.RZ.board = {
    id = 'redzone',
    label = 'NAIJA 2046 RED ZONE',
    footer = 'FREE FOR ALL · EVERY KILL COUNTS',
    accent = 'red',
    entries = 8,
}

-- -- the lobby ped --
--
-- A bubble on the arena's lobby ped that opens the zone picker.
--
-- Registered WITH THE ARENA, the same way the wall board is: the arena owns
-- the prompt system and knows nothing about this mode, so it is told a
-- position and an export name and calls back when somebody presses the key.
-- Stop this resource and the prompt goes with it.
--
-- Set enabled = false if you would rather people used /rz.
Config.RZ.prompt = {
    enabled = true,

    -- Its own ped, in the arena's lobby bucket. Stand where you want it and
    -- read your coords off /rzmark or any coords tool.
    ped = {
        model = 'g_m_y_lost_01',
        coords = vec4(304.99, -1589.64, 30.53, 118.23),
        scenario = 'WORLD_HUMAN_SMOKING',
    },

    distance = 2.5,
    title = 'RED ZONE',
    label = 'Open the Red Zone',
    keyLabel = 'E',
    key = 38,
}

-- Console lines for tracing what this mode is doing: entries, kills, drops,
-- refusals. Read by dbg() and off unless set -- it was already being read
-- with no config entry to turn it on, which made it undiscoverable.
Config.RZ.debug = false

-- -- handing zones to tenx-zones --
--
-- OFF. See the arena's Config.Zones for the full explanation; this is the
-- Red Zone half and both must be flipped together.
--
-- Red Zone zones are bound with armOnEntry, always. Entry spawns sit OUTSIDE
-- the boundary on purpose so players walk in, and a zone that went solid the
-- moment it bound would clamp them back before they moved.
Config.RZ.zones = {
    -- ON. See the arena's Config.Zones for the full explanation; both must
    -- be on together.
    --
    -- With it on and tenx-zones missing or too old, this resource refuses to
    -- start rather than running a mode with no zones.
    useExternal = true,

    -- ONE standing bucket for the whole mode.
    --
    -- The Red Zone is a place, not an instance. Everyone in it shares a
    -- world, which is the point of a free-for-all -- splitting seven zones
    -- across seven buckets fragments a player base that is thin enough
    -- already, and the zones are at different map locations anyway.
    --
    -- 2100, not a low number. Low buckets are where other resources squat
    -- without documenting it. This range was already reserved here and kept
    -- clear of the arena's lobby at 2046 and its match range at 4200+.
    --
    -- It also means the same patch of map can serve both modes with no
    -- bookkeeping: a PVP player is in a match bucket and only ever gets the
    -- arena polygon, a Red Zone player is in 2100 and only ever gets the
    -- spheres. The bucket decides.
    bucket = 2100,

    -- Which zones this mode offers.
    --
    -- A tag rather than a list of ids: drawing a sphere and tagging it is the
    -- whole job, and it appears in the next /rz with no config edit and no
    -- restart. A hand-maintained id list fails silently -- a zone that exists
    -- in the world and cannot be picked, with nothing saying why.
    tag = 'redzone',

    -- How far outside the boundary an entry spawn may sit. A maximum, not a
    -- minimum -- a spawn 200m away is as wrong as one inside the dome.
    --
    -- Wider than the arena's, because these are spheres and a player wants to
    -- land looking at the dome rather than pressed against it.
    spawnTolerance = 25.0,
}

Config.RZ.text = {
    entered = 'You are outside the zone. Walk in when you are ready.',
    left = 'Back at the lobby.',
    notReady = 'That zone has no spawns marked yet.',
    busy = 'Finish your match first.',
    noArena = 'The arena resource is not running.',
}

-- ============================================================
--  HOW LONG A PLAYER STAYS DOWN
-- ============================================================
-- The single number that controls the wait between going down and coming
-- back. Everything reads from here -- the death screen countdown, the revive,
-- the heal and the respawn all fire together at the end of it.
--
-- "Down" means EITHER of:
--   · knocked -- the ambulance script's incapacitated state, where the ped is
--     still alive on full health and only their screen says otherwise
--   · dead -- properly dead, ped and all
--
-- Both wait the same amount of time and both end the same way. There is no
-- separate path for one or the other, on purpose: from the player's side
-- being knocked and being dead are the same thing, and having them behave
-- differently is what made this confusing to test.
Config.RZ.down = {
    -- Seconds from going down to being revived, healed and placed at a spawn.
    --
    -- This is the whole wait. It is not added to anything else and nothing
    -- else is added to it -- the countdown you see on screen is this number.
    delay = 10.0,

    -- Extra seconds before the safety net forces it.
    --
    -- The normal path fires at `delay`. If something stops it -- their script
    -- never publishing a state, a kill report rejected, an export not
    -- answering -- a watchdog picks the player up at `delay + grace` instead
    -- and does the same thing regardless.
    --
    -- Keep it above zero. At zero the watchdog races the normal path and they
    -- both try to respawn the same player.
    grace = 5.0,

    -- How often the watchdog looks, in seconds. Slower is fine; it only ever
    -- matters when the normal path has already failed.
    checkEvery = 2.0,
}
