--[[
    Shared geometry.

    This file is loaded on BOTH sides on purpose. The server's
    authoritative in/out check and the client's clamp run the exact
    same maths, so a player can never be "inside" to one and
    "outside" to the other.

    Everything here is pure Lua. No natives, no allocations in the
    hot paths, no table churn per frame.
]]

TenxShapes = {}

local sqrt, min, max, abs = math.sqrt, math.min, math.max, math.abs

-- ============================================================
--  SPHERE
-- ============================================================

--- Squared 3D distance. Used everywhere we only need to compare,
--- because sqrt is the expensive part and comparisons don't need it.
function TenxShapes.dist2(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

function TenxShapes.inSphere(px, py, pz, cx, cy, cz, radius)
    return TenxShapes.dist2(px, py, pz, cx, cy, cz) <= radius * radius
end

--- Signed distance to the shell. Positive = inside, negative = outside.
function TenxShapes.sphereDepth(px, py, pz, cx, cy, cz, radius)
    return radius - sqrt(TenxShapes.dist2(px, py, pz, cx, cy, cz))
end


-- ============================================================
--  POLYGON (walled zone)
-- ============================================================

--- Standard ray cast point in polygon on the XY plane, plus a
--- height band. points is an array of { x =, y = }.
function TenxShapes.inPoly(px, py, pz, points, minZ, maxZ)
    if minZ and pz < minZ then return false end
    if maxZ and pz > maxZ then return false end

    local inside = false
    local n = #points
    local j = n

    for i = 1, n do
        local pi, pj = points[i], points[j]
        if (pi.y > py) ~= (pj.y > py) then
            local t = (py - pi.y) / (pj.y - pi.y)
            if px < pi.x + t * (pj.x - pi.x) then
                inside = not inside
            end
        end
        j = i
    end

    return inside
end

--- Closest point on the segment ab to p, on the XY plane.
--- Returns x, y and the squared distance to it.
function TenxShapes.closestOnSegment(px, py, ax, ay, bx, by)
    local abx, aby = bx - ax, by - ay
    local len2 = abx * abx + aby * aby

    if len2 == 0 then
        local dx, dy = px - ax, py - ay
        return ax, ay, dx * dx + dy * dy
    end

    local t = ((px - ax) * abx + (py - ay) * aby) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local cx, cy = ax + t * abx, ay + t * aby
    local dx, dy = px - cx, py - cy
    return cx, cy, dx * dx + dy * dy
end

--- Closest point on the polygon OUTLINE, and the distance to it.
function TenxShapes.closestOnPoly(px, py, points)
    local n = #points
    local bestX, bestY, bestD2 = points[1].x, points[1].y, math.huge
    local j = n

    for i = 1, n do
        local pi, pj = points[i], points[j]
        local cx, cy, d2 = TenxShapes.closestOnSegment(px, py, pj.x, pj.y, pi.x, pi.y)
        if d2 < bestD2 then
            bestX, bestY, bestD2 = cx, cy, d2
        end
        j = i
    end

    return bestX, bestY, sqrt(bestD2)
end

--- Signed distance to the polygon shell, taking the height band
--- into account. Positive = inside, negative = outside.
function TenxShapes.polyDepth(px, py, pz, points, minZ, maxZ)
    local _, _, flat = TenxShapes.closestOnPoly(px, py, points)
    local insideXY = TenxShapes.inPoly(px, py, pz, points, nil, nil)

    -- Vertical room left, if the zone is capped.
    local vertical = math.huge
    if minZ then vertical = min(vertical, pz - minZ) end
    if maxZ then vertical = min(vertical, maxZ - pz) end

    if insideXY then
        return min(flat, vertical)
    end

    return -flat
end


-- ============================================================
--  ZONE DISPATCH
--  A zone is { kind = 'sphere' | 'poly', ... }
-- ============================================================

function TenxShapes.contains(zone, px, py, pz, tolerance)
    if tolerance and tolerance ~= 0 then
        -- Positive tolerance grows the shape, which is what the
        -- server sweep wants so it never fights the client clamp.
        return TenxShapes.depth(zone, px, py, pz) > -tolerance
    end

    if zone.kind == 'sphere' then
        local c = zone.center
        return TenxShapes.inSphere(px, py, pz, c.x, c.y, c.z, zone.radius)
    end

    return TenxShapes.inPoly(px, py, pz, zone.points, zone.minZ, zone.maxZ)
end

--- Positive inside, negative outside. Drives both the tick gating
--- and the render fade, so it is called a lot. Kept allocation free.
function TenxShapes.depth(zone, px, py, pz)
    if zone.kind == 'sphere' then
        local c = zone.center
        return TenxShapes.sphereDepth(px, py, pz, c.x, c.y, c.z, zone.radius)
    end

    return TenxShapes.polyDepth(px, py, pz, zone.points, zone.minZ, zone.maxZ)
end

--- Cheap rejection test used before anything expensive. Uses the
--- zone's cached bounding radius so we can skip far zones with one
--- squared compare.
function TenxShapes.nearBounds(zone, px, py, pz, slack)
    local c = zone.boundsCenter or zone.center
    local r = (zone.boundsRadius or zone.radius or 0) + (slack or 0)
    return TenxShapes.dist2(px, py, pz, c.x, c.y, c.z) <= r * r
end


-- ============================================================
--  AREA / BOUNDS / INTERIOR POINT
--  All three are computed once when a zone loads and cached on
--  it. Nothing here runs in a hot path.
-- ============================================================

function TenxShapes.area(zone)
    if zone.kind == 'sphere' then
        return math.pi * zone.radius * zone.radius
    end

    -- Shoelace.
    local pts, n = zone.points, #zone.points
    local sum, j = 0.0, n
    for i = 1, n do
        sum = sum + (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y)
        j = i
    end
    return abs(sum) * 0.5
end

--- Axis aligned bounding box on XY. Cheap rejection and map blips.
function TenxShapes.aabb(zone)
    if zone.kind == 'sphere' then
        local c, r = zone.center, zone.radius
        return c.x - r, c.y - r, c.x + r, c.y + r
    end

    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for i = 1, #zone.points do
        local p = zone.points[i]
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end
    return minX, minY, maxX, maxY
end

--- A point GUARANTEED to be inside the shape.
---
--- The centroid is not safe for this. On a concave polygon -- an
--- L shaped arena, a zone drawn around a building -- the average
--- of the corners can land outside the shape entirely, and a
--- teleport to it puts an admin in a wall.
---
--- So: use the centroid when it is actually inside, otherwise
--- grid sample the bounding box and take the interior point
--- furthest from any edge. Runs once at load.
function TenxShapes.interiorPoint(zone)
    if zone.kind == 'sphere' then
        local c = zone.center
        return c.x, c.y, c.z
    end

    local cz = ((zone.minZ or 0) + (zone.maxZ or 0)) * 0.5

    local sumX, sumY, n = 0, 0, #zone.points
    for i = 1, n do
        sumX = sumX + zone.points[i].x
        sumY = sumY + zone.points[i].y
    end
    local gx, gy = sumX / n, sumY / n

    if TenxShapes.inPoly(gx, gy, cz, zone.points, nil, nil) then
        return gx, gy, cz
    end

    local minX, minY, maxX, maxY = TenxShapes.aabb(zone)
    local steps = 24
    local stepX = (maxX - minX) / steps
    local stepY = (maxY - minY) / steps

    local bestX, bestY, bestD = gx, gy, -1

    for i = 0, steps do
        local x = minX + stepX * i
        for j = 0, steps do
            local y = minY + stepY * j
            if TenxShapes.inPoly(x, y, cz, zone.points, nil, nil) then
                local _, _, d = TenxShapes.closestOnPoly(x, y, zone.points)
                if d > bestD then bestX, bestY, bestD = x, y, d end
            end
        end
    end

    return bestX, bestY, cz
end

--- Push a point to `distance` metres OUTSIDE the nearest edge.
--- The mirror of clamp, for Red Zone entry spawns which sit
--- outside the wall on purpose.
function TenxShapes.pushOutside(zone, px, py, pz, distance)
    distance = distance or 3.0

    if zone.kind == 'sphere' then
        local c = zone.center
        local dx, dy = px - c.x, py - c.y
        local flat = sqrt(dx * dx + dy * dy)
        if flat < 0.01 then dx, dy, flat = 1.0, 0.0, 1.0 end
        local target = zone.radius + distance
        return c.x + dx / flat * target, c.y + dy / flat * target, pz
    end

    local cx, cy = TenxShapes.closestOnPoly(px, py, zone.points)

    -- Step away from the interior, using the interior point rather
    -- than the centroid so a concave shape pushes the right way.
    local ix, iy = TenxShapes.interiorPoint(zone)
    local dx, dy = cx - ix, cy - iy
    local d = sqrt(dx * dx + dy * dy)
    if d < 0.01 then return cx, cy, pz end

    return cx + dx / d * distance, cy + dy / d * distance, pz
end


-- ============================================================
--  CLAMPING
--  Where a blocked player gets put. Returns x, y, z.
-- ============================================================

--- Sphere clamp.
--- Tries a flat XY pull toward the centre first and keeps the
--- player's own Z. That keeps them standing on the ground instead
--- of being yanked into the air or under the terrain. Only if the
--- flat pull cannot get them inside do we do a true 3D clamp,
--- which is the case when they are above or below the dome.
function TenxShapes.clampSphere(px, py, pz, cx, cy, cz, radius, margin)
    local target = radius - (margin or 1.5)
    if target < 1.0 then target = radius * 0.9 end

    local dz    = pz - cz
    local flat2 = (px - cx) ^ 2 + (py - cy) ^ 2
    local room2 = target * target - dz * dz

    if room2 > 1.0 then
        -- There is horizontal room at this height, so keep Z.
        local room = sqrt(room2)
        local flat = sqrt(flat2)
        if flat <= room then
            return px, py, pz
        end
        local s = room / flat
        return cx + (px - cx) * s, cy + (py - cy) * s, pz
    end

    -- Above or below the dome. Full 3D pull toward the centre.
    local d = sqrt(flat2 + dz * dz)
    if d == 0 then return cx, cy, cz end
    local s = target / d
    return cx + (px - cx) * s, cy + (py - cy) * s, cz + dz * s
end

--- Polygon clamp. Pulls to the nearest edge then steps inward
--- along the edge normal. Z is only touched if the height band
--- is what was breached.
function TenxShapes.clampPoly(px, py, pz, points, minZ, maxZ, margin)
    margin = margin or 1.5

    local nx, ny, nz = px, py, pz

    if not TenxShapes.inPoly(px, py, pz, points, nil, nil) then
        local cx, cy = TenxShapes.closestOnPoly(px, py, points)
        -- Step from the edge toward the polygon centroid so the
        -- margin always moves us inward, never along the wall.
        local sumX, sumY, n = 0, 0, #points
        for i = 1, n do
            sumX = sumX + points[i].x
            sumY = sumY + points[i].y
        end
        local gx, gy = sumX / n, sumY / n
        local dx, dy = gx - cx, gy - cy
        local d = sqrt(dx * dx + dy * dy)
        if d > 0 then
            nx, ny = cx + dx / d * margin, cy + dy / d * margin
        else
            nx, ny = cx, cy
        end
    end

    if minZ and nz < minZ + margin then nz = minZ + margin end
    if maxZ and nz > maxZ - margin then nz = maxZ - margin end

    return nx, ny, nz
end

function TenxShapes.clamp(zone, px, py, pz, margin)
    if zone.kind == 'sphere' then
        local c = zone.center
        return TenxShapes.clampSphere(px, py, pz, c.x, c.y, c.z, zone.radius, margin)
    end

    return TenxShapes.clampPoly(px, py, pz, zone.points, zone.minZ, zone.maxZ, margin)
end


-- ============================================================
--  BOUNDS
--  Precomputed once when a zone is loaded or edited, so the hot
--  path never recalculates them.
-- ============================================================

function TenxShapes.computeBounds(zone)
    if zone.kind == 'sphere' then
        zone.boundsCenter = zone.center
        zone.boundsRadius = zone.radius
        zone.centroid     = zone.center
        return TenxShapes.cacheDerived(zone)
    end

    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge

    for i = 1, #zone.points do
        local p = zone.points[i]
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end

    local cx, cy = (minX + maxX) * 0.5, (minY + maxY) * 0.5
    local cz = ((zone.minZ or 0) + (zone.maxZ or 0)) * 0.5

    local r = 0
    for i = 1, #zone.points do
        local p = zone.points[i]
        local d = sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2)
        if d > r then r = d end
    end

    local half = abs((zone.maxZ or 0) - (zone.minZ or 0)) * 0.5

    zone.boundsCenter = { x = cx, y = cy, z = cz }
    zone.boundsRadius = sqrt(r * r + half * half)
    zone.centroid     = { x = cx, y = cy, z = cz }

    return TenxShapes.cacheDerived(zone)
