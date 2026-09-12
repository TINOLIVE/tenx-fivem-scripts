--[[
    tenx-zones :: client core (v2)

    Two threads and both are gated.

    The boundary thread parks at 1000ms and touches nothing while you
    have no zones bound to you, which is the state almost every player
    is in almost all the time. With a zone it runs at 500ms until you
    approach the edge, and only then goes to every frame.

    The render list thread runs at 500ms and exists only to hand
    render.lua a short prepared list, so the draw loop never does any
    distance maths of its own.
]]

TenxZones = {
    list       = {},      -- zones that apply to me
    byId       = {},
    inside     = {},      -- [zoneId] = true
    render     = {},      -- zones close enough to draw
    depth      = math.huge,
    building   = false,   -- builder open: never clamp the builder
    lastWarn   = 0,
    lastReport = 0,
    claims     = {},      -- [reason] = true, local suspend claims
    hidden     = false,   -- shell suppressed by a claim
    lastPos    = nil,
    lastPosAt  = 0,
    anySolid   = false,   -- any zone in `list` that can actually block us
}

local State = TenxZones


-- ============================================================
--  SUSPEND CLAIMS
--
--  The clamp runs here, on the client, so a client raised claim
--  takes effect on the SAME FRAME -- there is no hop to lose a race
--  across. That is what makes wrapping a client side teleport safe:
--
--      SuspendLocal('arena:teleport')
--      ...your existing safeTeleport body, unchanged...
--      ResumeLocal('arena:teleport')
--
--  The claim is also reported to the server, and that part is not
--  optional. A collision load can take 12 seconds and the server
--  sweep runs every 4, so without the report the server would see a
--  player far outside a solid zone on three separate passes and
--  force correct them mid teleport.
--
--  Claims are named and nest: two overlapping teleports do not
--  release each other. Enforcement returns when the last one drops.
-- ============================================================

local function claimCount()
    local n = 0
    for _ in pairs(State.claims) do n = n + 1 end
    return n
end

local function suspended()
    return next(State.claims) ~= nil
end

local function addClaim(reason, quiet)
    if type(reason) ~= 'string' or reason == '' then return false end
    if State.claims[reason] then return true end

    State.claims[reason] = true
    State.hidden = true

    if not quiet then TriggerServerEvent('tenx-zones:claim', reason, false) end

    SendNUIMessage({ action = 'hideWarning' })
    return true
end

local function dropClaim(reason, quiet)
    if not State.claims[reason] then return false end

    State.claims[reason] = nil
    if not quiet then TriggerServerEvent('tenx-zones:claim', reason, true) end

    if not suspended() then
        State.hidden  = false
        State.lastPos = nil     -- do not read the teleport as displacement
    end
    return true
end

