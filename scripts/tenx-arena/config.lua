Config = {}

-- ============================================================
--  HOW LONG ANYONE WAITS
-- ============================================================
-- Their death screen takes about 10 seconds to finish. A revive landing
-- before that does nothing -- the screen comes up afterwards with nothing
-- left to dismiss it, and the player sits there looking at it.
--
-- So: wait for the screen, then move immediately. One second after it
-- finishes, not five. Nobody should be sat on a death screen wondering
-- whether the script forgot about them.
--
-- Change this ONE number if their death screen changes length -- every
-- respawn and revive in the resource is measured from it.
Config.DeathScreen = 10000   -- ms for their screen to finish
Config.ReviveAt    = 11000   -- ms until we act: the screen, plus one second

-- Note on how these combine.
--
-- The obvious reading is "wait ReviveAt, then run the revive sequence" -- but
-- that stacks the sequence ON TOP of the wait and puts a player back on their
-- feet at 13 seconds, not 11.
--
-- So the fade starts BEFORE the screen finishes and runs behind it. The
-- revive itself still lands after the screen is done, which is the part that
-- actually matters. Everything after the revive is trimmed to the minimum
-- that still works.

-- ============================================================
--  STAFF ACCESS
-- ============================================================
-- Who can open the builder and run arena commands.
-- Get your license in game with /arenawhoami.

Config.Staff = {
    ['license:PUT_YOUR_LICENSE_IDENTIFIER_HERE'] = 'Tino',
}

-- Also allow anyone with this ace permission. false to use the list only.
Config.AcePermission = 'naija.arena'

-- ============================================================
--  ROUTING BUCKETS
-- ============================================================
-- This is what keeps arena fights out of the main world, and it's the answer
-- to the dispatch problem.
--
-- Every dispatch script works by having a client witness a gunshot in the
-- live world and report it. Players inside a bucket don't exist to anyone
-- outside it, so no dispatch script ever sees anything to report. Nothing to
-- patch, nothing that breaks when ps-dispatch or qs updates.
--
-- It also means RP players never see a firefight in the middle of the city,
-- outsiders can't shoot into an arena, and two matches can run at the SAME
-- coordinates in different buckets without colliding.
Config.Buckets = {
    -- Base of the range this resource uses. Keep it clear of buckets other
    -- resources on your server already use.
    base = 4200,

    -- How many matches can run in the SAME arena at once.
    --
    -- Buckets make this nearly free: two matches at identical coordinates in
    -- different buckets cannot see or shoot each other. So one good arena can
    -- serve several 1v1s at the same time rather than everyone queueing for
    -- the one space.
    --
    -- Arena N instance I uses bucket: base + (N * instancesPerArena) + I
    -- With base 4200 and 6 instances, arena 1 occupies 4206-4211.
    instancesPerArena = 6,

    -- Strip AI traffic and pedestrians out of arena buckets. Leave this on:
    -- a clean arena and fewer entities to sync.
    stripPopulation = true,

    -- 'relaxed' lets clients create entities (weapons, props) normally.
    -- 'inactive' or 'strict' lock that down but break more than they fix here.
    lockdown = 'relaxed',
}

-- ============================================================
--  THE BOUNDARY
-- ============================================================
Config.Boundary = {
    -- Players are held inside the arena box. This is a soft wall: your
    -- position is clamped back to the edge rather than a physical collider
    -- being spawned. Colliders snag vehicles, survive resource restarts badly
    -- and break whenever the map updates -- clamping does neither.
    enabled = true,

    -- Metres inside the edge the clamp holds you. A small inset stops the
    -- jitter you get from being clamped exactly onto the line.
    inset = 0.6,

    -- Warning shown while you're being held back.
    warn = true,

    -- How the boundary is drawn.
    wall = {
        -- OFF.
        --
        -- The clamp already stops people leaving, and a player who walks into
        -- an invisible wall learns there is a wall -- the drawing was telling
        -- them something they find out anyway, at the cost of a few hundred
        -- DrawPoly calls a frame for as long as they stand near an edge.
        --
        -- What's left teaches the same thing for nothing: you stop, and a
        -- line of text says why.
        --
        -- Set true if you want it back. Everything below still works.
        enabled = false,

        -- ONLY drawn to players who are actually inside that arena.
        -- This is an RP city: someone driving past should never see a red
        -- wall across the road. Set true only for testing.
        showToEveryone = false,

        colour = { r = 60, g = 200, b = 255 },  -- cyan reads as a boundary, not a hazard
        alpha = 60,

        -- How close you have to be to see a corner post. Well under
        -- drawWithin on purpose: at the old range the whole zone was outlined
        -- in pillars from a rooftop, which gives the shape of the boundary
        -- away from halfway across the map.
        cornerWithin = 25.0,

        -- How much of an edge is drawn, in metres either side of the point
        -- nearest you. Drawing a whole 200m side when you can see thirty of
        -- it is most of what a boundary wall costs.
        segmentSpan = 30.0,

        -- The settings below only matter when enabled = true.
        --
        -- Draw the far side of each panel as well. Off: you stand on ONE
        -- side of a boundary, so the back face is behind the front and you
        -- were never going to see it -- and it doubles the cost of the wall.
        doubleSided = false,

        -- Most wall segments drawn at once. A zone with a long perimeter
        -- would otherwise draw every edge in range every frame -- and you can
        -- only run into one wall at a time.
        -- You can only walk into one wall at a time, and at a corner two.
        -- Six was drawing sides you were nowhere near.
        maxEdges = 3,


        height = 10.0,           -- how tall the wall stands
        -- Length of each wall panel.
        --
        -- Bigger is cheaper: this is a flat translucent plane, and a 15m
        -- panel looks identical to three 5m ones while costing a third as
        -- much. Small segments only matter on curves, and a zone edge is a
        -- straight line between two marked points.
        segment = 15.0,           -- metres per quad; smaller = smoother, more draw calls
        -- How close an edge has to be before any of it is drawn.
        --
        -- 60 rather than 120: the wall is there to tell you where the
        -- boundary is when you are about to hit it, not to outline the arena
        -- from across the map. It fades in over the last stretch rather than
        -- appearing all at once.
        drawWithin = 60.0,

        -- Over how many metres it fades in, measured inward from drawWithin.
        fadeOver = 25.0,
        -- Corner posts. Also off: same reasoning, and they gave the shape of
        -- the zone away from a rooftop.
        corners = false,          -- brighter posts at the four corners
    },
}

-- ============================================================
--  ZONE BUILDING
-- ============================================================
Config.Builder = {
    -- Default vertical height of a new arena, measured up from the lower
    -- corner. Rooftop arenas want less, street arenas want more.
    defaultHeight = 30.0,

    -- How far below the marked corner the box extends, so a small dip in the
    -- ground doesn't put someone "outside" the arena.
    floorGrace = 3.0,

    -- Preview the box while you're building it.
    preview = true,
}

-- ============================================================
--  DEFAULT MATCH LOADOUT
-- ============================================================
-- What players are given when they're sent into an arena. Each arena can
-- override this with its own list in the builder.
Config.DefaultLoadout = {
    { name = 'WEAPON_COMBATPISTOL', count = 1 },
    { name = 'cookies',             count = 5 },
}

-- Ammo item handed out alongside the weapon. false to skip.
Config.DefaultAmmo = { name = 'ammo-9', count = 120 }

-- ============================================================
--  APPEARANCE
-- ============================================================
-- Where notifications appear.
--
-- 'top-center' rather than the side: the side of the screen is where every
-- other resource puts its own, and an arena message lost in that column is a
-- message nobody reads.
--
-- ox_lib takes: top, top-right, top-left, bottom, bottom-right, bottom-left,
-- center-right, center-left
Config.NotifyPosition = 'top-center'

-- Print every zone edit and bucket move to the server console.
Config.Debug = true

Config.Text = {
    no_permission = 'You are not allowed to do that.',
    outside       = 'You cannot leave the arena.',
}