end

--- Everything the getters return, worked out once. GetZoneCentre,
--- GetZoneArea and GetZoneBounds are all table reads after this.
function TenxShapes.cacheDerived(zone)
    local ix, iy, iz = TenxShapes.interiorPoint(zone)
    zone.interior = { x = ix, y = iy, z = iz }

    zone.areaM2 = TenxShapes.area(zone)

    local minX, minY, maxX, maxY = TenxShapes.aabb(zone)
    zone.aabb = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }

    return zone
end


-- ============================================================
--  VALIDATION
--  Runs on the SERVER against anything arriving from a client.
--  Returns ok, errorMessage.
-- ============================================================

local function isFiniteNumber(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

TenxShapes.isFiniteNumber = isFiniteNumber

function TenxShapes.validate(zone, cfg)
    if type(zone) ~= 'table' then return false, 'not a table' end

    if type(zone.name) ~= 'string' or #zone.name < 1 or #zone.name > 48 then
        return false, 'name must be 1-48 characters'
    end

    if zone.kind == 'sphere' then
        local c = zone.center
        if type(c) ~= 'table'
            or not isFiniteNumber(c.x)
            or not isFiniteNumber(c.y)
            or not isFiniteNumber(c.z) then
            return false, 'bad centre'
        end
        if not isFiniteNumber(zone.radius) then return false, 'bad radius' end
        if zone.radius < cfg.minRadius or zone.radius > cfg.maxRadius then
            return false, ('radius must be %.1f-%.1f'):format(cfg.minRadius, cfg.maxRadius)
        end

    elseif zone.kind == 'poly' then
        if type(zone.points) ~= 'table' then return false, 'bad points' end
        local n = #zone.points
        if n < cfg.minPoints or n > cfg.maxPoints then
            return false, ('needs %d-%d points'):format(cfg.minPoints, cfg.maxPoints)
        end
        for i = 1, n do
            local p = zone.points[i]
            if type(p) ~= 'table' or not isFiniteNumber(p.x) or not isFiniteNumber(p.y) then
                return false, 'bad point ' .. i
            end
        end
        if not isFiniteNumber(zone.minZ) or not isFiniteNumber(zone.maxZ) then
            return false, 'bad height'
        end
        if zone.maxZ <= zone.minZ then return false, 'ceiling must be above floor' end
        if zone.maxZ - zone.minZ > 2000 then return false, 'height band too tall' end

    else
        return false, 'unknown shape'
    end

    local c = zone.color
    if type(c) ~= 'table' then return false, 'bad colour' end
    for _, k in ipairs({ 'r', 'g', 'b' }) do
        if not isFiniteNumber(c[k]) or c[k] < 0 or c[k] > 255 then
            return false, 'bad colour'
        end
    end

    return true
end
