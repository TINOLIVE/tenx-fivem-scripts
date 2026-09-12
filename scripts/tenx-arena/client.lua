-- ============================================================
--  STATE
-- ============================================================
local zones = {}          -- every arena, for drawing boundaries
local myArena = nil       -- the one I'm currently inside
local panelOpen = false
local blockedUntil = 0    -- while the wall is holding me back

-- ============================================================
--  NUI FOCUS
-- ============================================================
-- Focus is owned in one place. Several things can want the cursor -- the
-- builder, the player panel, the ready check, the map vote -- and if each set
-- it directly, whichever finished last would either steal it while another
-- still needed it or never give it back.
--
-- Each holds a named claim. Claims come in two kinds, and the difference
-- matters:
--
--   DELIBERATE (builder, panel) -- you opened it, so nothing releases it
--     except you. No timeout, no watchdog, no cleverness. An admin using the
--     builder during a live match is perfectly normal and must never have the
--     cursor taken away mid-click.
--
--   TRANSIENT (ready check, map vote) -- these appear on their own and are
--     expected to be gone within a known time. If one is still held long past
--     that, the flow broke somewhere and it gets dropped.
--
-- Only transient claims can ever expire. That is the whole safety mechanism.
local focusClaims = {}

local FOCUS_TTL = {
    ready = 60,   -- ready check: 20s window, so 60 is well past any real case
    vote  = 60,   -- map vote: same
    -- builder and panel deliberately absent: they never expire
}

local function applyFocus()
    local want = next(focusClaims) ~= nil
    SetNuiFocus(want, want)
end

--- Every notification goes through here.
---
--- 42 lib.notify calls and only 6 set a position, so the rest landed wherever
--- ox_lib defaults to -- the side of the screen, in the same column as every
--- other resource on the server. A message nobody reads is not a message.
function ArenaNotify(opts)
    opts = opts or {}
    opts.position = opts.position or Config.NotifyPosition or 'top-center'
    opts.title = opts.title or (Config.Brand or {}).notifyTitle or 'PVP'
    lib.notify(opts)
end

local function setFocus(reason, on)
    if on then
        focusClaims[reason] = GetGameTimer()
    else
        focusClaims[reason] = nil
    end
    applyFocus()
end

-- Whether the player panel is up. It was an implicit global -- it worked,
-- but anything else in the resource could have written to it by accident.
local playerPanelOpen = false

local function dropAllFocus()
    focusClaims = {}
    SetNuiFocus(false, false)
end

-- Only ever drops a transient claim that has outlived its window. A claim you
-- made by opening something is never touched.
CreateThread(function()
    while true do
        Wait(5000)

        local changed = false
        local now = GetGameTimer()

        for reason, since in pairs(focusClaims) do
            local ttl = FOCUS_TTL[reason]
            if ttl and (now - since) > (ttl * 1000) then
                focusClaims[reason] = nil
                changed = true
                print(('[arena] Dropped a stale "%s" cursor claim after %ss'):format(reason, ttl))
            end
        end

        if changed then
            applyFocus()
            SendNUIMessage({ action = 'forceClose' })
        end
    end
end)

-- Manual way out, if anything ever slips past all of that.
RegisterCommand('rzunstick', function()
    dropAllFocus()
    SendNUIMessage({ action = 'forceClose' })

    -- Say what is actually holding things, then let go of all of it.
    --
    -- This used to only drop NUI focus, which is not what people run it for.
    -- A stuck inventory has several possible owners and no way to tell them
    -- apart from in front of it, so it prints every flag that decides the
    -- lock before releasing.
    --
    -- The distinction that matters is invBusy vs ours: this resource only
    -- ever clears a lock it set itself, so an inventory still shut after this
    -- is being held by something else on the server and no amount of arena
    -- changes will open it.
    print('^3[arena] ---- inventory lock ----^0')
    print(('  ox_inventory invBusy : %s'):format(tostring(LocalPlayer.state.invBusy)))
    print(('  held by this resource: %s'):format(tostring(ArenaHoldsInvLock and ArenaHoldsInvLock())))
    print(('  arenaMatch           : %s'):format(tostring(LocalPlayer.state.arenaMatch)))
    print(('  arenaLobby           : %s'):format(tostring(LocalPlayer.state.arenaLobby)))
    print(('  arenaClaimed         : %s'):format(tostring(LocalPlayer.state.arenaClaimed)))
    print(('  LobbyKit             : %s'):format(tostring(LobbyKit)))
    print(('  KitHeldExternally    : %s'):format(tostring(KitHeldExternally)))
    print(('  Hotbar.active        : %s'):format(tostring(ArenaKitActive and ArenaKitActive())))
    print('^3[arena] ------------------------^0')

    -- Cuffs off, because this is the command people run when they are stuck
    -- and a leftover restraint is one of the ways to BE stuck: weapon locked,
    -- inventory refusing to open with "cannot open inventory (cuffed)".
    --
    -- Only ever run by staff or on yourself, so it cannot free a genuinely
    -- arrested player who did not ask for it.
    local ped = PlayerPedId()
    local wasCuffed = IsPedCuffed(ped)

    if wasCuffed then
        print('^3[arena] you were CUFFED -- releasing^0')
        SetEnableHandcuffs(ped, false)
        ClearPedSecondaryTask(ped)
        SetPedCanPlayGestureAnims(ped, true)
    end

    -- The weapon, which is the part that has been guesswork.
    do
        local sel = Hotbar and (Hotbar.slots or {})[Hotbar.selected]

        if sel and sel.name then
            local hash = joaat(sel.name)
            local onPed = HasPedGotWeapon(ped, hash, false)
            local _, cur = GetCurrentPedWeapon(ped, true)

            print(('  selected slot        : %s (%s)'):format(tostring(Hotbar.selected), sel.name))
            print(('  on ped               : %s'):format(tostring(onPed)))
            print(('  in hand              : %s'):format(tostring(cur == hash)))
            print(('  ammo                 : %s'):format(tostring(GetAmmoInPedWeapon(ped, hash))))

            -- Cuffs are checked FIRST, because they explain a weapon that
            -- will not stay drawn AND an inventory that will not open. Read
            -- as a holster problem it sends you after the wrong resource --
            -- which is exactly what happened here for a long time.
            if wasCuffed then
                print('^1  -> you were CUFFED. That unequips the weapon and blocks^0')
                print('^1     the inventory. Released above.^0')
            elseif onPed and cur ~= hash then
                print('^3  -> on the ped but not drawn: something is HOLSTERING you^0')
            elseif not onPed then
                print('^1  -> gone from the ped entirely: something is REMOVING it^0')
            end
        end
    end

    local wasOurs = ArenaHoldsInvLock and ArenaHoldsInvLock()

    LobbyKit = false
    KitHeldExternally = false
    if ArenaKitActive and ArenaKitActive() and ArenaHotbarStop then ArenaHotbarStop() end
    if ArenaReleaseInvLock then ArenaReleaseInvLock() end

    local msg = wasOurs
        and 'Interface released, and the inventory lock was ours -- cleared.'
        or (LocalPlayer.state.invBusy
            and 'Interface released. The inventory is locked by something ELSE -- see F8.'
            or 'Interface released. Nothing was holding the inventory.')

    ArenaNotify({
        title = (Config.Brand or {}).notifyTitle or 'PVP',
        description = msg,
        type = 'inform',
        position = Config.NotifyPosition or 'top-center'
    })
end, false)

-- ============================================================
--  FAIR FIGHTS
-- ============================================================
-- GTA decides a hit on the shooter's machine against a position it received a
-- moment ago. Nothing here changes that -- "I shot first" arguments come with
-- every online shooter.
--
-- What it does fix is the rest: invincibility that never cleared, damage
-- modifiers that differ between clients, and health the server and client
-- disagree about. On a scripted arena those cause far more disputed kills
-- than lag does.

-- Exactly when we intend someone to be untouchable. Anything else is a bug.
local protectedUntil = 0

-- Your HUD's stamina bar belongs to another resource and no native reaches
-- it. This flag is for that resource to read, so it can skip draining during
-- a match. One line in whatever owns your HUD:
--
--   if LocalPlayer.state.arenaNoStamina then return end
--
-- in its drain loop, and the bar stops moving during matches.
CreateThread(function()
    local last = nil

    while true do
        Wait(500)

        local want = (LocalPlayer.state.arenaMatch
            and Config.Fair and Config.Fair.infiniteStamina ~= false) or false

        if want ~= last then
            last = want
            LocalPlayer.state:set('arenaNoStamina', want, true)
        end
    end
end)

-- Tells us which stamina is actually the problem instead of guessing.
RegisterCommand('rzstamina', function()
    local player = PlayerId()
    local ped = PlayerPedId()

    print('^3============ STAMINA CHECK ============^0')
    print(('in a match:            %s'):format(tostring(LocalPlayer.state.arenaMatch or false)))
    print(('Config.Fair present:   %s'):format(tostring(Config.Fair ~= nil)))
    print(('infiniteStamina:       %s'):format(
        tostring(Config.Fair and Config.Fair.infiniteStamina)))
    print(('arenaNoStamina flag:   %s'):format(tostring(LocalPlayer.state.arenaNoStamina or false)))
    print('')
    local okA, rem = pcall(GetPlayerSprintStaminaRemaining, player)
    local okB, tim = pcall(GetPlayerSprintTimeRemaining, player)
    print(('GTA sprint remaining:  %s'):format(okA and ('%.1f'):format(rem) or 'unavailable'))
    print(('GTA sprint time left:  %s'):format(okB and ('%.1f'):format(tim) or 'unavailable'))
    print(('ped is sprinting:      %s'):format(tostring(IsPedSprinting(ped))))
    print('')
    print('^3If sprint remaining stays high while your HUD bar drains, the bar^0')
    print('^3belongs to another resource and needs the one-line guard above.^0')
    print('^3======================================^0')
end, false)

function ArenaProtect(seconds)
    protectedUntil = GetGameTimer() + math.floor((seconds or 0) * 1000)
end

function ArenaProtectClear()
    protectedUntil = 0
end

-- The watchdog. Invincible outside a protection window means something failed
-- to clean up -- a thread that died, a player who left mid-protection -- and
-- the result is somebody bulletproof for the rest of the match.
CreateThread(function()
    while true do
        Wait(500)

        if Config.Fair and Config.Fair.invincibilityWatchdog ~= false then
            local ped = PlayerPedId()
            local shouldBeProtected = GetGameTimer() < protectedUntil

            if not shouldBeProtected then
                -- Cheap to set every half second. Guarded because this is the
                -- one loop that absolutely must not die: if it does, someone
                -- eventually stays bulletproof.
                pcall(SetEntityInvincible, ped, false)
                pcall(SetPlayerInvincible, PlayerId(), false)
                pcall(SetEntityProofs, ped, false, false, false, false, false, false, false, false)
            end
        end
    end
end)

-- Everything that has to hold true for the whole match.
--
-- Every native call is guarded. One that does not exist -- a typo, or a name
-- that changed between builds -- throws, and a throw kills the whole thread.
-- That is exactly what happened here: a made-up defence-modifier native took
-- the loop down on its first pass, and with it the stamina restore that runs
-- in the same loop. Stamina "not working" was really "the thread is dead".
local function try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        -- Say it once rather than every frame.
        if not _G.__arenaNativeWarned then _G.__arenaNativeWarned = {} end
        local msg = tostring(err)
        if not _G.__arenaNativeWarned[msg] then
            _G.__arenaNativeWarned[msg] = true
            print('^3[arena] skipping an unavailable native: ' .. msg .. '^0')
        end
    end
    return ok
end

CreateThread(function()
    while true do
        local sleep = 1000

        -- Fair-fight rules: same weapons, same
        -- stamina, same lack of aim assist.
        local _p = PerfLoop and PerfLoop('fair-fight')

        -- Anywhere the arena has you, not just mid-match.
        --
        -- This tested arenaMatch alone, so the lobby and any mode running on
        -- top of the arena had ordinary GTA stamina -- you could run out of
        -- breath crossing the lobby, or in the middle of a Red Zone fight,
        -- while a match two metres away had none of that.
        --
        -- The rule was always meant to be "inside the arena's world, everyone
        -- is equal", and the lobby and the Red Zone are part of that world.
        -- KitShouldHold is the same answer the kit itself uses, so the two
        -- cannot drift apart.
        if KitShouldHold and KitShouldHold() and Config.Fair then
            -- NOT every frame.
            --
            -- This used to run at sleep = 0, so eight natives fired sixty
            -- times a second for the whole time you were fighting. None
            -- of them need that: they set a value that stays set. Something
            -- else has to actively change a damage modifier for this to have
            -- anything to do, and nothing does that per frame.
            --
            -- Stamina is the only one that drains continuously, and topping
            -- it up four times a second is indistinguishable from sixty.
            sleep = 250
            local player = PlayerId()
            local ped = PlayerPedId()

            -- Stamina. Nobody should lose a fight because they ran out of
            -- breath.
            --
            -- Two different things go by this name and they are unrelated:
            --   GTA sprint stamina -- how long you can run. RestorePlayerStamina.
            --   A framework stamina bar -- the one on your HUD next to hunger
            --     and water. That belongs to another resource entirely and no
            --     native touches it.
            if Config.Fair.infiniteStamina ~= false then
                try(RestorePlayerStamina, player, 1.0)
            end

            -- The same shot has to do the same damage whoever fires it. A
            -- modifier left on by another resource is invisible and decides
            -- fights.
            if Config.Fair.normaliseDamage ~= false then
                local mod = Config.Fair.damageModifier or 1.0
                try(SetPlayerWeaponDamageModifier, player, mod)
                try(SetPlayerMeleeWeaponDamageModifier, player, mod)
                try(SetPlayerWeaponDefenseModifier, player, 1.0)
                try(SetPlayerMeleeWeaponDefenseModifier, player, 1.0)
            end

            -- Controller and mouse on the same terms.
            if Config.Fair.disableAimAssist ~= false then
                try(SetPlayerLockonRangeOverride, player, 0.0)
                try(SetPlayerTargetingMode, 3)   -- 3 = free aim
            end
        else
            sleep = 1500
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- The server holds the real health and corrects a client that has drifted.
-- This is the one that stops "my screen said he was nearly dead".
RegisterNetEvent('naija-arena:client:syncHealth', function(expected)
    local ped = PlayerPedId()
    local actual = GetEntityHealth(ped)
    local tol = (Config.Fair and Config.Fair.healthSyncTolerance) or 15

    if math.abs(actual - expected) > tol then
        print(('[arena] health drift: client %s, server %s -- correcting'):format(actual, expected))
        SetEntityHealth(ped, expected)
    end
end)

-- ============================================================
--  BRINGING SOMEONE BACK
-- ============================================================
-- All of this happens inside the black screen of the respawn teleport, and
-- nowhere else.
--
-- Reviving at the moment of death fought their script every time: the revive
-- landed while their death UI was still animating in, did nothing, and the
-- screen stayed up for the rest of the match. Inside the fade nothing else is
-- competing -- their screen has long since finished, no other transition is
-- running, and the player cannot see any of it.

-- Which candidate worked, once we know. Cached for the session so only the
-- first death pays the cost of finding out.
local knownRevive = nil
local knownSkelly = nil

-- Which of their two states we are in, as reported by their own events.
--   'up' | 'knocked' | 'dead'
--
-- KNOCKED is the one that broke everything. A knocked player has a live ped
-- on full health -- only their UI and their internal flag say otherwise -- so
-- every IsEntityDead check I wrote correctly answered "not down" while the
-- player sat there staring at an incapacitated screen.
ArenaBodyState = 'up'

--- The QBCore object, fetched once. false means the fetch failed and should
--- not be retried on every call.
QBCoreCached = nil

--- The server heard their script and is telling us.
---
--- Covers the case where the ambulance script fires only its server-side
--- trigger. Without this the client half stays silent and the arena believes
--- somebody on an incapacitated screen is fine -- which is what
--- /rztestrevive reported: state up, health 200, staring at INCAPACITATED.
RegisterNetEvent('naija-arena:client:bodyState', function(state)
    if state ~= 'knocked' and state ~= 'dead' and state ~= 'up' then return end

    ArenaBodyState = state
    print(('[arena] their script (via server) says: %s'):format(state:upper()))
    TriggerEvent('naija-arena:bodyStateChanged', state)
end)

-- Their events are the truth. The ped is not.
CreateThread(function()
    Wait(1000)
    local cfg = Config.Ambulance

    if cfg.downEvent then
        RegisterNetEvent(cfg.downEvent)
        AddEventHandler(cfg.downEvent, function()
            ArenaBodyState = 'knocked'
            print('[arena] their script says: KNOCKED')
            TriggerEvent('naija-arena:bodyStateChanged', 'knocked')
        end)
    end

    if cfg.deathEvent then
        RegisterNetEvent(cfg.deathEvent)
        AddEventHandler(cfg.deathEvent, function()
            ArenaBodyState = 'dead'
            print('[arena] their script says: DEAD')
            TriggerEvent('naija-arena:bodyStateChanged', 'dead')
        end)
    end

    if cfg.reviveEvent then
        RegisterNetEvent(cfg.reviveEvent)
        AddEventHandler(cfg.reviveEvent, function()
            ArenaBodyState = 'up'
            print('[arena] their script says: REVIVED')
            TriggerEvent('naija-arena:bodyStateChanged', 'up')
        end)
    end
end)

-- Down by any measure: their state, the ped, or any flag a script might set.
local function isDown()
    local ped = PlayerPedId()

    -- Their own state first, because it is the only one that knows about
    -- being knocked.
    if ArenaBodyState == 'knocked' then return true, 'knocked' end
    if ArenaBodyState == 'dead' then return true, 'dead' end

    if IsEntityDead(ped) or IsPedFatallyInjured(ped) then return true, 'ped dead' end
    if GetEntityHealth(ped) <= 100 then return true, 'health floor' end

    -- CUFFED counts as down.
    --
    -- ak47_qb_ambulancejob restrains a downed player rather than killing the
    -- ped: health stays at 200, the ped stays alive, no statebag changes, and
    -- every other check here answers "fine". Cuffs are the one thing that
    -- moves -- which is why this resource spent so long reporting "state: up,
    -- health: 200" at a player staring at an incapacitated screen.
    --
    -- Safe inside this resource's world: nobody is being arrested in an arena
    -- or a Red Zone, so cuffed here means downed, not policed.
    if IsPedCuffed(ped) then return true, 'cuffed' end

    -- Statebags. Different scripts use different names, so check the lot.
    local st = LocalPlayer.state
    for _, flag in ipairs({ 'dead', 'isDead', 'isdead', 'laststand',
                            'inLaststand', 'inlaststand', 'downed', 'knockedout' }) do
        if st[flag] then return true, 'state.' .. flag end
    end

    -- QBCore keeps it in player metadata.
    -- The core object is fetched ONCE and kept.
    --
    -- GetCoreObject marshals the whole QBCore table across a resource
    -- boundary, and this is the LAST check here -- so a player who is fine
    -- reaches it every call. Harmless when only the arena's own respawn
    -- asked; not harmless once the Red Zone asked several times a second for
    -- as long as anyone was in a zone. Cross-resource calls are billed to the
    -- resource being called, which is why it showed as the arena costing
    -- milliseconds inside no thread /rzperf could measure.
    if QBCoreCached == nil then
        local gotCore, core = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        QBCoreCached = (gotCore and core) or false
    end

    if QBCoreCached then
        local ok, pd = pcall(function()
            return QBCoreCached.Functions.GetPlayerData()
        end)
        if ok and pd and pd.metadata then
            if pd.metadata.isdead then return true, 'metadata.isdead' end
            if pd.metadata.inlaststand then return true, 'metadata.inlaststand' end
        end
    end

    return false
end

local function fireOne(entry)
    if not entry or not entry.event then return end

    if entry.side == 'server' then
        TriggerServerEvent('naija-arena:server:fireAmbulance', entry.event)
    else
        TriggerEvent(entry.event)
    end
end

--- Try each candidate and check after every one, so we find out what actually
--- works on this server instead of assuming.
--- @return table|nil the entry that worked
local function findWorkingRevive()
    local cfg = Config.Ambulance

    -- Already know? Use it.
    local known = knownRevive or cfg.reviveKnown
    if known then
        fireOne(known)
        local waited = 0
        while waited < 1500 do
            Wait(100)
            waited = waited + 100
            if not isDown() then return known end
        end
        -- It stopped working; fall through and search again.
        print('[arena] The known revive stopped working, searching again')
        knownRevive = nil
    end

    for _, entry in ipairs(cfg.reviveCandidates or {}) do
        print(('[arena] trying revive: %s %s'):format(entry.side, entry.event))
        fireOne(entry)

        local waited = 0
        while waited < (cfg.reviveInterval or 800) do
            Wait(100)
            waited = waited + 100

            if not isDown() then
                knownRevive = entry
                print(('^2[arena] REVIVE WORKED: %s %s^0'):format(entry.side, entry.event))
                print('^2[arena] Put that in Config.Ambulance.reviveKnown to skip the search^0')
                return entry
            end
        end
    end

    return nil
end

local function fireSkelly()
    local cfg = Config.Ambulance

    if knownSkelly then
        fireOne(knownSkelly)
        return
    end

    -- No way to detect whether a skellyfix took, so all candidates are fired.
    -- Triggering an event their script does not listen to costs nothing.
    for _, entry in ipairs(cfg.skellyCandidates or {}) do
        fireOne(entry)
    end
end

local function nativeHeal()
    local ped = PlayerPedId()
    local cfg = Config.Ambulance

    -- Guarded individually so one unavailable native cannot stop the rest --
    -- the health set at the end is the part that matters most.
    pcall(ClearPedBloodDamage, ped)
    pcall(ResetPedVisibleDamage, ped)
    pcall(ClearPedLastWeaponDamage, ped)
    pcall(ResetPedMovementClipset, ped, 0.0)

    pcall(SetPedMaxHealth, ped, cfg.setHealth or 200)
    pcall(SetEntityHealth, ped, cfg.setHealth or 200)
    pcall(SetPedArmour, ped, cfg.setArmour or 0)
end

--- The full sequence, run behind a black screen. Blocking on purpose: the
--- caller fades out, calls this, then teleports and fades back in.
function ArenaReviveBehindFade()
    local cfg = Config.Ambulance

    -- ── revive ──
    -- Fired ALWAYS, never gated on the ped reading as dead.
    --
    -- A KNOCKED player has a live ped on full health, so every IsEntityDead
    -- check answered "not down" and the revive was skipped entirely, for
    -- every round. Their state is the only thing that knows the difference.
    local down, why = isDown()
    print(('[arena] revive starting -- their state: %s, down: %s%s')
        :format(ArenaBodyState, tostring(down), why and (' (' .. why .. ')') or ''))

    do
        local worked = nil

        for round = 1, 2 do
            worked = findWorkingRevive()
            if worked then break end
            if round == 1 then
                print('[arena] no candidate confirmed on the first pass, trying again')
                Wait(500)
            end
        end

        if not worked and cfg.nativeFallback ~= false then
            -- Worth being clear about this: a native resurrect on its own is
            -- usually not enough. Their script keeps its own isDead state and
            -- its loop will put the player straight back down. It is here so
            -- nobody is stranded, not because it is a real fix.
            print('^1[arena] NO REVIVE EVENT WORKED. Falling back to the native.^0')
            print('^1[arena] Run rztestrevive while dead and tell me what it prints.^0')

            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), true, false)
            Wait(500)

            if isDown() then
                print('^1[arena] Still down after the native -- their script is holding the player down.^0')
            end
        end
    end

    ClearPedTasksImmediately(PlayerPedId())

    -- ── then the skelly, once they are genuinely up ──
    Wait(cfg.skellyAfterRevive or 2000)

    for i = 1, math.max(1, cfg.skellyRepeat or 2) do
        fireSkelly()
        if cfg.nativeHealing ~= false then nativeHeal() end
        if i < (cfg.skellyRepeat or 2) then Wait(cfg.skellyInterval or 800) end
    end
end

-- Find out which method actually works here, rather than me guessing again.
RegisterCommand('rztestrevive', function(_, args)
    local force = args and args[1] == 'force'
    local cfg = Config.Ambulance

    print('^3================ ARENA REVIVE TEST ================^0')
    local down, why = isDown()
    print(('their state: %s'):format(ArenaBodyState))
    print(('down: %s%s   health: %s'):format(
        tostring(down), why and (' (' .. why .. ')') or '', GetEntityHealth(PlayerPedId())))

    -- "force" exists because the case that needs this command most is the one
    -- where the arena thinks you are UP.
    --
    -- ak47_qb_ambulancejob can show an incapacitated screen without setting
    -- the ped dead, dropping health, setting a statebag or writing QBCore
    -- metadata -- so every check here answers "fine" while the player stares
    -- at INCAPACITATED. Refusing to run then made the tool useless at exactly
    -- the moment it was needed.
    if not down and not force then
        print('^3The arena thinks you are up.^0')
        print('^3^0')
        print('^3If you are looking at an incapacitated screen right now, that IS^0')
        print('^3the problem: their script has told this resource nothing, so^0')
        print('^3nothing here knows you are down.^0')
        print('^3^0')
        print('^2Run  /rztestrevive force  to try the revive candidates anyway.^0')
        print('^3==================================================^0')
        return
    end

    if force then
        print('^3forced -- ignoring the up/down check^0')
    end

    for _, entry in ipairs(cfg.reviveCandidates or {}) do
        local before = isDown()
        fireOne(entry)
        Wait(1200)
        local after = isDown()
        if ArenaBodyState == 'up' then after = false end

        print(('  %-7s %-42s  %s'):format(
            entry.side, entry.event,
            (before and not after) and '^2<-- THIS ONE WORKED^0' or 'no change'))

        if before and not after then
            print('^2Add this to your config:^0')
            print(("^2  reviveKnown = { side = '%s', event = '%s' },^0"):format(entry.side, entry.event))
            print('^3==================================================^0')
            return
        end
    end

    print('^1None of the candidates worked.^0')
    print('^1Find the real event name: open your ambulance resource and grep for^0')
    print('^1  RegisterNetEvent   in its client files. Send me what you find.^0')
    print('^3==================================================^0')
end, false)