-- ============================================================
--  MATCH MODES
-- ============================================================
Config.Modes = {
    -- Nothing goes past 20.
    --
    -- A first-to-40 squad match is forty rounds of respawning, and people
    -- leave long before it finishes -- which is worse than a short match,
    -- because everyone who stayed gets nothing either.
    { id = '1v1',    label = '1v1',       perTeam = 1, scores = { 5, 7, 10 },   defaultScore = 7  },
    { id = '2v2',    label = '2v2',       perTeam = 2, scores = { 7, 10, 15 },  defaultScore = 10 },
    { id = '3v3',    label = '3v3',       perTeam = 3, scores = { 10, 15, 20 }, defaultScore = 15 },
    { id = '4v4',    label = '4v4',       perTeam = 4, scores = { 10, 15, 20 }, defaultScore = 15 },
    { id = 'squad',  label = 'Squad 5v5', perTeam = 5, scores = { 10, 15, 20 }, defaultScore = 15 },
}

Config.DefaultMode = '1v1'

-- ============================================================
--  THE MEETING ZONE
-- ============================================================
-- Where players gather to queue. More than one is fine -- players use
-- whichever is nearest. Mark them in the admin panel rather than typing
-- coordinates.
Config.Meeting = {
    -- Where players stand once they are in the lobby. Same physical spot
    -- as the city, but in its own routing bucket -- so a crowd of arena
    -- players waiting for a match is invisible to everyone doing RP there.
    coords = vec4(283.55, -1588.77, 30.53, 20.71),

    -- The door, in both directions.
    --
    -- One ped, two options, only ever one showing. The ped is created
    -- client-side so it exists in every bucket -- standing in the lobby you
    -- would otherwise see it offering to let you into somewhere you already
    -- are. Which option shows depends on which side you are on.
    entry = {
        coords = vec4(288.45, -1601.55, 31.27, 315.72),
        model = 's_m_y_blackops_01',
        scenario = 'WORLD_HUMAN_GUARD_STAND',

        -- Three options on the one ped, and only the relevant ones show.
        -- The ped is created client-side so it exists in every bucket --
        -- without this you would see it offering to let you into somewhere
        -- you are already standing.
        -- Labels come from Config.Brand so the naming stays consistent.
        icon = 'fas fa-crosshairs',
        menuIcon = 'fas fa-list',
        exitIcon = 'fas fa-city',

        distance = 2.5,
    },

    -- The bucket the lobby lives in. Keep clear of the arena range, which
    -- starts at Config.Buckets.base.
    bucket = 2046,

    -- Players can also open the panel with this command once they are in.
    --
    -- 'pvp', not 'rz': the Red Zone resource registers /rz for itself, and two
    -- resources claiming one command means whichever loaded last wins.
    command = 'pvp',

    -- The floating sign over the ped above. There is no second ped any more:
    -- one ped in one place, whose options change with which bucket you are
    -- standing in. Two peds meant one of them was always in the wrong world.
    ped = {
        enabled = true,
        drawDistance = 25.0,
    },

    blip = {
        enabled = true,
        sprite = 313,
        colour = 3,
        scale = 0.9,
        shortRange = false,
        label = 'PVP',
    },

    -- Where leaving puts you. Defaults to the entry ped, so you
    -- step out roughly where you stepped in.
    exitCoords = vec4(288.45, -1601.55, 31.27, 135.0),

    -- After a match, players return to the lobby rather than the city. They
    -- came to fight; put them back where the next one starts.
    returnToLobbyAfterMatch = true,

    -- Nobody stays down in the lobby.
    --
    -- The lobby is a waiting room, not somewhere to bleed out. Anyone in this
    -- bucket who is knocked or dead is picked back up automatically, wherever
    -- they are on the map -- there is no medic in here and no reason to make
    -- them wait for one.
    autoRevive = true,
    autoReviveCheck = 2000,   -- ms between checks

    -- Wait before picking them up.
    --
    -- Their death screen takes time to appear, and a revive that lands before
    -- it exists does nothing -- the screen then comes up with nothing left to
    -- dismiss it. Same trap as the match revive, and the same fix: let the
    -- screen finish, then revive into it.
    -- Starts BEFORE the screen ends, same as a match respawn -- the fade runs
    -- behind the tail of it so the revive lands just after. Waiting for the
    -- full ten and then starting is what left people sitting there.
    autoReviveDelay = 9500,
}


-- ============================================================
--  PARTIES
-- ============================================================
Config.Party = {
    -- Codes are for people who aren't near you. The nearby-player list is
    -- for people who are -- one click, no typing, which is how most invites
    -- actually happen.
    codeLength = 4,
    inviteRange = 12.0,     -- metres for someone to show in the nearby list
    inviteTimeout = 30,     -- seconds before an invite expires
    maxSize = 5,            -- ceiling; a mode's team size caps it further

    -- An invite arrives while you're walking around, so it can't take the
    -- mouse -- buttons on it would be unclickable. Keys instead.
    --
    -- Control IDs, not characters. 246 is Y, 249 is N.
    -- Note: 249 is also push-to-talk in most voice resources, so pressing N
    -- may key your mic for an instant. Harmless, but if it bothers you,
    -- 177 (Backspace) or 194 (also Backspace) are clean alternatives.
    acceptKey = 246,
    declineKey = 249,
}

-- ============================================================
--  MATCHMAKING
-- ============================================================
Config.Queue = {
    -- Ask people to accept before starting?
    --
    -- OFF. You joined a queue -- that IS the agreement. An accept prompt
    -- after the fact is a second question about a decision already made, and
    -- it only ever costs you matches: one person looks away, everyone else
    -- goes back to waiting.
    --
    -- Set true to bring it back, with readyCheck as the timeout.
    requireAccept = false,

    -- Seconds to wait for everyone to accept, when requireAccept is on.
    readyCheck = 20,

    -- Seconds the "match found" card stays up before you are taken in. Long
    -- enough to read, short enough not to be a wait.
    foundFor = 3,

    -- Seconds of map voting once everyone is ready. 0 skips the vote and
    -- picks a random free arena.
    mapVote = 15,

    -- Seconds between the map being locked and players being teleported in.
    startDelay = 5,

    -- An arena already hosting a match is never offered in the vote.
    hideBusyArenas = true,
}

-- ============================================================
--  FAIR FIGHTS
-- ============================================================
-- Things that make a match feel consistent between players.
--
-- Be clear about what this can and cannot do. GTA decides a hit on the
-- SHOOTER's machine, against a position it received a moment ago. That is the
-- netcode and no script changes it -- "I shot first" arguments are part of
-- every shooter ever made.
--
-- What it CAN fix is everything else: leftover invincibility, damage
-- modifiers that differ between clients, and health the server and client
-- disagree about. On a scripted arena those cause far more "I hit him and he
-- didn't die" than lag does.
Config.Fair = {
    -- Never let anyone be invincible outside spawn protection. If a thread
    -- dies mid-protection or someone leaves while protected, they would
    -- otherwise stay bulletproof for the rest of the match -- which is
    -- exactly what "I headshot you and you didn't die" looks like.
    invincibilityWatchdog = true,

    -- Force every player in a match to the same weapon damage multiplier. If
    -- one client has a modifier from another resource and another does not,
    -- the same shot does different damage depending on who fired it.
    normaliseDamage = true,
    damageModifier = 1.0,

    -- The server holds the real health value and corrects a client that has
    -- drifted from it. Catches the case where your screen says they are on
    -- 20hp and theirs says 120.
    healthSync = true,
    healthSyncInterval = 2000,   -- ms
    healthSyncTolerance = 15,    -- only correct drift bigger than this

    -- Unlimited stamina during a match.
    --
    -- Two different things go by that name:
    --   GTA sprint stamina -- how long you can run before slowing. Handled
    --     here directly.
    --   Your HUD's stamina bar -- the one beside hunger and water. That
    --     belongs to another resource and no native can reach it.
    --
    -- For the second, this sets LocalPlayer.state.arenaNoStamina during a
    -- match. Add one line to whatever owns your HUD, in its drain loop:
    --
    --     if LocalPlayer.state.arenaNoStamina then return end
    --
    -- Run rzstamina in game to see which of the two is actually the problem.
    infiniteStamina = true,

    -- Turn off aim assist inside a match so controller and mouse are on the
    -- same terms.
    disableAimAssist = true,
}

