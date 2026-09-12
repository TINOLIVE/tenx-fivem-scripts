--[[
    tenx-zones :: render

    The expensive part of any zone script is not the maths, it is
    the translucent shell. A 300m dome drawn at full opacity while
    you stand in the middle of it is filling every pixel on screen
    every frame, and that is what costs frames.

    So the shell fades out as you move away from its edge. Deep
    inside a zone you draw nothing at all. Walk toward the wall and
    it comes back. Wall geometry is segmented once and cached on the
    zone, never rebuilt per frame, and segments behind you or far
    away are skipped before any draw call is made.

    When nothing is in range this thread parks at 500ms.
]]

local State = TenxZones

local floor, sqrt = math.floor, math.sqrt


-- ============================================================
--  FADE
--  Returns an alpha multiplier 0-1 from the player's signed
--  distance to the shell.
--
--  The window is derived from the ZONE's size, not a fixed metre
--  value. A flat "gone past 90m deep" made a 180m dome invisible
--  at its own centre, because its centre is exactly 90m deep.
-- ============================================================

--- How deep this particular zone can get, worked out once.
local function innerReach(zone)
    if zone.reach then return zone.reach end

    local r
    if zone.kind == 'sphere' then
        r = zone.radius
    else
        -- For walls, the deepest you can be is the distance from the
        -- interior point to the nearest edge -- not the bounding
        -- radius, which would overstate a long thin arena badly.
        local p = zone.interior
        if p then
            local _, _, d = TenxShapes.closestOnPoly(p.x, p.y, zone.points)
            r = d
        else
            r = zone.boundsRadius or 50.0
        end
    end

    zone.reach = r
    return r
end

function TenxZonesFade(zone, depth)
    -- Outside the zone, or right on the line: full strength.
    if depth <= 0 then return 1.0 end

    local reach = innerReach(zone)
    if reach <= 0 then return 1.0 end

    local start = reach * Config.Render.fadeStartFrac
    if depth <= start then return 1.0 end

    -- Ease from full strength at `start` down to the floor at the
    -- deepest point the zone has. Never reaches zero, so the zone you
    -- are standing in is always visible.
    local span = reach - start
    if span <= 0 then return 1.0 end

    local t = (depth - start) / span
    if t > 1.0 then t = 1.0 end

    local floorA = Config.Render.fadeFloor
    return 1.0 - (1.0 - floorA) * t
end

local fadeFor = TenxZonesFade


-- ============================================================
--  WALL GEOMETRY CACHE
--  Built once per zone, thrown away when the zone is resynced.
-- ============================================================

local function buildWall(zone)
    local seg    = Config.Render.wallSegment
    local points = zone.points
    local n      = #points
    local quads  = {}

    local j = n
    for i = 1, n do
        local a, b = points[j], points[i]
        local dx, dy = b.x - a.x, b.y - a.y
        local len = sqrt(dx * dx + dy * dy)
        local steps = len > seg and floor(len / seg) or 1
        if steps < 1 then steps = 1 end

        for s = 0, steps - 1 do
            local t0 = s / steps
            local t1 = (s + 1) / steps

            local x0, y0 = a.x + dx * t0, a.y + dy * t0
            local x1, y1 = a.x + dx * t1, a.y + dy * t1

            quads[#quads + 1] = {
                x0 = x0, y0 = y0,
                x1 = x1, y1 = y1,
                mx = (x0 + x1) * 0.5,
                my = (y0 + y1) * 0.5,
            }
        end

        j = i
    end

    zone._wall = quads
    return quads
end

local function drawWall(zone, px, py, alpha)
    local quads = zone._wall or buildWall(zone)
    local c     = zone.color
    local r, g, b = c.r, c.g, c.b
    local a     = floor(Config.Render.wallAlpha * alpha)
    if a < 2 then return end

    local zLo, zHi = zone.minZ, zone.maxZ
    local reach    = Config.Render.distance
    local reach2   = reach * reach

    for i = 1, #quads do
        local q = quads[i]
        local ddx, ddy = q.mx - px, q.my - py

        if ddx * ddx + ddy * ddy <= reach2 then
            local x0, y0, x1, y1 = q.x0, q.y0, q.x1, q.y1

            -- Two triangles make the quad. DrawPoly is single
            -- sided, so each is drawn again wound the other way,
            -- otherwise the wall vanishes from one side.
            DrawPoly(x0, y0, zLo, x1, y1, zLo, x0, y0, zHi, r, g, b, a)
            DrawPoly(x1, y1, zLo, x1, y1, zHi, x0, y0, zHi, r, g, b, a)
            DrawPoly(x0, y0, zHi, x1, y1, zLo, x0, y0, zLo, r, g, b, a)
            DrawPoly(x0, y0, zHi, x1, y1, zHi, x1, y1, zLo, r, g, b, a)

            if Config.Render.wallTopLine then
                DrawLine(x0, y0, zHi, x1, y1, zHi, r, g, b, 200)
            end
        end
    end
end

local function drawDome(zone, alpha)
    local c = zone.center
    local k = zone.color
    local a = floor(Config.Render.sphereAlpha * alpha)
    if a < 2 then return end

    -- DrawMarker takes 24 arguments. This was passing 23, which slid
    -- drawOnEnts into the textureName slot. It tolerated it, but it
    -- was wrong.
    --   ..., bobUpAndDown, faceCamera, p19, rotate, texDict, texName, drawOnEnts
    DrawMarker(
        28,
        c.x, c.y, c.z,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        zone.radius, zone.radius, zone.radius,
        k.r, k.g, k.b, a,
        false, false, 2, false, nil, nil, false
    )
end


-- ============================================================
--  DRAW THREAD
-- ============================================================

CreateThread(function()
    while true do
        local render = State.render
        local n = #render

        if n == 0 then
            Wait(500)
        else
            local c = GetEntityCoords(PlayerPedId())
            local px, py, pz = c.x, c.y, c.z

            for i = 1, n do
                local zone = render[i]
                if zone.visible ~= false then
                    local alpha = fadeFor(zone, TenxShapes.depth(zone, px, py, pz))

                    if alpha > 0.01 then
                        if zone.kind == 'sphere' then
                            drawDome(zone, alpha)
                        else
                            drawWall(zone, px, py, alpha)
                        end
                    end
                end
            end

            Wait(0)
        end
    end
end)