exports('SuspendLocal', function(reason) return addClaim(reason) end)
exports('ResumeLocal',  function(reason) return dropClaim(reason) end)
exports('IsSuspended',  function() return suspended() end)
exports('GetLocalClaims', function()
    local out = {}
    for r in pairs(State.claims) do out[#out + 1] = r end
    return out
end)

-- Server raised claims arrive here so both sides agree.
RegisterNetEvent('tenx-zones:suspend', function(reason, release)
    if release then dropClaim(reason, true) else addClaim(reason, true) end
end)

RegisterNetEvent('tenx-zones:clearSuspends', function()
    State.claims  = {}
    State.hidden  = false
    State.lastPos = nil
end)


-- ============================================================
--  SYNC
-- ============================================================

RegisterNetEvent('tenx-zones:sync', function(zones)
    local list, byId = {}, {}
    local anySolid = false

    for i = 1, #zones do
        local z = TenxShapes.computeBounds(zones[i])
        list[i]    = z
        byId[z.id] = z
        if z.solid then anySolid = true end
    end

    -- Anything we were inside that is gone now must fire a leave, or
    -- a listening resource never gets told.
    for id in pairs(State.inside) do
        if not byId[id] then
            State.inside[id] = nil
            TriggerEvent('tenx-zones:left', id, nil, 'unbound')
        end
    end

    State.list  = list
    State.byId  = byId
    State.depth = math.huge

    -- The fast tick exists so the CLAMP feels smooth. A passable zone
    -- has no clamp, so approaching its edge is no reason to run at
    -- frame rate. Red Zone binds several passable domes to one standing
    -- bucket, and without this a player stood near any of them would
    -- burn a frame-rate loop doing nothing but arithmetic.
    State.anySolid = anySolid

    if #list == 0 then
        State.render = {}
        SendNUIMessage({ action = 'hideWarning' })
    end
end)

--- Handshake rather than a fixed wait. The server holds off syncing
--- until it hears this, so a client side resource restart cannot
--- leave a player silently unbounded.
CreateThread(function()
    while true do
        TriggerServerEvent('tenx-zones:ready')
        Wait(2000)
        if #State.list > 0 then return end
        -- No zones may simply mean none apply. Ask twice, then stop.
        Wait(4000)
        TriggerServerEvent('tenx-zones:ready')
        return
    end
end)


-- ============================================================
--  WARNING BANNER
--  Sent to the NUI page without ever taking focus, so it cannot
--  steal the cursor or lock a player out of anything.
-- ============================================================

local function warn()
    if State.hidden then return end

    local now = GetGameTimer()
    if now - State.lastWarn < Config.Boundary.warnCooldown then return end
    State.lastWarn = now

    SendNUIMessage({
        action = 'warning',
        title  = Config.Boundary.warnText,
        text   = Config.Boundary.warnSubText,
        hold   = Config.Boundary.warnCooldown - 500,
    })
end


-- ============================================================
--  CLAMP
-- ============================================================

--- Vehicles.
---
--- The old fix zeroed velocity outright. That is wrong: on a desync
--- the clamp fires late, and a hard stop at speed either launches the
--- car or embeds it in geometry. Instead we split velocity against
--- the boundary normal, kill only the component heading OUT through
--- the wall, and keep the tangential one -- so a car hitting the wall
--- at an angle slides along it, and one hitting it square comes to a
--- stop over a few frames instead of one.
local function dampVehicle(veh, nx, ny, px, py)
    local damping = Config.Boundary.vehicleDamping
    if damping <= 0.0 then
        SetEntityVelocity(veh, 0.0, 0.0, 0.0)
        return
    end

    local v = GetEntityVelocity(veh)

    -- Outward normal at the contact point: from where we put them back
    -- toward where they were trying to get to.
    local ox, oy = px - nx, py - ny
    local len = math.sqrt(ox * ox + oy * oy)
    if len < 0.001 then
        SetEntityVelocity(veh, v.x * damping, v.y * damping, v.z)
        return
    end
    ox, oy = ox / len, oy / len

    local outward = v.x * ox + v.y * oy
    if outward <= 0.0 then return end     -- already heading back in, leave it

    -- Remove the outward part, scale what is left.
    local tx = (v.x - ox * outward) * damping
    local ty = (v.y - oy * outward) * damping

    SetEntityVelocity(veh, tx, ty, v.z)
end

local function applyClamp(entity, zone, px, py, pz, inVehicle)
    local nx, ny, nz = TenxShapes.clamp(zone, px, py, pz, Config.Boundary.margin)

    SetEntityCoordsNoOffset(entity, nx, ny, nz, false, false, false)

    if inVehicle then dampVehicle(entity, nx, ny, px, py) end

    warn()
end

--- Server correction. Trusted, applied without argument.
RegisterNetEvent('tenx-zones:forcePosition', function(x, y, z)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = veh ~= 0 and veh or ped

    SetEntityCoordsNoOffset(ent, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    if veh ~= 0 then SetEntityVelocity(ent, 0.0, 0.0, 0.0) end

    State.lastPos = nil
    warn()
end)


-- ============================================================
--  DISPLACEMENT
--
--  A position jump nobody claimed. An escrowed ambulance script
--  moving a downed player to hospital looks exactly like this, and
--  clamping a teleport is always wrong -- the player ends up bouncing
--  at the wall from the hospital.
--
--  Distance alone is not enough to detect it. The far tick is 500ms
--  and a car at 200km/h covers 27 metres in that, so a low threshold
--  reads an ordinary fast approach as a teleport. So a jump counts
--  only when it clears BOTH the flat distance AND what the player's
--  own speed could plausibly have produced in the elapsed time.
--
--  What happens next is the SERVER's decision, not ours -- we only
--  report it. See Config.Security.trustDisplacement.
-- ============================================================

local function isDisplacement(px, py, pz, speed)
    local last = State.lastPos
    local now  = GetGameTimer()

    if not last then
        State.lastPos, State.lastPosAt = { px, py, pz }, now
        return false, 0
    end

    local dt = (now - State.lastPosAt) / 1000.0
    State.lastPos, State.lastPosAt = { px, py, pz }, now

    if dt <= 0 then return false, 0 end

    local dx, dy, dz = px - last[1], py - last[2], pz - last[3]
    local moved = math.sqrt(dx * dx + dy * dy + dz * dz)

    if moved < Config.Boundary.teleportJumpMetres then return false, moved end

    -- Plausible travel for their own speed over the elapsed time.
    local plausible = math.max(speed, 1.0) * dt * Config.Boundary.teleportJumpFactor
    if moved <= plausible then return false, moved end

    return true, moved
end


-- ============================================================
--  BOUNDARY THREAD
-- ============================================================

CreateThread(function()
    local abs = math.abs

    while true do
        local sleep = Config.Tick.idle
        local list  = State.list
        local n     = #list

        if n > 0 and not State.building and not suspended() then
            local ped       = PlayerPedId()
            local veh       = GetVehiclePedIsIn(ped, false)
            local inVehicle = veh ~= 0
            local entity    = inVehicle and veh or ped
            local c         = GetEntityCoords(entity)
            local px, py, pz = c.x, c.y, c.z

            local speed  = GetEntitySpeed(entity)
            local jumped, moved = isDisplacement(px, py, pz, speed)

            local band    = inVehicle and Config.Tick.nearDistanceVeh
                                      or Config.Tick.nearDistance
            local closest = math.huge
            local blocked = false

            for i = 1, n do
                local zone  = list[i]
                local depth = TenxShapes.depth(zone, px, py, pz)
                local isIn  = depth > 0

                if isIn and not State.inside[zone.id] then
                    State.inside[zone.id] = true
                    TriggerServerEvent('tenx-zones:entered', zone.id)
                    TriggerEvent('tenx-zones:entered', zone.id, zone)

                elseif not isIn and State.inside[zone.id] then
                    State.inside[zone.id] = nil
                    local reason = jumped and 'displaced' or 'walked'
                    if jumped then
                        TriggerServerEvent('tenx-zones:displaced', zone.id, moved)
                    else
                        TriggerServerEvent('tenx-zones:left', zone.id)
                    end
                    TriggerEvent('tenx-zones:left', zone.id, zone, reason)
                end

                -- Never clamp a jump we could not account for. The
                -- server decides whether it was legitimate.
                if zone.solid and depth <= 0 and not jumped then
                    applyClamp(entity, zone, px, py, pz, inVehicle)

                    -- The near tick is every frame, so an unthrottled
                    -- report here is a net event per frame for as long
                    -- as someone leans on the wall.
                    local now = GetGameTimer()
                    if now - State.lastReport > 1000 then
                        State.lastReport = now
                        TriggerServerEvent('tenx-zones:clamped', zone.id)
                    end

                    State.inside[zone.id] = true
                    blocked = true
                    closest = 0
                    break
                end

                if abs(depth) < abs(closest) then closest = depth end
            end

            State.depth = closest

            if State.anySolid then
                sleep = (blocked or abs(closest) <= band)
                    and Config.Tick.near
                    or  Config.Tick.far
            else
                -- Nothing here can block us. Enter/leave at 500ms is
                -- all a marker zone needs, and rewards are decided by
                -- a server query at the moment of the kill, not by
                -- how often this loop runs.
                sleep = Config.Tick.far
            end
        else
            State.lastPos = nil   -- do not measure a jump we are not watching
        end

        Wait(sleep)
    end
end)


-- ============================================================
--  RENDER LIST THREAD
--  Decides what render.lua is allowed to draw. 500ms.
-- ============================================================

CreateThread(function()
    while true do
        Wait(500)

        local source = State.builderZones or State.list
        local n = #source

        if n == 0 or (State.hidden and not State.building) then
            if #State.render > 0 then State.render = {} end
        else
            local c = GetEntityCoords(PlayerPedId())
            local px, py, pz = c.x, c.y, c.z
            local reach = Config.Render.distance

            local out = {}
            for i = 1, n do
                local zone = source[i]
                if zone.visible ~= false
                   and TenxShapes.nearBounds(zone, px, py, pz, reach) then
                    out[#out + 1] = zone
                end
            end

            State.render = out
        end
    end
end)


-- ============================================================
--  CLIENT EXPORTS
-- ============================================================

exports('IsInZone', function(id) return State.inside[id] == true end)

exports('GetMyZones', function()
    local out = {}
    for i = 1, #State.list do out[i] = State.list[i].id end
    return out
end)

exports('GetZoneDepth', function(id)
    local z = State.byId[id]
    if not z then return nil end
    local c = GetEntityCoords(PlayerPedId())
    return TenxShapes.depth(z, c.x, c.y, c.z)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