-- ============================================================
--  THE MATCH HOTBAR
-- ============================================================
-- Arena matches do NOT confiscate anyone's inventory.
--
-- arena match is three minutes long and everyone gets identical gear, so
-- snapshotting a full inventory to the database and restoring it slot by slot
-- is a great deal of machinery and a great deal of risk for nothing.
--
-- Instead: ox_inventory is blocked for the duration, weapons are given
-- natively, and everything is stripped on the way out. The player's real
-- inventory is never touched, so there is nothing that can be lost.
Config.Hotbar = {
    enabled = true,
    blockInventory = true,

    -- Number keys, in order. Weapons first, then utilities.
    slots = {
        { id = 'primary', type = 'weapon', key = '1', label = 'Primary' },
        { id = 'sidearm', type = 'weapon', key = '2', label = 'Sidearm' },
        -- Keys 3 and 4 are the two things that actually do something now.
        -- Charges are per life; the shop items are the real supply.
        { id = 'naija_slurpy', type = 'item', key = '3', label = 'Slurpy',  charges = 0 },
        { id = 'n46_gummies',  type = 'item', key = '4', label = 'Gummies', charges = 0 },
    },

    -- Utilities. EMPTY on purpose.
    --
    -- This is the OLD way of saying what an item does, kept only so anything
    -- still written that way keeps working. Everything real now lives in
    -- Config.Items[id].effect, which is where the Slurpy and the Gummies are.
    -- Adding an item here would split the answer across two places, and
    -- useUtility only falls back to this one.
    items = {},
}

-- Weapons players can pick from when setting up a match.
-- Images come from ox_inventory, so there is no art to make: the icon you
-- already have for the item is the icon shown in the picker.
--
-- Either slot can also be set to NONE in the room, so pistols-only and
-- rifles-only are both one click. Both set to none is fists only, which is
-- allowed -- the room warns you before you start it.
--
-- These are what a NEW room starts with. Set either to false for a server
-- where, say, nobody should get a rifle unless the host picks one.
Config.DefaultRoomWeapons = {
    -- No primaries left, so rooms start sidearm-only. Leaving this pointed at
    -- a rifle that no longer exists would have every new room hand out a
    -- weapon the game cannot give.
    primary = false,                   -- false for none
    sidearm = 'WEAPON_COMBATPISTOL',   -- false for none
}
Config.Weapons = {
    -- Empty, not removed. The room panel reads this list to build its picker,
    -- and an absent table and an empty one are different things to it -- one
    -- shows no options, the other is a nil index.
    primary = {},

    sidearm = {
        { id = 'WEAPON_PISTOL',        label = 'Pistol',        ammo = 120, clip = 12 },
        { id = 'WEAPON_COMBATPISTOL',  label = 'Combat Pistol', ammo = 120, clip = 12 },
        { id = 'WEAPON_APPISTOL',      label = 'AP Pistol',     ammo = 120, clip = 18 },
    },

    -- Never runs dry. Arena matches are about aim, not ammo management.
    infiniteAmmo = true,
    infiniteClip = false,
}

-- Where weapon icons come from. Anything that isn't already a path or URL is
-- resolved against ox_inventory's image folder.
Config.OxImagePath = 'nui://ox_inventory/web/images'

-- ============================================================
--  TEAMMATE NAMETAGS
-- ============================================================
-- Native GTA Online gamer tags over teammates: real name, real health bar,
-- correct font. The natives update the health bar themselves, so this costs
-- almost nothing compared to drawing text every frame.
Config.Nametags = {
    enabled = true,
    drawDistance = 250.0,
    scanInterval = 500,     -- ms while in a match
    showDead = false,
    nameColour = 0,
    healthColour = 9,
}

-- ============================================================
--  TEST MODE
-- ============================================================
-- Fills a lobby with dummy players so you can walk the whole flow alone.
--
-- Be clear about what these are: they occupy slots so matchmaking, teams,
-- spawns and the scoreboard can be tested end to end. They do not fight back.
-- Peds that path, take cover and shoot competently are a serious AI project,
-- not a config option.
Config.TestMode = {
    enabled = true,         -- set false and every trace of this is gone
    maxDummies = 9,
    namePrefix = 'DUMMY',
    spawnPeds = true,       -- put a standing ped at each dummy's spawn point
    pedModel = 's_m_y_dealer_01',
}

-- ============================================================
--  ROOMS
-- ============================================================
-- A room is a lobby you make and control. You pick the weapons, the items,
-- the rounds and the kills to win, then press start when everyone's in.
--
-- This is instead of waiting on matchmaking. On a server your size, sitting
-- in a queue hoping seven strangers want the same mode is not going to
-- happen -- and it's also why the dummies were unusable: there was no way to
-- make a match start. A room has a start button.
Config.Rooms = {
    enabled = true,

    codeLength = 4,
    maxPublic = 24,          -- how many rooms show in the browser
    defaultPrivate = false,  -- new rooms public unless the host says otherwise

    -- Even the teams out automatically as people join, instead of everyone
    -- piling onto one side.
    autoBalance = true,

    -- Host can start with fewer than a full lobby, e.g. a 3v3 room with 2v2
    -- in it. Off means both sides must be full.
    allowUneven = true,

    -- Minimum bodies before start is allowed. 2 so you can't start alone --
    -- unless they're dummies, which is the point of test mode.
    minPlayers = 2,
}

-- Items players can put in their loadout when setting up a room. Charges are
-- how many uses they get per life.
Config.PickableItems = {
    { id = 'naija_slurpy', label = 'Naija Slurpy', image = 'naija_slurpy', maxCharges = 3, default = 1 },
    { id = 'n46_gummies',  label = 'N46 Gummies',  image = 'n46_gummies',  maxCharges = 2, default = 1 },
}

-- ============================================================
--  THE MATCH INVENTORY
-- ============================================================
-- A real inventory for the duration of a match: a grid you open, with items
-- you drag between slots, a slot count and a weight limit.
--
-- It is entirely separate from ox_inventory, which stays locked. Nothing here
-- touches a player's real belongings -- the match inventory is built fresh at
-- the start and thrown away at the end, so there is nothing that can be lost.
--
-- The first few slots ARE the hotbar. Drag something into slot 1 and it's on
-- key 1. That's the whole interaction: arranging your hotbar is arranging
-- your inventory.
-- ── whose guns ──
--
-- ownWeapons = true means a match uses whatever you brought, exactly like the
-- shop. You bought it, you carry it, you fight with it -- and there is no
-- reason for the same weapon to be free in one mode and cost coins in the
-- other.
--
-- Set false to go back to the room picking a weapon everyone shares.
Config.OwnWeapons = true

Config.MatchInventory = {
    enabled = true,

    slots = 20,             -- total slots in the grid
    columns = 5,            -- how the grid is laid out
    hotbarSlots = 5,        -- the first N slots are the hotbar, on keys 1-N
    maxWeight = 100000,     -- grams. 100000 = 100kg

    -- How close you have to be to hand something over. Checked again on the
    -- server, because the list the client showed could be a minute old.
    giveRange = 4.0,

    -- ── dropped things ──
    --
    -- They land on the ground and anyone can pick them up. Items that simply
    -- vanish is the fastest way to make people distrust an inventory -- if
    -- something disappears they assume it was eaten, and they are usually
    -- right.
    dropRange = 2.0,        -- how close you stand to pick one up
    dropExpiry = 300,       -- seconds before a pile disappears
    dropMax = 40,           -- most piles on the ground at once, per bucket

    -- Default key. Players can rebind it in FiveM's own keybind settings
    -- (Settings > Key Bindings > FiveM), which is why this is only a default
    -- rather than the final word.
    key = 'TAB',
    keyLabel = 'Open match inventory',

    -- Close it when the round ends, so nobody is sat in a menu when the next
    -- one starts.
    closeOnRoundEnd = true,
}

