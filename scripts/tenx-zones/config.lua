Config = {}

-- ============================================================
--  ACCESS
--  Checked on the SERVER for every open / create / edit / delete.
--  The client never decides this.
-- ============================================================
-- Whoever is listed here can open the builder. Yours and Duel's are
-- already in, so nothing needs setting up by hand.
--
-- To add anyone else: they run /zonesid in game and paste the
-- license line it prints.
--
-- Prefer `license:` -- it is stable and does not depend on the
-- player being on Steam or on a Discord resource being running.
Config.Admins = {
    'license:PUT_YOUR_LICENSE_IDENTIFIER_HERE',   -- Tino
    'license:PUT_A_SECOND_ADMIN_LICENSE_HERE',   -- Duel
}

-- Optional ACE fallback, on top of the list above. Leave it on and
-- it costs nothing if you never grant the ace; turn it off if you
-- want the identifier list to be the only way in.
--   add_ace group.admin tenx.zones allow
Config.UseAce     = true
Config.AdminAce   = 'tenx.zones'

-- Command that opens the builder. Also gated server side.
Config.Command    = 'zones'

-- Key that toggles noclip while the builder is open.
Config.NoclipKey  = 'F2'


-- ============================================================
--  PERFORMANCE
--  These are the numbers that decide idle cost. Leave them
--  alone unless you know why you are changing them.
-- ============================================================
Config.Tick = {
    -- Sleep when the player has no zones bound to them at all.
    -- Nothing runs in this state, the thread just parks.
    idle          = 1000,

    -- Sleep when bound to a zone but comfortably away from its edge.
    far           = 500,

    -- Sleep when close to the edge. 0 = every frame.
    near          = 0,

    -- How close to the boundary before switching to the fast tick.
    nearDistance  = 25.0,

    -- Same again but for vehicles, which cover ground much faster
    -- and need the fast tick to start earlier.
    nearDistanceVeh = 90.0,

    -- SERVER: how often every connected player's routing bucket is
    -- compared against the cached one. This exists because
    -- RefreshPlayer being forgotten at a single call site is a
    -- silent bug -- a zone that quietly does not apply, with no
    -- error. One native call per player per tick, which at 64
    -- players is not measurable. RefreshPlayer stays as the
    -- instant path; this is the safety net under it.
    bucketPoll      = 2000,
}

Config.Render = {
    -- Never draw a zone further away than this.
    distance      = 350.0,

    -- FADE.
    -- The shell gets lighter as you move deeper inside a zone, so a
    -- big dome is not filling every pixel on screen while you stand
    -- in the middle of it. That is the real frame cost.
    --
    -- It used to fade to NOTHING at a flat 90m deep. Two things wrong
    -- with that. The number was absolute, so a 180m dome vanished
    -- exactly at its own centre (its centre IS 90m deep). And fading
    -- to zero means the zone you are standing in becomes invisible,
    -- which is the opposite of useful.
    --
    -- Now: full strength out to half the zone's own size, then it
    -- eases down to a floor it never drops below. Always visible,
    -- at any zone size, while still cutting the overdraw that costs
    -- frames.
    fadeStartFrac = 0.5,    -- full strength until this deep in
    fadeFloor     = 0.35,   -- never lighter than this while inside

    -- Sphere shell opacity at full strength (0-255).
    sphereAlpha   = 55,

    -- Wall opacity at full strength (0-255).
    wallAlpha     = 70,

    -- Metres per wall quad. Lower = smoother, more draw calls.
    wallSegment   = 6.0,

    -- Draw the wall top cap line.
    wallTopLine   = true,
}


-- ============================================================
--  BOUNDARY BEHAVIOUR
-- ============================================================
Config.Boundary = {
    -- How far back inside the edge a blocked player is placed.
    margin            = 1.5,

    -- Gap between repeat warnings, ms.
    warnCooldown      = 4000,

    -- Warning shown when a solid boundary blocks you.
    warnText          = 'Boundary reached',
    warnSubText       = 'You cannot leave this zone',

    -- VEHICLES.
    -- Zeroing velocity outright was the old behaviour and it was
    -- wrong: on a desync the clamp fires late and a hard stop at
    -- speed launches the car or buries it in geometry. Instead we
    -- kill only the component heading OUT through the wall and
    -- keep the tangential one, so a car slides along the boundary
    -- rather than slamming into it.
    vehicleDamping    = 0.82,   -- per frame, on the outward axis
    vehicleFrames     = 4,      -- frames to bleed it off
    -- Set vehicleDamping = 0.0 for the old hard stop.

    -- DISPLACEMENT.
    -- A position jump this large that the player's own speed could
    -- not accounted for is a teleport, not movement. Clamping a
    -- teleport is always wrong -- an escrowed ambulance script
    -- moving a downed player must not be dragged back.
    --
    -- 25m was the first proposal and it is too low: the far tick is
    -- 500ms and a car at 200km/h covers 27m in that, so a vehicle
    -- crossing a boundary at speed would read as a teleport.
    teleportJumpMetres = 90.0,
    -- ...and it must also exceed what their speed could produce in
    -- the elapsed time, times this. A fast car moving fast is never
    -- displacement. A standing player appearing 200m away is.
    teleportJumpFactor = 3.0,
}