-- ============================================================
--  HELPERS
-- ============================================================
local function boundsOf(id)
    for _, z in ipairs(zones) do
        if z.id == id then return z.bounds, z end
    end
    return nil
end

-- How far outside the box a point is. Zero means inside.
-- How far outside the boundary, flat. Zero when inside.
local function outsideBy(c, b)
    if b.points then
        if Poly.contains(b.points, c.x, c.y) then return 0.0, 0.0 end
        local nx, ny = Poly.nearestEdge(b.points, c.x, c.y)
        return math.abs(c.x - nx), math.abs(c.y - ny)
    end

    local dx = math.max(b.minX - c.x, 0.0, c.x - b.maxX)
    local dy = math.max(b.minY - c.y, 0.0, c.y - b.maxY)
    return dx, dy
end

-- Push back to just inside the nearest edge, not to the middle -- being
-- yanked across the zone would feel far worse than being stopped at the wall.
local function clampToBox(c, b, inset)
    inset = inset or 0.6

    if b.points then
        return Poly.clampInside(b.points, c.x, c.y, inset)
    end

    return
        math.min(math.max(c.x, b.minX + inset), b.maxX - inset),
        math.min(math.max(c.y, b.minY + inset), b.maxY - inset)
end

-- ============================================================
--  ZONE DATA
-- ============================================================
AddStateBagChangeHandler('arenaZones', 'global', function(_, _, value)
    zones = value or {}
end)

CreateThread(function()
    Wait(1500)
    zones = GlobalState.arenaZones or {}
end)

-- ============================================================
--  THE INVISIBLE WALL
-- ============================================================
-- A soft wall: your position is clamped back inside rather than a physical
-- collider being spawned. Colliders snag vehicles, break when the map updates
-- and leak entities on restart. Clamping does none of that and reads the same
-- from inside -- you simply cannot get through.
CreateThread(function()
    while true do
        local sleep = 500

        -- Not while tenx-zones owns the boundary.
        --
        -- Checked in the loop rather than at load, so flipping the config and
        -- restarting is enough -- a thread that decided once at startup would
        -- be wrong until the next restart, which is exactly the sort of thing
        -- nobody remembers when they flip a flag.
        --
        -- Two resources clamping the same player is the jitter this handover
        -- exists to remove, so this is a hard stand-down, not a softening.
        if myArena and Config.Boundary.enabled
           and (not ZoneLinkC or ZoneLinkC.ownClamp()) then
            local b = boundsOf(myArena)

            if b then
                sleep = 0

                local ped = PlayerPedId()
                local c = GetEntityCoords(ped)

                -- Cheap rejection first.
                --
                -- The full test walks every edge of the polygon. Standing in
                -- the middle of a twenty-sided zone, that is twenty segment
                -- projections a frame for an answer that was never going to
                -- change -- so a bounding-box check well inside the edges
                -- skips it and slows the loop right down.
                local wellInside = false

                if b.points then
                    local minX, minY, maxX, maxY = Poly.bbox(b.points)
                    local margin = 12.0

                    wellInside = c.x > minX + margin and c.x < maxX - margin
                             and c.y > minY + margin and c.y < maxY - margin
                             and c.z > b.minZ and c.z < b.maxZ
                end

                local dx, dy = 0.0, 0.0
                if not wellInside then
                    dx, dy = outsideBy(c, b)
                else
                    sleep = 250
                end

                if dx > 0.0 or dy > 0.0 or c.z > b.maxZ then
                    local nx, ny = clampToBox(c, b, Config.Boundary.inset)
                    local nz = math.min(c.z, b.maxZ - 1.0)

                    local veh = GetVehiclePedIsIn(ped, false)
                    local entity = (veh ~= 0) and veh or ped

                    -- Kill outward momentum too, or a fast car just bounces
                    -- against the wall over and over.
                    SetEntityCoordsNoOffset(entity, nx, ny, nz, false, false, false)
                    SetEntityVelocity(entity, 0.0, 0.0, 0.0)

                    blockedUntil = GetGameTimer() + 900
                end
            end
        end

        Wait(sleep)
    end
end)