-- Everything that can exist in a match inventory.
--
-- weight is grams. stack is how many fit in one slot -- 1 means every one
-- takes its own slot, which is what makes weapons and armour feel heavy.
-- image resolves against ox_inventory's images, so there is no art to make.
-- ============================================================
--  "YOU RECEIVED" POPUP
-- ============================================================
-- A small card, bottom centre, whenever something lands in the bag.
--
-- It lives on the INVENTORY, not on any one mode. Everything that gives a
-- player anything goes through the same add -- a shop purchase, an admin
-- give, a wager payout, a Red Zone kill drop, a match pickup -- so putting it
-- there means every one of them announces itself, and the next mode written
-- gets it without asking.
Config.ItemToast = {
    enabled = true,

    -- How long a card stays, in milliseconds.
    duration = 3200,

    -- Most cards on screen at once. Older ones slide off rather than the
    -- stack growing until it fills the screen.
    max = 4,

    -- Items that should NOT pop a card.
    --
    -- Coins are in here because they are an item like everything else, so
    -- every kill would otherwise show two cards -- the coins and the drop --
    -- and the coin figure is already on screen. Take it out if you want them
    -- announced too.
    ignore = {
        rz_coin = true,
    },
}

Config.Items = {
    -- utilities
    -- stack = 0 means unlimited. Weight is the real limit -- a stack cap on
    -- top of it is a second rule saying the same thing badly, and it is what
    -- scattered five medkits across five slots.
    --
    -- Weapons stay at 1 because durability is tracked per weapon: two rifles
    -- in one slot could not have different wear.

    -- ── the NAIJA items ──
    --
    -- These three exist nowhere else, so they ship their own pictures in
    -- html/items/ rather than being looked up in ox_inventory. Everything
    -- above this line is in the city too and uses ox's image, which is why
    -- a medkit looks the same in here as it does out there.

    -- Coins you can hold.
    --
    -- These ARE your balance -- the shop counts what is in your bag and
    -- spending takes it out. There is no separate number, because two places
    -- to look means two places to disagree.
    rz_coin = {
        -- Weightless on purpose: a balance that fills your bag would stop
        -- you carrying anything once you had saved up, which punishes
        -- exactly the behaviour the shop wants.
        label = 'RZ Coin', weight = 0, stack = 0, usable = false,
        image = 'rz_coin',
        rz = { effect = 'coin', value = 1 }
    },

    -- ── what these actually do ──
    --
    -- Effects are data, not a branch in the code. Add an item with an effect
    -- block and it works; there is no matching `if id == ...` to remember.
    --
    --   health      set health to this, capped at 200
    --   heal        add this much health
    --   armour      set armour to this
    --   regen       { amount, seconds } -- health per second, for a while
    --   useTime     seconds of animation before it lands

    naija_slurpy = {
        label = 'Naija Slurpy', weight = 500, stack = 0, usable = true,
        image = 'naija_slurpy',
        effect = {
            armour = 50,
            regen = { amount = 2, seconds = 10 },
            useTime = 2.0,
            anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle', flag = 49 },
            message = '+50 armour, healing for 10 seconds'
        }
    },

    n46_gummies = {
        label = 'N46 Gummies', weight = 200, stack = 0, usable = true,
        image = 'n46_gummies',
        effect = {
            health = 200,
            armour = 100,
            useTime = 2.5,
            anim = { dict = 'mp_suicide', clip = 'pill', flag = 49 },
            message = 'Full health and armour'
        }
    },

    -- ammo
    -- Only 9mm now. Rifle rounds fed weapons that no longer exist, and an
    -- item that cannot be spent is just weight in a bag.
    ['ammo-9']    = { label = '9mm',   weight = 8,  stack = 0, image = 'ammo-9' },

    -- weapons are one per slot and heavy, so carrying two costs you
    -- durability: how many deaths a weapon survives before it breaks. This is
    -- what makes the shop matter -- you keep what you bought, but not forever.
    -- Price and durability together decide whether a weapon is sustainable.
    -- A rifle at 3000 coins lasting 12 deaths costs 250 coins a death, which
    -- at ~28 coins a kill needs a 9:1 K/D just to stand still -- the top of
    -- the shop would be unreachable in practice. These are set so a decent
    -- player can keep what they bought:
    --
    --   weapon          per death    kills/death to sustain
    --   Pistol              8            0.3
    --   Micro SMG          19            0.7
    --   SMG                45            1.6
    --   Carbine            54            1.9
    --   Assault Rifle      60            2.1
    --   weapon          per death    kills/death to sustain
    --   Pistol              8            0.3
    --   Combat Pistol      20            0.7
    --   AP Pistol          33            1.2
    WEAPON_PISTOL       = { label = 'Pistol',        weight = 1800, stack = 1, weapon = true, durability = 20 },
    WEAPON_COMBATPISTOL = { label = 'Combat Pistol', weight = 2000, stack = 1, weapon = true, durability = 22 },
    WEAPON_APPISTOL     = { label = 'AP Pistol',     weight = 2200, stack = 1, weapon = true, durability = 20 },
}

-- ============================================================
--  THE MATCH
-- ============================================================
Config.Match = {
    -- Seconds dead before you're back in. Short: this is an arena, not RP.
    -- The death card on screen counts down from this exact number.
    -- Seconds before the respawn sequence STARTS -- not before it finishes.
    --
    -- The fade runs behind the tail of their death screen so the revive lands
    -- just after it ends. Pulled slightly under DeathScreen for that reason;
    -- push it lower and the revive fires while their screen is still up,
    -- which is the exact failure this whole sequence exists to avoid.
    respawnDelay = 9.5,

    -- How a match is won.
    --
    -- 'rounds' -- a round ends when an entire TEAM is down. The survivors take
    --   the point, then EVERYONE respawns on full health for the next one.
    --   Dying means you are out until the round ends. This is the real arena
    --   format: your death costs your team the round, so it matters.
    --
    -- 'kills'  -- straight deathmatch. Every kill is a point and the dead
    --   player is back in a few seconds. Kills are all that count.
    scoring = 'rounds',

    -- In 'rounds': how many rounds it takes to win the match.
    -- In 'kills' : how many kills it takes.
    defaultScore = 7,
    scoreOptions = { 3, 5, 7, 10, 15 },

    -- Only used in 'kills' mode -- best-of sets on top of the kill target.
    defaultRounds = 1,
    roundOptions = { 1, 3, 5 },

    -- Seconds between a round ending and the next one starting. The dead lie
    -- where they fell for this long -- then the screen fades, they are revived
    -- and healed inside the black, and the next round begins.
    --
    -- This has to clear their death screen too, so it sits just under it for
    -- the same reason respawnDelay does: the fade covers the tail rather than
    -- waiting politely for it to end.
    roundBreak = 9.5,

    -- ── what a match pays ──
    --
    -- What a match pays. Coins are spent in the shop; points are the
    -- leaderboard record. Kept separate on purpose.
    coins = {
        perKill = 8,
        win = 60,
        loss = 20,     -- turning up and losing is still turning up
    },

    -- War points, the casual leaderboard score. Separate from coins: coins
    -- are spent, points are a record.
    points = {
        perKill = 10,
        win = 100,
        loss = 25,
    },

    -- Most rounds a room may be set to. Nothing above 20: a match nobody can
    -- finish is a match everybody leaves, and the people who stayed get
    -- nothing either.
    maxRounds = 20,

    -- Seconds of invincibility at the start of each round, so nobody is shot
    -- while the screen is still fading in.
    roundStartProtection = 3,

    -- Seconds of invincibility on respawn so you can't be spawn-camped.
    spawnProtection = 3,

    -- Can teammates damage each other?
    friendlyFire = false,

    -- Dying to the world -- falling, the wall, your own grenade -- still
    -- counts as a death for you, but gives the other team nothing.
    worldDeathScoresNothing = true,

    -- Seconds the result card stays up before everyone is sent home.
    endDelay = 10,

    -- Hard ceiling on match length regardless of score. 0 for none.
    timeLimit = 15 * 60,
}

