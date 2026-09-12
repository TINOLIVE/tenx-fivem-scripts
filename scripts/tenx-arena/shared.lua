-- ============================================================
--  POLYGON MATHS
-- ============================================================
-- Shared, not duplicated. The client clamps you inside a zone every frame and
-- the server checks the same thing on a slow sweep -- if the two used even
-- slightly different maths, the server would keep shoving players back into a
-- zone their own client thought they were already inside.
--
-- Zones are polygons of three or more points with a floor and a ceiling.
-- Rectangles marked before this are converted to four-point polygons when
-- they load, so there is one shape and one code path.

Poly = {}

--- Turn an old { minX, minY, maxX, maxY } rectangle into a polygon.
--- @return table bounds in the new shape
function Poly.fromRect(b)
    return {
        points = {
            { x = b.minX, y = b.minY },
            { x = b.maxX, y = b.minY },
            { x = b.maxX, y = b.maxY },
            { x = b.minX, y = b.maxY }
        },
        minZ = b.minZ,
        maxZ = b.maxZ
    }
end

--- Accepts either shape and always returns the polygon one.
function Poly.normalise(b)
    if not b then return nil end
    if b.points then return b end
    if b.minX then return Poly.fromRect(b) end
    return nil
end

--- Ray casting. Counts how many edges a ray from the point crosses -- odd
--- means inside. Works for any shape, including concave ones, which a
--- min/max box test cannot do.
function Poly.contains(points, x, y)
    if not points or #points < 3 then return false end

    local inside = false
    local j = #points

    for i = 1, #points do
        local pi, pj = points[i], points[j]

        if ((pi.y > y) ~= (pj.y > y))
           and (x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x) then
            inside = not inside
        end

        j = i
    end

    return inside
end

--- Closest point on a line segment to a given point.
local function nearestOnSegment(ax, ay, bx, by, px, py)
    local dx, dy = bx - ax, by - ay
    local len = (dx * dx) + (dy * dy)

    if len == 0 then return ax, ay, ((px - ax) ^ 2) + ((py - ay) ^ 2) end

    local t = (((px - ax) * dx) + ((py - ay) * dy)) / len
    t = math.max(0, math.min(1, t))

    local nx, ny = ax + (t * dx), ay + (t * dy)
    return nx, ny, ((px - nx) ^ 2) + ((py - ny) ^ 2)
end

--- The nearest point on the boundary, and how far away it is. Used to push a
--- player back to the closest edge rather than to the middle, which would
--- feel like being yanked.
--- @return number x, number y, number distance
function Poly.nearestEdge(points, x, y)
    local bestX, bestY, bestD = x, y, math.huge
    local j = #points

    for i = 1, #points do
        local nx, ny, d = nearestOnSegment(
            points[j].x, points[j].y, points[i].x, points[i].y, x, y)

        if d < bestD then
            bestX, bestY, bestD = nx, ny, d
        end

        j = i
    end

    return bestX, bestY, math.sqrt(bestD)
end

--- Push a point to just inside the boundary. The inset stops players
--- oscillating on the line itself.
function Poly.clampInside(points, x, y, inset)
    if Poly.contains(points, x, y) then return x, y, false end

    local nx, ny = Poly.nearestEdge(points, x, y)
    inset = inset or 0.5

    -- Step from the edge toward the centre, so the correction is always
    -- inward regardless of which edge was crossed.
    local cx, cy = Poly.centre(points)
    local dx, dy = cx - nx, cy - ny
    local len = math.sqrt((dx * dx) + (dy * dy))

    if len > 0.001 then
        nx = nx + ((dx / len) * inset)
        ny = ny + ((dy / len) * inset)
    end

    return nx, ny, true
end

--- Average of the points. Good enough for "fly me to it" and for deciding
--- which way is inward.
function Poly.centre(points)
    if not points or #points == 0 then return 0.0, 0.0 end

    local sx, sy = 0.0, 0.0
    for _, p in ipairs(points) do
        sx = sx + p.x
        sy = sy + p.y
    end

    return sx / #points, sy / #points
end

--- Bounding box, for cheap distance rejection before doing the real test.
function Poly.bbox(points)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge

    for _, p in ipairs(points) do
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end

    return minX, minY, maxX, maxY
end

--- Rough area, so the panel can say how big a zone is.
function Poly.area(points)
    if not points or #points < 3 then return 0 end

    local a = 0.0
    local j = #points

    for i = 1, #points do
        a = a + ((points[j].x + points[i].x) * (points[j].y - points[i].y))
        j = i
    end

    return math.abs(a / 2.0)
end

--- A point just OUTSIDE the boundary, near the middle of a given edge.
---
--- Kept for anything that needs a rough point outside a zone.
--- @param points table the polygon
--- @param edge number|nil which edge; random if omitted
--- @param distance number how far outside, in metres
--- @return number x, number y
function Poly.outsideEdge(points, edge, distance)
    if not points or #points < 3 then return 0.0, 0.0 end

    edge = edge or math.random(#points)
    if edge > #points then edge = #points end

    local a = points[edge]
    local b = points[(edge % #points) + 1]

    local mx, my = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
    local cx, cy = Poly.centre(points)

    -- Straight out from the centre through the edge midpoint.
    local dx, dy = mx - cx, my - cy
    local len = math.sqrt((dx * dx) + (dy * dy))

    if len < 0.001 then return mx, my end

    return mx + ((dx / len) * (distance or 4.0)),
           my + ((dy / len) * (distance or 4.0))
end