-- ============================================================
--  BUILDER
-- ============================================================
-- ============================================================
--  AUTO TAGS
--  Tags applied automatically when a zone is drawn in /zones,
--  by shape. Here because on this server the shape IS the
--  purpose: spheres are only ever Red Zones, polygons are only
--  ever arenas -- and tagging as a separate step afterwards is
--  a step that gets forgotten.
--
--  These are a DEFAULT, not a rule. The tag shows up as a chip
--  in the save form before you commit, and you can click it off
--  or type a different one. So a sphere that is not a Red Zone
--  is still possible, it just is not the assumption.
--
--  Set either to {} to turn it off for that shape.
--
--  Zones created through the CreateZone export -- the arena
--  migration, anything scripted -- are NOT touched by this.
--  They pass whatever tags they want and get exactly those.
-- ============================================================
Config.AutoTags = {
    sphere = { 'redzone' },
    poly   = { 'arena' },
}

Config.Build = {
    minRadius       = 5.0,
    maxRadius       = 600.0,
    radiusStep      = 2.5,      -- scroll
    radiusStepFast  = 15.0,     -- shift + scroll

    minPoints       = 3,
    maxPoints       = 32,

    -- Auto height for walled zones. Floor sits this far BELOW the
    -- lowest ground sample so nobody clips out under a slope.
    autoFloorBelow  = 4.0,
    -- Ceiling sits this far ABOVE the highest ground sample.
    autoRoofAbove   = 50.0,

    -- Noclip speeds, cycled with the speed key.
    noclipSpeeds    = { 0.35, 1.2, 4.0, 14.0 },
    defaultSpeed    = 2,
}


-- ============================================================
--  DEFAULT LOOK OF A NEW ZONE
-- ============================================================
Config.Defaults = {
    -- Passable zones default to green, solid to red. You can
    -- change any individual zone in the panel afterwards.
    passableColor = { r = 0,   g = 224, b = 138 },
    solidColor    = { r = 255, g = 77,  b = 61  },
    solid         = true,
    visible       = true,
}


-- ============================================================
--  SECURITY
-- ============================================================
Config.Security = {
    -- Hard ceiling on stored zones.
    maxZones            = 250,

    -- Per player cooldown on any write action, ms.
    writeCooldown       = 750,

    -- How often the server independently checks that bound
    -- players are actually inside their solid zones. This is a
    -- BACKSTOP, not a second clamp -- it runs slowly with generous
    -- slack, and never repositions anyone at frame rate. The
    -- client clamp is what a player feels.
    sweepInterval       = 4000,

    -- Metres of slack the server allows before it calls a
    -- violation. Must be larger than Config.Boundary.margin so
    -- normal clamping never trips it.
    sweepTolerance      = 12.0,

    -- Violations before the player is force corrected server side.
    violationsBeforeSnap = 2,

    -- Violations before it is logged for you to look at.
    violationsBeforeLog  = 4,

    -- DISPLACEMENT POLICY.
    -- false: an unexplained exit is clamped back AND reported.
    -- true:  an unexplained exit disarms the zone and they stay out.
    --
    -- Default false, deliberately. An unexplained exit and a
    -- teleport hack are the same signal from here. If unexplained
    -- exits disarm the zone then the wall is decorative for anyone
    -- with a menu. Route legitimate teleports through a claim
    -- (SuspendZone / SuspendLocal) and displacement stays rare.
    trustDisplacement   = false,

    -- CLIENT RAISED SUSPEND CLAIMS.
    -- SuspendLocal stops the sweep as well as the clamp, which is
    -- what makes a client side teleport safe. The cost is that
    -- anyone with client code execution can raise one. So they
    -- EXPIRE on their own -- 20s comfortably covers a 12s collision
    -- load -- and the worst case becomes 20 seconds and a log line
    -- rather than an open door.
    --
    -- Claims raised server side by SuspendZone never expire.
    maxLocalClaim       = 20000,
    localClaimCooldown  = 2000,

    -- Called for a genuine unexplained exit, a repeated client
    -- claim, or a player found well outside a solid zone.
    --   src, zoneId, distance, claim (nil unless during a claim), timestamp
    onViolation = function(src, zoneId, distance, claim, timestamp)
        print(('[tenx-zones] %s (%s) %.1fm outside zone %s%s')
            :format(GetPlayerName(src) or '?', src, distance or 0, zoneId,
                    claim and (' during claim ' .. claim) or ''))
    end,
}