-- ============================================================
--  YOUR DEATH SYSTEM
-- ============================================================
-- ak47_qb_ambulancejob owns death on this server: incapacitated screen,
-- bleedout timer, distress signal. All correct for RP and all completely
-- wrong for a 1v1 -- nobody wants a three minute bleedout between rounds.
--
-- It's escrowed, so its death flow can't be disabled from outside. What we do
-- instead is revive through its own documented trigger the instant a match
-- death is detected, which clears its screen before it settles, and then run
-- our own respawn countdown on top.
Config.Ambulance = {
    resource = 'ak47_qb_ambulancejob',

    -- ── WHICH EVENT ACTUALLY REVIVES ──
    --
    -- I do not know which of these your build of their script listens to, and
    -- guessing has cost you several test rounds. So it tries them in order and
    -- CHECKS after each one, then prints which worked.
    --
    -- Watch your F8 console the first time someone dies. You will get a line
    -- like:
    --      [arena] REVIVE WORKED: client ak47_qb_ambulancejob:revive
    -- Put that one in reviveKnown below and it will skip straight to it
    -- afterwards.
    --
    -- side: 'client' fires it locally, 'server' fires it from the server with
    -- the player id, which is how their ESX docs show it being used.
    reviveCandidates = {
        { side = 'client', event = 'ak47_qb_ambulancejob:revive' },
        { side = 'server', event = 'ak47_qb_ambulancejob:revive' },
        { side = 'client', event = 'ak47_ambulancejob:revive' },
        { side = 'server', event = 'ak47_ambulancejob:revive' },
        { side = 'client', event = 'hospital:client:Revive' },
        { side = 'server', event = 'hospital:client:Revive' },
        { side = 'client', event = 'ak47_qb_ambulancejob:client:revive' },
        { side = 'server', event = 'ak47_qb_ambulancejob:server:revive' },

        -- txAdmin's heal. Its docs say this exists precisely for scripts that
        -- "keep a player unconscious even after the health being restored",
        -- which is exactly what yours does. Worth a shot, with a caveat:
        -- qb-ambulancejob checks GetInvokingResource() == 'monitor' before
        -- accepting it, so it only listens to txAdmin itself. If ak47 does the
        -- same, these will be ignored -- but they cost nothing to try.
        { side = 'client', event = 'txcl:heal' },
        { side = 'server', event = 'txAdmin:events:healedPlayer', arg = 'txheal' },
        { side = 'server', event = 'txAdmin:events:playerHealed', arg = 'txheal2' },
    },

    -- Confirmed working on this server, so the search is skipped entirely.
    -- Set to nil to make it search again if you ever change ambulance script.
    reviveKnown = { side = 'client', event = 'ak47_qb_ambulancejob:revive' },

    -- ── THE TWO STATES ──
    --
    -- Their script has two, and they are not the same thing:
    --
    --   KNOCKED  -- bleeding out, medic can revive you. The ped is ALIVE and
    --              on full health; only their UI and their own state flag say
    --              otherwise. This is what kept reading as "not down".
    --   DEAD     -- actually dead, respawn timer running.
    --
    -- Their own documented events tell us which is which, so we listen to
    -- those instead of guessing from the ped.
    downEvent  = 'ak47_qb_ambulancejob:onPlayerDown',
    deathEvent = 'ak47_qb_ambulancejob:onPlayerDeath',
    reviveEvent = 'ak47_qb_ambulancejob:onPlayerRevive',

    -- In an arena, being KNOCKED is being out of the fight -- you cannot
    -- shoot back. So a knock counts as the kill rather than waiting for the
    -- bleedout to finish. Set false to only count full deaths.
    knockCountsAsKill = true,

    -- Same treatment for the skelly fix.
    skellyCandidates = {
        { side = 'client', event = 'ak47_qb_ambulancejob:skellyfix' },
        { side = 'client', event = 'ak47_ambulancejob:skellyfix' },
        { side = 'server', event = 'ak47_qb_ambulancejob:skellyfix' },
    },

    skellyClientEvent = 'ak47_qb_ambulancejob:skellyfix',

    -- ── WHEN the revive happens ──
    --
    -- Not at the moment of death. Everything is done inside the black screen
    -- of the respawn teleport, which is the only moment nothing else is
    -- competing for the player's state: their death screen has long finished
    -- animating, no other script is mid-transition, and the player cannot see
    -- any of it happen.
    --
    -- Reviving at the moment of death fought their script every time -- the
    -- revive landed while their UI was still coming up, did nothing, and the
    -- screen stayed. This sequence sidesteps that entirely.
    --
    --   fade to black
    --   revive, and keep trying until they are actually up
    --   wait skellyAfterRevive
    --   fix the skelly
    --   teleport, set health
    --   fade back in
    -- Trimmed to the minimum that still works. Everything here happens AFTER
    -- the revive lands, so every millisecond is one the player spends looking
    -- at a black screen wondering what is happening.
    --
    -- Retries stay generous: they cost nothing when the first attempt works,
    -- and they are the difference between a rare failure and a stuck player.
    fadeOut = 400,              -- ms of fade, runs behind their death screen
    reviveAttempts = 8,
    reviveInterval = 350,       -- ms between attempts while checking
    skellyAfterRevive = 400,    -- ms between the revive landing and the skellyfix
    skellyRepeat = 2,
    skellyInterval = 350,
    fadeIn = 400,

    -- Native resurrect if their script never brings them back, so nobody is
    -- ever stranded on a death screen.
    nativeFallback = true,

    -- Clear blood and visible damage with natives alongside their skellyfix.
    nativeHealing = true,

    setHealth = 200,
    setArmour = 0,

    -- Revive everyone when a match starts, in case someone was already down
    -- in the city when it was called.
    reviveOnMatchStart = true,

    -- And when it ends. Whoever loses the final round is knocked or dead at
    -- that moment -- without this they are sent back into the city still on
    -- the floor, in the middle of whatever RP is happening there.
    --
    -- It runs while the result card is up, so there is a good ten seconds of
    -- cover for it to land in.
    reviveOnMatchEnd = true,
}



-- ============================================================
--  THE LEADERBOARD BILLBOARD
-- ============================================================
-- A live board in the lobby showing the top players by war points.
--
-- It renders a real HTML page onto a prop using DUI, so it uses the same
-- fonts and colours as the rest of the panel rather than an image somebody
-- has to remake every season. It updates itself when matches finish.
-- ============================================================
--  NAMING
-- ============================================================
-- Everything players read, in one place. Change it here and it changes on the
-- board, the peds, the notifications and the panel together, rather than
-- being spelled three different ways across the script.
Config.Brand = {
    -- What the mode is called everywhere else.
    modeName = 'PVP',


    -- Notification title.
    notifyTitle = 'PVP',

    -- The ped, in the city and in the lobby.
    enterLabel = 'Enter PVP',
    menuLabel = 'Open the PVP menu',
    exitLabel = 'Go to free roam',

    -- The floating sign over the ped.
    signTitle = 'PVP',
    signCity = '1v1s, team matches, leaderboard',
}