-- Warning while you're being held back.
CreateThread(function()
    while true do
        local sleep = 300

        local _p = PerfLoop and PerfLoop('boundary-warn')

        -- tenx-zones draws its own warning. Ours would be a second one saying
        -- the same thing in a different place.
        if blockedUntil > GetGameTimer() and Config.Boundary.warn
           and (not ZoneLinkC or ZoneLinkC.ownClamp()) then
            sleep = 0

            -- With the wall no longer drawn, this IS the boundary as far as
            -- the player is concerned: you stop, and a line tells you why.
            -- So it is worth being clear rather than subtle.
            SetTextFont(4)
            SetTextScale(0.62, 0.62)
            SetTextColour(235, 70, 60, 255)
            SetTextOutline()
            SetTextCentre(true)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName(Config.Text.outside or 'You cannot leave the arena.')
            EndTextCommandDisplayText(0.5, 0.80)

            -- A red edge on the screen, so it reads as a boundary rather than
            -- a bug where you stopped walking for no reason.
            DrawRect(0.5, 0.997, 1.0, 0.006, 228, 72, 60, 200)
            DrawRect(0.5, 0.003, 1.0, 0.006, 228, 72, 60, 200)
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- ============================================================
--  DRAWING THE BOUNDARY
-- ============================================================
-- Only edges near the player are drawn. A big arena has a lot of perimeter and
-- none of it matters until you're close enough to run into it.
-- DrawPoly, not markers. Marker type 43 is not a flat plane -- fed a wall's
-- dimensions it renders as huge skewed triangles across the screen. Two
-- triangles make a proper quad, which is what a wall actually is.
--
-- Polys are single sided, so each quad is drawn twice with opposite winding.
-- Otherwise the wall vanishes when you walk around to the other side of it.
local function drawQuad(x1, y1, x2, y2, zBottom, zTop, r, g, b, a, doubleSided)
    -- front
    DrawPoly(x1, y1, zBottom, x2, y2, zBottom, x1, y1, zTop, r, g, b, a)
    DrawPoly(x2, y2, zBottom, x2, y2, zTop,    x1, y1, zTop, r, g, b, a)

    -- Back faces double the cost of the entire wall. You are on ONE side of
    -- a boundary, so the far side of it is behind the near side and you were
    -- never going to see it.
    if doubleSided then
        DrawPoly(x1, y1, zTop,    x2, y2, zBottom, x1, y1, zBottom, r, g, b, a)
        DrawPoly(x1, y1, zTop,    x2, y2, zTop,    x2, y2, zBottom, r, g, b, a)
    end
end

--- Draw only the part of an edge you are standing near.
---
--- This used to walk the whole edge regardless. A 200m side became 34
--- segments, each four DrawPoly, six edges at sixty frames a second -- about
--- 48,000 DrawPoly calls a second for a wall you could see maybe thirty
--- metres of. DrawPoly is not cheap to spam.
local function drawEdge(x1, y1, x2, y2, zBottom, zTop, cfg, alpha, pos)
    local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    if len < 0.1 then return end

    local seg = math.max(1.0, cfg.segment or 6.0)
    local count = math.ceil(len / seg)
    local r, g, b = cfg.colour.r or 60, cfg.colour.g or 200, cfg.colour.b or 255

    -- How much of it is worth drawing, either side of the closest point.
    local span = cfg.segmentSpan or 40.0
    local first, last = 0, count - 1

    if pos then
        -- Where along the edge you are, 0 to 1.
        local dx, dy = x2 - x1, y2 - y1
        local t = (((pos.x - x1) * dx) + ((pos.y - y1) * dy)) / (len * len)
        t = math.max(0.0, math.min(1.0, t))

        local mid = math.floor(t * count)
        local reach = math.ceil(span / seg)

        first = math.max(0, mid - reach)
        last = math.min(count - 1, mid + reach)
    end

    local double = cfg.doubleSided == true

    for i = first, last do
        local t1, t2 = i / count, (i + 1) / count
        drawQuad(
            x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1,
            x1 + (x2 - x1) * t2, y1 + (y2 - y1) * t2,
            zBottom, zTop, r, g, b, alpha, double)
    end
end

CreateThread(function()
    -- Nothing to draw, nothing to run.
    --
    -- Guarding inside the loop still woke it up twice a second forever to
    -- check a value that cannot change without a restart. Returning here
    -- means the thread does not exist at all.
    local cfg = Config.Boundary.wall
    if not (cfg and cfg.enabled) then return end

    while true do
        local sleep = 700

        local _p = PerfLoop and PerfLoop('boundary-wall')
        if #zones > 0 then
            local pos = GetEntityCoords(PlayerPedId())
            local within = cfg.drawWithin or 120.0
            local drew = false

            for _, z in ipairs(zones) do
                -- Only the arena you're actually in, unless you've explicitly
                -- turned that off. This is an RP city -- nobody driving past
                -- should see a wall across the road.
                local mine = (myArena == z.id)
                    or cfg.showToEveryone

                if mine and z.showWall ~= false and z.bounds and z.bounds.points then
                    local b = z.bounds
                    local pts = b.points

                    -- Cheap rejection first: only work out edges if the
                    -- bounding box is anywhere near.
                    local minX, minY, maxX, maxY = Poly.bbox(pts)

                    local nearX = pos.x > (minX - within) and pos.x < (maxX + within)
                    local nearY = pos.y > (minY - within) and pos.y < (maxY + within)
                    local nearZ = pos.z > (b.minZ - 80.0) and pos.z < (b.maxZ + 80.0)

                    if nearX and nearY and nearZ then
                        local zBottom = b.minZ + (Config.Builder.floorGrace or 3.0)
                        local zTop = zBottom + (cfg.height or 10.0)
                        local alpha = cfg.alpha or 60

                        -- Brighter while the wall is actually stopping you.
                        if blockedUntil > GetGameTimer() then
                            alpha = math.min(200, alpha * 3)
                        end

                        -- Only the edges you are near. A large zone has a lot
                        -- of perimeter and none of it matters until you can
                        -- run into it -- and capped, because a many-sided
                        -- zone with the whole perimeter in range would draw
                        -- every side every frame.
                        local drawn = 0
                        local maxEdges = cfg.maxEdges or 6

                        local wallCfg = cfg

                        local j = #pts
                        for i = 1, #pts do
                            local a, bb = pts[j], pts[i]
                            local mx, my = (a.x + bb.x) * 0.5, (a.y + bb.y) * 0.5

                            local edgeDist = #(pos - vec3(mx, my, pos.z))

                            if drawn < maxEdges and edgeDist < within then
                                drew = true
                                drawn = drawn + 1

                                -- Fade in over the last stretch, so the wall
                                -- appears as you approach rather than
                                -- switching on at a hard line.
                                local fade = 1.0
                                local over = cfg.fadeOver or 25.0

                                if over > 0 and edgeDist > (within - over) then
                                    fade = (within - edgeDist) / over
                                end

                                drawEdge(a.x, a.y, bb.x, bb.y, zBottom, zTop,
                                    wallCfg, math.floor(alpha * math.max(0.0, fade)), pos)
                            end

                            j = i
                        end

                        -- Corner posts, at close range only.
                        --
                        -- These used the same 120m range as the old wall, so
                        -- from a rooftop you saw the whole zone outlined in
                        -- pillars -- the shape of the boundary given away
                        -- from halfway across the map. They mark where a
                        -- corner is when you are next to it, nothing more.
                        --
                        -- And no taller than the wall: 1.3x meant they poked
                        -- above it and were visible over rooftops.
                        if cfg.corners then
                            local wc = cfg.colour
                            local r, g, bcol = wc.r or 60, wc.g or 200, wc.b or 255
                            local cornerRange = cfg.cornerWithin or 25.0

                            for _, p in ipairs(pts) do
                                local d = #(pos - vec3(p.x, p.y, pos.z))
                                if d < cornerRange then
                                    -- Fades in as you approach rather than
                                    -- snapping on at the edge of range.
                                    local fade = 1.0 - (d / cornerRange)

                                    DrawMarker(1, p.x, p.y, zBottom,
                                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                                        0.8, 0.8, (cfg.height or 10.0),
                                        r, g, bcol,
                                        math.floor(math.min(200, alpha + 60) * fade),
                                        false, false, 2, nil, nil, false)
                                end
                            end
                        end
                    end
                end
            end

            if drew then sleep = 0 end
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- ============================================================
--  ENTERING AND LEAVING
-- ============================================================
--- Every boundary-crossing teleport in this resource routes through here, so
--- wrapping this one function suspends the boundary for all of them: leaving
--- an arena, forceExit, goTo, and the Red Zone's respawn placement.
---
--- The claim is held across the whole sequence including the collision wait,
--- which can run for twelve seconds. tenx-zones reports it to its own server
--- side, so the periodic sweep holds off too -- otherwise the sweep would see
--- a player far outside a solid zone with no explanation and correct them
--- mid-teleport.
---
--- A no-op while Config.Zones.useExternal is off.
local function safeTeleport(x, y, z, heading)
    if ZoneLinkC and ZoneLinkC.active() then
        return ZoneLinkC.around('arena:teleport',
            RawSafeTeleport, x, y, z, heading)
    end

    return RawSafeTeleport(x, y, z, heading)
end

function RawSafeTeleport(x, y, z, heading)
    local ped = PlayerPedId()

    DoScreenFadeOut(350)
    Wait(400)

    if IsPedInAnyVehicle(ped, false) then
        TaskLeaveVehicle(ped, GetVehiclePedIsIn(ped, false), 16)
        Wait(200)
        ped = PlayerPedId()
    end

    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, z + 20.0, false, false, false)

    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    local waited = 0
    while not HasCollisionLoadedAroundEntity(ped) and waited < 12000 do
        RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
        Wait(100)
        waited = waited + 100
    end

    local groundZ = z
    for _, probe in ipairs({ z + 20.0, z + 3.0, z, 300.0, 100.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probe + 0.0, false)
        if found and gz then groundZ = gz break end
    end

    ped = PlayerPedId()
    SetEntityCollision(ped, true, true)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, groundZ + 0.5, false, false, false)
    if heading then SetEntityHeading(ped, heading + 0.0) end
    ClearPedTasksImmediately(ped)

    Wait(250)
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(400)
end

RegisterNetEvent('naija-arena:client:enter', function(data)
    myArena = data.arena.id

    -- Keep a copy locally: the arena I'm in has to be drawable and clampable
    -- even before the global list has synced.
    local known = false
    for _, z in ipairs(zones) do
        if z.id == data.arena.id then known = true break end
    end
    if not known then zones[#zones + 1] = data.arena end

    safeTeleport(data.spawn.x, data.spawn.y, data.spawn.z, data.spawn.w)

    ArenaNotify({
        title = 'Arena',
        description = ('You are in %s on Team %s.'):format(data.arena.name, data.team),
        type = 'success',
        position = Config.NotifyPosition or 'top-center'
    })
end)

RegisterNetEvent('naija-arena:client:leave', function(returnCoords)
    myArena = nil
    blockedUntil = 0
    TriggerEvent('naija-arena:cleanupMatch')

    -- Backstop for every other way out: forfeit, pulled by an admin,
    -- /arenaout, the arena switched off mid-match. Nobody returns to the city
    -- on the floor.
    if Config.Ambulance.reviveOnMatchEnd ~= false then
        CreateThread(function()
            Wait(300)
            local down = isDown()

            if down or ArenaBodyState ~= 'up' then
                print('[arena] still down on the way out -- reviving')
                ArenaReviveBehindFade()
            end

            local ped = PlayerPedId()
            pcall(SetEntityHealth, ped, Config.Ambulance.setHealth or 200)
            pcall(ClearPedBloodDamage, ped)
            pcall(ResetPedVisibleDamage, ped)
        end)
    end

    if returnCoords then
        safeTeleport(returnCoords.x, returnCoords.y, returnCoords.z, returnCoords.w)
    end

    ArenaNotify({
        title = 'Arena',
        description = 'You are back in the city.',
        type = 'inform',
        position = Config.NotifyPosition or 'top-center'
    })
end)

-- The server's backstop found me well outside. Put me back.
RegisterNetEvent('naija-arena:client:forceInside', function(b)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local nx, ny = clampToBox(c, b, 2.0)
    safeTeleport(nx, ny, b.minZ + (Config.Builder.floorGrace or 3.0))
end)

RegisterNetEvent('naija-arena:client:goTo', function(coords)
    safeTeleport(coords.x, coords.y, coords.z)
end)

-- ============================================================
--  BUILDER PANEL  (NUI)
-- ============================================================
local function setPanel(open, data)
    panelOpen = open
    setFocus('builder', open)
    SendNUIMessage({ action = open and 'open' or 'close', state = data })
end

RegisterNetEvent('naija-arena:client:openPanel', function(data)
    setPanel(true, data)
end)

RegisterNetEvent('naija-arena:client:panelUpdate', function(data)
    if not panelOpen then return end
    SendNUIMessage({ action = 'update', state = data })
end)

RegisterNUICallback('close', function(_, cb)
    setPanel(false)
    TriggerServerEvent('naija-arena:server:panelClosed')
    cb({})
end)

-- Thin pipes to the server. The reply shown is whatever the server decided.
local function relay(name)
    RegisterNUICallback(name, function(data, cb)
        lib.callback('naija-arena:server:panel', false, function(result)
            cb(result or { ok = false, message = 'No reply from the server.' })
        end, name, data)
    end)
end

for _, name in ipairs({
    'createArena', 'deleteArena', 'renameArena', 'toggleArena', 'toggleWall',
    'markPoints', 'clearBounds', 'addSpawn', 'clearSpawns', 'setLoadout',
    'addRzSpawn', 'clearRzSpawns',
    'testEnter', 'testLeave', 'pullOut', 'teleportTo'
}) do
    relay(name)
end

-- Close the panel when the builder is being edited from in-world, so the
-- admin can walk to a corner without the cursor trapping them.
RegisterNUICallback('minimise', function(_, cb)
    setFocus('builder', false)
    SendNUIMessage({ action = 'minimised' })
    cb({})
end)

RegisterNUICallback('restore', function(_, cb)
    setFocus('builder', true)
    cb({})
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    dropAllFocus()
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    DoScreenFadeIn(0)
end)

-- ============================================================
--  STAGE 2: MEETING ZONE, HOTBAR, NAMETAGS, PLAYER PANEL
-- ============================================================

-- ============================================================
--  THE LOBBY AND THE WAY IN
-- ============================================================
-- The lobby is the same physical spot as the city, in its own routing bucket.
-- A crowd of arena players waiting for a match is invisible to everyone doing
-- RP in that street, and they cannot shoot each other while they wait.
--
-- The ENTRY ped stands in the normal world so the city can see it. The LOBBY
-- ped only exists inside the bucket.

local entryPed = nil
local lobbyBlip = nil

-- The three placement modes share keys, so each has to know whether another
-- is running. Declared up here because the blocks live far apart in the file.
local marking = false
local placing = nil
local editing = nil
local meetingPrompt = false


local function spawnPed(model, coords, scenario)
    local hash = joaat(model)
    RequestModel(hash)

    local tries = 0
    while not HasModelLoaded(hash) and tries < 120 do
        Wait(50)
        tries = tries + 1
    end
    if not HasModelLoaded(hash) then return nil end

    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, coords.w or 0.0, false, true)
    SetEntityAsMissionEntity(ped, true, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    if scenario then TaskStartScenarioInPlace(ped, scenario, 0, true) end
    SetModelAsNoLongerNeeded(hash)

    return ped
end

local function removePeds()
    if entryPed and DoesEntityExist(entryPed) then
        pcall(function() exports.ox_target:removeLocalEntity(entryPed) end)
        DeleteEntity(entryPed)
    end
    if lobbyBlip and DoesBlipExist(lobbyBlip) then RemoveBlip(lobbyBlip) end
    entryPed, lobbyBlip = nil, nil
    if meetingPrompt then pcall(lib.hideTextUI) meetingPrompt = false end
end

-- The entry ped, in the normal world. Third-eye it to reach the lobby.
CreateThread(function()
    Wait(2500)

    local cfg = Config.Meeting.entry
    if not cfg then return end

    entryPed = spawnPed(cfg.model, cfg.coords, cfg.scenario)
    if not entryPed then
        print('^1[arena] could not spawn the entry ped^0')
        return
    end

    -- The bubble, unless ox_target is explicitly asked for.
    --
    -- The ped exists in every bucket -- it is created client-side, so it is
    -- wherever you are. Standing in the lobby you could still see it offering
    -- to let you in somewhere you already are, so each option is keyed to
    -- which side you are on and it reads correctly from both.
    -- Guarded: the prompt system is defined further down this file, and a
    -- ped that spawns before the chunk finishes loading would find it nil.
    if ArenaPromptRegister
       and (Config.Prompt or {}).enabled and not (Config.Prompt or {}).useTarget then
        local brand = Config.Brand or {}

        ArenaPromptRegister('arena_entry', {
            entity = function() return entryPed end,
            distance = cfg.distance or 2.5,
            title = brand.signTitle or 'PVP',
            actions = {
                {
                    key = 38, keyLabel = 'E',
                    label = brand.enterLabel or 'Enter PVP',
                    condition = function()
                        return not LocalPlayer.state.arenaLobby
                    end,
                    action = function()
                        TriggerServerEvent('naija-arena:server:enterLobby')
                    end
                },
                {
                    key = 38, keyLabel = 'E',
                    label = brand.menuLabel or 'Open the PVP menu',
                    condition = function()
                        return LocalPlayer.state.arenaLobby == true
                            and not LocalPlayer.state.arenaMatch
                    end,
                    action = function()
                        TriggerServerEvent('naija-arena:server:requestPanel')
                    end
                },
                {
                    -- G rather than a second E: the lobby offers two things
                    -- at once and one key cannot do both. ox_target could put
                    -- them on a list; a bubble has to give them separate keys.
                    key = 47, keyLabel = 'G',
                    label = brand.exitLabel or 'Go to free roam',
                    condition = function()
                        return LocalPlayer.state.arenaLobby == true
                            and not LocalPlayer.state.arenaMatch
                    end,
                    action = function()
                        TriggerServerEvent('naija-arena:server:leaveLobby')
                    end
                }
            }
        })

        print('[arena] entry ped ready with prompts')
        return
    end

    local targeted = pcall(function()
        exports.ox_target:addLocalEntity(entryPed, {
            {
                name = 'tenx_arena_enter',
                label = (Config.Brand or {}).enterLabel or 'Enter PVP',
                icon = cfg.icon or 'fas fa-crosshairs',
                distance = cfg.distance or 2.5,
                canInteract = function()
                    return not LocalPlayer.state.arenaLobby
                end,
                onSelect = function()
                    TriggerServerEvent('naija-arena:server:enterLobby')
                end
            },
            {
                name = 'tenx_arena_menu',
                label = (Config.Brand or {}).menuLabel or 'Open the PVP menu',
                icon = cfg.menuIcon or 'fas fa-list',
                distance = cfg.distance or 2.5,
                canInteract = function()
                    return LocalPlayer.state.arenaLobby == true
                        and not LocalPlayer.state.arenaMatch
                end,
                onSelect = function()
                    TriggerServerEvent('naija-arena:server:requestPanel')
                end
            },
            {
                name = 'tenx_arena_exit',
                label = (Config.Brand or {}).exitLabel or 'Go to free roam',
                icon = cfg.exitIcon or 'fas fa-city',
                distance = cfg.distance or 2.5,
                canInteract = function()
                    return LocalPlayer.state.arenaLobby == true
                end,
                onSelect = function()
                    TriggerServerEvent('naija-arena:server:leaveLobby')
                end
            }
        })
    end)

    if targeted then
        print('[arena] entry ped ready with ox_target')
        return
    end

    print('[arena] ox_target unavailable, using a press-E prompt on the entry ped')

    CreateThread(function()
        while true do
            local sleep = 1000

            if entryPed and DoesEntityExist(entryPed) then
                local d = #(GetEntityCoords(PlayerPedId()) - vec3(cfg.coords.x, cfg.coords.y, cfg.coords.z))
                local inLobby = LocalPlayer.state.arenaLobby == true

                if d < (cfg.distance or 2.5) then
                    sleep = 0
                    if not meetingPrompt then
                        -- Without ox_target there is only one key, so in the
                        -- lobby it opens the menu and /rzleave is the way out.
                        local brand = Config.Brand or {}
                        lib.showTextUI('[E]  ' .. (inLobby
                            and (brand.menuLabel or 'Open the PVP menu')
                            or (brand.enterLabel or 'Enter PVP')),
                            { position = 'left-center' })
                        meetingPrompt = true
                    end
                    if IsControlJustReleased(0, 38) then
                        TriggerServerEvent(inLobby
                            and 'naija-arena:server:requestPanel'
                            or 'naija-arena:server:enterLobby')
                        Wait(500)
                    end
                elseif meetingPrompt then
                    lib.hideTextUI()
                    meetingPrompt = false
                end
            elseif meetingPrompt then
                lib.hideTextUI()
                meetingPrompt = false
            end

            Wait(sleep)
        end
    end)
end)

-- ── going in ──
RegisterNetEvent('naija-arena:client:enterLobby', function(c)
    if not c.quiet then
        DoScreenFadeOut(500)
        local waited = 0
        while not IsScreenFadedOut() and waited < 2000 do Wait(50) waited = waited + 50 end
    end

    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, c.x + 0.0, c.y + 0.0, c.z + 0.0, false, false, false)
    SetEntityHeading(ped, c.w or 0.0)

    -- Stream the lobby in before showing it.
    RequestCollisionAtCoord(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    local waited = 0
    while not HasCollisionLoadedAroundEntity(ped) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    if not c.quiet then
        Wait(300)
        DoScreenFadeIn(600)
    end

    -- Boards draw themselves wherever they are marked, but ask for fresh
    -- data on the way in so the first look is current.
    TriggerServerEvent('naija-arena:server:wantBillboard')

    -- Turn the kit on.
    --
    -- This was missing entirely, and it is why ox_inventory opened perfectly
    -- happily while standing in bucket 2046. blockInventory is only ever
    -- called from ArenaHotbarStart, so a lobby that never started the kit
    -- never blocked anything -- the hotbar loop sat in its idle branch and
    -- the city inventory was one TAB away the whole time.
    --
    -- Everything else was already written for a lobby with the grid up: the
    -- server answers an inventory request for anyone on its lobby list, the
    -- sync arms the ped when arenaLobby is set, and armFromInventory has a
    -- rule handing lobby weapons zero rounds. All of it was waiting on a
    -- start that never came.
    --
    -- Set before the start call, because arming reads it and the statebag has
    -- usually not arrived yet.
    LobbyKit = true
    ArenaHotbarStart(nil)
end)

-- ── coming out ──
RegisterNetEvent('naija-arena:client:leaveLobby', function(c)
    DoScreenFadeOut(500)
    local waited = 0
    while not IsScreenFadedOut() and waited < 2000 do Wait(50) waited = waited + 50 end

    if lobbyBlip and DoesBlipExist(lobbyBlip) then RemoveBlip(lobbyBlip) lobbyBlip = nil end

    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, c.x + 0.0, c.y + 0.0, c.z + 0.0, false, false, false)
    SetEntityHeading(ped, c.w or 0.0)

    RequestCollisionAtCoord(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    waited = 0
    while not HasCollisionLoadedAroundEntity(ped) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    Wait(300)
    DoScreenFadeIn(600)

    -- Kit off on the way out. Weapons go back to ox_inventory's world, the
    -- block is released and TAB stops opening the grid.
    --
    -- Cleared before the stop so the watchdog cannot see a held lobby and put
    -- it straight back.
    LobbyKit = false
    if ArenaHotbarStop then ArenaHotbarStop() end
end)

-- The floating sign is gone. Text drawn in the world scales with distance and
-- gets in the way of whatever is behind it -- mark a board with /rzboard and
-- set it to 'info' instead, which sits flat on a wall and stays readable.


AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then removePeds() end
end)

-- ============================================================
--  MATCH HOTBAR
-- ============================================================
-- No confiscation. ox_inventory is blocked, weapons are given natively, and
-- everything is stripped on the way out -- the player's real inventory is
-- never touched, so there is nothing that can be lost or need restoring.
local Hotbar = { active = false, charges = {}, weapons = nil, selected = 'primary', using = false }

local KEY_MAP = { ['1'] = 157, ['2'] = 158, ['3'] = 160, ['4'] = 164, ['5'] = 165 }

-- We set invBusy to keep ox_inventory shut during a match. Other resources use
-- the same flag, so we track whether WE are the ones holding it -- clearing it
-- blindly would unlock an inventory something else deliberately locked.
local weHoldInvBusy = false

--- Do WE hold the inventory lock?
---
--- Global on purpose: /rzunstick is registered near the top of this file,
--- far above these locals, so it cannot see them. Referencing weHoldInvBusy
--- from up there reads a nil global and quietly reports the wrong thing.
function ArenaHoldsInvLock()
    return weHoldInvBusy == true
end

--- Is the kit up? Same scope reason as above.
function ArenaKitActive()
    return Hotbar ~= nil and Hotbar.active == true
end

local function blockInventory(on)
    weHoldInvBusy = on and true or false
    LocalPlayer.state:set('invBusy', weHoldInvBusy, false)

    if on then
        pcall(function() exports.ox_inventory:closeInventory() end)
        pcall(function() exports.ox_inventory:weaponWheel(true) end)
    else
        pcall(function() exports.ox_inventory:weaponWheel(false) end)
    end
end

--- Let go, but only of a lock that is ours. An inventory something else shut
--- deliberately is not ours to open.
---
--- Defined AFTER blockInventory deliberately. A closure captures a local as
--- it exists when the closure is created, so writing this above blockInventory
--- would have captured a nil global and released nothing, silently.
function ArenaReleaseInvLock()
    if not weHoldInvBusy then return false end
    blockInventory(false)
    return true
end

-- The flag was getting stuck on. ArenaHotbarStop was only reached on a clean
-- match end -- leaving any other way (pulled out by an admin, /arenaout, the
-- arena switched off) left the hotbar loop running, and it re-set invBusy
-- every single frame. Result: "cannot open inventory (is busy)" forever, for
-- a player who is back in the city.
-- Whether the kit was started by something outside this resource.
--
-- The watchdog below cannot see another resource's mode, so without this it
-- treats a perfectly good kit as a stuck lock and tears it down -- hotbar
-- gone, ox_inventory unblocked, weapons back in the city inventory, every
-- two seconds. That is exactly what "no hotbar and I can still use my city
-- inventory" looked like.
--
-- It is only a BRIDGE, though. The server is the authority -- see
-- ExternalKit below. A local boolean is something nothing can disprove: if
-- the claiming resource never released, because it restarted or because the
-- player left through one of the arena's own exits, this stuck true, the
-- hotbar loop kept setting invBusy every frame, and the stuck-lock watchdog
-- could not see past it. A permanently locked inventory, caused by the very
-- flag added to protect the kit.
KitHeldExternally = false

--- Is a mode outside this resource holding this player?
---
--- Statebag first, because the server keeps the real claim list and cleans it
--- up when a resource stops or a player drops. The local flag only covers the
--- moment between the mode starting and that state replicating.
function ExternalKit()
    return LocalPlayer.state.arenaClaimed == true or KitHeldExternally == true
end

--- In the arena lobby, decided locally.
---
--- The server sets an arenaLobby statebag, but statebags replicate
--- asynchronously and the kit is started the moment the lobby event lands --
--- so the state regularly has not arrived yet when the grid is first armed.
--- Reading it alone gave lobby players a full magazine, which is the one
--- thing the lobby is meant not to do.
---
--- This is a bridge over that gap, not a second source of truth: the watchdog
--- below drops it back to whatever the statebag says once it has settled.
LobbyKit = false

--- In the lobby and ONLY the lobby.
---
--- The lobby has rules no other mode wants: weapons handed out empty, the
--- trigger disabled, auto-revive on. Every one of them was written as
--- "arenaLobby and not arenaMatch", copied out by hand in four places.
---
--- Entering another resource's mode does not clear arenaLobby -- the arena
--- still has the player on its lobby list, because that is where they go back
--- to -- so all four read true inside the Red Zone. That is a player with a
--- full magazine who cannot pull the trigger, being revived by a script that
--- has no idea what killed them.
---
--- One function now, so fixing this once fixes it everywhere and the next
--- mode does not have to find them all again.
--- What the server said, last time it sent a grid. nil until it has.
ServerSaysLobby = nil

function LobbyOnly()
    -- The server's word wins.
    --
    -- It knows which table the player is in and answers in the same tick it
    -- builds the inventory. Everything below is replicated state, which can
    -- arrive late, arrive out of order, or -- when it is cleared by being set
    -- to nil -- never arrive at all. Reading it was how a player ended up in
    -- a real match holding a gun with no rounds while everyone else was fine.
    if ServerSaysLobby ~= nil then return ServerSaysLobby end

    -- Only before the first grid has landed.
    return (LocalPlayer.state.arenaLobby == true or LobbyKit == true)
        and not LocalPlayer.state.arenaMatch
        and not ExternalKit()
end

--- How many rounds a weapon is handed over with.
---
--- One place, because it is asked in several -- arming and switching slots
--- both did it inline, which is how a lobby fix reaches one and not the other.
function kitAmmo()
    if LobbyOnly() then
        local n = (Config.Kit or {}).lobbyAmmo
        return n == nil and 1 or n
    end
    return (Config.Kit or {}).ammoOnSpawn or 250
end

--- Should the kit still be up?
---
--- ONE answer, asked by everything that can tear the kit down. There used to
--- be two separate conditions -- the watchdog checked KitHeldExternally and
--- the hotbar loop did not -- so entering another resource's mode had the
--- loop killing the kit a second after it was started: weapons removed,
--- ox_inventory unblocked, hotbar hidden. Two places deciding the same thing
--- is how they drift apart, so now there is only one.
---
--- A match, the lobby, or somebody else's mode. Anything else and the kit is
--- a leftover that should be cleaned up.
function KitShouldHold()
    return LocalPlayer.state.arenaMatch == true
        or LocalPlayer.state.arenaLobby == true
        or LobbyKit == true
        or ExternalKit()
end

CreateThread(function()
    while true do
        Wait(2000)

        -- Two seconds is long enough for the statebag to have arrived, so it
        -- is the authority from here. Without this a lobby flag set locally
        -- would survive being pulled out of the lobby by anything that did
        -- not go through the leave event.
        if LobbyKit and LocalPlayer.state.arenaLobby ~= true then
            LobbyKit = false
        end

        -- Same for a claim. Two seconds is long enough for the state to have
        -- arrived, so from here the server's answer wins -- which is what
        -- makes a mode that stopped without releasing recoverable, instead of
        -- an inventory locked until reconnect.
        if KitHeldExternally and LocalPlayer.state.arenaClaimed ~= true then
            KitHeldExternally = false
        end

        if weHoldInvBusy and not KitShouldHold() then
            weHoldInvBusy = false
            LocalPlayer.state:set('invBusy', false, false)
            pcall(function() exports.ox_inventory:weaponWheel(false) end)
            Hotbar.active = false
            SendNUIMessage({ action = 'hotbar', data = { show = false } })
            print('[arena] Released a stuck inventory lock')
        end
    end
end)

-- Either slot can be empty. "Rifles only" and "pistols only" are both real
-- ways to want to play, so a slot set to none simply isn't given.
local function slotWeapon(slot)
    local w = Hotbar.weapons
    if not w then return nil end
    local id = (slot == 'sidearm') and w.sidearm or w.primary
    -- false, nil or the literal string all mean the same thing here.
    if not id or id == false or id == 'none' or id == '' then return nil end
    return id
end

local function hasAnyWeapon()
    return slotWeapon('primary') ~= nil or slotWeapon('sidearm') ~= nil
end

local function giveMatchWeapons(select)
    local w = Hotbar.weapons
    if not w then return end

    local ped = PlayerPedId()
    RemoveAllPedWeapons(ped, true)

    local function spec(slot, id)
        for _, entry in ipairs(Config.Weapons[slot] or {}) do
            if entry.id == id then return entry end
        end
        return { id = id, ammo = 200, clip = 30 }
    end

    local given = {}

    for _, slot in ipairs({ 'primary', 'sidearm' }) do
        local id = slotWeapon(slot)
        if id then
            local entry = spec(slot, id)
            local hash = joaat(id)

            GiveWeaponToPed(ped, hash, entry.ammo or 200, false, true)

            if Config.Weapons.infiniteAmmo then
                SetPedInfiniteAmmo(ped, true, hash)
            end
            if not Config.Weapons.infiniteClip then
                SetAmmoInClip(ped, hash, entry.clip or 20)
            end

            given[slot] = hash
        end
    end

    SetPedInfiniteAmmoClip(ped, Config.Weapons.infiniteClip and true or false)

    -- Land on the slot asked for if it has something in it, otherwise
    -- whichever one does. Both empty is fists, which is allowed.
    local want = select
    if not given[want] then
        want = given.primary and 'primary' or (given.sidearm and 'sidearm' or nil)
    end

    if want and given[want] then
        Hotbar.selected = want
        SetCurrentPedWeapon(ped, given[want], true)
    else
        Hotbar.selected = 'primary'
        SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
    end
end

local function hotbarPayload()
    local slots = {}
    local count = Hotbar.hotbarCount
        or (Config.MatchInventory and Config.MatchInventory.hotbarSlots) or 5

    for i = 1, count do
        local entry = (Hotbar.slots or {})[i]
        slots[#slots + 1] = {
            id = i,
            key = tostring(i),
            name = entry and entry.name or nil,
            label = entry and entry.label or nil,
            image = entry and entry.image or nil,
            weapon = entry and entry.weapon or false,
            usable = entry and entry.usable or false,
            charges = entry and not entry.weapon and entry.count or nil,
            empty = entry == nil,
            selected = Hotbar.selected == i
        }
    end

    return {
        show = Hotbar.active,
        slots = slots,
        selected = Hotbar.selected,

        -- So an empty hand looks deliberate rather than broken. The slot stays
        -- highlighted -- it is still the weapon you would draw -- just dimmed.
        holstered = Hotbar.holstered == true,
        oxPath = Config.OxImagePath
    }
end

local function refreshHotbar()
    SendNUIMessage({ action = 'hotbar', data = hotbarPayload() })
end

--- "You received X" -- fired by the server whenever anything lands in the bag.
---
--- The server decides WHETHER to send one; this only draws it. oxPath is
--- added here because image resolution is a client-side concern and the
--- server has no business knowing where the pictures live.
RegisterNetEvent('naija-arena:client:itemToast', function(d)
    if not d or not d.item then return end

    SendNUIMessage({ action = 'itemToast', data = {
        item   = d.item,
        label  = d.label or d.item,
        count  = d.count or 1,
        image  = d.image,
        oxPath = Config.OxImagePath,
        ttl    = (Config.ItemToast or {}).duration or 3200,
        max    = (Config.ItemToast or {}).max or 4,
    }})
end)

-- Put the weapon in a given inventory slot into their hands. Every weapon in
-- the grid is given to the ped, so switching is instant.
--- Switching weapons, with the animation GTA already has for it.
---
--- SetCurrentPedWeapon(..., true) swaps instantly -- the gun is simply in
--- your other hand between frames. Passing false makes the ped actually
--- holster and draw, which is what every other shooter does and what makes
--- switching feel like an action rather than a menu.
--- Equip a slot, or put the weapon away if it is already the one in hand.
---
--- Pressing the key you are already holding HOLSTERS. It used to return early
--- and do nothing, so once a weapon was out there was no way to put it away
--- -- and the per-frame hold below would have drawn it straight back anyway.
---
--- Holstered is a real state, not just "nothing selected": the ped keeps the
--- weapon, the grid still shows it, the slot stays highlighted. Only the hands
--- are empty. Press the same key again and it comes back.
function equipFromSlot(slot)
    local entry = (Hotbar.slots or {})[slot]
    if not entry or not entry.weapon then return end

    local ped = PlayerPedId()
    local hash = joaat(entry.name)

    if slot == Hotbar.selected then
        Hotbar.holstered = not Hotbar.holstered

        if Hotbar.holstered then
            SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
        else
            if not HasPedGotWeapon(ped, hash, false) then
                GiveWeaponToPed(ped, hash, kitAmmo(), false, false)
            end
            SetCurrentPedWeapon(ped, hash, true)
        end

        refreshHotbar()
        return
    end

    -- Switching to a different slot always draws it. Wanting to hold nothing
    -- and wanting to hold something else are different intentions.
    Hotbar.holstered = false

    -- The ped should already have it, but a grid rearrangement can outrun the
    -- arming. Give it rather than silently failing to switch.
    if not HasPedGotWeapon(ped, hash, false) then
        GiveWeaponToPed(ped, hash,
            kitAmmo(),
            false, false)
    end

    Hotbar.selected = slot

    -- false = play the draw. Skipped while running flat out, because the
    -- animation gets cut short anyway and a half-played draw looks worse
    -- than none.
    local drawIt = not IsPedRunning(ped) and not IsPedSprinting(ped)
    SetCurrentPedWeapon(ped, hash, not drawIt)

    refreshHotbar()
end


-- The hotbar is a view of the first inventory slots, not a separate thing.
-- Whatever is in slot 1 is on key 1.
--- Put every weapon in the grid onto the ped.
---
--- Without this the grid is a picture. It shows the rifle you bought, you
--- press 1, and nothing happens -- because the ped was never given it. The
--- match path armed the ped from Config.Weapons, which own-weapons does not
--- use, so this arms it from whatever is actually in the inventory.
local function armFromInventory(slots)
    local ped = PlayerPedId()
    local given = {}

    -- A fresh arming decides what is in hand, so any holster from a previous
    -- life is over. Left set, a player would respawn empty-handed with a full
    -- grid and no idea why.
    Hotbar.holstered = false

    RemoveAllPedWeapons(ped, true)

    -- No ammo in the lobby.
    --
    -- You can hold what you bought and look at it, but an empty weapon
    -- cannot fire -- which is a cleaner guarantee than blocking the trigger
    -- and hoping nothing slips past. Ammo comes back the moment you are
    -- actually fighting.
    -- Another resource's mode is NOT the lobby.
    --
    -- Entering one never clears arenaLobby -- the arena still has the player
    -- on its lobby list, because that is where they will be put back. So this
    -- read true inside the Red Zone and every weapon was handed over with
    -- zero rounds: the gun was in their hands, the grid was correct, and the
    -- trigger did nothing.
    --
    -- KitHeldExternally rather than a zone check, so this stays right for any
    -- mode written later without the arena needing to know it exists.
    local lobbyOnly = LobbyOnly()
    local ammo = kitAmmo()

    -- Say so when a weapon is handed over empty.
    --
    -- Only when it happens, so it costs nothing the rest of the time. An
    -- empty gun in a match has been chased through three different theories
    -- now, and every one of them was a guess at which flag was wrong. This
    -- prints the flags at the moment the decision is made, so the next time
    -- it happens the answer is in the console rather than in an argument.
    if ammo == 0 then
        print(('^3[arena] arming with ZERO ammo -- server said lobby: %s | ' ..
               'arenaLobby: %s | arenaMatch: %s | LobbyKit: %s | claimed: %s^0')
            :format(tostring(ServerSaysLobby),
                    tostring(LocalPlayer.state.arenaLobby),
                    tostring(LocalPlayer.state.arenaMatch),
                    tostring(LobbyKit),
                    tostring(LocalPlayer.state.arenaClaimed)))
    end

    for _, entry in ipairs(slots or {}) do
        if entry.weapon and entry.name then
            local hash = joaat(entry.name)
            GiveWeaponToPed(ped, hash, ammo, false, false)
            given[#given + 1] = { slot = entry.slot, hash = hash }
        end
    end

    -- Hold the lowest-numbered weapon, so key 1 is what you end up with.
    table.sort(given, function(a, b) return a.slot < b.slot end)

    if given[1] then
        Hotbar.selected = given[1].slot
        SetCurrentPedWeapon(ped, given[1].hash, true)

        -- Did they KEEP them?
        --
        -- The other half of the empty-gun problem: weapons handed over
        -- correctly and then taken off the ped a moment later by something
        -- else finishing its own respawn. That looks identical from the
        -- outside -- a full grid and empty hands -- and needs telling apart
        -- from being armed with nothing in the first place.
        local first = given[1].hash
        CreateThread(function()
            Wait(1500)
            local p = PlayerPedId()
            if Hotbar.active and not HasPedGotWeapon(p, first, false) then
                print('^1[arena] the weapon was given and then REMOVED within ' ..
                      '1.5s -- something else stripped the ped after we armed it^0')
            end
        end)
    else
        Hotbar.selected = 1
        SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
    end

    return #given
end

function ArenaHotbarSync(data)
    if not data or not data.slots then return end

    Hotbar.slots = {}
    Hotbar.charges = {}

    local hotbarCount = data.hotbar or 5

    for _, entry in ipairs(data.slots) do
        if entry.slot <= hotbarCount then
            Hotbar.slots[entry.slot] = entry
            if not entry.weapon then
                Hotbar.charges[entry.slot] = entry.count
            end
        end
    end

    Hotbar.hotbarCount = hotbarCount

    -- The grid IS the loadout, so the ped is armed from it every time it
    -- changes -- buy a gun and it is in your hands without respawning.
    --
    -- Keyed on Hotbar.active, NOT on the statebag. Statebags replicate
    -- asynchronously, so at match start the grid regularly arrived before
    -- arenaMatch did -- the check failed, nothing was armed, and people
    -- spawned holding nothing while their inventory sat there full.
    --
    -- Hotbar.active is set locally by ArenaHotbarStart, which runs before the
    -- grid is even asked for, so it is true by the time this fires.
    -- The lobby counts too: you can hold what you own and look at it, you
    -- just cannot fire it. Being told to buy a gun and then not being able
    -- to see it until a match starts is a poor way to spend coins.
    if (Hotbar.active or LocalPlayer.state.arenaLobby)
       and (Config.OwnWeapons or LocalPlayer.state.arenaLobby) then
        armFromInventory(data.slots)
    end

    refreshHotbar()
end

function ArenaHotbarStart(weapons)
    if not (Config.Hotbar and Config.Hotbar.enabled) then return end

    Hotbar.weapons = weapons
    Hotbar.active = true
    Hotbar.using = false
    Hotbar.holstered = false
    Hotbar.slots = Hotbar.slots or {}

    if Config.Hotbar.blockInventory ~= false then blockInventory(true) end

    -- With own-weapons on, the ped is armed from the grid when it arrives --
    -- the room no longer decides what anyone carries, so there is nothing to
    -- hand out here.
    if not Config.OwnWeapons then
        giveMatchWeapons('primary')
    end

    refreshHotbar()

    -- Ask for the grid; the hotbar is a view of it.
    TriggerServerEvent('naija-arena:server:invRequest')
end

function ArenaHotbarStop()
    -- The server's lobby answer goes with the kit. It is only refreshed when
    -- a grid arrives, so leaving it set means the next thing to ask gets an
    -- answer about a situation that ended.
    ServerSaysLobby = nil

    Hotbar.active = false
    Hotbar.using = false
    Hotbar.holstered = false
    Hotbar.weapons = nil

    local ped = PlayerPedId()
    RemoveAllPedWeapons(ped, true)
    SetPedInfiniteAmmoClip(ped, false)

    blockInventory(false)
    SendNUIMessage({ action = 'hotbar', data = { show = false } })
end

-- Anything currently healing you over time. One entry per effect, so a second
-- Slurpy extends rather than restarting -- and so a death cancels the lot.
local regenUntil = 0
local regenRate = 0

function ArenaClearRegen()
    regenUntil, regenRate = 0, 0
end

CreateThread(function()
    while true do
        Wait(1000)

        if regenUntil > GetGameTimer() and regenRate > 0 then
            local ped = PlayerPedId()

            -- Stop if they go down. Healing a corpse is how a downed player
            -- ends up stuck between states.
            if IsEntityDead(ped) or (ArenaBodyState and ArenaBodyState ~= 'up') then
                regenUntil, regenRate = 0, 0
            else
                SetEntityHealth(ped, math.min(200, GetEntityHealth(ped) + regenRate))
            end
        end
    end
end)

--- Use an item.
---
--- Effects come from Config.Items[id].effect -- data, not a branch here. The
--- old version had an `if id == 'armour' ... elseif id == 'medkit'` chain, so
--- every new item meant editing this function and remembering to.
function useUtility(id)
    if Hotbar.using or not Hotbar.active then return end

    local def = (Config.Items or {})[id] or {}
    local fx = def.effect

    -- Fall back to the old hotbar config, so anything defined the previous
    -- way still works.
    local legacy = (Config.Hotbar.items or {})[id]
    if not fx and not legacy then return end

    fx = fx or {
        health = (id == 'medkit') and (legacy.health or 200) or nil,
        heal = (id == 'bandage') and (legacy.heal or 50) or nil,
        armour = (id == 'armour') and (legacy.armour or 100) or nil,
        useTime = legacy.duration,
        anim = legacy.anim
    }

    Hotbar.using = true
    local ped = PlayerPedId()
    local useTime = fx.useTime or 1.5

    if fx.anim and fx.anim.dict then
        RequestAnimDict(fx.anim.dict)
        local t = GetGameTimer() + 2000
        while not HasAnimDictLoaded(fx.anim.dict) and GetGameTimer() < t do Wait(10) end
        if HasAnimDictLoaded(fx.anim.dict) then
            TaskPlayAnim(ped, fx.anim.dict, fx.anim.clip, 4.0, 4.0,
                math.floor(useTime * 1000), fx.anim.flag or 49, 0.0, false, false, false)
        end
    end

    Wait(math.floor(useTime * 1000))
    ClearPedTasks(PlayerPedId())

    ped = PlayerPedId()

    -- Nothing lands if they went down mid-animation. Otherwise a medkit used
    -- as you die heals the body you are no longer in.
    if IsEntityDead(ped) or (ArenaBodyState and ArenaBodyState ~= 'up') then
        Hotbar.using = false
        return
    end

    if fx.health then SetEntityHealth(ped, math.min(200, fx.health)) end
    if fx.heal   then SetEntityHealth(ped, math.min(200, GetEntityHealth(ped) + fx.heal)) end
    if fx.armour then SetPedArmour(ped, math.min(100, fx.armour)) end

    if fx.regen then
        -- Extends rather than restarting, so two in a row is twenty seconds
        -- of healing rather than ten.
        local add = (fx.regen.seconds or 10) * 1000
        local now = GetGameTimer()
        regenUntil = math.max(regenUntil, now) + add
        regenRate = math.max(regenRate, fx.regen.amount or 2)
    end

    if fx.message then
        ArenaNotify({
            title = def.label or id,
            description = fx.message,
            type = 'success',
            duration = 3000
        })
    end

    -- The count is the server's; it has already decremented and will push the
    -- new grid down, which refreshes the hotbar with it.
    Hotbar.using = false
end

CreateThread(function()
    if not (Config.Hotbar and Config.Hotbar.enabled) then return end

    while true do
        if not Hotbar.active then
            Wait(1000)
        elseif not KitShouldHold() then
            -- Active but nothing is holding it any more: something failed to
            -- stop us.
            --
            -- This tested arenaMatch alone, which is false in the lobby and
            -- false in any mode living in another resource. So the Red Zone
            -- called startKit, and one second later this branch stripped the
            -- ped, released ox_inventory and hid the hotbar -- "both
            -- inventories open" and "guns don't work", from one line.
            ArenaHotbarStop()
            Wait(1000)
        else
            Wait(0)

            -- Block the normal weapon wheel and slot keys; the hotbar owns them.
            DisableControlAction(0, 37, true)
            DisableControlAction(0, 199, true)
            for _, ctrl in ipairs({ 157, 158, 159, 160, 161, 162, 163, 164, 165 }) do
                DisableControlAction(0, ctrl, true)
            end

            -- Only while something is actually holding the kit. Re-setting
            -- this on a player who has already returned to the city is what
            -- jammed their inventory.
            --
            -- Same check as the teardown above, deliberately: a state good
            -- enough to keep the kit up is good enough to keep ox_inventory
            -- shut, and anything else lets the two disagree.
            if Config.Hotbar.blockInventory ~= false
               and KitShouldHold() then
                weHoldInvBusy = true
                LocalPlayer.state:set('invBusy', true, false)
            end

            local count = Hotbar.hotbarCount
                or (Config.MatchInventory and Config.MatchInventory.hotbarSlots) or 5

            for i = 1, count do
                local ctrl = KEY_MAP[tostring(i)]
                if ctrl and IsDisabledControlJustPressed(0, ctrl) then
                    local entry = (Hotbar.slots or {})[i]

                    if entry then
                        if entry.weapon then
                            equipFromSlot(i)
                        elseif entry.usable then
                            -- The server owns the count, so ask rather than
                            -- decrementing here and hoping.
                            TriggerServerEvent('naija-arena:server:invUse', i)
                        end
                    end
                end
            end

            -- Hold them on the slot they picked, so a dropped weapon or a
            -- script elsewhere can't quietly swap what's in their hands.
            -- Hold them on the slot they picked, so a dropped weapon or
            -- another script can't quietly swap what's in their hands.
            local sel = (Hotbar.slots or {})[Hotbar.selected]
            if sel and sel.weapon and not Hotbar.using then
                local ped = PlayerPedId()
                local want = joaat(sel.name)

                -- Not while deliberately holstered. This loop exists to stop
                -- something ELSE swapping what is in your hands; a player
                -- choosing to hold nothing is not that, and without this
                -- check it would redraw the weapon the same frame you put it
                -- away.
                if HasPedGotWeapon(ped, want, false) and not Hotbar.holstered then
                    local _, cur = GetCurrentPedWeapon(ped, true)
                    if cur ~= want then SetCurrentPedWeapon(ped, want, true) end
                end
            end
        end
    end
end)

-- Ammo readout
CreateThread(function()
    while true do
        local _p = PerfLoop and PerfLoop('hotbar-ammo')
        local sel = Hotbar.active and (Hotbar.slots or {})[Hotbar.selected]

        if sel and sel.weapon then
            if PerfEnd then PerfEnd(_p) end
            Wait(250)
            local ped = PlayerPedId()
            local hash = joaat(sel.name)
            local _, clip = GetAmmoInClip(ped, hash)
            local total = GetAmmoInPedWeapon(ped, hash) or 0
            SendNUIMessage({ action = 'hotbarAmmo', data = {
                clip = clip or 0,
                reserve = math.max(0, total - (clip or 0)),
                selected = Hotbar.selected
            }})
        else
            Wait(1500)
        end
    end
end)

-- ============================================================
--  TEAMMATE NAMETAGS
-- ============================================================
-- Native GTA Online gamer tags: real name, real health bar, correct font.
-- The natives keep the health bar current themselves, so this costs a scan
-- every half second rather than work every frame.
local tags = {}
local roster = {}

local function removeTag(id)
    local entry = tags[id]
    if not entry then return end
    pcall(RemoveMpGamerTag, entry.tag)
    tags[id] = nil
end

local function clearTags()
    for id in pairs(tags) do removeTag(id) end
    tags = {}
end

function ArenaSetRoster(list)
    roster = list or {}
end

CreateThread(function()
    while true do
        local cfg = Config.Nametags
        local sleep = 1500

        local _p = PerfLoop and PerfLoop('nametags')

        if cfg and cfg.enabled ~= false and LocalPlayer.state.arenaMatch and #roster > 0 then
            sleep = math.max(250, cfg.scanInterval or 500)

            local myId = GetPlayerServerId(PlayerId())
            local myTeam = LocalPlayer.state.arenaTeam
            local myPos = GetEntityCoords(PlayerPedId())
            local seen = {}

            for _, entry in ipairs(roster) do
                -- Teammates only. Seeing the enemy through walls is not a tag,
                -- it's a wallhack.
                if entry.id and entry.id ~= myId and entry.team == myTeam then
                    local player = GetPlayerFromServerId(entry.id)
                    if player and player ~= -1 then
                        local ped = GetPlayerPed(player)
                        if ped and ped ~= 0 and DoesEntityExist(ped) then
                            local alive = not IsEntityDead(ped)
                            if (alive or cfg.showDead) and #(myPos - GetEntityCoords(ped)) <= (cfg.drawDistance or 250.0) then
                                seen[entry.id] = true
                                local label = ('[%s] %s'):format(entry.id, entry.name or 'Player')
                                local existing = tags[entry.id]

                                if not existing or existing.ped ~= ped or existing.label ~= label then
                                    removeTag(entry.id)
                                    local tag = CreateFakeMpGamerTag(ped, label, false, false, '', 0)
                                    SetMpGamerTagVisibility(tag, 0, true)
                                    SetMpGamerTagVisibility(tag, 2, true)
                                    SetMpGamerTagAlpha(tag, 0, 255)
                                    SetMpGamerTagAlpha(tag, 2, 255)
                                    SetMpGamerTagColour(tag, 0, cfg.nameColour or 0)
                                    SetMpGamerTagHealthBarColour(tag, cfg.healthColour or 9)
                                    tags[entry.id] = { tag = tag, ped = ped, label = label }
                                end
                            end
                        end
                    end
                end
            end

            for id in pairs(tags) do
                if not seen[id] then removeTag(id) end
            end
        elseif next(tags) then
            clearTags()
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- ============================================================
--  MATCH EVENTS
-- ============================================================
RegisterNetEvent('naija-arena:client:matchBegin', function(data)
    -- Someone already down in the city when the match was called would
    -- otherwise arrive as a corpse. The scatter fades the screen anyway, so
    -- the same sequence runs behind it.
    if Config.Ambulance.reviveOnMatchStart ~= false then
        CreateThread(function()
            Wait(300)
            ArenaReviveBehindFade()
        end)
    end

    -- Clear the queue overlays. The builder is left alone -- see above.
    setFocus('ready', false)
    setFocus('vote', false)
    setFocus('panel', false)
    playerPanelOpen = false

    ArenaSetRoster(data.roster)
    Wait(800)
    -- The lobby is over. Cleared here as well as on the server, because this
    -- arrives with the match and the statebag has its own timing -- and every
    -- lobby rule keys off this flag.
    LobbyKit = false

    ArenaHotbarStart(data.weapons)

    SendNUIMessage({ action = 'matchBegin', data = data })
end)

RegisterNetEvent('naija-arena:client:matchEnd', function(data)
    ArenaHotbarStop()
    ArenaSetRoster({})
    clearTags()
    TriggerEvent('naija-arena:cleanupMatch')
    SendNUIMessage({ action = 'matchEnd', data = data })

    -- Whoever lost the final round is still down right now. Without this they
    -- get sent back into the city on the floor, in the middle of whatever RP
    -- is happening there.
    --
    -- The result card is up for about ten seconds, which is plenty of cover
    -- for the sequence to land in.
    if Config.Ambulance.reviveOnMatchEnd ~= false then
        CreateThread(function()
            Wait(500)
            ArenaReviveBehindFade()

            -- Whatever happens, they leave the arena on their feet and whole.
            local ped = PlayerPedId()
            pcall(SetEntityHealth, ped, Config.Ambulance.setHealth or 200)
            pcall(ClearPedBloodDamage, ped)
            pcall(ResetPedVisibleDamage, ped)
        end)
    end
end)

-- Told, not asked. Joining the queue was the agreement; this is just the
-- moment it happened, and then you are in.
RegisterNetEvent('naija-arena:client:matchFound', function(data)
    SendNUIMessage({ action = 'matchFound', data = data })
end)

RegisterNetEvent('naija-arena:client:readyCheck', function(data)
    -- The panel is hidden for this, but the card needs the cursor -- and the
    -- player may well have closed the panel already, so focus cannot be
    -- assumed to be on.
    playerPanelOpen = false
    setFocus('panel', false)
    setFocus('ready', true)
    SendNUIMessage({ action = 'readyCheck', data = data })
end)

RegisterNetEvent('naija-arena:client:readyUpdate', function(data)
    SendNUIMessage({ action = 'readyUpdate', data = data })
end)

RegisterNetEvent('naija-arena:client:matchCancelled', function(data)
    setFocus('ready', false)
    setFocus('vote', false)
    SendNUIMessage({ action = 'matchCancelled', data = data })
    ArenaNotify({
        title = (Config.Brand or {}).notifyTitle or 'PVP',
        description = data.blamed and 'You declined, so the match was called off.' or data.reason,
        type = 'error',
        position = Config.NotifyPosition or 'top-center'
    })
end)

RegisterNetEvent('naija-arena:client:mapVote', function(data)
    setFocus('ready', false)
    setFocus('vote', true)
    SendNUIMessage({ action = 'mapVote', data = data })
end)

RegisterNetEvent('naija-arena:client:voteUpdate', function(tally)
    SendNUIMessage({ action = 'voteUpdate', data = tally })
end)

RegisterNetEvent('naija-arena:client:matchStarting', function(data)
    -- The queue overlays are done with. The builder is NOT touched: if an
    -- admin has it open they opened it deliberately, and a match starting
    -- elsewhere is no reason to close it under them.
    setFocus('ready', false)
    setFocus('vote', false)
    setFocus('panel', false)
    playerPanelOpen = false
    SendNUIMessage({ action = 'matchStarting', data = data })
end)

RegisterNetEvent('naija-arena:client:party', function(party)
    SendNUIMessage({ action = 'party', data = party })
end)

RegisterNetEvent('naija-arena:client:playerUpdate', function(state)
    SendNUIMessage({ action = 'playerUpdate', state = state })
end)

-- ── party invites ──
-- Answered with keys, not buttons. An invite lands while you're walking
-- around, so the toast can't take the cursor -- buttons on it would sit there
-- unclickable, which is exactly what was happening.
local pendingInvite = nil

-- Control IDs to something readable, so the prompt shows the actual key.
local KEY_NAMES = {
    [246] = 'Y', [249] = 'N', [177] = 'BACKSPACE', [194] = 'BACKSPACE',
    [38] = 'E', [23] = 'F', [47] = 'G', [74] = 'H', [311] = 'K', [182] = 'L',
    [288] = 'F1', [289] = 'F2', [170] = 'F3', [166] = 'F5', [167] = 'F6',
    [168] = 'F7', [289] = 'F2', [56] = 'F9', [57] = 'F10', [20] = 'Z',
    [73] = 'X', [26] = 'C', [22] = 'SPACE', [19] = 'ALT', [21] = 'SHIFT',
}

local function keyName(control)
    return KEY_NAMES[control] or ('KEY %s'):format(control)
end

local function closeInvite()
    pendingInvite = nil
    SendNUIMessage({ action = 'inviteClosed' })
end

RegisterNetEvent('naija-arena:client:invite', function(data)
    local accept = Config.Party.acceptKey or 246
    local decline = Config.Party.declineKey or 249

    pendingInvite = {
        code = data.code,
        isRoom = data.room and true or false,
        expires = GetGameTimer() + ((data.seconds or 30) * 1000),
        accept = accept,
        decline = decline
    }

    data.acceptLabel = keyName(accept)
    data.declineLabel = keyName(decline)

    SendNUIMessage({ action = 'invite', data = data })
end)

-- Only runs while an invite is actually up, so it costs nothing otherwise.
CreateThread(function()
    while true do
        local sleep = 500

        if pendingInvite then
            sleep = 0

            if GetGameTimer() > pendingInvite.expires then
                closeInvite()
            elseif IsControlJustPressed(0, pendingInvite.accept) then
                TriggerServerEvent(
                    pendingInvite.isRoom and 'naija-arena:server:acceptRoomInvite'
                                          or 'naija-arena:server:acceptInvite',
                    pendingInvite.code)
                closeInvite()
            elseif IsControlJustPressed(0, pendingInvite.decline) then
                closeInvite()
                ArenaNotify({
                    title = (Config.Brand or {}).notifyTitle or 'PVP',
                    description = 'Invite declined.',
                    type = 'inform',
                    position = Config.NotifyPosition or 'top-center'
                })
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  PLAYER PANEL
-- ============================================================
RegisterNetEvent('naija-arena:client:openPlayer', function(state)
    playerPanelOpen = true
    setFocus('panel', true)
    SendNUIMessage({ action = 'openPlayer', state = state })
end)

RegisterNUICallback('closePlayer', function(_, cb)
    playerPanelOpen = false
    setFocus('panel', false)
    SendNUIMessage({ action = 'closePlayer' })
    cb({})
end)

RegisterNUICallback('player', function(data, cb)
    lib.callback('naija-arena:server:player', false, function(result)
        cb(result or { ok = false, message = 'No reply from the server.' })
    end, data.name, data.payload or {})
end)

RegisterNUICallback('ready', function(data, cb)
    TriggerServerEvent('naija-arena:server:ready', data.id, data.accept)

    -- Declining ends it here. Accepting keeps the card up showing the count,
    -- but there is nothing left to click, so the cursor goes back.
    setFocus('ready', false)
    cb({})
end)

RegisterNUICallback('vote', function(data, cb)
    TriggerServerEvent('naija-arena:server:vote', data.id, data.arena)
    -- Vote cast; the grid stays up so they can watch the tally, but it no
    -- longer needs the cursor.
    setFocus('vote', false)
    cb({})
end)

RegisterNUICallback('acceptInvite', function(data, cb)
    TriggerServerEvent('naija-arena:server:acceptInvite', data.code)
    cb({})
end)

RegisterNUICallback('room', function(data, cb)
    lib.callback('naija-arena:server:room', false, function(result)
        cb(result or { ok = false, message = 'No reply from the server.' })
    end, data.name, data.payload or {})
end)

RegisterNetEvent('naija-arena:client:room', function(room, arenas)
    SendNUIMessage({ action = 'room', data = room, arenas = arenas })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    removePeds()
    clearTags()
    if Hotbar.active then ArenaHotbarStop() end

    -- Whatever happens, give the inventory back.
    LocalPlayer.state:set('invBusy', false, false)
    pcall(function() exports.ox_inventory:weaponWheel(false) end)

    dropAllFocus()

    -- Never leave someone invisible, frozen or immortal because the resource
    -- stopped while they were mid-respawn.
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)
end)

-- ============================================================
--  MATCH DEATHS AND RESPAWNS
-- ============================================================
-- Your death system owns dying on this server: incapacitated screen, bleedout
-- timer, distress signal. Correct for RP, completely wrong for a 1v1.
--
-- It's escrowed, so its flow can't be switched off from outside. What we do is
-- fire its own revive the instant a match death is detected, which clears its
-- screen before it settles, then run our own respawn countdown over the top.
local matchDead = false
local respawnProtected = false

-- Who actually killed us. Roadkill reports the VEHICLE as the source of
-- death, not a ped, and the killer entity isn't always resolved the moment
-- death fires -- so this unwraps the vehicle and retries for a short while.
local function resolveKiller(ped)
    for _ = 1, 8 do
        local killer = GetPedSourceOfDeath(ped)

        if killer and killer ~= 0 then
            if IsEntityAVehicle(killer) then
                killer = GetPedInVehicleSeat(killer, -1)
            end

            if killer and killer ~= 0 and IsEntityAPed(killer) and IsPedAPlayer(killer) then
                local player = NetworkGetPlayerIndexFromPed(killer)
                if player and player ~= -1 then
                    return GetPlayerServerId(player)
                end
            end
        end

        Wait(100)
    end

    return 0
end

-- A knock is being out of the fight -- you cannot shoot back while bleeding
-- out. So the kill is reported on the KNOCK, not on the bleedout finishing.
--
-- The old version polled IsEntityDead, which never fires for a knocked
-- player, so kills went unreported and rounds never ended.
local function reportDeath(reason)
    if not LocalPlayer.state.arenaMatch then return end
    if matchDead then return end

    matchDead = true

    -- Flags set before resolveKiller, which yields for up to 800ms.
    local killer = resolveKiller(PlayerPedId())
    print(('[arena] reporting %s, killer = %s'):format(reason, tostring(killer)))
    TriggerServerEvent('naija-arena:server:reportKill', killer, reason)
end

AddEventHandler('naija-arena:bodyStateChanged', function(state)
    if state == 'knocked' then
        if Config.Ambulance.knockCountsAsKill ~= false then
            reportDeath('knocked')
        end
    elseif state == 'dead' then
        reportDeath('dead')
    end
end)

-- Backstop, in case their events do not fire for some deaths. Polls the ped
-- the old way, but only as a fallback -- their events are the primary source.
CreateThread(function()
    local wasDead = false

    while true do
        local sleep = 500

        if LocalPlayer.state.arenaMatch and not matchDead then
            sleep = 250
            local ped = PlayerPedId()
            local dead = IsEntityDead(ped) or IsPedFatallyInjured(ped)

            if dead and not wasDead then
                wasDead = true
                print('[arena] ped death detected without one of their events')
                reportDeath('shot')
            elseif not dead then
                wasDead = false
            end
        else
            wasDead = false
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('naija-arena:client:died', function(d)
    matchDead = true

    -- Nothing is done to the player here. They lie where they fell.
    --
    -- Every previous attempt tried to revive at this moment and every one
    -- failed: the revive landed while their death screen was still animating
    -- in, did nothing, and the screen stayed. All of it now happens inside
    -- the black screen of the respawn instead.
    SendNUIMessage({ action = 'matchDeath', data = { seconds = d.seconds or 5 } })
end)

-- Safety net for the death card. It used to be hidden only by the respawn
-- event -- so if that never arrived (match ended while you were down, you got
-- revived by something else, a packet went missing) the card sat on your
-- screen forever while you walked around alive. Now anything that puts you
-- back on your feet clears it.
CreateThread(function()
    while true do
        local sleep = 1000

        if matchDead then
            sleep = 250
            local ped = PlayerPedId()

            -- Alive, visible and unfrozen means the respawn already happened
            -- by some other route. The card has no business still being up.
            if not IsEntityDead(ped) and IsEntityVisible(ped) and not IsEntityPositionFrozen(ped) then
                matchDead = false
                SendNUIMessage({ action = 'matchRespawn' })
            end

            -- And if we're not in a match at all any more, clear regardless.
            if not LocalPlayer.state.arenaMatch then
                matchDead = false
                SendNUIMessage({ action = 'matchRespawn' })
                TriggerEvent('naija-arena:cleanupMatch')
            end
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('naija-arena:client:respawn', function(d)
    local cfg = Config.Ambulance
    print('[arena] respawn received, starting the fade sequence')

    -- ── 1. black screen ──
    DoScreenFadeOut(cfg.fadeOut or 600)
    local waited = 0
    while not IsScreenFadedOut() and waited < 2000 do
        Wait(50)
        waited = waited + 50
    end

    -- Untouchable for the whole black screen, declared so the watchdog does
    -- not fight it. It ends when the fade does.
    ArenaProtect(30)

    -- Undo anything holding them, so the revive meets a normal ped.
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)

    -- ── 2. revive, then 3. skelly, both behind the black ──
    ArenaReviveBehindFade()

    -- ── 4. put them on their spawn ──
    ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, d.spawn.x + 0.0, d.spawn.y + 0.0, d.spawn.z + 0.0, false, false, false)
    SetEntityHeading(ped, d.spawn.w or 0.0)

    SetEntityHealth(ped, cfg.setHealth or 200)
    SetPedArmour(ped, cfg.setArmour or 0)
    ClearPedBloodDamage(ped)
    ClearPedTasksImmediately(ped)

    -- Weapons back, because dying strips them.
    ArenaHotbarStart(d.weapons)

    matchDead = false
    ArenaBodyState = 'up'
    SendNUIMessage({ action = 'matchRespawn' })

    if d.roundStart then
        SendNUIMessage({ action = 'roundStart', data = { round = d.roundStart } })
    end

    -- ── 5. and back in ──
    Wait(200)
    DoScreenFadeIn(cfg.fadeIn or 700)

    -- Brief protection so nobody is shot while the screen is still fading.
    local secs = d.protection or 3
    if secs > 0 then
        respawnProtected = true

        -- Declared up front, so the watchdog knows this is intentional and
        -- knows exactly when it ends. Nothing can leave someone bulletproof.
        ArenaProtect(secs)
        SendNUIMessage({ action = 'spawnProtection', data = { seconds = secs } })

        CreateThread(function()
            for _ = 1, secs * 2 do
                local p = PlayerPedId()
                SetEntityInvincible(p, true)
                SetPlayerInvincible(PlayerId(), true)
                Wait(500)
            end

            respawnProtected = false
            ArenaProtectClear()
            SendNUIMessage({ action = 'spawnProtectionEnd' })
        end)
    else
        ArenaProtectClear()
    end
end)

-- Down, but the round is still running. You stay out until your team either
-- takes it or loses it -- that's the format, and it's why a death matters.
RegisterNetEvent('naija-arena:client:downed', function(d)
    matchDead = true

    -- Same as above: left alone until the round ends and the respawn runs.
    SendNUIMessage({ action = 'matchDowned', data = {
        teammatesLeft = d.teammatesLeft or 0,
        team = d.team
    }})
end)

RegisterNetEvent('naija-arena:client:score', function(data)
    SendNUIMessage({ action = 'score', data = data })
end)

-- Clean up whatever state a match left behind.
AddEventHandler('naija-arena:cleanupMatch', function()
    matchDead = false
    respawnProtected = false
    ArenaProtectClear()
    ArenaSetRoster({})

    -- This is the one that was missing. Leaving an arena by any route other
    -- than a clean match end left the hotbar running and the inventory locked.
    if Hotbar.active then
        ArenaHotbarStop()
    elseif weHoldInvBusy then
        -- Kit already down but OUR lock outlived it. Only ever released when
        -- we are the ones holding it, so this cannot unlock an inventory
        -- something else shut on purpose.
        blockInventory(false)
    end

    SendNUIMessage({ action = 'hudOff' })
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)
end)

-- ============================================================
--  THE MATCH INVENTORY
-- ============================================================
-- The grid you open during a match. The server owns the contents -- this only
-- renders what it's told and posts intent back, so a modified client can move
-- pixels around and change nothing real.
--
-- The first slots ARE the hotbar. Drag a gun into slot 1 and it's on key 1;
-- rearranging the grid rearranges your keys.
local invOpen = false
local invData = nil

-- Usable anywhere in the PVP world, not only mid-fight. People want to look
-- at what they own, rearrange it and see what they can afford before they walk
-- into anything.
local function invVisible()
    if not (Config.MatchInventory and Config.MatchInventory.enabled) then return false end
    if matchDead then return false end

    -- Follows the KIT, not a list of our own states.
    --
    -- Listing states meant another resource could start the kit through
    -- startKit() and the player would get a hotbar with no way to open the
    -- grid behind it -- weapons they own, on number keys, and no way to
    -- rearrange them. Hotbar.active is true whenever the kit is up, whoever
    -- turned it on.
    return (Hotbar and Hotbar.active == true)
        or LocalPlayer.state.arenaMatch
        or LocalPlayer.state.arenaLobby == true
end

local function closeInventory()
    if not invOpen then return end
    invOpen = false
    setFocus('inventory', false)
    SendNUIMessage({ action = 'invClose' })
end

local function openInventory()
    if invOpen or not invVisible() then return end
    invOpen = true
    setFocus('inventory', true)
    TriggerServerEvent('naija-arena:server:invRequest')
    SendNUIMessage({ action = 'invOpen', data = invData })
end

local function toggleInventory()
    if invOpen then closeInventory() else openInventory() end
end

-- RegisterKeyMapping puts this in FiveM's own Key Bindings settings, so
-- players rebind it there rather than us inventing a settings menu for one
-- key. The config value is only the default.
RegisterCommand('+arenaInv', function()
    if invVisible() then toggleInventory() end
end, false)
RegisterCommand('-arenaInv', function() end, false)

RegisterKeyMapping('+arenaInv',
    (Config.MatchInventory and Config.MatchInventory.keyLabel) or 'Open match inventory',
    'keyboard',
    (Config.MatchInventory and Config.MatchInventory.key) or 'TAB')

RegisterNetEvent('naija-arena:client:inventory', function(data)
    invData = data or nil

    -- The server's answer on whether this is a lobby kit, kept for arming.
    -- It arrives WITH the grid, so it cannot disagree with the items it came
    -- alongside -- unlike a statebag, which has its own timing and its own
    -- ways of not turning up.
    if data and data.lobby ~= nil then
        ServerSaysLobby = data.lobby == true
    end

    if not data then
        ServerSaysLobby = nil
        closeInventory()
        SendNUIMessage({ action = 'invData', data = false })
        return
    end

    SendNUIMessage({ action = 'invData', data = data })

    -- The hotbar mirrors the first slots, so a change to the grid is a change
    -- to the hotbar.
    if Hotbar.active then
        ArenaHotbarSync(data)
    end
end)

RegisterNetEvent('naija-arena:client:printLines', function(lines)
    for _, l in ipairs(lines or {}) do print(l) end
end)

RegisterNUICallback('invNearby', function(_, cb)
    lib.callback('naija-arena:server:invNearby', false, function(res)
        cb(res or { players = {} })
    end)
end)

RegisterNUICallback('invGive', function(d, cb)
    TriggerServerEvent('naija-arena:server:invGive', d.slot, d.amount, d.target)
    cb({})
end)

RegisterNUICallback('invDrop', function(d, cb)
    TriggerServerEvent('naija-arena:server:invDrop', d.slot, d.amount)
    cb({})
end)

RegisterNUICallback('invSplit', function(d, cb)
    TriggerServerEvent('naija-arena:server:invSplit', d.from, d.to, d.amount)
    cb({})
end)

RegisterNUICallback('invMove', function(d, cb)
    TriggerServerEvent('naija-arena:server:invMove', d.from, d.to)
    cb({})
end)

RegisterNUICallback('invUse', function(d, cb)
    TriggerServerEvent('naija-arena:server:invUse', d.slot)
    cb({})
end)

RegisterNUICallback('invClose', function(_, cb)
    closeInventory()
    cb({})
end)

-- Using something from the grid runs the same effect the hotbar key does.
RegisterNetEvent('naija-arena:client:invUsed', function(name, slot)
    useUtility(name)
end)

-- Rearranging the grid can change what's in your hands.
-- What a match paid, shown once at the end rather than silently landing in
-- the bag.
RegisterNetEvent('naija-arena:client:coinsEarned', function(d)
    ArenaNotify({
        title = ('+%s %s'):format(d.amount, Config.Coins.label),
        description = ('%s. You now have %s.'):format(d.reason, d.balance),
        type = 'success',
        duration = 6000
    })
end)

RegisterNetEvent('naija-arena:client:invChanged', function()
    if Hotbar.active and invData then
        ArenaHotbarSync(invData)
    end
end)

-- Shut it when the round ends, so nobody is stood in a menu when the next
-- one starts.
AddEventHandler('naija-arena:cleanupMatch', function()
    invData = nil
    closeInventory()

    -- Any healing over time ends with the fight. Carrying regen out of a
    -- match into the city would be a small, confusing gift.
    if ArenaClearRegen then ArenaClearRegen() end
end)



-- ============================================================
--  THE LEADERBOARD BOARDS
-- ============================================================
-- Drawn straight into the world as two textured triangles across four points
-- you mark yourself -- not onto a prop.
--
-- Props meant hunting undocumented texture names, guessing a scale, and
-- fighting the model's own orientation, and a wrong guess gave a blank object
-- with nothing to debug. Four points has none of that: the board fits the wall
-- you point at, at the size and angle you choose, and you can have as many as
-- you like.

-- A page per KIND, not per board. Two 'pvp' boards on different walls show
-- the same thing, so they share one render rather than paying for two.
local boardDuis = {}   -- [kind] = { dui, tex }
local feedPage         -- defined below; pageFor uses it to fill a new page
local boardData = nil  -- the leaderboard currently showing
local infoData = nil   -- what is happening right now
local boards = {}

-- marking state
local markCorners = {}
local markName = ''
local markKind = 'pvp'

local function pageFor(kind)
    if boardDuis[kind] then return boardDuis[kind] end

    local cfg = Config.Billboard

    -- The info board is its own page: it shows what is happening rather than
    -- a table of players, and forcing both through one file made neither
    -- read well.
    local resolved = BoardKind and BoardKind(kind) or kind
    local sources = ((Config.Boards or {})[resolved] or {}).sources or {}

    local url = (sources[1] == 'info')
        and ('nui://%s/html/boardinfo.html'):format(GetCurrentResourceName())
        or  ('nui://%s/html/billboard.html'):format(GetCurrentResourceName())

    local entry = {}

    local ok = pcall(function()
        entry.dui = CreateDui(url, cfg.width or 1280, cfg.height or 640)

        local txd = ('naija_board_%s_%s'):format(kind, math.random(10000, 99999))
        local runtime = CreateRuntimeTxd(txd)
        CreateRuntimeTextureFromDuiHandle(runtime, 'board', GetDuiHandle(entry.dui))

        entry.tex = { dict = txd, name = 'board' }
    end)

    if not ok or not entry.dui then
        print(('^1[arena] could not create the %s board page^0'):format(kind))
        return nil
    end

    boardDuis[kind] = entry

    -- Whatever we already have, so a board is never blank while it waits for
    -- the next push.
    if feedPage then feedPage(kind, entry) end

    return entry
end

local function destroyDui()
    for _, entry in pairs(boardDuis) do
        if entry.dui then pcall(DestroyDui, entry.dui) end
    end
    boardDuis = {}
end

-- Two triangles make the quad. UVs run 0-1 across it, so the page is
-- stretched to whatever shape the four marked points describe -- there is no
-- scaling to work out and no prop to fight.
--
-- Drawn from behind as well, so a board is not invisible from one side.
--- Draw a board.
---
--- A quad is two triangles, and DrawSpritePoly is single-sided -- wind it the
--- wrong way and the board is invisible from that side. So each triangle is
--- drawn twice, once per winding, and the board reads from wherever you are
--- standing.
---
--- But you can only ever be on ONE side of it. The other two calls are
--- painting a face pointing away from you, every frame, for nothing.
---
--- With the cull on, the side is worked out first and only that pair drawn:
--- four DrawSpritePoly per board becomes two. This loop runs at sleep = 0
--- while any board is in range, so near the lobby that is two calls per board
--- saved every frame.
---
--- Off by default -- see Config.Billboard.cullBackFace for why.
local function drawBoard(c, tex, camPos)
    if not tex or not c or #c ~= 4 then return end

    local tl, tr, br, bl = c[1], c[2], c[3], c[4]
    local d, n = tex.dict, tex.name

    -- Which way the face points: the cross product of two of its edges. Same
    -- corner convention as boardNormal further down, so the editor and this
    -- agree about which way a board is facing.
    local ax, ay, az = tr.x - tl.x, tr.y - tl.y, tr.z - tl.z
    local bx, by, bz = bl.x - tl.x, bl.y - tl.y, bl.z - tl.z

    local nx = (ay * bz) - (az * by)
    local ny = (az * bx) - (ax * bz)
    local nz = (ax * by) - (ay * bx)

    -- No camera position means draw both, which is what the board editor
    -- wants -- it needs the outline visible while you walk around it. Same
    -- when the cull is switched off, which is the default.
    local cull = camPos and (Config.Billboard or {}).cullBackFace == true
    local front = true

    if cull then
        front = (((camPos.x - tl.x) * nx)
               + ((camPos.y - tl.y) * ny)
               + ((camPos.z - tl.z) * nz)) >= 0.0

        if (Config.Billboard or {}).cullFlip == true then front = not front end
    end

    if front or not cull then
        DrawSpritePoly(
            tl.x, tl.y, tl.z,  tr.x, tr.y, tr.z,  br.x, br.y, br.z,
            255, 255, 255, 255, d, n,
            0.0, 0.0, 1.0,   1.0, 0.0, 1.0,   1.0, 1.0, 1.0)

        DrawSpritePoly(
            tl.x, tl.y, tl.z,  br.x, br.y, br.z,  bl.x, bl.y, bl.z,
            255, 255, 255, 255, d, n,
            0.0, 0.0, 1.0,   1.0, 1.0, 1.0,   0.0, 1.0, 1.0)
    end

    if not front or not cull then
        DrawSpritePoly(
            br.x, br.y, br.z,  tr.x, tr.y, tr.z,  tl.x, tl.y, tl.z,
            255, 255, 255, 255, d, n,
            1.0, 1.0, 1.0,   1.0, 0.0, 1.0,   0.0, 0.0, 1.0)

        DrawSpritePoly(
            bl.x, bl.y, bl.z,  br.x, br.y, br.z,  tl.x, tl.y, tl.z,
            255, 255, 255, 255, d, n,
            0.0, 1.0, 1.0,   1.0, 1.0, 1.0,   0.0, 0.0, 1.0)
    end
end

AddStateBagChangeHandler('arenaBoards', 'global', function(_, _, value)
    boards = value or {}
end)

--- An old board kind, resolved to what it means now. Boards live in the
--- database, so renaming a kind would strand every wall already marked --
--- anything unrecognised falls back to pvp rather than going blank.
function BoardKind(kind)
    kind = kind or 'pvp'
    if (Config.Boards or {})[kind] then return kind end
    return (Config.BoardAliases or {})[kind] or 'pvp'
end

-- Which source each rotating board is currently showing.
local boardTurn = {}

-- Each board is fed the one thing it is for.
--
-- Everything arrives in the payload, so a wall pinned to a kind that is not
-- currently showing still gets its data -- which is the bug that had a
-- a board sitting empty while another kind was being pushed.
--- A cheap fingerprint of what a board would show.
---
--- Used to decide whether sending anything is worth it: a leaderboard that
--- has not moved does not need pushing into a browser every ten seconds, and
--- most of the time it has not moved.
local function boardFingerprint(data)
    if not data then return '' end

    local parts = { data.title or '', tostring(data.footer or '') }

    for _, r in ipairs(data.rows or {}) do
        parts[#parts + 1] = ('%s|%s|%s|%s|%s')
            :format(r.rank or '', r.name or '', r.kills or r.elo or '',
                    r.points or r.peak or '', r.wins or '')
    end

    -- The info board is counters rather than rows.
    if data.queue then
        for _, q in ipairs(data.queue) do
            parts[#parts + 1] = ('%s=%s'):format(q.label or '', q.count or 0)
        end
        parts[#parts + 1] = ('%s/%s/%s'):format(
            data.lobby or 0, data.liveMatches or 0, data.rooms or 0)
    end

    return table.concat(parts, ';')
end

--- Feed a board.
---
--- Skipped entirely when the board is asleep or when nothing it shows has
--- changed. Both matter: a DUI only costs while it is painting, and it only
--- repaints when something is sent to it.
function feedPage(kind, page, force)
    if not page or not page.dui or not boardData then return end
    if page.asleep and not force then return end

    kind = BoardKind(kind)
    local def = (Config.Boards or {})[kind] or {}
    local sources = def.sources or { 'pvp' }

    -- Which of its sources this board is on right now. A board with one
    -- source never moves off it.
    local turn = boardTurn[kind] or 1
    if turn > #sources then turn = 1 end
    local source = sources[turn]

    if source == 'info' then
        SendDuiMessage(page.dui, json.encode({
            action = 'info', data = boardData.info
        }))
        return
    end

    -- Ours, or one another resource registered.
    local data = boardData[source] or (boardData.providers or {})[source]
    if not data then return end

    -- Title and footer come from config and ride along, so branding stays a
    -- config edit rather than a change to the page.
    data.title  = (def.titles or {})[source] or def.title
    data.footer = (def.footers or {})[source] or def.footer

    -- Has anything actually changed?
    local print_ = boardFingerprint(data)
    if not force and page.lastPrint == print_ then return end
    page.lastPrint = print_

    SendDuiMessage(page.dui, json.encode({ action = 'board', data = data }))
end

-- Boards with more than one source swap between them on a timer. Full width,
-- one at a time -- side by side halves the width of each and costs the
-- readability that makes a wall worth looking at from a distance.
CreateThread(function()
    Wait(8000)

    while true do
        local shortest = 20

        for kind, def in pairs(Config.Boards or {}) do
            local sources = def.sources or {}
            if #sources > 1 then
                shortest = math.min(shortest, def.rotate or 20)
            end
        end

        Wait(shortest * 1000)

        for kind, page in pairs(boardDuis) do
            local def = (Config.Boards or {})[BoardKind(kind)] or {}
            local sources = def.sources or {}

            if #sources > 1 then
                local turn = (boardTurn[BoardKind(kind)] or 1) + 1
                if turn > #sources then turn = 1 end
                boardTurn[BoardKind(kind)] = turn

                feedPage(kind, page)
            end
        end
    end
end)

RegisterNetEvent('naija-arena:client:billboard', function(payload)
    boardData = payload
    infoData = payload and payload.info or nil

    -- Data arriving does not mean anything gets sent to a page: feedPage
    -- checks whether the board is awake and whether what it shows actually
    -- changed. Most pushes end here.
    for kind, page in pairs(boardDuis) do
        feedPage(kind, page)
    end
end)

-- ============================================================
--  BOARDS SLEEP WHEN NOBODY IS NEAR
-- ============================================================
-- A DUI is an offscreen browser. It costs while it paints, and it paints when
-- something is sent to it -- so a board nobody is near is fed nothing and
-- told to stop animating.
--
-- The page is NOT destroyed. Recreating a DUI costs far more than letting an
-- idle one sit there, and a board that has to rebuild itself every time
-- somebody walks past is worse on both counts.
--
-- Each kind also has its own refresh rate: a queue counter earns attention a
-- ladder does not.

local boardLastFed = {}

CreateThread(function()
    Wait(4000)

    while true do
        local cfg = Config.Billboard or {}
        local wake = cfg.wakeDistance or 45.0

        -- Nothing marked, or boards turned off: this thread has nothing to do
        -- but check again slowly.
        if not cfg.enabled or #boards == 0 or not next(boardDuis) then
            Wait(5000)
            goto continue
        end

        do
            local pos = GetEntityCoords(PlayerPedId())
            local anyNear = false

            -- Which kinds have a board within range.
            local nearKinds = {}
            for _, b in ipairs(boards) do
                local c = b.corners
                if c and #c == 4 then
                    local cx = (c[1].x + c[3].x) / 2
                    local cy = (c[1].y + c[3].y) / 2
                    local cz = (c[1].z + c[3].z) / 2

                    if #(pos - vec3(cx, cy, cz)) < wake then
                        nearKinds[BoardKind(b.kind)] = true
                        anyNear = true
                    end
                end
            end

            local now = GetGameTimer()

            for kind, page in pairs(boardDuis) do
                local near = nearKinds[kind] == true

                -- Waking or sleeping is a single message, sent only on the
                -- change -- not every pass.
                if near and page.asleep then
                    page.asleep = false
                    SendDuiMessage(page.dui, json.encode({ action = 'wake' }))
                    feedPage(kind, page, true)      -- forced: it may be stale
                    boardLastFed[kind] = now

                elseif not near and not page.asleep then
                    page.asleep = true
                    SendDuiMessage(page.dui, json.encode({ action = 'sleep' }))
                end

                -- Awake boards are refreshed at their own rate, and even then
                -- only if something changed.
                if not page.asleep then
                    local every = ((cfg.refreshRates or {})[kind] or 10) * 1000
                    if (now - (boardLastFed[kind] or 0)) >= every then
                        boardLastFed[kind] = now
                        feedPage(kind, page)
                    end
                end
            end

            -- Slow right down when nobody is anywhere near a board, which is
            -- almost all of the time.
            Wait(anyNear and 1000 or 5000)
        end

        ::continue::
    end
end)

-- Draw whatever boards are near enough to read.
CreateThread(function()
    Wait(3000)
    boards = GlobalState.arenaBoards or {}

    while true do
        local sleep = 800
        local cfg = Config.Billboard

        local _p = PerfLoop and PerfLoop('boards')

        if cfg and cfg.enabled and #boards > 0 then
            local pos = GetEntityCoords(PlayerPedId())
            local range = cfg.drawDistance or 70.0
            local drew = false

            -- The CAMERA decides which face is showing, not the ped. In third
            -- person the two are metres apart, and close to a board that is
            -- enough to be on opposite sides of it.
            local cam = GetGameplayCamCoord()

            for _, b in ipairs(boards) do
                local c = b.corners
                if c and #c == 4 then
                    local mid = vec3(
                        (c[1].x + c[3].x) * 0.5,
                        (c[1].y + c[3].y) * 0.5,
                        (c[1].z + c[3].z) * 0.5)

                    if #(pos - mid) < range then
                        -- Each board renders its own kind. A wall showing the
                        -- ranked board and one showing what is happening
                        -- right now are different pages, not the same one.
                        local kind = b.kind or 'pvp'
                        local page = pageFor(kind)
                        if page then
                            drawBoard(c, page.tex, cam)
                            drew = true
                        end
                    end
                end
            end

            if drew then
                sleep = 0
            elseif next(boardDuis) then
                -- Nothing in range: throw the pages away.
                --
                -- This said `boardDui` -- singular, a variable that has not
                -- existed since the boards became one page per kind. A nil
                -- global is falsy, so the branch never ran and every page you
                -- had ever walked past kept rendering for the rest of the
                -- session.
                --
                -- Each one is an offscreen browser at 1280x640, painting
                -- continuously whether or not anything is looking at it.
                -- Three of those is most of what this resource was costing,
                -- everywhere on the map, forever.
                destroyDui()
            end
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- ── marking a board ──
--
-- Aim at a wall and press E four times: top left, top right, bottom right,
-- bottom left. The shape so far is drawn as you go, so you can see it before
-- committing.
local function raycastAim()
    local cam = GetGameplayCamCoords()
    local rot = GetGameplayCamRot(2)
    local rad = vector3(math.rad(rot.x), math.rad(rot.y), math.rad(rot.z))

    local dir = vector3(
        -math.sin(rad.z) * math.abs(math.cos(rad.x)),
         math.cos(rad.z) * math.abs(math.cos(rad.x)),
         math.sin(rad.x))

    local dest = cam + (dir * 25.0)
    local ray = StartShapeTestRay(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, -1, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)

    if hit == 1 then return coords end
    return nil
end

RegisterCommand(Config.Billboard.markCommand or 'rzboard', function(_, args)
    local sub = args[1]

    if sub == 'cancel' then
        marking = false
        markCorners = {}
        lib.hideTextUI()
        return
    end

    -- The board listing moved off 'list' -- that is a board KIND now, and a
    -- subcommand sharing a name with a kind means one of them can never be
    -- reached. This one moved because typing it is rarer.
    if sub == 'boards' or sub == 'all' then
        TriggerServerEvent('naija-arena:server:listBoards')
        return
    end

    if sub == 'delete' then
        if not args[2] then
            print('[arena] rzboard delete <id>   -- run rzboard boards for ids')
            return
        end
        TriggerServerEvent('naija-arena:server:deleteBoard', args[2])
        return
    end

    -- Adjusting one after the fact.
    --
    -- A building face with ridges is not flat, so a board on the marked
    -- points sinks into them. Push it out and it hangs in front instead --
    -- which is what a sign does anyway.
    if sub == 'push' or sub == 'out' then
        local id, amount = args[2], tonumber(args[3]) or 0.25
        if not id then return print('[arena] rzboard push <id> [metres]  (negative pulls it back)') end
        TriggerServerEvent('naija-arena:server:adjustBoard', id, 'push', amount)
        return
    end

    if sub == 'bigger' or sub == 'scale' then
        local id, amount = args[2], tonumber(args[3]) or 1.25
        if not id then return print('[arena] rzboard bigger <id> [multiplier]  (0.8 shrinks it)') end
        TriggerServerEvent('naija-arena:server:adjustBoard', id, 'scale', amount)
        return
    end

    if sub == 'raise' then
        local id, amount = args[2], tonumber(args[3]) or 0.5
        if not id then return print('[arena] rzboard raise <id> [metres]  (negative lowers it)') end
        TriggerServerEvent('naija-arena:server:adjustBoard', id, 'raise', amount)
        return
    end

    if sub == 'kinds' then
        print('^3======== BOARD KINDS ========^0')
        for id, b in pairs(Config.Boards or {}) do
            print(('  %-10s %s'):format(id, b.title or ''))
        end
        print('^3rzboard <kind> <name>  to mark one^0')
        print('^3=============================^0')
        return
    end

    if marking then
        marking = false
        markCorners = {}
        lib.hideTextUI()
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP', description = 'Marking cancelled.', type = 'inform' })
        return
    end

    if editing then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Finish editing that board first.', type = 'error' })
        return
    end

    -- Both this and the prop placer share keys. Running them together would
    -- have each stealing the other's keypresses.
    if placing then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Finish placing the prop first.', type = 'error' })
        return
    end

    -- First word is the kind, the rest is the name.
    -- Straight from config, so a kind added there works here without an edit.
    local kinds = Config.Boards or {}

    -- An unrecognised kind is almost always a typo, and silently marking a
    -- PVP board instead is how you end up with a wall showing the wrong
    -- thing and no idea why.
    if sub and sub ~= '' and not kinds[sub] then
        local names = {}
        for id in pairs(kinds) do names[#names + 1] = id end
        table.sort(names)

        ArenaNotify({
            title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = ('No board kind called "%s". Try: %s'):format(sub, table.concat(names, ', ')),
            type = 'error',
            duration = 7000
        })
        return
    end

    marking = true
    markCorners = {}

    markKind = kinds[sub] and sub or 'pvp'
    if kinds[sub] then table.remove(args, 1) end

    markName = table.concat(args, ' ')

    ArenaNotify({
        title = (Config.Brand or {}).notifyTitle or 'PVP',
        description = ('Marking a %s board. Aim at a wall and press %s: top left, top right, bottom right, bottom left.')
            :format(markKind, Config.Billboard.markKeyName or 'right mouse'),
        type = 'inform',
        duration = 8000
    })
end, false)

local CORNER_NAMES = { 'TOP LEFT', 'TOP RIGHT', 'BOTTOM RIGHT', 'BOTTOM LEFT' }

CreateThread(function()
    while true do
        local sleep = 500

        if marking then
            sleep = 0

            local next_ = #markCorners + 1
            local markKey = Config.Billboard.markKey or 25
            local keyName = Config.Billboard.markKeyName or 'RIGHT MOUSE'

            -- Disable it first, then read the disabled state.
            --
            -- Right mouse is the aim control -- left enabled, the game
            -- consumes the press to raise your weapon and the marker never
            -- sees it. Disabling stops the game acting on it while still
            -- letting us read it, which is the standard way round this.
            DisableControlAction(0, markKey, true)
            DisableControlAction(0, 24, true)    -- and don't fire either
            DisableControlAction(0, 257, true)

            lib.showTextUI(('[%s]  Mark %s   (%s of 4)')
                :format(keyName, CORNER_NAMES[next_] or '?', next_),
                { position = 'left-center' })

            -- Show where the point would land, so you are not guessing.
            local aim = raycastAim()
            if aim then
                DrawMarker(28, aim.x, aim.y, aim.z, 0,0,0, 0,0,0,
                    Config.Billboard.markerSize or 0.28,
                    Config.Billboard.markerSize or 0.28,
                    Config.Billboard.markerSize or 0.28,
                    22, 228, 95, 190, false, false, 2, nil, nil, false)
            end

            -- And the corners placed so far, plus the edges between them.
            for i, c in ipairs(markCorners) do
                DrawMarker(28, c.x, c.y, c.z, 0,0,0, 0,0,0, 0.22, 0.22, 0.22,
                    201, 162, 39, 220, false, false, 2, nil, nil, false)

                local nxt = markCorners[i + 1] or (i == 4 and markCorners[1]) or nil
                if nxt then
                    DrawLine(c.x, c.y, c.z, nxt.x, nxt.y, nxt.z, 201, 162, 39, 220)
                end
            end

            -- Enter works as a second way in, so a key that turns out to be
            -- claimed by something else never leaves you stuck.
            if (IsDisabledControlJustReleased(0, Config.Billboard.markKey or 25)
                or IsControlJustReleased(0, 201)) and aim then
                markCorners[#markCorners + 1] = { x = aim.x, y = aim.y, z = aim.z }

                if #markCorners >= 4 then
                    TriggerServerEvent('naija-arena:server:saveBoard', markCorners, markName, markKind)
                    marking = false
                    markCorners = {}
                    lib.hideTextUI()
                else
                    Wait(200)
                end
            end
        else
            lib.hideTextUI()
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('naija-arena:client:boardList', function(list)
    print('^3============ LEADERBOARD BOARDS ============^0')
    if #list == 0 then
        print('none marked yet -- run rzboard to mark one')
    end
    for _, b in ipairs(list) do
        local c = b.corners[1]
        print(('  %s   %s   near %.0f %.0f %.0f   by %s')
            :format(b.id, b.name, c.x, c.y, c.z, b.by or '?'))
    end
    -- Flag any that sit on top of each other, since that is invisible from
    -- the list otherwise.
    for i, a in ipairs(list) do
        for j, b in ipairs(list) do
            if i < j and a.corners and b.corners then
                local ax = (a.corners[1].x + a.corners[3].x) / 2
                local ay = (a.corners[1].y + a.corners[3].y) / 2
                local bx = (b.corners[1].x + b.corners[3].x) / 2
                local by = (b.corners[1].y + b.corners[3].y) / 2
                if math.sqrt((ax-bx)^2 + (ay-by)^2) < 4.0 then
                    print(('^1  OVERLAP: %s and %s are in the same place^0')
                        :format(a.name or a.id, b.name or b.id))
                end
            end
        end
    end

    print('^3rzboard delete <id> to remove one^0')
    print('^3============================================^0')
end, false)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then destroyDui() end
end)

-- The unconditional way out, from /exitrz. Deliberately does not check any of
-- our own state -- the whole point is that it works when that state is wrong.
RegisterNetEvent('naija-arena:client:forceExit', function(c)
    DoScreenFadeOut(500)
    local waited = 0
    while not IsScreenFadedOut() and waited < 2000 do Wait(50) waited = waited + 50 end

    -- Tear down anything a match, the lobby OR another resource's mode left
    -- behind. This is the command people run when something is stuck, so it
    -- clears the held-kit flags itself rather than waiting for the watchdog.
    LobbyKit = false
    KitHeldExternally = false
    TriggerEvent('naija-arena:cleanupMatch')

    myArena = nil
    blockedUntil = 0
    matchDead = false
    ArenaProtectClear()

    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    pcall(SetEntityInvincible, ped, false)
    pcall(SetPlayerInvincible, PlayerId(), false)
    pcall(SetEntityHealth, ped, 200)

    SetEntityCoordsNoOffset(ped, c.x + 0.0, c.y + 0.0, c.z + 0.0, false, false, false)
    SetEntityHeading(ped, c.w or 0.0)

    RequestCollisionAtCoord(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    waited = 0
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    Wait(300)
    DoScreenFadeIn(600)
end)

-- ============================================================
--  PLACING PROPS
-- ============================================================
-- Spawn a billboard and position it by hand, so a board does not have to sit
-- flat against a wall that is not flat. Pitch and roll are here for exactly
-- that: angle the prop to the surface, then mark the board on it.

local placedProps = {}    -- [id] = object handle
-- `placing` is declared at the top of the file: the board marker needs to
-- know whether this is running, and it sits above here.

local PLACE_KEYS = {
    -- control, label, what it does
    { 32,  'W',        'forward'   },
    { 33,  'S',        'back'      },
    { 34,  'A',        'left'      },
    { 35,  'D',        'right'     },
    { 44,  'Q',        'turn left' },
    { 38,  'E',        'turn right'},
    { 10,  'PgUp',     'up'        },
    { 11,  'PgDn',     'down'      },
    { 20,  'Z',        'pitch'     },
    { 73,  'X',        'roll'      },
    { 21,  'Shift',    'faster'    },
    { 191, 'Enter',    'place it'  },
    { 194, 'Backspace','cancel'    },
    { 45,  'R',        'to ground' },
    { 47,  'G',        'level'     },
    { 74,  'H',        'snap 45'   },
}

local function spawnPlaced(entry)
    local model = joaat(entry.model)
    RequestModel(model)

    local tries = 0
    while not HasModelLoaded(model) and tries < 120 do
        Wait(50)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then return nil end

    local obj = CreateObject(model, entry.x, entry.y, entry.z, false, false, false)
    SetEntityRotation(obj, entry.rx or 0.0, entry.ry or 0.0, entry.rz or 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetModelAsNoLongerNeeded(model)

    return obj
end

local function rebuildProps(list)
    for id, obj in pairs(placedProps) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
        placedProps[id] = nil
    end

    for _, entry in ipairs(list or {}) do
        local obj = spawnPlaced(entry)
        if obj then placedProps[entry.id] = obj end
    end
end

AddStateBagChangeHandler('arenaProps', 'global', function(_, _, value)
    rebuildProps(value)
end)

CreateThread(function()
    Wait(3500)
    rebuildProps(GlobalState.arenaProps or {})
end)

RegisterCommand('rzprop', function(_, args)
    local sub = args[1]

    if sub == 'list' then
        TriggerServerEvent('naija-arena:server:listProps')
        return
    end

    if sub == 'delete' then
        if not args[2] then
            print('[arena] rzprop delete <id>   -- run rzprop list for ids')
            return
        end
        TriggerServerEvent('naija-arena:server:deleteProp', args[2])
        return
    end

    if placing then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP', description = 'Already placing something.', type = 'error' })
        return
    end

    if editing then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Finish editing that board first.', type = 'error' })
        return
    end

    if marking then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Finish marking the board first, or rzboard cancel.', type = 'error' })
        return
    end

    local model = sub or 'prop_billboard_05'
    local hash = joaat(model)

    if not IsModelValid(hash) then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = ('%s is not a valid model.'):format(model), type = 'error' })
        return
    end

    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 120 do Wait(50) tries = tries + 1 end
    if not HasModelLoaded(hash) then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP', description = 'That model would not load.', type = 'error' })
        return
    end

    -- Start it a few metres in front of you, facing the way you are.
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local fwd = vector3(-math.sin(math.rad(heading)), math.cos(math.rad(heading)), 0.0)
    local at = pos + (fwd * 5.0)

    local obj = CreateObject(hash, at.x, at.y, at.z, false, false, false)
    SetEntityHeading(obj, heading)
    SetEntityCollision(obj, false, false)
    SetEntityAlpha(obj, 200, false)
    FreezeEntityPosition(obj, true)
    SetModelAsNoLongerNeeded(hash)

    placing = { obj = obj, model = model, rx = 0.0, ry = 0.0, rz = heading }

    ArenaNotify({
        title = (Config.Brand or {}).notifyTitle or 'PVP',
        description = 'Controls are on screen. R drops it to the ground, G levels it, H snaps the heading.',
        type = 'inform',
        duration = 7000
    })
end, false)

CreateThread(function()
    while true do
        local sleep = 500

        if placing then
            sleep = 0
            local obj = placing.obj

            if not DoesEntityExist(obj) then
                placing = nil
            else
                -- Block the controls we are borrowing.
                --
                -- 32-35 are the discrete WASD keys, but 30 and 31 are the
                -- movement AXES -- which is what actually walks the ped. Only
                -- blocking the former is why the character ran around behind
                -- the prop while you were placing it.
                DisableControlAction(0, 30, true)   -- move left/right
                DisableControlAction(0, 31, true)   -- move forward/back
                DisableControlAction(0, 21, true)   -- sprint
                DisableControlAction(0, 22, true)   -- jump
                DisableControlAction(0, 23, true)   -- enter vehicle
                DisableControlAction(0, 24, true)   -- attack
                DisableControlAction(0, 25, true)   -- aim
                DisableControlAction(0, 36, true)   -- duck
                DisableControlAction(0, 44, true)   -- cover / our Q
                DisableControlAction(0, 37, true)   -- weapon wheel

                for _, k in ipairs(PLACE_KEYS) do
                    DisableControlAction(0, k[1], true)
                end

                local fast = IsDisabledControlPressed(0, 21)
                local step = fast and 0.30 or 0.05
                local turn = fast and 3.0 or 0.5

                local c = GetEntityCoords(obj)
                local cam = GetGameplayCamRot(2)
                local yaw = math.rad(cam.z)

                -- Movement is relative to where the camera is looking, which
                -- is what you expect when nudging something into place.
                local fwd = vector3(-math.sin(yaw), math.cos(yaw), 0.0)
                local right = vector3(math.cos(yaw), math.sin(yaw), 0.0)
                local move = vector3(0.0, 0.0, 0.0)

                if IsDisabledControlPressed(0, 32) then move = move + (fwd * step) end
                if IsDisabledControlPressed(0, 33) then move = move - (fwd * step) end
                if IsDisabledControlPressed(0, 34) then move = move - (right * step) end
                if IsDisabledControlPressed(0, 35) then move = move + (right * step) end
                if IsDisabledControlPressed(0, 10) then move = move + vector3(0.0, 0.0, step) end
                if IsDisabledControlPressed(0, 11) then move = move - vector3(0.0, 0.0, step) end

                if move.x ~= 0.0 or move.y ~= 0.0 or move.z ~= 0.0 then
                    SetEntityCoordsNoOffset(obj, c.x + move.x, c.y + move.y, c.z + move.z, false, false, false)
                end

                if IsDisabledControlPressed(0, 44) then placing.rz = placing.rz - turn end
                if IsDisabledControlPressed(0, 38) then placing.rz = placing.rz + turn end

                -- Pitch and roll, for surfaces that are not flat.
                if IsDisabledControlPressed(0, 20) then placing.rx = placing.rx + turn end
                if IsDisabledControlPressed(0, 73) then placing.ry = placing.ry + turn end

                -- R: drop it to the ground. Getting height right by eye is
                -- the slowest part of placing anything.
                if IsDisabledControlJustReleased(0, 45) then
                    local found, gz = GetGroundZFor_3dCoord(c.x, c.y, c.z + 20.0, false)
                    if found then
                        SetEntityCoordsNoOffset(obj, c.x, c.y, gz, false, false, false)
                    end
                end

                -- G: straighten it up. Easy to tilt something by accident and
                -- fiddly to get back to level by hand.
                if IsDisabledControlJustReleased(0, 47) then
                    placing.rx, placing.ry = 0.0, 0.0
                end

                -- H: snap the heading to the nearest 45 degrees, for anything
                -- that should sit square to a building.
                if IsDisabledControlJustReleased(0, 74) then
                    placing.rz = math.floor((placing.rz + 22.5) / 45) * 45.0
                end

                SetEntityRotation(obj, placing.rx, placing.ry, placing.rz, 2, true)

                -- ── on-screen controls ──
                --
                -- Font and scale are set INSIDE the loop. GTA resets them
                -- after every DrawText, so setting them once meant the first
                -- line drew correctly and every line after it came out at the
                -- default size -- which is enormous, and why this covered
                -- half the screen.
                local lines = {
                    { ('~y~PLACING  ~s~%s'):format(placing.model), 0.34 },
                    { ('~c~%.2f  %.2f  %.2f'):format(c.x, c.y, c.z), 0.30 },
                    { ('~c~rot  %.1f  %.1f  %.1f'):format(placing.rx, placing.ry, placing.rz), 0.30 },
                    { '', 0.24 },
                    { '~y~W A S D~s~   move', 0.30 },
                    { '~y~Q / E~s~   turn        ~y~Z~s~   pitch        ~y~X~s~   roll', 0.30 },
                    { '~y~PgUp / PgDn~s~   height       ~y~Shift~s~   faster', 0.30 },
                    { '~y~R~s~   drop to ground    ~y~G~s~   level     ~y~H~s~   snap 45', 0.30 },
                    { '', 0.24 },
                    { '~g~ENTER~s~  place it        ~r~BACKSPACE~s~  cancel', 0.32 }
                }

                -- a panel behind it, so it reads over any background
                DrawRect(0.145, 0.425, 0.25, 0.225, 0, 0, 0, 170)
                DrawRect(0.145, 0.318, 0.25, 0.005, 201, 162, 39, 220)

                local y = 0.330
                for _, entry in ipairs(lines) do
                    local text, scale = entry[1], entry[2]

                    if text ~= '' then
                        SetTextFont(4)
                        SetTextScale(scale, scale)
                        SetTextColour(232, 239, 233, 235)
                        SetTextOutline()
                        SetTextEntry('STRING')
                        AddTextComponentString(text)
                        DrawText(0.028, y)
                    end

                    y = y + (scale * 0.062)
                end

                if IsDisabledControlJustReleased(0, 191) then
                    local final = GetEntityCoords(obj)
                    TriggerServerEvent('naija-arena:server:saveProp', {
                        model = placing.model,
                        x = final.x, y = final.y, z = final.z,
                        rx = placing.rx, ry = placing.ry, rz = placing.rz
                    })
                    DeleteEntity(obj)
                    placing = nil

                elseif IsDisabledControlJustReleased(0, 194) then
                    DeleteEntity(obj)
                    placing = nil
                    ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP', description = 'Cancelled.', type = 'inform' })
                end
            end
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('naija-arena:client:propList', function(list)
    print('^3============ PLACED PROPS ============^0')
    if #list == 0 then print('none placed yet -- run rzprop to place one') end
    for _, pr in ipairs(list) do
        print(('  %s   %s   %.1f %.1f %.1f   by %s')
            :format(pr.id, pr.model, pr.x, pr.y, pr.z, pr.by or '?'))
    end
    print('^3rzprop delete <id> to remove one^0')
    print('^3======================================^0')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if placing and DoesEntityExist(placing.obj) then DeleteEntity(placing.obj) end
    for _, obj in pairs(placedProps) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
end)

-- ============================================================
--  MARKING A ZONE
-- ============================================================
-- Walk the shape and press E at each point. Three or more, any shape -- a
-- rectangle was always a compromise, and a zone that follows the walls of the
-- place you are actually fighting in is a better zone.
--
-- The panel gets out of the way while you do it, since you cannot walk a
-- perimeter with a cursor trapped in a menu.

local zoneMarking = nil   -- { arenaId, points }

local function stopZoneMarking(silent)
    zoneMarking = nil
    pcall(lib.hideTextUI)
    if not silent then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Marking cancelled.', type = 'inform' })
    end
end

RegisterNUICallback('control', function(d, cb)
    lib.callback('naija-arena:server:control', false, function(res)
        cb(res or { ok = false, message = 'No reply from the server.' })
    end, d.action, d.payload or {})
end)

RegisterNUICallback('startMarking', function(d, cb)
    cb({})

    if marking or placing then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'Finish what you are placing first.', type = 'error' })
        return
    end

    zoneMarking = { arenaId = d.id, points = {} }

    -- Out of the way so the perimeter can actually be walked.
    setPanel(false)

    local alt = Config.Billboard.markKeyAlt
    if alt == nil then alt = 38 end

    ArenaNotify({
        title = (Config.Brand or {}).notifyTitle or 'PVP',
        description = ('Walk the shape. %s at each point, Enter to save, Backspace to cancel.')
            :format(alt
                and ('%s or %s'):format(
                    Config.Billboard.markKeyName or 'right mouse',
                    Config.Billboard.markKeyAltName or 'E')
                or (Config.Billboard.markKeyName or 'right mouse')),
        type = 'inform',
        duration = 9000
    })
end)

CreateThread(function()
    while true do
        local sleep = 500

        if zoneMarking then
            sleep = 0

            local n = #zoneMarking.points
            local markKey = Config.Billboard.markKey or 25
            local keyName = Config.Billboard.markKeyName or 'RIGHT MOUSE'

            -- A second key that does the same thing.
            --
            -- Right mouse is the one most likely to be claimed by another
            -- resource, and when it is, this loop had no way through at all:
            -- the text sits on screen saying to right click, and right
            -- clicking does nothing. The board marker takes Enter as an
            -- alternate for exactly this reason and says so; this never got
            -- the same treatment, and Enter is already the save key here.
            local altKey = Config.Billboard.markKeyAlt
            if altKey == nil then altKey = 38 end
            local altName = Config.Billboard.markKeyAltName or 'E'

            -- Same reason as the board marker: right mouse is the aim
            -- control, and the game eats it unless it is disabled first.
            DisableControlAction(0, markKey, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 257, true)
            if altKey then DisableControlAction(0, altKey, true) end

            -- Both keys named on screen, so nobody has to find out the hard
            -- way that the first one is not landing.
            local keys = altKey and ('%s or %s'):format(keyName, altName) or keyName

            lib.showTextUI(
                n < 3 and ('[%s]  Mark point %s   (need %s more)'):format(keys, n + 1, 3 - n)
                       or ('[%s]  Mark point %s   ·   [Enter] save %s points')
                            :format(keys, n + 1, n),
                { position = 'left-center' })

            local pos = GetEntityCoords(PlayerPedId())

            -- Where you are standing is the point. Walking the shape is more
            -- accurate than aiming at it from a distance.
            DrawMarker(28, pos.x, pos.y, pos.z - 0.95, 0,0,0, 0,0,0,
                0.25, 0.25, 0.25, 22, 228, 95, 170, false, false, 2, nil, nil, false)

            -- The shape so far, closed back to the first point so you can see
            -- what you are actually going to get.
            for i, p in ipairs(zoneMarking.points) do
                DrawMarker(28, p.x, p.y, p.z - 0.95, 0,0,0, 0,0,0, 0.22, 0.22, 0.22,
                    201, 162, 39, 220, false, false, 2, nil, nil, false)

                local nxt = zoneMarking.points[i + 1]
                if nxt then
                    DrawLine(p.x, p.y, p.z, nxt.x, nxt.y, nxt.z, 201, 162, 39, 220)
                elseif #zoneMarking.points >= 3 then
                    local first = zoneMarking.points[1]
                    DrawLine(p.x, p.y, p.z, first.x, first.y, first.z, 201, 162, 39, 120)
                end

                -- and a line from the last point to where you are now
                if i == #zoneMarking.points then
                    DrawLine(p.x, p.y, p.z, pos.x, pos.y, pos.z, 22, 228, 95, 200)
                end
            end

            if IsDisabledControlJustReleased(0, markKey)
               or (altKey and IsDisabledControlJustReleased(0, altKey)) then
                zoneMarking.points[#zoneMarking.points + 1] = {
                    x = pos.x, y = pos.y, z = pos.z
                }
                Wait(150)

            elseif IsControlJustReleased(0, 191) then
                if #zoneMarking.points < 3 then
                    ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
                        description = 'A zone needs at least three points.', type = 'error' })
                else
                    local id, points = zoneMarking.arenaId, zoneMarking.points
                    zoneMarking = nil
                    pcall(lib.hideTextUI)

                    lib.callback('naija-arena:server:panel', false, function(res)
                        ArenaNotify({
                            title = (Config.Brand or {}).notifyTitle or 'PVP',
                            description = (res and res.message) or 'Saved.',
                            type = (res and res.ok) and 'success' or 'error'
                        })
                        -- The BUILDER back, not the player menu -- you were
                        -- mid-setup, not looking for a match.
                        TriggerServerEvent('naija-arena:server:reopenBuilder')
                    end, 'markPoints', { id = id, points = points })
                end

            elseif IsControlJustReleased(0, 194) then
                stopZoneMarking()
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  RANKED AND THE LOBBY
-- ============================================================
-- These three sat inside the block that held the free-for-all zones and came
-- out with it. Nothing about them was part of that mode: ranked results, the
-- ranked panel and the button that walks you back to the lobby.

RegisterNetEvent('naija-arena:client:rankedResult', function(d)
    SendNUIMessage({ action = 'rankedResult', data = d })
end)

RegisterNUICallback('backToLobby', function(_, cb)
    TriggerServerEvent('naija-arena:server:backToLobby')
    cb({})
end)

RegisterNUICallback('ranked', function(d, cb)
    lib.callback('naija-arena:server:ranked', false, function(res)
        cb(res or { ok = false })
    end, d.action)
end)

-- ============================================================
--  NOBODY STAYS DOWN IN THE LOBBY
-- ============================================================
-- The lobby is a waiting room, not somewhere to bleed out. There is no medic
-- in here and no reason to make anyone wait for one, so anyone in the lobby
-- bucket who is knocked or dead is picked back up -- wherever they are on the
-- map, and whether they got there through a match or walked in already hurt.
CreateThread(function()
    local reviving = false

    while true do
        -- One place decides this, so the lobby and the Red Zone cannot end
        -- up waiting different amounts for the same thing.
        Wait(math.floor(((Config.Down or {}).checkEvery or 2.0) * 1000))

        -- LobbyOnly, not arenaLobby: dying in another resource's mode is
        -- that mode's business. Reviving somebody mid death-screen from here
        -- fights whatever is already handling it.
        if Config.Meeting.autoRevive ~= false
           and LobbyOnly()
           and not reviving then

            local down, why = isDown()

            if down then
                reviving = true
                print(('[arena] down in the lobby (%s) -- picking them up'):format(why or '?'))

                -- Wait for the tail of their death screen, then go. Starting
                -- after it finishes rather than under it is what left people
                -- sitting there wondering.
                Wait(math.floor(((Config.Down or {}).delay
                    or ((Config.Meeting.autoReviveDelay or 9500) / 1000)) * 1000))

                -- Still down? They may have been picked up meanwhile.
                if isDown() then
                    ArenaReviveBehindFade()
                end

                -- Whatever happens, they end up on their feet and whole.
                local ped = PlayerPedId()
                pcall(SetEntityHealth, ped, Config.Ambulance.setHealth or 200)
                pcall(ClearPedBloodDamage, ped)
                pcall(ResetPedVisibleDamage, ped)
                pcall(ClearPedTasksImmediately, ped)

                reviving = false
            end
        end
    end
end)

-- ============================================================
--  THE SHOP PED
-- ============================================================
-- Created and deleted with the lobby, not left standing in the world.
--
-- Peds made client-side exist in whatever bucket you happen to be in, so one
-- spawned at boot follows you into the city. Gating what it OFFERS is not
-- enough -- the ped itself was still standing there, in the middle of RP,
-- with nothing to say.

local shopPed = nil
local shopOpen = false

local function removeShopPed()
    if shopPed and DoesEntityExist(shopPed) then
        pcall(function() exports.ox_target:removeLocalEntity(shopPed) end)
        DeleteEntity(shopPed)
    end
    shopPed = nil

    -- The prompt goes with the ped. Left behind it points at a handle that no
    -- longer exists, which the bubble would resolve to nothing every scan.
    if ArenaPromptRemove then ArenaPromptRemove('arena_shop') end
end

local function createShopPed()
    local cfg = Config.Shop
    if not (cfg and cfg.enabled and cfg.ped) then return end
    if shopPed and DoesEntityExist(shopPed) then return end

    shopPed = spawnPed(cfg.ped.model, cfg.ped.coords, cfg.ped.scenario)
    if not shopPed then
        print('^1[arena] could not spawn the shop ped^0')
        return
    end

    if ArenaPromptRegister
       and (Config.Prompt or {}).enabled and not (Config.Prompt or {}).useTarget then
        ArenaPromptRegister('arena_shop', {
            entity = function() return shopPed end,
            distance = cfg.ped.distance or 2.5,
            title = 'SHOP',
            actions = {
                {
                    key = 38, keyLabel = 'E',
                    label = cfg.ped.label or 'Arena Shop',
                    action = function()
                        TriggerServerEvent('naija-arena:server:openShop')
                    end
                }
            }
        })
        return
    end

    pcall(function()
        exports.ox_target:addLocalEntity(shopPed, {
            {
                name = 'tenx_arena_shop',
                label = cfg.ped.label or 'Arena Shop',
                icon = cfg.ped.icon or 'fas fa-store',
                distance = cfg.ped.distance or 2.5,
                onSelect = function()
                    TriggerServerEvent('naija-arena:server:openShop')
                end
            }
        })
    end)
end

-- It exists only while you are in the lobby.
CreateThread(function()
    Wait(3000)
    local was = nil

    while true do
        Wait(1000)
        local now = LocalPlayer.state.arenaLobby == true

        if now ~= was then
            was = now
            if now then createShopPed() else removeShopPed() end
        end
    end
end)

-- Back to the lobby without opening a menu, because mid-fight is exactly
-- when you want it and exactly when a menu is awkward.
RegisterCommand('lobby', function()
    TriggerServerEvent('naija-arena:server:backToLobby')
end, false)

RegisterCommand('rzshop', function()
    if not LocalPlayer.state.arenaLobby then
        ArenaNotify({ title = (Config.Brand or {}).notifyTitle or 'PVP',
            description = 'The shop is in the lobby.', type = 'error' })
        return
    end
    TriggerServerEvent('naija-arena:server:openShop')
end, false)

RegisterNetEvent('naija-arena:client:openShop', function(state)
    shopOpen = true
    setFocus('shop', true)
    SendNUIMessage({ action = 'openShop', state = state })
end)

RegisterNUICallback('closeShop', function(_, cb)
    shopOpen = false
    setFocus('shop', false)
    SendNUIMessage({ action = 'closeShop' })
    cb({})
end)

RegisterNUICallback('shop', function(d, cb)
    lib.callback('naija-arena:server:shop', false, function(res)
        cb(res or { ok = false, message = 'No reply from the server.' })
    end, d.action, d.payload or {})
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then removeShopPed() end
end)

-- ============================================================
--  THINGS ON THE GROUND
-- ============================================================
-- Dropped items are drawn where they landed and anyone can pick them up. An
-- item that vanishes when dropped is how people stop trusting an inventory.

local groundDrops = {}

RegisterNetEvent('naija-arena:client:drops', function(list)
    groundDrops = list or {}
end)

AddStateBagChangeHandler('arenaMatch', ('player:%s'):format(GetPlayerServerId(PlayerId())),
    function()
        TriggerServerEvent('naija-arena:server:wantDrops')
        -- And re-arm: a weapon held empty in the lobby needs its ammo now.
        TriggerServerEvent('naija-arena:server:invRequest')
    end)
AddStateBagChangeHandler('arenaLobby', ('player:%s'):format(GetPlayerServerId(PlayerId())),
    function() TriggerServerEvent('naija-arena:server:wantDrops') end)

CreateThread(function()
    Wait(4000)
    TriggerServerEvent('naija-arena:server:wantDrops')

    local prompting = false

    -- Which drops are close enough to bother with, worked out four times a
    -- second rather than sixty. Drawing has to happen every frame; deciding
    -- WHAT to draw does not, and doing that maths for every pile on the map
    -- sixty times a second was most of the cost.
    local near = {}
    local lastScan = 0

    while true do
        local sleep = 700

        local _p = PerfLoop and PerfLoop('ground-drops')
        if #groundDrops > 0 then
            local pos = GetEntityCoords(PlayerPedId())
            local range = (Config.MatchInventory and Config.MatchInventory.dropRange) or 2.0
            local closest, closestD = nil, 999.0
            local now = GetGameTimer()

            if now - lastScan > 250 then
                lastScan = now
                near = {}
                for _, d in ipairs(groundDrops) do
                    if #(pos - vec3(d.x, d.y, d.z)) < 20.0 then
                        near[#near + 1] = d
                    end
                end
            end

            for _, d in ipairs(near) do
                local dist = #(pos - vec3(d.x, d.y, d.z))

                if dist < 20.0 then
                    sleep = 0

                    DrawMarker(21, d.x, d.y, d.z + 0.6, 0,0,0, 0,0,0,
                        0.28, 0.28, 0.28,
                        201, 162, 39, 140, true, false, 2, nil, nil, false)

                    if dist < 6.0 then
                        -- THREE return values: success, x, y.
                        --
                        -- Read as two, sx got the boolean and sy got the
                        -- screen X, and the Y was thrown away -- so the label
                        -- drew hard against the left edge at whatever height
                        -- the X happened to be, nowhere near the marker it
                        -- belonged to. The `if sx` guard hid it: the boolean
                        -- is false when the point is off screen, so the text
                        -- appeared and disappeared at roughly the right times
                        -- while never being in the right place.
                        local onScreen, sx, sy =
                            GetScreenCoordFromWorldCoord(d.x, d.y, d.z + 1.0)

                        if onScreen then
                            SetTextFont(4)
                            SetTextScale(0.32, 0.32)
                            SetTextCentre(true)
                            SetTextColour(232, 239, 233, 220)
                            SetTextOutline()
                            SetTextEntry('STRING')
                            AddTextComponentString(('%s ~y~x%s'):format(d.label or d.name, d.count))
                            DrawText(sx, sy)
                        end
                    end

                    if dist < closestD then closest, closestD = d, dist end
                end
            end

            if closest and closestD < range then
                if not prompting then
                    lib.showTextUI(('[E]  Pick up %s x%s'):format(closest.label, closest.count),
                        { position = 'left-center' })
                    prompting = true
                end

                if IsControlJustReleased(0, 38) then
                    TriggerServerEvent('naija-arena:server:pickup', closest.id)
                    Wait(400)
                end
            elseif prompting then
                pcall(lib.hideTextUI)
                prompting = false
            end
        elseif prompting then
            pcall(lib.hideTextUI)
            prompting = false
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

-- ============================================================
--  NOTHING TRAPS YOU
-- ============================================================
-- Escape closes whatever is open, handled in the interface. This is the layer
-- under that: a keybind the game itself owns, so it works even if the page
-- has stopped responding -- which is exactly when you need it.

RegisterCommand('naija_escape', function()
    local anything = playerPanelOpen or shopOpen or next(focusClaims or {})
    if not anything then return end

    -- Tell the page first so it can close tidily and remember what it was
    -- doing; the hard release below is the fallback.
    SendNUIMessage({ action = 'forceClose' })

    playerPanelOpen = false
    shopOpen = false
    dropAllFocus()
end, false)

-- Bound to BACKSPACE rather than ESC: FiveM does not give a resource the
-- escape key, because the pause menu owns it. Anyone who has ever been stuck
-- in a NUI knows to reach for something, and this is documented in /rzhelp.
RegisterKeyMapping('naija_escape', 'Close any NAIJA panel', 'keyboard', 'BACK')

-- A last resort that does not need a key at all.
RegisterCommand('rzclose', function()
    ExecuteCommand('naija_escape')
end, false)

-- ============================================================
--  HOLDING A GUN IN THE LOBBY
-- ============================================================
-- You can equip and look at what you own; you cannot fire it.
--
-- The alternative is buying a weapon and not seeing it until a match starts,
-- which is a poor way to spend a thousand coins. But a lobby full of people
-- test-firing into each other is not a lobby.

CreateThread(function()
    while true do
        local sleep = 500

        -- AND the kit has to be up.
        --
        -- LobbyOnly leans on the server's answer, which is only refreshed
        -- when a grid arrives -- so a player who walked out to the city
        -- without one would still be carrying the lobby's answer, and this
        -- thread would quietly disable their trigger in the middle of Los
        -- Santos. The kit going down is unambiguous and local, so it is the
        -- backstop: no arena kit, no arena rules.
        if LobbyOnly() and ArenaKitActive() then
            sleep = 0

            -- Attack, aim, melee and the vehicle equivalents. Blocking the
            -- trigger rather than taking the weapon away, so it stays in
            -- your hands and looks right.
            --
            -- 47 is in this list, and 47 is also the "go to free roam" key on
            -- the entry ped's bubble. That is why pressing G in the lobby did
            -- nothing: this thread disables it every frame as a weapon
            -- control. The prompt reads its keys with
            -- IsDisabledControlJustReleased for exactly this reason -- a
            -- disabled control still reports, it just does not act.
            DisableControlAction(0, 24, true)    -- attack
            DisableControlAction(0, 25, true)    -- aim
            DisableControlAction(0, 47, true)    -- weapon
            DisableControlAction(0, 58, true)    -- weapon (alt)
            DisableControlAction(0, 140, true)   -- melee light
            DisableControlAction(0, 141, true)   -- melee heavy
            DisableControlAction(0, 142, true)   -- melee alternate
            DisableControlAction(0, 257, true)   -- attack 2
            DisableControlAction(0, 263, true)   -- melee attack 1
            DisableControlAction(0, 264, true)   -- melee attack 2
            DisableControlAction(0, 331, true)   -- vehicle attack

            -- The weapon is already empty -- see armFromInventory -- so this
            -- is only about not raising it at someone. No clip fiddling:
            -- emptying a magazine here would follow them into the match.
            SetPlayerCanDoDriveBy(PlayerId(), false)
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  LOOKING AT PROPS
-- ============================================================
-- Finding a big flat prop is guesswork otherwise: you read a name off a list,
-- spawn it, and find out it has legs. This steps through the candidates one
-- at a time so you can look at each before committing to it.

local browseIndex = 0
local browseObj = nil

local function clearBrowse()
    if browseObj and DoesEntityExist(browseObj) then DeleteEntity(browseObj) end
    browseObj = nil
end

local function showProp(index)
    local list = Config.FlatProps or {}
    if #list == 0 then return end

    -- Wraps both ways, so you can walk back past the start.
    browseIndex = ((index - 1) % #list) + 1
    local name = list[browseIndex]

    clearBrowse()

    local hash = joaat(name)
    if not IsModelValid(hash) then
        ArenaNotify({ title = 'Props',
            description = ('%s is not a valid model (%s of %s).')
                :format(name, browseIndex, #list),
            type = 'error' })
        return
    end

    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 100 do Wait(50) tries = tries + 1 end

    if not HasModelLoaded(hash) then
        ArenaNotify({ title = 'Props',
            description = ('%s would not load.'):format(name), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local fwd = vector3(-math.sin(math.rad(heading)), math.cos(math.rad(heading)), 0.0)
    local at = pos + (fwd * 8.0)

    browseObj = CreateObject(hash, at.x, at.y, at.z, false, false, false)
    SetEntityHeading(browseObj, heading + 180.0)
    SetEntityCollision(browseObj, false, false)
    SetEntityAlpha(browseObj, 220, false)
    FreezeEntityPosition(browseObj, true)
    SetModelAsNoLongerNeeded(hash)

    -- Its actual size, which is the thing you are trying to judge.
    local min, max = GetModelDimensions(hash)
    local w = math.abs(max.x - min.x)
    local d = math.abs(max.y - min.y)
    local h = math.abs(max.z - min.z)
    local thinnest = math.min(w, d)

    ArenaNotify({
        title = ('%s of %s'):format(browseIndex, #list),
        description = ('%s\n%.1fm wide, %.1fm tall, %.1fm thick%s')
            :format(name, math.max(w, d), h, thinnest,
                thinnest < 0.6 and '  — properly flat' or ''),
        type = thinnest < 0.6 and 'success' or 'inform',
        duration = 6000
    })
end

RegisterCommand('rzprops', function(_, args)
    local sub = (args[1] or ''):lower()

    if sub == 'stop' or sub == 'cancel' then
        clearBrowse()
        return ArenaNotify({ title = 'Props', description = 'Done.', type = 'inform' })
    end

    if sub == 'use' then
        local list = Config.FlatProps or {}
        local name = list[browseIndex]
        if not name then
            return ArenaNotify({ title = 'Props',
                description = 'Nothing to place yet -- run rzprops first.', type = 'error' })
        end

        clearBrowse()
        -- Straight into the placer, so you can position it properly.
        ExecuteCommand('rzprop ' .. name)
        return
    end

    if sub == 'prev' or sub == 'back' then
        return showProp(browseIndex - 1)
    end

    -- A name typed directly, so you can check anything you find elsewhere
    -- without editing the config first.
    if sub ~= '' and sub ~= 'next' then
        local list = Config.FlatProps or {}

        -- Already on the list? Jump to it rather than adding a duplicate.
        for i, name in ipairs(list) do
            if name:lower() == sub then return showProp(i) end
        end

        list[#list + 1] = args[1]
        return showProp(#list)
    end

    -- Anything else steps forward, including a bare rzprops.
    showProp(browseIndex + 1)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearBrowse()
    -- An unsaved edit is discarded rather than half-applied.
    editing = nil
end)

-- ============================================================
--  EDITING A BOARD IN PLACE
-- ============================================================
-- Pick one, then move it with the keys and size it with the wheel, watching
-- it the whole time. Typing metres into a command and re-reading the result
-- is a slow way to hang a sign.
--
-- The edit is local until you save: the board you are dragging is drawn from
-- a working copy, and cancelling leaves the stored one untouched.

-- `editing` is declared at the top of the file: the other placement modes
-- check it and they sit well above here.

local EDIT_KEYS = {
    32, 33, 34, 35,     -- WASD
    10, 11,             -- PgUp / PgDn
    14, 15,             -- mouse wheel
    21,                 -- shift
    44, 38,             -- Q / E
    20, 73,             -- Z / X
    191, 194,           -- enter / backspace
    24, 25, 22, 23, 36, 37, 47, 58,
}

--- A copy, so cancelling really does cancel.
local function copyCorners(c)
    local out = {}
    for i = 1, 4 do
        out[i] = { x = c[i].x + 0.0, y = c[i].y + 0.0, z = c[i].z + 0.0 }
    end
    return out
end

--- The face's own normal -- which way the board is pointing.
local function boardNormal(c)
    local ax, ay, az = c[2].x - c[1].x, c[2].y - c[1].y, c[2].z - c[1].z
    local bx, by, bz = c[4].x - c[1].x, c[4].y - c[1].y, c[4].z - c[1].z

    local nx = (ay * bz) - (az * by)
    local ny = (az * bx) - (ax * bz)
    local nz = (ax * by) - (ay * bx)

    local len = math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
    if len < 0.0001 then return 0.0, 0.0, 1.0 end

    return nx / len, ny / len, nz / len
end

local function boardCentre(c)
    return (c[1].x + c[2].x + c[3].x + c[4].x) / 4,
           (c[1].y + c[2].y + c[3].y + c[4].y) / 4,
           (c[1].z + c[2].z + c[3].z + c[4].z) / 4
end

local function moveBoard(c, dx, dy, dz)
    for i = 1, 4 do
        c[i].x = c[i].x + dx
        c[i].y = c[i].y + dy
        c[i].z = c[i].z + dz
    end
end

--- Grow or shrink around the middle, so it stays where you put it.
local function scaleBoard(c, k)
    -- Clamped: a board scaled to nothing cannot be scaled back, because
    -- every corner is in the same place and there is no shape left to grow.
    local w = math.sqrt((c[2].x - c[1].x)^2 + (c[2].y - c[1].y)^2 + (c[2].z - c[1].z)^2)
    if (w * k) < 0.5 or (w * k) > 400.0 then return end

    local cx, cy, cz = boardCentre(c)
    for i = 1, 4 do
        c[i].x = cx + ((c[i].x - cx) * k)
        c[i].y = cy + ((c[i].y - cy) * k)
        c[i].z = cz + ((c[i].z - cz) * k)
    end
end

--- Spin it around its own normal, for a board that ended up crooked.
local function rollBoard(c, degrees)
    local cx, cy, cz = boardCentre(c)
    local nx, ny, nz = boardNormal(c)
    local a = math.rad(degrees)
    local cosA, sinA = math.cos(a), math.sin(a)

    for i = 1, 4 do
        local px, py, pz = c[i].x - cx, c[i].y - cy, c[i].z - cz

        -- Rodrigues' rotation: the general case, because the normal is
        -- whatever the wall happened to be and not a tidy axis.
        local dot = (px * nx) + (py * ny) + (pz * nz)
        local crx = (ny * pz) - (nz * py)
        local cry = (nz * px) - (nx * pz)
        local crz = (nx * py) - (ny * px)

        c[i].x = cx + (px * cosA) + (crx * sinA) + (nx * dot * (1 - cosA))
        c[i].y = cy + (py * cosA) + (cry * sinA) + (ny * dot * (1 - cosA))
        c[i].z = cz + (pz * cosA) + (crz * sinA) + (nz * dot * (1 - cosA))
    end
end

--- Start editing. With no id, the board you are standing nearest.
local function beginEdit(id)
    if marking or placing or zoneMarking then
        return ArenaNotify({ title = 'Boards',
            description = 'Finish what you are marking first.', type = 'error' })
    end

    local target

    if id then
        for _, b in ipairs(boards) do
            if b.id == id then target = b break end
        end
        if not target then
            return ArenaNotify({ title = 'Boards',
                description = 'No board with that id.', type = 'error' })
        end
    else
        -- Nearest, so you can walk up to one and just type the command.
        local pos = GetEntityCoords(PlayerPedId())
        local best = math.huge

        for _, b in ipairs(boards) do
            if b.corners and #b.corners == 4 then
                local cx = (b.corners[1].x + b.corners[3].x) / 2
                local cy = (b.corners[1].y + b.corners[3].y) / 2
                local cz = (b.corners[1].z + b.corners[3].z) / 2
                local d = #(pos - vec3(cx, cy, cz))
                if d < best then best, target = d, b end
            end
        end

        if not target then
            return ArenaNotify({ title = 'Boards',
                description = 'No boards marked yet.', type = 'error' })
        end
        if best > 80.0 then
            return ArenaNotify({ title = 'Boards',
                description = 'Nothing close by. Walk up to one, or give its id.',
                type = 'error' })
        end
    end

    editing = {
        id = target.id,
        name = target.name or target.id,
        kind = target.kind,
        corners = copyCorners(target.corners),
        original = copyCorners(target.corners)
    }

    ArenaNotify({
        title = 'Editing ' .. editing.name,
        description = 'Controls are on screen. Enter saves, Backspace throws it away.',
        type = 'inform',
        duration = 7000
    })
end

-- Place a point without a key at all.
--
-- Whichever key gets chosen, some server somewhere has it bound to something
-- that eats it. A command cannot be stolen, so this is the way out rather
-- than being stuck unable to mark anything.
RegisterCommand('rzmark', function()
    if zoneMarking then
        local pos = GetEntityCoords(PlayerPedId())
        zoneMarking.points[#zoneMarking.points + 1] = { x = pos.x, y = pos.y, z = pos.z }
        return
    end

    if marking then
        local aim = raycastAim()
        if not aim then
            return ArenaNotify({ title = 'Boards',
                description = 'Look at a wall first.', type = 'error' })
        end

        markCorners[#markCorners + 1] = { x = aim.x, y = aim.y, z = aim.z }

        if #markCorners >= 4 then
            TriggerServerEvent('naija-arena:server:saveBoard', markCorners, markName, markKind)
            marking = false
            markCorners = {}
            pcall(lib.hideTextUI)
        end
        return
    end

    ArenaNotify({ title = 'Boards',
        description = 'Nothing is being marked. Start with /rzboard or the zone builder.',
        type = 'inform' })
end, false)

RegisterCommand('rzedit', function(_, args)
    if editing then
        editing = nil
        return ArenaNotify({ title = 'Boards', description = 'Stopped.', type = 'inform' })
    end
    beginEdit(args[1])
end, false)

CreateThread(function()
    while true do
        local sleep = 500

        if editing then
            sleep = 0
            local c = editing.corners

            -- Everything we are borrowing, so nothing walks off or shoots.
            DisableControlAction(0, 30, true)
            DisableControlAction(0, 31, true)
            for _, k in ipairs(EDIT_KEYS) do DisableControlAction(0, k, true) end

            local fast = IsDisabledControlPressed(0, 21)
            local step = fast and 0.35 or 0.06
            local spin = fast and 3.0 or 0.6

            -- Movement follows the camera, which is what you expect when
            -- nudging something you are looking at.
            local yaw = math.rad(GetGameplayCamRot(2).z)
            local fwd = vector3(-math.sin(yaw), math.cos(yaw), 0.0)
            local right = vector3(math.cos(yaw), math.sin(yaw), 0.0)

            if IsDisabledControlPressed(0, 32) then moveBoard(c, fwd.x * step, fwd.y * step, 0.0) end
            if IsDisabledControlPressed(0, 33) then moveBoard(c, -fwd.x * step, -fwd.y * step, 0.0) end
            if IsDisabledControlPressed(0, 34) then moveBoard(c, -right.x * step, -right.y * step, 0.0) end
            if IsDisabledControlPressed(0, 35) then moveBoard(c, right.x * step, right.y * step, 0.0) end
            if IsDisabledControlPressed(0, 10) then moveBoard(c, 0.0, 0.0, step) end
            if IsDisabledControlPressed(0, 11) then moveBoard(c, 0.0, 0.0, -step) end

            -- Q and E push it off the wall and back, along its own normal.
            if IsDisabledControlPressed(0, 44) or IsDisabledControlPressed(0, 38) then
                local nx, ny, nz = boardNormal(c)
                local dir = IsDisabledControlPressed(0, 38) and 1.0 or -1.0
                moveBoard(c, nx * step * dir, ny * step * dir, nz * step * dir)
            end

            -- Z and X roll it, for one that ended up crooked.
            if IsDisabledControlPressed(0, 20) then rollBoard(c, spin) end
            if IsDisabledControlPressed(0, 73) then rollBoard(c, -spin) end

            -- The wheel sizes it. Just-released rather than pressed, or one
            -- flick of the wheel runs for several frames and jumps.
            if IsDisabledControlJustReleased(0, 15) then scaleBoard(c, fast and 1.20 or 1.04) end
            if IsDisabledControlJustReleased(0, 14) then scaleBoard(c, fast and 0.83 or 0.96) end

            -- Draw it where it currently is. The stored board is drawn too,
            -- so you can see what you are changing it from.
            local page = pageFor(BoardKind(editing.kind))
            if page then drawBoard(c, page.tex) end

            -- Outline, so the edges are visible against the wall.
            for i = 1, 4 do
                local a, b = c[i], c[(i % 4) + 1]
                DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 22, 228, 95, 220)
            end

            local w = math.sqrt((c[2].x - c[1].x)^2 + (c[2].y - c[1].y)^2 + (c[2].z - c[1].z)^2)
            local h = math.sqrt((c[4].x - c[1].x)^2 + (c[4].y - c[1].y)^2 + (c[4].z - c[1].z)^2)

            local lines = {
                { ('~y~EDITING  ~s~%s'):format(editing.name), 0.34 },
                { ('~c~%.1fm wide,  %.1fm tall'):format(w, h), 0.30 },
                { '', 0.22 },
                { '~y~W A S D~s~   move        ~y~PgUp / PgDn~s~   height', 0.29 },
                { '~y~Q / E~s~   off the wall     ~y~Z / X~s~   straighten', 0.29 },
                { '~y~MOUSE WHEEL~s~   size      ~y~Shift~s~   faster', 0.29 },
                { '', 0.22 },
                { '~g~ENTER~s~  save        ~r~BACKSPACE~s~  throw it away', 0.31 }
            }

            DrawRect(0.145, 0.415, 0.25, 0.20, 0, 0, 0, 175)
            DrawRect(0.145, 0.318, 0.25, 0.005, 201, 162, 39, 220)

            local y = 0.330
            for _, entry in ipairs(lines) do
                if entry[1] ~= '' then
                    SetTextFont(4)
                    SetTextScale(entry[2], entry[2])
                    SetTextColour(232, 239, 233, 235)
                    SetTextOutline()
                    SetTextEntry('STRING')
                    AddTextComponentString(entry[1])
                    DrawText(0.028, y)
                end
                y = y + (entry[2] * 0.062)
            end

            if IsDisabledControlJustReleased(0, 191) then
                TriggerServerEvent('naija-arena:server:saveBoardShape', editing.id, editing.corners)
                editing = nil

            elseif IsDisabledControlJustReleased(0, 194) then
                editing = nil
                ArenaNotify({ title = 'Boards',
                    description = 'Left as it was.', type = 'inform' })
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================
--  THE BLIP
-- ============================================================
-- Shown in the city, hidden once you are inside.
--
-- It was created when you ENTERED the lobby, which is backwards: the blip
-- exists to tell people in the city where to go, and once you are there it
-- is a marker on top of your own head.

CreateThread(function()
    local blip = nil

    local function makeBlip()
        if blip and DoesBlipExist(blip) then return end

        local b = Config.Meeting.blip
        if not (b and b.enabled) then return end

        blip = AddBlipForCoord(Config.Meeting.coords.x, Config.Meeting.coords.y,
                               Config.Meeting.coords.z)
        SetBlipSprite(blip, b.sprite or 313)
        SetBlipColour(blip, b.colour or 3)
        SetBlipScale(blip, b.scale or 0.9)
        SetBlipAsShortRange(blip, b.shortRange == true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(b.label or (Config.Brand or {}).modeName or 'PVP')
        EndTextCommandSetBlipName(blip)
    end

    local function dropBlip()
        if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
        blip = nil
    end

    Wait(2000)

    local was = nil

    while true do
        Wait(1000)

        -- In the city, and nowhere else. Not the lobby, not a match, not a
        -- a match -- in all of them you are already there.
        local inCity = not LocalPlayer.state.arenaLobby
            and not LocalPlayer.state.arenaMatch
    

        if inCity ~= was then
            was = inCity
            if inCity then makeBlip() else dropBlip() end
        end
    end
end)

-- ============================================================
--  WHERE THE TIME GOES
-- ============================================================
-- resmon says the resource costs 5ms; it does not say which of forty threads
-- is spending it. Guessing from a list of likely suspects is how you spend an
-- evening optimising something that was already cheap.
--
--   /rzperf        start measuring
--   /rzperf        again to stop and print the table
--
-- Wraps each named section and reports total time, call count and the worst
-- single call. Off by default and costs nothing when off.

local perfOn = false
local perfData = {}
local perfSince = 0

--- Time a section. Cheap enough to leave in permanently: one boolean check
--- when measuring is off.
function Perf(name, fn)
    if not perfOn then return fn() end

    local t0 = GetGameTimer()
    local a, b, c = fn()
    local dt = GetGameTimer() - t0

    local e = perfData[name]
    if not e then
        e = { total = 0, calls = 0, worst = 0 }
        perfData[name] = e
    end

    e.total = e.total + dt
    e.calls = e.calls + 1
    if dt > e.worst then e.worst = dt end

    return a, b, c
end

--- Wrap a whole loop body. Used by the threads below, so the table shows one
--- row per thread rather than one per call site.
--- GetGameTimer, and that is fine.
---
--- There is no sub-millisecond clock in FiveM's client Lua -- `os` is not in
--- the sandbox at all, which is what the errors were. GetGameTimer returns
--- whole milliseconds.
---
--- That is still usable, because of how the rounding falls: a call costing
--- 0.3ms reads 0 most of the time and 1 whenever it happens to straddle a
--- millisecond boundary, which is roughly 30% of the time. Summed over
--- thousands of calls the total converges on the truth.
---
--- So a section reporting 0.0 across 200 calls really is cheap. It is a
--- single reading that means nothing, not the total.
function PerfLoop(name)
    if not perfOn then return nil end
    return { name = name, t0 = GetGameTimer() }
end

function PerfEnd(mark)
    if not mark or not perfOn then return end

    local dt = GetGameTimer() - mark.t0

    local e = perfData[mark.name]
    if not e then
        e = { total = 0.0, calls = 0, worst = 0.0 }
        perfData[mark.name] = e
    end

    e.total = e.total + dt
    e.calls = e.calls + 1
    if dt > e.worst then e.worst = dt end
end

RegisterCommand('rzperf', function()
    if perfOn then
        perfOn = false

        local rows = {}
        for name, e in pairs(perfData) do rows[#rows + 1] = { name = name, e = e } end
        table.sort(rows, function(x, y) return x.e.total > y.e.total end)

        print('^3[arena] where the time went^0')
        print(('  %-24s %10s %8s %9s %9s')
            :format('section', 'total ms', 'calls', 'avg ms', 'worst ms'))

        if #rows == 0 then
            print('  nothing was measured -- no wrapped section ran')
        end

        local grand = 0.0
        for _, r in ipairs(rows) do
            grand = grand + r.e.total
            print(('  %-24s %10.2f %8d %9.4f %9.3f'):format(
                r.name, r.e.total, r.e.calls,
                r.e.calls > 0 and (r.e.total / r.e.calls) or 0.0,
                r.e.worst))
        end

        local secs = perfSince > 0 and ((GetGameTimer() - perfSince) / 1000) or 1
        print(('  %-24s %10.2f  over %.0f seconds'):format('TOTAL', grand, secs))
        print(('  %-24s %10.2f  ms per second of play')
            :format('', grand / math.max(1, secs)))
        print('')
        print('  Timing is whole-millisecond, so one call reading 0 means')
        print('  nothing -- but a TOTAL of 0 across hundreds of calls is real.')

        perfData = {}
        ArenaNotify({ title = 'Perf', description = 'Stopped. Table is in F8.', type = 'inform' })
    else
        perfOn = true
        perfData = {}
        perfSince = GetGameTimer()
        ArenaNotify({
            title = 'Perf',
            description = 'Measuring. Play for a minute, then /rzperf again.',
            type = 'inform', duration = 6000
        })
    end
end, false)

-- ============================================================
--  EXPORTS FOR OTHER MODES
-- ============================================================
-- The grid, the hotbar and the ox_inventory block, so another resource can
-- run a mode that uses the same kit.
--
-- Without these a mode outside this resource gets a player with an inventory
-- on the server and nothing on screen: no hotbar, no number keys, and a
-- weapon they own but cannot hold.

--- Turn the arena kit on. Call when a player enters your mode.
---
--- Arms them from the grid, blocks ox_inventory, binds the number keys and
--- asks the server for their inventory -- everything a match does.
exports('startKit', function()
    -- Tells the stuck-lock watchdog that this kit is deliberate. Without it
    -- the watchdog tears the whole thing down two seconds later, because it
    -- cannot see a mode that lives in another resource.
    KitHeldExternally = true

    if ArenaHotbarStart then ArenaHotbarStart(nil) end
end)

--- And off. Gives their weapons back to ox_inventory's world.
exports('stopKit', function()
    KitHeldExternally = false
    if ArenaHotbarStop then ArenaHotbarStop() end
end)

--- Ask the server to push the kept inventory down again.
--- Use it after giving somebody something, so it appears without waiting.
exports('refreshKit', function()
    TriggerServerEvent('naija-arena:server:invRequest')
end)

--- Is the grid currently up?
exports('kitActive', function()
    return Hotbar and Hotbar.active == true
end)

-- ============================================================
--  INTERACTION PROMPTS
-- ============================================================
-- The floating bubble over a ped -- key chip, label, tail.
--
-- It is drawn in the NUI and positioned with World3dToScreen2d, because the
-- rounded corners, the chip and the tail are the entire look and no native
-- draws any of them. DrawRect gives a sharp box; a texture dictionary gives a
-- worse result for far more work.
--
-- ONE registry, one thread. Everything that wants a bubble registers here --
-- the entry ped, the shop, the wardrobe, and the Red Zone from its own
-- resource -- so there is one place that decides what is nearest, one place
-- that reads keys, and no two systems fighting over the screen.

local Prompts = {}       -- id -> definition
local activePrompt = nil -- id currently on screen
local promptShown = false

--- Register a bubble.
---
--- def:
---   entity    function returning an entity handle, or nil
---   coords    vec3, when there is no entity
---   offset    metres above the origin           (default Config.Prompt.offset)
---   distance  how close before it appears       (default Config.Prompt.distance)
---   title     small line above the label, optional
---   condition function, whole prompt hidden when it returns false
---   actions   list of { key, keyLabel, label, action, condition }
---
--- Later registrations of the same id replace the earlier one, so a resource
--- restarting does not end up with two.
function ArenaPromptRegister(id, def)
    if not id or type(def) ~= 'table' then return false end
    Prompts[id] = def
    return true
end

function ArenaPromptRemove(id)
    if not id then return false end
    Prompts[id] = nil
    if activePrompt == id then activePrompt = nil end
    return true
end

--- Where a prompt lives right now, or nil if it has gone.
local function promptPoint(def)
    if def.entity then
        local ok, ent = pcall(def.entity)
        if not ok or not ent or ent == 0 or not DoesEntityExist(ent) then return nil end

        local c = GetEntityCoords(ent)
        return c.x, c.y, c.z + (def.offset or (Config.Prompt or {}).offset or 1.05)
    end

    if def.coords then
        return def.coords.x, def.coords.y,
               def.coords.z + (def.offset or (Config.Prompt or {}).offset or 1.05)
    end

    return nil
end

--- The actions currently worth showing.
---
--- An action whose condition is false is left out entirely rather than greyed
--- out: the entry ped offers three things and never more than two of them
--- make sense at once, and a bubble listing options that do nothing is worse
--- than a shorter bubble.
local function liveActions(def)
    local out = {}

    for _, a in ipairs(def.actions or {}) do
        local show = true
        if a.condition then
            local ok, res = pcall(a.condition)
            show = ok and res and true or false
        end

        if show then
            out[#out + 1] = {
                key      = a.key or 38,
                keyLabel = a.keyLabel or 'E',
                label    = a.label or '',
                action   = a.action,
                resource = a.resource,
                export   = a.export,
            }
        end
    end

    return out
end

--- Fire an action, whether it belongs to this resource or another one.
---
--- A function cannot cross a resource boundary, so anything registered from
--- outside gives an export NAME instead -- the same arrangement registerBoard
--- uses for the wall boards, for the same reason.
local function runAction(a)
    if a.action then
        pcall(a.action)
        return
    end

    if a.resource and a.export then
        if GetResourceState(a.resource) ~= 'started' then return end
        pcall(function() exports[a.resource][a.export](nil) end)
    end
end

local function hidePrompt()
    if not promptShown then return end
    promptShown = false
    activePrompt = nil
    SendNUIMessage({ action = 'promptHide' })
end

CreateThread(function()
    local nearest, nearActions = nil, nil
    local lastScan = 0
    local lastX, lastY = -999, -999

    while true do
        local cfg = Config.Prompt
        local sleep = 500

        -- Measurable, so /rzperf can name this thread rather than leaving it
        -- as one of forty suspects.
        local _p = PerfLoop and PerfLoop('prompt')

        -- Nothing on screen while a menu is open.
        --
        -- NUI focus covers all of them at once -- the arena panel, the shop,
        -- the clothing menu, anything added later -- rather than a list of
        -- flags that has to be extended every time something new opens. A
        -- bubble telling you to press E while you are already looking at what
        -- E opened is just untidy.
        if IsNuiFocused() then
            hidePrompt()
            Wait(250)
            goto continue
        end

        if cfg and cfg.enabled then
            local now = GetGameTimer()

            -- The cheap half: which prompt, if any, is close enough. Runs a
            -- few times a second, not every frame -- nothing here moves fast
            -- enough to need more.
            if now - lastScan > (cfg.scanInterval or 400) then
                lastScan = now
                nearest, nearActions = nil, nil

                local me = GetEntityCoords(PlayerPedId())
                local best = math.huge

                for id, def in pairs(Prompts) do
                    local show = true
                    if def.condition then
                        local ok, res = pcall(def.condition)
                        show = ok and res and true or false
                    end

                    if show then
                        local x, y, z = promptPoint(def)
                        if x then
                            local d = #(me - vec3(x, y, z))
                            local within = def.distance or cfg.distance or 2.5

                            if d <= within and d < best then
                                local acts = liveActions(def)
                                if #acts > 0 then
                                    best = d
                                    nearest = id
                                    nearActions = acts
                                end
                            end
                        end
                    end
                end
            end

            if nearest and Prompts[nearest] then
                -- The expensive half, and only ever for ONE prompt: follow
                -- the camera every frame so the bubble sits on the ped
                -- instead of swimming behind it.
                sleep = 0

                local def = Prompts[nearest]
                local x, y, z = promptPoint(def)

                if x then
                    local ok, sx, sy = World3dToScreen2d(x, y, z)

                    if ok then
                        -- Only send when it has actually moved. Standing
                        -- still is the common case and costs nothing, rather
                        -- than sixty identical messages a second.
                        local moved = math.abs(sx - lastX) > 0.0007
                                   or math.abs(sy - lastY) > 0.0007

                        if not promptShown or activePrompt ~= nearest then
                            activePrompt = nearest
                            promptShown = true

                            local rows = {}
                            for i, a in ipairs(nearActions) do
                                rows[i] = { key = a.keyLabel, label = a.label }
                            end

                            SendNUIMessage({ action = 'promptShow', data = {
                                title = def.title,
                                rows  = rows,
                                x = sx, y = sy,
                            }})
                            lastX, lastY = sx, sy

                        elseif moved then
                            SendNUIMessage({ action = 'promptMove',
                                data = { x = sx, y = sy } })
                            lastX, lastY = sx, sy
                        end

                        -- Disabled, then read in their disabled state.
                        --
                        -- G is INPUT_DETONATE, which the game only reports
                        -- when it thinks detonating is possible -- so reading
                        -- it enabled did nothing at all in the lobby, and the
                        -- exit option looked broken. Reading it disabled works
                        -- regardless, and stops the game acting on the key
                        -- itself while a bubble is up: no detonating, and no
                        -- climbing into a car when you meant to open a menu.
                        for _, a in ipairs(nearActions) do
                            DisableControlAction(0, a.key, true)
                        end

                        for _, a in ipairs(nearActions) do
                            if IsDisabledControlJustReleased(0, a.key) then
                                runAction(a)
                                Wait(400)   -- so one press is not two
                                lastScan = 0
                                break
                            end
                        end
                    else
                        -- Behind the camera. Hidden rather than clamped to
                        -- the edge, where it would look like a prompt for
                        -- something else.
                        if promptShown then
                            promptShown = false
                            SendNUIMessage({ action = 'promptHide' })
                        end
                    end
                else
                    hidePrompt()
                end
            else
                hidePrompt()
            end
        else
            hidePrompt()
        end

        ::continue::
        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

--- Let other resources put a bubble on something.
---
--- Actions carry an export NAME, never a function -- functions do not survive
--- crossing a resource boundary. Registrations are dropped automatically when
--- the resource that made them stops, so a stopped mode leaves no prompt
--- pointing at nothing.
exports('registerPrompt', function(id, def)
    if not id or type(def) ~= 'table' then return false end

    local owner = GetInvokingResource()
    def.owner = owner

    -- coords only: an entity handle from another resource is meaningless here.
    def.entity = nil

    for _, a in ipairs(def.actions or {}) do
        a.action = nil
        a.resource = a.resource or owner
    end

    return ArenaPromptRegister(id, def)
end)

exports('unregisterPrompt', function(id)
    return ArenaPromptRemove(id)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end

    for id, def in pairs(Prompts) do
        if def.owner == res then ArenaPromptRemove(id) end
    end
end)

-- ============================================================
--  THE PODIUM
-- ============================================================
-- Top three ranked, standing in the lobby with their rank above them.
--
-- The platform itself is NOT placed here. /rzprop and /rzprops already exist
-- for putting models in the world and are a better tool for it than a model
-- name hardcoded in a config -- a wrong one is an invisible prop and a player
-- standing on nothing. Build it, then point Config.Podium.spots at the top.

local podiumPeds = {}
local podiumRows = {}

local function clearPodium()
    for i, ped in pairs(podiumPeds) do
        if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
        podiumPeds[i] = nil
    end
end

--- Dress a podium ped as the real player.
---
--- Client side and PED-targeted on purpose. The server-side SetAppearance
--- saves as well as applies, so pointing that at a podium would overwrite a
--- real player's stored look -- somebody would log in wearing whoever was
--- second on the ladder. These only dress a ped and persist nothing.
---
--- Returns the model to spawn, or nil if there is no usable look.
local function podiumLook(row)
    local cfg = Config.Podium
    if not (cfg and cfg.realFaces) then return nil end
    if not (row and row.appearance) then return nil end

    local ok, look = pcall(json.decode, row.appearance)
    if not ok or type(look) ~= 'table' then return nil end

    return look
end

local function dressPodiumPed(ped, look)
    for _, c in ipairs((Config.Podium or {}).appearanceSet or {}) do
        if GetResourceState(c.resource) == 'started' then
            local ok = pcall(function()
                exports[c.resource][c.export](nil, ped, look)
            end)
            if ok then return true end
        end
    end

    return false
end

local function buildPodium()
    local cfg = Config.Podium
    if not (cfg and cfg.enabled) then return end

    for i = 1, 3 do
        local spot = cfg.spots and cfg.spots[i]

        if spot and not (podiumPeds[i] and DoesEntityExist(podiumPeds[i])) then
            -- Their own model when we have a look for them, the stand-in
            -- otherwise. The model has to come from the appearance or the
            -- clothing will be applied to the wrong body -- freemode
            -- components mean nothing on a story ped.
            local look = podiumLook(podiumRows[i])
            local model = (look and look.model)
                or (cfg.models or {})[i]
                or 'a_m_y_business_01'

            local ped = spawnPed(model, spot, cfg.scenario)

            if ped then
                -- Nothing here should be shootable, lootable or in the way.
                SetEntityInvincible(ped, true)
                SetBlockingOfNonTemporaryEvents(ped, true)
                FreezeEntityPosition(ped, true)

                if look then dressPodiumPed(ped, look) end

                podiumPeds[i] = ped
            end
        end
    end
end

RegisterNetEvent('naija-arena:client:podium', function(rows)
    local before = podiumRows
    podiumRows = rows or {}

    -- Rebuild when WHO is on the podium changes.
    --
    -- The peds are built the moment you walk into the lobby; the standings
    -- arrive a round trip later. So the first build always uses stand-in
    -- models, and without this they would stay stand-ins until the next time
    -- somebody entered the lobby. The ped's MODEL comes from the appearance,
    -- so it cannot be re-dressed in place -- freemode clothing means nothing
    -- on a story ped and the whole ped has to be replaced.
    --
    -- Only on a change of person or of stored look, not on every refresh:
    -- deleting and respawning three peds every two minutes for identical
    -- standings would be visible as a flicker.
    local function sig(list)
        local out = {}
        for i = 1, 3 do
            local r = list and list[i]
            out[i] = r and ((r.name or '') .. '|' .. #(r.appearance or '')) or ''
        end
        return table.concat(out, ';')
    end

    if next(podiumPeds) and sig(before) ~= sig(podiumRows) then
        clearPodium()
        buildPodium()
    end
end)

-- Ask for the standings, and keep the peds in step with whether we are in the
-- lobby at all.
CreateThread(function()
    Wait(4000)
    local was = nil

    -- TWO clocks, not one.
    --
    -- This used to reuse the loop's own wait for the standings refresh, so
    -- while you were in the lobby the whole loop slept for two minutes --
    -- including the check for whether you were still in the lobby. Walk out
    -- during that and three peds walked out with you and stood in Legion
    -- Square until the timer came round.
    --
    -- Worth being clear about why deleting them is the only control there is:
    -- these are created client-side, which makes them local to one player's
    -- game. Routing buckets do not apply to them at all. They are wherever
    -- that client is until something removes them.
    local lastRefresh = 0

    while true do
        local cfg = Config.Podium

        if cfg and cfg.enabled then
            local inLobby = (not cfg.lobbyOnly) or LocalPlayer.state.arenaLobby == true

            if inLobby ~= was then
                was = inLobby
                if inLobby then
                    buildPodium()
                    lastRefresh = 0        -- ask straight away
                else
                    clearPodium()
                end
            end

            if inLobby then
                local now = GetGameTimer()
                if now - lastRefresh > (cfg.refresh or 120000) then
                    lastRefresh = now
                    TriggerServerEvent('naija-arena:server:wantPodium')
                end
            end
        elseif was then
            was = nil
            clearPodium()
        end

        -- Always a second. Whether the peds should exist is a question that
        -- has to be asked at the speed a player can walk away, not at the
        -- speed a leaderboard changes.
        Wait(1000)
    end
end)

-- The labels above them. Same NUI as the prompts, so they share the styling
-- and there is one place that turns a world position into a screen one.
CreateThread(function()
    local shown = false
    local lastSig, lastCount = nil, 0
    local lastPos = {}

    while true do
        local cfg = Config.Podium
        local sleep = 1000

        local _p = PerfLoop and PerfLoop('podium')

        if cfg and cfg.enabled and next(podiumPeds) then
            local me = GetEntityCoords(PlayerPedId())
            local items = {}

            for i = 1, 3 do
                local ped = podiumPeds[i]
                local spot = cfg.spots and cfg.spots[i]

                if ped and DoesEntityExist(ped) and spot then
                    local d = #(me - vec3(spot.x, spot.y, spot.z))

                    if d <= (cfg.drawDistance or 30.0) then
                        local c = GetEntityCoords(ped)
                        local ok, sx, sy = World3dToScreen2d(c.x, c.y, c.z + 1.15)

                        if ok then
                            local row = podiumRows[i]
                            items[#items + 1] = {
                                rank  = i,
                                name  = row and row.name or (cfg.emptyLabel or 'UNCLAIMED'),
                                score = row and row.elo or nil,
                                x = sx, y = sy,
                            }
                        end
                    end
                end
            end

            if #items > 0 then
                -- Still per frame, because the labels follow the camera. But
                -- only SENT when something actually changed.
                --
                -- This used to fire a SendNUIMessage every frame for as long
                -- as anyone stood within thirty metres -- which is the whole
                -- lobby, permanently. Sixty JSON encodes and sixty IPC
                -- crossings a second, to redraw three labels in exactly the
                -- place they were already in. That alone took this resource
                -- from about 1ms back up to nearly 5.
                --
                -- Projecting the points is cheap; talking to the browser is
                -- not. So the projection stays per frame and the message
                -- waits for a reason.
                sleep = 0

                local moved = not shown or #items ~= lastCount

                if not moved then
                    for i = 1, #items do
                        local lp = lastPos[i]
                        if not lp
                           or math.abs(items[i].x - lp[1]) > 0.0007
                           or math.abs(items[i].y - lp[2]) > 0.0007 then
                            moved = true
                            break
                        end
                    end
                end

                -- Names and ratings change on a two-minute refresh, so they
                -- are compared rather than assumed constant.
                local sig = ''
                for i = 1, #items do
                    sig = sig .. items[i].name .. '|' .. tostring(items[i].score) .. ';'
                end

                if moved or sig ~= lastSig then
                    SendNUIMessage({ action = 'podium', data = { items = items } })

                    lastSig, lastCount = sig, #items
                    for i = 1, #items do
                        lastPos[i] = { items[i].x, items[i].y }
                    end
                    shown = true
                end
            elseif shown then
                shown = false
                lastSig, lastCount = nil, 0
                SendNUIMessage({ action = 'podium', data = { items = {} } })
            end
        elseif shown then
            shown = false
            lastSig, lastCount = nil, 0
            SendNUIMessage({ action = 'podium', data = { items = {} } })
        end

        if PerfEnd then PerfEnd(_p) end
        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearPodium()
end)

-- ============================================================
--  THE WARDROBE PED
-- ============================================================
-- Change into a saved outfit. Not a clothing shop -- this fires the
-- appearance script's OUTFIT menu, which only lists looks the player has
-- already saved, so there is nothing to buy and nothing to spend.
--
-- Lobby only, like the shop: it is part of getting ready for a match, not a
-- service the city needs a second copy of.

local wardrobePed = nil

local function removeWardrobePed()
    if wardrobePed and DoesEntityExist(wardrobePed) then
        DeleteEntity(wardrobePed)
    end
    wardrobePed = nil
    if ArenaPromptRemove then ArenaPromptRemove('arena_wardrobe') end
end

local function openWardrobe()
    local cfg = Config.Wardrobe or {}

    -- An export if one is configured, otherwise the event. Appearance scripts
    -- disagree about which they offer, and the difference is one line here
    -- rather than a fork of this whole function.
    if cfg.export and cfg.export.resource and cfg.export.method then
        if GetResourceState(cfg.export.resource) ~= 'started' then
            return ArenaNotify({
                title = 'Wardrobe',
                description = 'The clothing resource is not running.',
                type = 'error'
            })
        end

        pcall(function() exports[cfg.export.resource][cfg.export.method](nil) end)
        return
    end

    TriggerEvent(cfg.event or 'illenium-appearance:client:openOutfitMenu')
end

local function createWardrobePed()
    local cfg = Config.Wardrobe
    if not (cfg and cfg.enabled and cfg.ped) then return end
    if wardrobePed and DoesEntityExist(wardrobePed) then return end

    wardrobePed = spawnPed(cfg.ped.model, cfg.ped.coords, cfg.ped.scenario)
    if not wardrobePed then
        print('^1[arena] could not spawn the wardrobe ped^0')
        return
    end

    if ArenaPromptRegister
       and (Config.Prompt or {}).enabled and not (Config.Prompt or {}).useTarget then
        ArenaPromptRegister('arena_wardrobe', {
            entity = function() return wardrobePed end,
            distance = cfg.ped.distance or 2.5,
            title = cfg.title or 'WARDROBE',
            actions = {
                {
                    key = cfg.key or 38,
                    keyLabel = cfg.keyLabel or 'E',
                    label = cfg.label or 'Change outfit',
                    action = openWardrobe
                }
            }
        })
        return
    end

    pcall(function()
        exports.ox_target:addLocalEntity(wardrobePed, {
            {
                name = 'tenx_arena_wardrobe',
                label = cfg.label or 'Change outfit',
                icon = 'fas fa-shirt',
                distance = cfg.ped.distance or 2.5,
                onSelect = openWardrobe
            }
        })
    end)
end

-- In the lobby only, and torn down on the way out. Same shape as the shop
-- ped, deliberately -- two peds with the same lifetime should not have two
-- different ways of managing it.
CreateThread(function()
    Wait(3200)
    local was = nil

    while true do
        Wait(1000)
        local now = LocalPlayer.state.arenaLobby == true

        if now ~= was then
            was = now
            if now then createWardrobePed() else removeWardrobePed() end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeWardrobePed()
end)

-- ============================================================
--  THE AMBULANCE SCRIPT, FOR OTHER RESOURCES
-- ============================================================
-- Working out whether a player is down, and getting them back up, is not
-- something a second resource should be solving again.
--
-- ak47_qb_ambulancejob leaves a KNOCKED player with a live ped on full
-- health. IsEntityDead answers "not down" for them, which is why the arena
-- stopped asking the ped and started listening to their events instead --
-- ArenaBodyState above. Any mode that reimplements the naive check gets the
-- naive result: a death nobody notices, their script running its own bleedout
-- underneath, and two systems moving the same player to different places.
--
-- Reviving is worse, because which event actually works differs between
-- builds of their script. The arena searches the candidates once and
-- remembers which one worked. That search is not worth having twice.

--- Is this player down, by any measure that matters?
--- @return boolean down, string|nil why
exports('isDown', function()
    local down, why = isDown()
    return down, why
end)

--- Their script's own word: 'up', 'knocked' or 'dead'.
--- Finer than isDown, for anything that treats the two differently.
exports('bodyState', function()
    return ArenaBodyState
end)

--- Everything about whether this player is up, in one call.
---
--- The Red Zone was asking isDown and getting a single boolean, which is not
--- enough to act on: knocked and dead need the same respawn but a different
--- revive, and "the arena could not tell" needs to be distinguishable from
--- "they are fine". A boolean flattens all three.
---
--- @return table
---   down    boolean  knocked OR dead -- respawn on either
---   state   string   'up' | 'knocked' | 'dead', their script's own word
---   why     string   which check answered, for the console
---   health  number
---   sure    boolean  false when nothing could be read at all
exports('deathState', function()
    local ped = PlayerPedId()
    local down, why = isDown()

    return {
        down   = down and true or false,
        state  = ArenaBodyState,
        why    = why,
        health = GetEntityHealth(ped),

        -- Their events are the only thing that knows about being KNOCKED --
        -- a knocked player has a live ped on full health, so every native
        -- check answers "fine". If we have never heard from their script,
        -- say so rather than reporting a confident "up".
        sure   = ArenaBodyState ~= nil,
    }
end)

--- Put them back up, heal them, and clear the arena's own body state.
---
--- Runs the same candidate search the arena's own respawn uses, so a mode
--- calling this gets whatever was found to work on this server rather than a
--- guess. Safe to call when already up -- it costs a moment and changes
--- nothing.
exports('revivePlayer', function(heal)
    ArenaReviveBehindFade()

    local ped = PlayerPedId()

    -- Let the cuffs off.
    --
    -- Their script restrains a downed player and clears it on ITS own revive.
    -- When we revive instead, nothing clears it -- so the restraint follows
    -- the player out of the arena and into the city: weapon force-unequipped,
    -- unable to re-equip, and ox_inventory refusing to open with "cannot open
    -- inventory (cuffed)". That is the whole gun bug, and it is why it
    -- survived every fix aimed at weapons.
    SetEnableHandcuffs(ped, false)
    ClearPedSecondaryTask(ped)
    SetPedCanPlayGestureAnims(ped, true)

    if heal ~= false then
        SetEntityHealth(ped, GetEntityMaxHealth(ped))
        ClearPedBloodDamage(ped)
        ClearPedTasksImmediately(ped)
    end

    -- The flag that gates every heal.
    --
    -- useUtility refuses to apply anything while this is not 'up', so a mode
    -- that revives a player without clearing it leaves them permanently
    -- unable to use a medkit -- the item is spent, nothing happens, and it
    -- stays that way for the rest of the session.
    ArenaBodyState = 'up'

    return true
end)
