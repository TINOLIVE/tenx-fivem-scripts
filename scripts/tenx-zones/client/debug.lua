--[[
    tenx-zones :: debug

    /zonedebug prints the whole render pipeline for the player running
    it, stage by stage, so an invisible zone stops being a guess.

    The pipeline is:
      server binding -> sync sent -> State.list -> render list -> alpha
    and this shows the value at every step, so whichever stage is
    empty is the answer.
]]

local State = TenxZones

local function yn(v) return v and 'yes' or 'no' end

RegisterCommand('zonedebug', function()
    local ped = PlayerPedId()
    local c   = GetEntityCoords(ped)
    local out = {}

    local function add(s) out[#out + 1] = s end

    add('===== tenx-zones client debug =====')
    add(('position       : %.1f, %.1f, %.1f'):format(c.x, c.y, c.z))

    -- STAGE 1: did anything arrive from the server?
    add(('zones synced   : %d   <- if 0, nothing is bound to you'):format(#State.list))

    -- STAGE 2: is the render source being hijacked?
    -- An empty table is truthy in Lua, so `builderZones or list` picks
    -- an empty builderZones over a full list and draws nothing.
    local bz = State.builderZones
    add(('builderZones   : %s%s'):format(
        bz == nil and 'nil (correct)' or ('table with ' .. #bz .. ' entries'),
        (bz ~= nil and #bz == 0) and '   <-- BUG: empty table hides everything' or ''))

    add(('shell hidden   : %s   (suspend claim active)'):format(yn(State.hidden)))
    add(('builder open   : %s'):format(yn(State.building)))
    add(('any solid zone : %s'):format(yn(State.anySolid)))
    add(('render distance: %.0fm'):format(Config.Render.distance))
    add(('fade window    : scales per zone (%.0f%%-%.0f%% of its own size)')
        :format(Config.Render.fadeStartFrac * 100, Config.Render.fadeEndFrac * 100))

    -- STAGE 3: per zone, why is it in or out?
    if #State.list == 0 then
        add('')
        add('No zones on this client. Either nothing is bound to your')
        add('bucket, or the server never sent a sync. Check the server')
        add('console output printed alongside this.')
    else
        add('')
        for i = 1, #State.list do
            local z     = State.list[i]
            local depth = TenxShapes.depth(z, c.x, c.y, c.z)
            local near  = TenxShapes.nearBounds(z, c.x, c.y, c.z, Config.Render.distance)

            -- Ask render.lua for the real number rather than keeping a
            -- second copy of the formula here. A debug view that
            -- reimplements the thing it is diagnosing will eventually
            -- lie to you, which is worse than no debug view.
            local alpha = TenxZonesFade and TenxZonesFade(z, depth) or 1.0

            local finalA = math.floor(
                (z.kind == 'sphere' and Config.Render.sphereAlpha or Config.Render.wallAlpha) * alpha)

            add(('[%d] %s'):format(z.id, z.name or '?'))
            add(('     kind=%s  visible=%s  solid=%s')
                :format(z.kind, yn(z.visible ~= false), yn(z.solid)))
            if z.kind == 'sphere' then
                add(('     centre=%.1f,%.1f,%.1f  radius=%.1f')
                    :format(z.center.x, z.center.y, z.center.z, z.radius))
                add(('     distance to centre=%.1fm')
                    :format(#(vector3(z.center.x, z.center.y, z.center.z) - c)))
            else
                add(('     points=%d  minZ=%.1f maxZ=%.1f')
                    :format(#z.points, z.minZ or 0, z.maxZ or 0))
            end
            add(('     depth=%.1fm (%s)  inRange=%s  alpha=%d/255')
                :format(depth, depth > 0 and 'INSIDE' or 'outside', yn(near), finalA))

            if not near then
                add('     -> SKIPPED: further than render distance')
            elseif z.visible == false then
                add('     -> SKIPPED: zone marked not visible')
            elseif finalA < 2 then
                add('     -> SKIPPED: faded out, you are too deep inside it')
            else
                add('     -> should be drawing')
            end
        end
    end

    add(('render list    : %d zone(s) queued to draw'):format(#State.render))
    add('===================================')

    print(table.concat(out, '\n'))
    TriggerServerEvent('tenx-zones:debug')
end, false)