Config.Billboard = {
    enabled = true,

    -- ── how it is drawn ──
    --
    -- Not on a prop. Props meant hunting undocumented texture names, guessing
    -- scale, and fighting the model's own orientation -- and a wrong guess
    -- gave a blank object with no error saying why.
    --
    -- Instead the board is drawn directly into the world as two textured
    -- triangles across four points you mark yourself. It fits whatever wall
    -- you point at, at whatever size and angle you want, and there is nothing
    -- to guess.
    --
    -- Mark one with /rzboard while looking at a wall. Boards are saved to
    -- boards.json in the resource folder and survive restarts.

    -- How far away boards are drawn. Beyond this they cost nothing.
    drawDistance = 70.0,

    -- -- back-face culling --
    --
    -- A board is two triangles, and DrawSpritePoly only draws one side of a
    -- triangle. So each one is drawn twice, once per winding, and the board
    -- reads from either side. But you are only ever on ONE side of it, so
    -- half of those calls paint a face pointing away from you.
    --
    -- Turning this on works out which side you are on and draws only that
    -- pair: four calls per board per frame become two. The draw loop runs
    -- flat out while any board is in range, so near the lobby that is the
    -- saving repeated every frame.
    --
    -- OFF by default because which winding GTA treats as front-facing is not
    -- something that can be checked without running it. Turn it on and walk
    -- past your boards.
    --
    --   Boards still read from both sides  ->  leave it on, it worked
    --   Boards invisible from both sides   ->  set cullFlip below to true
    --   Still wrong                        ->  set this back to false
    --
    -- Nothing else depends on it, and the board editor always draws both
    -- sides regardless so you can walk around one while moving it.
    cullBackFace = false,

    -- Only read when cullBackFace is on. Reverses which side counts as the
    -- front, for if the above came out backwards.
    cullFlip = false,

    -- Resolution of the rendered page.
    width = 1280,
    height = 640,

    -- How many players a board lists.
    entries = 8,

    -- ── how hard the boards work ──

    -- DUI size. Leave it.
    --
    -- I tried 1024x512 to save pixels. The pages are designed against 1280x640
    -- -- every font size, column width and padding -- so a smaller surface
    -- either crops them or letterboxes them, and both looked wrong on a wall.
    --
    -- The saving was small next to the DUI leak that was the actual cost, and
    -- a board that looks wrong is not worth it.
    width = 1280,
    height = 640,

    -- Nothing is sent to a board nobody is near.
    --
    -- The pages stay alive -- recreating a DUI is far more expensive than
    -- letting an idle one sit there -- but they stop being fed, and they
    -- pause their own animations while asleep.
    wakeDistance = 45.0,

    -- How often each kind is refreshed, in seconds, and only when the data
    -- has actually changed.
    --
    -- A ladder that moves once an hour does not need the same attention as a
    -- queue counter. Countdowns are never debounced -- those are sent the
    -- moment they change.
    refreshRates = {
        list   = 2,    -- queues and rooms: what people are watching for
        pvp    = 10,   -- match records move slowly
        ranked = 30,   -- ratings move slower still
    },

    -- Closest two boards may be, in metres. Any nearer and they render
    -- through each other -- which looks like a bug in one board rather than
    -- two boards in the same place.
    minGap = 4.0,

    -- Boards come in three kinds, each showing two panes at once:
    --
    --   pvp     the two casual leaderboards, alternating
    --   ranked  the ladder, on its own
    --   list    live queues and open rooms
    --
    -- Mark one with: /rzboard pvp <name>

    -- Seconds between refreshes. It also refreshes the moment a match ends,
    -- so this is only a backstop.
    refresh = 60,

    -- Only staff can mark and remove boards.
    markCommand = 'rzboard',

    -- Which key places a point while marking.
    --
    -- Not E: half the servers running this have E on noclip, a menu, or a
    -- door, and fighting an admin tool over a key you use constantly is the
    -- kind of thing that makes a tool not worth using.
    --
    -- The control is DISABLED while marking and then read in its disabled
    -- state -- otherwise the game acts on it first (right mouse raises your
    -- weapon) and the marker never sees the press.
    --
    --   25   right mouse (aim)    -- the default
    --   24   left mouse (attack)
    --   38   E
    --   47   G
    --   246  Y
    --   303  U
    --
    -- /rzmark places a point with no key at all, for when whatever you pick
    -- turns out to be claimed by something else.
    markKey = 25,
    markKeyName = 'RIGHT MOUSE',

    -- A SECOND key that does the same thing.
    --
    -- Right mouse is the most likely of all of these to be claimed by
    -- something else on a server, and when it is, marking a zone has no way
    -- through at all -- the board marker takes Enter as an alternate for
    -- exactly this reason, and zone marking had nothing.
    --
    -- Both keys are disabled while marking and read in their disabled state,
    -- so whichever one another resource is listening on, it will not act on
    -- it while you are walking a shape.
    --
    -- Set to false to turn the alternate off. Same code list as above.
    markKeyAlt = 38,
    markKeyAltName = 'E',

    -- How far off the wall a new board sits, in metres.
    --
    -- Aiming at a wall puts the point ON the surface, and a board flush with
    -- a ridged building face disappears into the ridges. A few centimetres
    -- out and it hangs in front of them, which is what a sign does anyway.
    --
    -- rzboard push <id> <metres> adjusts one afterwards.
    markOffset = 0.12,

    -- While marking, the corners you have placed are shown as markers so you
    -- can see the shape before you commit to it.
    markerSize = 0.28,
}



-- ============================================================
--  WHAT YOU CARRY
-- ============================================================
-- Settings for the kit itself, kept when the free-for-all zones were
-- removed -- matches use all four.
Config.Kit = {
    -- Rounds handed out when you enter a fight. Your weapons come from your
    -- own inventory; this is just what feeds them.
    ammoOnSpawn = 250,

    -- Rounds in the LOBBY. One, not zero.
    --
    -- Zero does not do what it looks like it does: GTA will not keep an empty
    -- weapon drawn, so the ped holsters it by itself and the gun keeps
    -- dropping out of players' hands looking like a bug. The trigger is
    -- already blocked in the lobby by its own thread, so the empty magazine
    -- was a second lock on a door that was already shut.
    lobbyAmmo = 1,

    -- Given only to someone with nothing at all, so nobody stands there
    -- watching a match they cannot take part in.
    starterWeapon = 'WEAPON_PISTOL',

    -- Weapons wear out. This is deaths survived, not shots fired: dying with
    -- something costs you a little of it, and at zero it breaks.
    durabilityLossPerDeath = 1,
    durabilityWarnAt = 3,
}

-- ============================================================
--  RZ COINS AND THE SHOP
-- ============================================================
Config.Coins = {
    -- What the currency is called on screen.
    label = 'RZ Coins',
    short = 'RZC',

    -- Converting coins to in-city money. Goes straight to the BANK, not
    -- cash -- money that appears in a pocket during a firefight is money
    -- someone will argue about.
    convert = {
        enabled = true,

        -- How many dollars one coin is worth.
        rate = 5,

        -- Least you can convert at once, so the ledger is not a thousand
        -- one-coin lines.
        minimum = 50,

        -- Cut taken on conversion, as a fraction. 0.1 is 10%.
        -- A sink keeps the economy from inflating; set 0 for none.
        fee = 0.05,
    },
}

-- What the shop sells. Prices are in coins.
--
-- The cheap pistol matters: someone with nothing needs a way back in that
-- does not require grinding first. It is deliberately worse than everything
-- else so it is a stepping stone, not a destination.
-- ── flat things to hang a board on ──
--
-- Candidates for a big flat surface with no pole. I cannot verify these
-- without the game, so rather than guess one and have you chase it:
--
--   /rzprops            step through them one at a time
--   /rzprops next       the next one
--   /rzprops use        place the one you are looking at
--
-- Each spawns in front of you so you can see it before committing. Add any
-- you find to this list.
Config.FlatProps = {
    -- billboard faces, some of which are the panel alone
    'prop_billboard_04',
    'prop_billboard_06',
    'prop_billboard_09',
    'prop_billboard_12',
    'prop_billboard_16',

    -- shipping container sides: genuinely large and completely flat
    'prop_container_ld',
    'prop_container_ld_pu',
    'prop_contnr_01a',

    -- flat sheets and plates
    'prop_metal_plates01',
    'prop_metal_plates02',
    'prop_rub_planks_01',
    'prop_woodpile_01a',

    -- gates and fence panels, flat and tall
    'prop_facgate_04b',
    'prop_fnclink_03gate1',
    'prop_gate_prison_01',
    'prop_sec_barrier_ld_02a',

    -- screens, if you want something that already looks like a display
    'prop_ld_screen_01',
    'prop_tv_flat_03',
    'prop_monitor_01a',

    -- walls
    'prop_wallbrick_01',
    'prop_barrier_wat_03a',
    'prop_mp_barrier_02b',
}

Config.Shop = {
    enabled = true,

    -- The ped, in the lobby.
    ped = {
        model = 's_m_m_ammucountry',
        coords = vec4(290.28, -1621.39, 30.53, 1.07),
        scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
        label = 'Arena Shop',
        icon = 'fas fa-store',
        distance = 2.5,
    },

    categories = {
        {
            name = 'Weapons',
            items = {
                { item = 'WEAPON_PISTOL',       price = 150,  label = 'Pistol' },
                { item = 'WEAPON_COMBATPISTOL', price = 450,  label = 'Combat Pistol' },
                { item = 'WEAPON_APPISTOL',     price = 650,  label = 'AP Pistol' },
            }
        },
        {
            name = 'Supplies',
            items = {
                { item = 'ammo-9',        price = 25,  count = 60 },
            }
        },
        {
            name = 'Field kit',
            items = {
                { item = 'naija_slurpy',  price = 120, count = 1 },
                { item = 'n46_gummies',   price = 200, count = 1 },
            }
        },
    },
}

