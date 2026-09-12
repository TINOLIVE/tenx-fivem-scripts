-- tenx-adminjail/config_recovery.lua
-- SHARED (client + server). Recovery tools:
--   1. HEAL ZONES — die anywhere inside one and you're revived on the spot.
--      Covers the moons: sent-to-moon players, admin-jail-on-moon, AND anyone
--      just visiting. It's a property of the GROUND, not the punishment.
--   2. /rescue [id] — console-only. TP a stuck player to Legion + revive.
--
-- Both use ak47_qb_ambulancejob for the revive. Event names live here.

Config = Config or {}

Config.Recovery = {
    -- ========================================================
    --  HEAL ZONES
    --  Spheres. Die inside one -> auto-revived where you died (not moved).
    --  centre = vec3(x,y,z). radius = metres. Tune radius with the debug draw
    --  (see healDebugCommand) so it actually covers the whole platform.
    -- ========================================================
    HealZones = {
        { name = 'Red Moon',   centre = vec3(-3913.73, 292.08,   642.06),  radius = 80.0 },
        { name = 'White Moon', centre = vec3(-5178.77, -2510.53, 1789.15), radius = 80.0 },
    },

    -- ms after death before the auto-revive fires (lets the death register first)
    healReviveDelay = 1500,

    -- Seconds minimum between auto-revives for the SAME player. Stops a
    -- revive->instant-death->revive loop from hammering if someone ends up in
    -- a wall or off the edge. They still get healed, just not 30x a second.
    healCooldown = 5,

    -- Staff-only client command that draws the zone spheres so you can eyeball
    -- whether the radius covers the platform. Toggle on, walk the edges, toggle
    -- off. Set to false to disable the command entirely.
    healDebugCommand = 'healzones',

    -- ========================================================
    --  LEGION SQUARE SAFE SPOT (stuck-player rescue lands here)
    -- ========================================================
    legion = vec4(228.89, -789.26, 30.67, 174.54),

    -- ========================================================
    --  CONSOLE RESCUE COMMAND
    -- ========================================================
    -- Console-only (txAdmin). Enforced two ways: RegisterCommand is `restricted`
    -- AND the handler rejects any source that isn't the console.
    rescueCommand = 'rescue',   -- usage: rescue [id]

    -- ========================================================
    --  AMBULANCE INTEGRATION (ak47_qb_ambulancejob)
    -- ========================================================
    -- Revive runs ON THE TARGET'S CLIENT, faithful to the resource's own usage:
    --   TriggerServerEvent(reviveServerEvent, ownServerId) then skellyfix.
    -- skellyfix is a LOCAL client event, so it can only run on the target.
    ambulance = {
        reviveServerEvent = 'ak47_qb_ambulancejob:revive',
        skellyFixEvent    = 'ak47_qb_ambulancejob:skellyfix',
        skellyFixDelay    = 500,    -- ms between revive and skellyfix

        -- ms to wait AFTER revive before we place a RESCUED player at Legion
        -- (the ambulance script may teleport them to a hospital first).
        settleDelay       = 1800,
    },

    -- ========================================================
    --  RESCUE BEHAVIOUR
    -- ========================================================
    rescueRevives           = true,   -- revive as well as teleport
    rescueClearsPunishments = true,   -- clear cuff/jail/community/moon first so
                                      -- nothing snaps them back after the TP
}