-- ============================================================
--  RANKED
-- ============================================================
-- A separate ladder from the casual queue. Same arenas, same rules, but the
-- result counts -- and it is scored with Elo rather than a win count, so
-- beating someone above you is worth more than beating someone below.
Config.Ranked = {
    enabled = true,

    -- Everyone starts here. Middle of Bronze, so the first few results move
    -- you somewhere meaningful rather than crawling off zero.
    startingElo = 1000,

    -- Matches before a rank is shown. Until then it says provisional, and
    -- swings are larger so people land near where they belong quickly rather
    -- than grinding out of a bad start.
    placementMatches = 10,
    placementMultiplier = 2.0,

    -- How much a single result can move you. Higher K = faster, twitchier.
    --
    -- 32 is the chess default, but chess players have careers and your
    -- players have evenings. At 32 a 60% player needs about 230 matches to
    -- reach Gold; at 40 that is nearer 180, which is a season rather than a
    -- year. Raise it further if the ladder still feels slow.
    kFactor = 40,

    -- Elo never drops below this, so a bad run cannot bury someone.
    floor = 100,

    -- Modes that count toward rank. Anything not listed is casual.
    -- Modes that CAN be ranked. Whether a given match actually is depends on
    -- which panel you queued from -- these are the ones the ranked panel
    -- offers at all.
    rankedModes = { '1v1', '2v2', '3v3', '4v4', 'squad' },

    -- What a ranked match pays on top of the casual reward. Winning a rated
    -- game is worth more than winning a friendly, and it should feel like it.
    coins = {
        win = 120,
        loss = 40,
    },

    -- ── the ladder ──
    --
    -- Colours are used by the badge, which is drawn rather than an image --
    -- so adding a tier here is all it takes to have one.
    --   hue drives the gem, accent is the glow, and tier picks the shape:
    --   1 plain gem, 2 gains shoulders, 3 gains wings, 4 gains a crown.
    tiers = {
        -- Spacing is tighter at the bottom and widens as you climb. An even
        -- spread meant roughly 290 matches to reach Gold at a 60% win rate,
        -- which leaves the middle of the ladder feeling dead. Early tiers
        -- should come quickly enough to show the system works; the top
        -- should take real time.
        { name = 'Bronze I',    elo = 0,    hue = '#B06A3A', accent = '#E39B62', tier = 1 },
        { name = 'Bronze II',   elo = 1060, hue = '#BE7440', accent = '#F0A96D', tier = 1 },
        { name = 'Bronze III',  elo = 1130, hue = '#CC7E46', accent = '#FFB877', tier = 1 },

        { name = 'Silver I',    elo = 1220, hue = '#8A93A8', accent = '#C3CBDA', tier = 2 },
        { name = 'Silver II',   elo = 1320, hue = '#98A2B8', accent = '#D2DAE8', tier = 2 },
        { name = 'Silver III',  elo = 1430, hue = '#A6B1C8', accent = '#E1E8F4', tier = 2 },

        { name = 'Gold I',      elo = 1560, hue = '#C9A227', accent = '#F2D06B', tier = 2 },
        { name = 'Gold II',     elo = 1700, hue = '#D6AE2E', accent = '#FFDC7C', tier = 2 },
        { name = 'Gold III',    elo = 1860, hue = '#E3BA35', accent = '#FFE68D', tier = 2 },

        { name = 'Platinum I',  elo = 2040, hue = '#2DD4BF', accent = '#7FF0E2', tier = 3 },
        { name = 'Platinum II', elo = 2240, hue = '#38E0CB', accent = '#8DF7EA', tier = 3 },
        { name = 'Platinum III', elo = 2460, hue = '#43ECD7', accent = '#9BFFF2', tier = 3 },

        { name = 'Diamond',     elo = 2700, hue = '#4EA8F7', accent = '#9BCEFF', tier = 3 },
        { name = 'Master',      elo = 2980, hue = '#A855F7', accent = '#D5AAFF', tier = 4 },
        { name = 'Grandmaster', elo = 3300, hue = '#C026D3', accent = '#F0A6FA', tier = 4 },
        { name = 'Champion',    elo = 3650, hue = '#F472B6', accent = '#FFB3DA', tier = 4 },
    },
}

-- ============================================================
--  WALL BOARDS
-- ============================================================
-- Every board that can be marked with /rzboard, defined here rather than
-- buried in the page or the server.
--
-- The kinds, their titles, their colours and their columns all come from
-- this table -- so renaming a board, recolouring one, or changing which
-- numbers it shows is a config edit, not a code edit. Add a kind here and
-- /rzboard accepts it immediately.
--
-- source   which set of numbers the board reads
--            'pvp'      unranked match record
--            'ranked'   the ELO ladder
--            'info'     live queues and zones (no leaderboard)
--
-- columns  what each row shows, left to right after the rank and name.
--            key    which field to read
--            label  the column heading
--            tone   colour: nil, 'dim', 'good', 'bad', 'hot'
--            width  column width in px
-- ============================================================
--  WALL BOARDS
-- ============================================================
-- Three kinds, marked with /rzboard <kind> <name>:
--
--   pvp     the two casual leaderboards, alternating
--   ranked  the ladder, on its own
--   list    what is happening right now -- queues and live zones
--
-- Old names still work. A board marked before this keeps pointing at
-- something sensible rather than going blank or, worse, quietly showing the
-- wrong leaderboard -- see Config.BoardAliases below.
Config.Boards = {
    pvp = {
        -- Two sources, shown one at a time.
        --
        -- Side by side halves the width of each and costs the readability
        -- that makes a wall worth looking at from across a street. So it
        -- alternates instead: full width, one at a time.
        sources = { 'pvp' },
        rotate = 20,            -- seconds on each before it swaps

        titles = {
            pvp     = 'NAIJA 2046 PVP LEADERBOARD',
        },
        footers = {
            pvp     = 'NAIJA 2046 · 100 A WIN · 25 A LOSS · 10 A KILL',
        },
    },

    ranked = {
        sources = { 'ranked' },
        title  = 'NAIJA 2046 RANKED',
        footer = 'SEASON 3 · TEN MATCHES TO PLACE',
    },

    list = {
        sources = { 'info' },
        title  = 'NAIJA 2046',
    },
}

-- What older board kinds now mean.
--
-- Boards live in the database, so renaming a kind would strand every wall
-- already marked. Nothing here maps to ranked on purpose: a board marked
-- before ranked existed should never start showing it.
Config.BoardAliases = {
    rzpvp    = 'pvp',
    rotate   = 'pvp',
    rzranked = 'ranked',
    info     = 'list',
}

-- ============================================================
--  WAGERS
-- ============================================================
-- Casual rooms only. Both sides put coins in, the winners take the pot.
--
-- Not on ranked: a rating already means something, and money on top of it
-- turns a bad game into a real loss. Casual is where a side bet belongs.
Config.Wager = {
    enabled = true,

    -- What can be staked, per player. Anything not on this list is refused,
    -- which is simpler to reason about than a min and max.
    amounts = { 0, 50, 100, 250, 500, 1000 },

    -- Taken when the match starts, not when it is agreed.
    --
    -- Held by the server for the duration -- otherwise someone stakes 500,
    -- spends it in the shop while the countdown runs, and wins a pot that
    -- was never fully paid in.
    --
    -- If a match is called off, everything goes back.
    houseCut = 0,     -- fraction the house keeps, 0.05 for 5%. 0 for none.
}

-- ============================================================
--  INTERACTION PROMPTS
-- ============================================================
-- The floating bubble over a ped: a key chip, a label, and a tail pointing
-- down at whatever it belongs to.
--
-- Drawn in the NUI rather than with DrawRect, because DrawRect gives you a
-- sharp rectangle and no tail. Rounded corners, the chip and the font are the
-- whole point of the look, and natives cannot do any of them.
--
-- ox_target still works if you prefer it -- set useTarget below. The two are
-- deliberately exclusive: a ped offering both is two ways to do one thing,
-- and players find the worse one.
Config.Prompt = {
    enabled = true,

    -- true  = ox_target eye on every ped, no bubbles (the old behaviour)
    -- false = bubbles, and ox_target is not registered for these peds at all
    useTarget = false,

    -- How close before a bubble appears. Per-prompt values override this.
    distance = 2.5,

    -- How far above the ped's origin the bubble floats, in metres.
    offset = 1.05,

    -- How often the scan for "is anything near me" runs, in ms. The bubble
    -- itself follows the camera every frame once one is in range; this is
    -- only the cheap check that decides whether that happens at all.
    scanInterval = 400,
}

-- ============================================================
--  WARDROBE
-- ============================================================
-- A ped that opens your saved outfits. No shop, no buying -- this fires
-- illenium-appearance's outfit menu, which only lists looks you already
-- saved.
--
-- The event is client-side and takes no arguments. If you run a different
-- appearance script, change `event` to whatever it uses:
--     qb-clothing          qb-clothing:client:openOutfitMenu
--     fivem-appearance     handled by export, set `export` instead
Config.Wardrobe = {
    enabled = true,

    -- Lobby only, like the shop ped.
    ped = {
        model = 's_f_y_shop_low',
        coords = vec4(276.95, -1584.82, 30.53, 211.20),
        scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
        distance = 2.5,
    },

    title = 'WARDROBE',
    label = 'Change outfit',
    keyLabel = 'E',
    key = 38,

    -- op-clothing's free wardrobe. No prices, nothing to spend.
    --
    -- Worth knowing: OpenWardrobe gives owned outfits AND the full catalogue
    -- for free, which is more than "change into what you already have". If
    -- you want it limited to saved outfits only, op-clothing has no export
    -- that does it -- that would be a request to them, not something this can
    -- work around.
    export = { resource = 'op-clothing', method = 'OpenWardrobe' },

    -- Used only when export is nil. Left here for other clothing scripts:
    --   illenium-appearance   illenium-appearance:client:openOutfitMenu
    --   qb-clothing           qb-clothing:client:openOutfitMenu
    --   op-clothing           op-clothing:client:openWardrobe
    event = 'op-clothing:client:openWardrobe',
}

-- ============================================================
--  THE PODIUM
-- ============================================================
-- The top three ranked players, standing first, second and third, with their
-- rank and rating above them.
--
-- NO PROPS ARE PLACED BY THIS. You already have /rzprop and /rzprops for
-- putting models in the world, and they are a far better way to build the
-- platform than a model name guessed in here -- a wrong one is an invisible
-- prop and somebody standing on nothing. Place the podium yourself, then set
-- the three coordinates below to stand on top of it.
--
-- The Z is the one you read STANDING THERE -- your own coordinates, not the
-- floor. Peds in this resource are all created one metre below the coordinate
-- given, which is what makes a player's own position work as a ped position.
-- Read your coords while stood where you want them and paste that in.
Config.Podium = {
    enabled = true,

    -- Lobby only. There is no reason to pay for this out in the city.
    lobbyOnly = true,

    -- How often the standings are re-read, in ms. Ranked ratings do not move
    -- quickly enough to be worth checking often.
    refresh = 120000,

    -- How far away the peds and their labels appear.
    drawDistance = 12.0,

    -- First, second, third. Heading is which way they face.
    spots = {
        vec4(272.25, -1612.09, 31.15, 308.54),   -- 1st, the middle and highest
        vec4(273.19, -1613.36, 30.95, 307.47),   -- 2nd
        vec4(271.18, -1611.00, 30.80, 296.12),   -- 3rd
    },

    -- Fallback models, used when a player's own look cannot be applied.
    --
    -- Applying the REAL player's appearance means reading their saved skin
    -- out of the appearance script's tables and rebuilding it on a ped, which
    -- breaks for anyone who has never saved one. These stand in instead: the
    -- rank, the name and the rating above them are the part that matters.
    models = { 'a_m_y_business_01', 'a_m_y_hipster_01', 'a_m_y_skater_01' },

    -- What they do while standing there.
    scenario = 'WORLD_HUMAN_GUARD_STAND',

    -- Shown when nobody has placed yet.
    emptyLabel = 'UNCLAIMED',

    -- ── real characters on the podium ──
    --
    -- On: the top three appear as themselves -- their face, their clothes,
    -- whatever they were wearing last time they played a ranked match.
    -- Off: the stand-in models above.
    --
    -- How it works, because the limitation matters: every clothing script's
    -- "get appearance" takes a CONNECTED player, and a leaderboard is mostly
    -- people who are offline. So a look is captured when a ranked result is
    -- written -- the one moment somebody is both online and worth putting on
    -- a podium -- and stored against their ranked row.
    --
    -- It therefore fills in over time. Anyone who has not played a ranked
    -- match since this was turned on shows a stand-in until they do.
    realFaces = true,

    -- Where to ask, in order. The first started resource that answers wins.
    --
    -- op-clothing is first because it is what this server runs. The rest are
    -- there so this keeps working if the clothing script is ever swapped --
    -- op-clothing itself ships a compatibility layer that answers to several
    -- of these names, so more than one may be live at once.
    appearanceGet = {
        { resource = 'op-clothing',          export = 'GetAppearance' },
        { resource = 'illenium-appearance',  export = 'getPlayerAppearance' },
        { resource = 'fivem-appearance',     export = 'getPlayerAppearance' },
        { resource = 'qb-clothing',          export = 'getPlayerSkin' },
    },

    -- And where to APPLY it, client side, on the podium ped.
    --
    -- These take a PED, which is the important part -- the server-side
    -- SetAppearance saves as well as applies, and pointing that at a podium
    -- would overwrite a real player's stored look. These only dress a ped and
    -- persist nothing.
    appearanceSet = {
        { resource = 'op-clothing',          export = 'SetPedAppearance' },
        { resource = 'illenium-appearance',  export = 'setPedAppearance' },
        { resource = 'fivem-appearance',     export = 'setPedAppearance' },
        { resource = 'rcore_clothing',       export = 'setPedSkin' },
    },
}

-- ============================================================
--  HANDING ZONES TO tenx-zones
-- ============================================================
-- OFF. Turning this on moves every boundary, wall and in/out test to
-- tenx-zones, and switches the arena's own clamp off so the two never fight
-- over the same player.
--
-- The arena's boundary code is still present and still works with this off.
-- It is removed only once the handover has been tested on a live server, so
-- that going back is a config change rather than a rollback.
--
-- Before turning it on:
--   1. ensure tenx-zones BEFORE this resource in server.cfg
--   2. run the migration so every arena has a zoneId
--   3. flip this and restart
--
-- With it on and tenx-zones missing or too old, this resource refuses to
-- start and prints exactly which exports are absent. That is deliberate --
-- a half-working boundary is worse than none, because nobody notices.
Config.Zones = {
    -- ON. tenx-zones owns every boundary, wall and in/out test, and the
    -- arena's own clamp stands down so the two never fight over the same
    -- player.
    --
    -- This is now a hard dependency: with it on and tenx-zones missing,
    -- stopped or too old, this resource REFUSES TO START and prints exactly
    -- which exports are absent. That is deliberate -- a half-handed-over
    -- boundary is worse than either side owning it, because nobody notices.
    --
    -- ensure tenx-zones BEFORE this resource in server.cfg.
    --
    -- Set back to false to return to the arena's own boundary code, which is
    -- still present and still works. That remains the way back if anything
    -- goes wrong.
    useExternal = true,

    -- How far a spawn point may sit from the boundary when it is validated.
    -- Team spawns must be inside; Red Zone entry spawns must be outside and
    -- within this distance, so players land near the wall and walk in rather
    -- than hiking.
    spawnTolerance = 5.0,
}

-- ============================================================
--  HOW LONG A PLAYER STAYS DOWN
-- ============================================================
-- The arena's half of the same setting the Red Zone has. One number for the
-- wait between going down and being picked up, healed and put back.
--
-- "Down" means EITHER of:
--   · knocked -- the ambulance script's incapacitated state, where the ped is
--     still alive on full health and only their screen says otherwise
--   · dead -- properly dead, ped and all
--
-- Both wait the same and both end the same way. There is deliberately no
-- separate path for one or the other: to the player they are the same thing,
-- and making them behave differently is what made this hard to test.
--
-- This governs the LOBBY pickup. A match respawn has its own timing tied to
-- rounds and scoring, in Config.Match.
Config.Down = {
    -- Seconds from going down to the revive, heal and pickup firing.
    delay = 10.0,

    -- How often to look, in seconds. It only matters once somebody is down,
    -- so slower is fine.
    checkEvery = 2.0,
}
