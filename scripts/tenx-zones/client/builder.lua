--[[
    tenx-zones :: builder

    Fly, size, save.

    Focus is owned by exactly one place in this file. Your arena had
    a bug where several overlays each set NUI focus independently and
    nobody released it, so the cursor locked up mid match. The same
    mistake is not repeated here: setFocus() is the only thing that
    touches SetNuiFocus, it tracks who asked, and a watchdog releases
    the cursor if focus is somehow still held while the builder is
    closed. /zonesunstick is the manual escape hatch.
]]

local State = TenxZones

local Builder = {
    open      = false,
    noclip    = false,
    speed     = Config.Build.defaultSpeed,
    mode      = nil,        -- 'sphere' | 'poly'
    draft     = nil,        -- live preview zone
    points    = {},
    editingId = nil,
}

TenxZonesBuilder = Builder


-- ============================================================
--  FOCUS: ONE OWNER
-- ============================================================

local focusHeldBy = nil

local function setFocus(owner, mouse)
    if owner then
        focusHeldBy = owner
        SetNuiFocus(true, mouse ~= false)
    else
        focusHeldBy = nil
        SetNuiFocus(false, false)
    end
end

-- Watchdog. If focus is held but the builder is shut, let go.
CreateThread(function()
    while true do
        Wait(1000)
        if focusHeldBy and not Builder.open then
            setFocus(nil)
        end
    end
end)

RegisterCommand('zonesunstick', function()
    setFocus(nil)
    Builder.open, Builder.mode, Builder.draft = false, nil, nil
    Builder.noclip = false
    State.building, State.builderZones = false, nil
    SendNUIMessage({ action = 'close' })
    SendNUIMessage({ action = 'keys', show = false })
end, false)


-- ============================================================
--  NOCLIP
-- ============================================================

--- Probe from several heights. A single probe at the player's own Z
--- fails whenever they are under the terrain or above unstreamed
--- ground, and a failed probe was the whole reason people were
--- falling through the map on exit.
local function groundAt(x, y, z)
    for _, h in ipairs({ z + 1.0, z + 25.0, z + 150.0, 500.0, 1000.0, 20.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x, y, h, false)
        if found and gz > -190.0 then return gz end
    end
    return nil
end

local function applyNoclipState(ped, on)
    SetEntityCollision(ped, not on, not on)
    SetEntityInvincible(ped, on)
    FreezeEntityPosition(ped, on)
    SetEntityVisible(ped, not on, false)
    SetLocalPlayerVisibleLocally(true)
end

--- Restores state with no yielding. Only for onResourceStop, where
--- yielding is not allowed.
local function forceRestore()
    applyNoclipState(PlayerPedId(), false)
end

local function setNoclip(on)
    local ped = PlayerPedId()

    if on then
        Builder.noclip = true
        applyNoclipState(ped, true)
        return
    end

    if Builder.settling then return end

    -- Exiting. The old version re-enabled collision and released the
    -- freeze FIRST and only then went looking for the ground, so for a
    -- frame or two you were solid, unfrozen and mid-air -- gravity won
    -- before the placement landed. And when the probe failed it did
    -- nothing at all, leaving you exactly there.
    --
    -- Now: stay frozen and non-colliding until there is confirmed
    -- ground underneath, and if there is not, go back into noclip
    -- rather than drop the player.
    Builder.noclip   = false
    Builder.settling = true

    CreateThread(function()
        local p = PlayerPedId()
        local c = GetEntityCoords(p)

        -- Fly far enough in noclip and the terrain below has not
        -- streamed in. Probing unloaded collision always fails.
        RequestCollisionAtCoord(c.x, c.y, c.z)
        local waited = 0
        while not HasCollisionLoadedAroundEntity(p) and waited < 6000 do
            RequestCollisionAtCoord(c.x, c.y, c.z)
            Wait(50)
            waited = waited + 50
        end

        local gz = groundAt(c.x, c.y, c.z)

        if gz then
            SetEntityCoordsNoOffset(p, c.x, c.y, gz + 1.0, false, false, false)
            Wait(50)                       -- let the placement settle
            applyNoclipState(p, false)
        else
            Builder.noclip = true
            applyNoclipState(p, true)
            SendNUIMessage({
                action = 'toast', ok = false,
                text   = 'No ground found here - staying in noclip. Move somewhere clearer.',
            })
        end

        Builder.settling = false
    end)
end

local function noclipStep()
    local ped   = PlayerPedId()
    local speed = Config.Build.noclipSpeeds[Builder.speed] or 2.0

    if IsControlPressed(0, 21) then speed = speed * 4.0 end  -- LSHIFT boost

    local rot  = GetGameplayCamRot(2)
    local rz   = math.rad(rot.z)
    local rx   = math.rad(rot.x)
    local cosx = math.cos(rx)

    local fx = -math.sin(rz) * cosx
    local fy =  math.cos(rz) * cosx
    local fz =  math.sin(rx)

    local sx = math.cos(rz)
    local sy = math.sin(rz)

    local dx, dy, dz = 0.0, 0.0, 0.0

    if IsControlPressed(0, 32) then dx, dy, dz = dx + fx, dy + fy, dz + fz end -- W
    if IsControlPressed(0, 33) then dx, dy, dz = dx - fx, dy - fy, dz - fz end -- S
    if IsControlPressed(0, 34) then dx, dy = dx - sx, dy - sy end              -- A
    if IsControlPressed(0, 35) then dx, dy = dx + sx, dy + sy end              -- D
    if IsControlPressed(0, 22) then dz = dz + 1.0 end                          -- SPACE
    if IsControlPressed(0, 36) then dz = dz - 1.0 end                          -- LCTRL

    if dx ~= 0.0 or dy ~= 0.0 or dz ~= 0.0 then
        local c = GetEntityCoords(ped)
        SetEntityCoordsNoOffset(
            ped,
            c.x + dx * speed,
            c.y + dy * speed,
            c.z + dz * speed,
            false, false, false
        )
    end

    SetEntityHeading(ped, rot.z)
end


-- ============================================================
--  DRAFTS
-- ============================================================

local function pushPreview()
    State.builderZones = Builder.draft and { Builder.draft } or nil
    State.render       = Builder.draft and { Builder.draft } or State.render
end

local function draftColor()
    local d = Builder.draft
    if not d then return Config.Defaults.solidColor end
    return d.solid and Config.Defaults.solidColor or Config.Defaults.passableColor
end

local function newSphere()
    local c = GetEntityCoords(PlayerPedId())

    Builder.mode  = 'sphere'
    Builder.draft = TenxShapes.computeBounds({
        id      = -1,
        name    = 'New zone',
        kind    = 'sphere',
        center  = { x = c.x, y = c.y, z = c.z },
        radius  = 40.0,
        solid   = Config.Defaults.solid,
        visible = true,
        color   = Config.Defaults.solidColor,
    })

    -- The dome rides along until you press E to drop it. Without
    -- this the centre stays wherever you happened to be standing
    -- when you picked the shape, and there is no way to move it.
    Builder.draft.followMe   = true
    Builder.draft.centerLift = 0.0

    pushPreview()
end

local function newPoly()
    Builder.mode   = 'poly'
    Builder.points = {}
    Builder.draft  = nil
    pushPreview()
end

--- Ground samples at every marked point decide the starting floor
--- and ceiling. Floor sits below the lowest sample so nobody clips
--- out under a slope; ceiling sits above the highest.
local function autoHeight(points)
    local lo, hi = math.huge, -math.huge

    for i = 1, #points do
        local p = points[i]
        local found, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 25.0, false)
        local z = found and gz or p.z
        if z < lo then lo = z end
        if z > hi then hi = z end
    end

    if lo == math.huge then lo, hi = 0.0, 50.0 end

    return lo - Config.Build.autoFloorBelow, hi + Config.Build.autoRoofAbove
end

local function rebuildPolyDraft()
    if #Builder.points < 3 then
        Builder.draft = nil
        pushPreview()
        return
    end

    local minZ, maxZ = autoHeight(Builder.points)

    local pts = {}
    for i = 1, #Builder.points do
        pts[i] = { x = Builder.points[i].x, y = Builder.points[i].y }
    end

    Builder.draft = TenxShapes.computeBounds({
        id      = -1,
        name    = Builder.draft and Builder.draft.name or 'New zone',
        kind    = 'poly',
        points  = pts,
        minZ    = Builder.draft and Builder.draft.minZ or minZ,
        maxZ    = Builder.draft and Builder.draft.maxZ or maxZ,
        solid   = Builder.draft and Builder.draft.solid or Config.Defaults.solid,
        visible = true,
        color   = draftColor(),
    })

    pushPreview()
end

local function addPoint()
    if #Builder.points >= Config.Build.maxPoints then return end

    local c = GetEntityCoords(PlayerPedId())
    local found, gz = GetGroundZFor_3dCoord(c.x, c.y, c.z, false)

    Builder.points[#Builder.points + 1] = {
        x = c.x, y = c.y, z = found and gz or c.z
    }

    rebuildPolyDraft()
    SendNUIMessage({ action = 'points', count = #Builder.points })
end

local function undoPoint()
    if #Builder.points == 0 then return end
    Builder.points[#Builder.points] = nil
    rebuildPolyDraft()
    SendNUIMessage({ action = 'points', count = #Builder.points })
end

local function scrollRadius(dir)
    local d = Builder.draft
    if not d or d.kind ~= 'sphere' then return end

    local step = IsControlPressed(0, 21)
        and Config.Build.radiusStepFast
        or  Config.Build.radiusStep

    local r = d.radius + step * dir
    if r < Config.Build.minRadius then r = Config.Build.minRadius end
    if r > Config.Build.maxRadius then r = Config.Build.maxRadius end

    d.radius = r
    TenxShapes.computeBounds(d)

    SendNUIMessage({ action = 'radius', value = r })
end

--- Hand the draft back to the panel and take focus so it can be
--- named and saved.
local function finishDraft()
    if not Builder.draft then return end

    if Builder.mode == 'poly' and #Builder.points < Config.Build.minPoints then
        SendNUIMessage({
            action = 'toast',
            ok = false,
            text = ('Mark at least %d points'):format(Config.Build.minPoints)
        })
        return
    end

    Builder.draft.followMe = nil

    SendNUIMessage({ action = 'keys', show = false })
    SendNUIMessage({ action = 'draft', zone = Builder.draft, editingId = Builder.editingId })
    setFocus('panel')
end


-- ============================================================
--  DRAFT CONTROL THREAD
-- ============================================================

CreateThread(function()
    while true do
        if Builder.open and Builder.mode and not focusHeldBy then
            if Builder.noclip then noclipStep() end

            -- On foot, Space and Ctrl move the dome's centre height as
            -- a NUMBER rather than moving you. That covers a rooftop
            -- dome or one over a multi-storey building without ever
            -- lifting the ped off the ground -- so there is nothing to
            -- land on afterwards and nothing to fall through.
            if not Builder.noclip and Builder.mode == 'sphere' and Builder.draft then
                local step = 0.0
                if IsControlPressed(0, 22) then step =  0.25 end   -- SPACE
                if IsControlPressed(0, 36) then step = -0.25 end   -- LCTRL
                if IsControlPressed(0, 21) then step = step * 4.0 end -- SHIFT boost

                if step ~= 0.0 then
                    local d = Builder.draft
                    d.followMe = false          -- lifting it anchors it
                    d.center.z = d.center.z + step
                    d.centerLift = (d.centerLift or 0.0) + step
                    TenxShapes.computeBounds(d)
                    SendNUIMessage({ action = 'lift', value = d.centerLift })
                end
            end

            -- Scroll sizes the dome.
            if IsControlJustPressed(0, 241) then scrollRadius(1)  end -- wheel up
            if IsControlJustPressed(0, 242) then scrollRadius(-1) end -- wheel down

            if IsControlJustPressed(0, 288) then                       -- F2
                if not Builder.settling then
                    setNoclip(not Builder.noclip)
                    SendNUIMessage({ action = 'noclip', on = Builder.noclip })
                end
            end

            if IsControlJustPressed(0, 157) then                       -- 1
                Builder.speed = Builder.speed % #Config.Build.noclipSpeeds + 1
                SendNUIMessage({ action = 'speed', value = Config.Build.noclipSpeeds[Builder.speed] })
            end

            if Builder.mode == 'poly' then
                if IsControlJustPressed(0, 38) then addPoint()  end    -- E
                -- Undo used to sit on 194, which the frontend also
                -- fires for cancel, so one press could drop a point
                -- and kill the draft. Moved to R.
                if IsControlJustPressed(0, 45) then undoPoint() end    -- R

            elseif Builder.mode == 'sphere' then
                if IsControlJustPressed(0, 38) then                    -- E
                    local d = Builder.draft
                    if d then
                        d.followMe = not d.followMe
                        SendNUIMessage({ action = 'anchored', on = not d.followMe })
                    end
                end
            end

            if IsControlJustPressed(0, 191) then finishDraft() end     -- ENTER

            if IsControlJustPressed(0, 202) then                       -- ESC / BACK
                -- This used to take NUI focus for the panel without
                -- ever telling the panel to show itself again. The rail
                -- was hidden when drawing started, so you ended up with
                -- focus held, nothing rendered, and the page's own
                -- Escape handler checking "is the rail visible?" --
                -- it wasn't, so nothing happened. Locked out until the
                -- resource was restarted.
                Builder.mode, Builder.draft, Builder.points = nil, nil, {}
                Builder.editingId  = nil
                State.builderZones = nil

                SendNUIMessage({ action = 'keys', show = false })
                SendNUIMessage({ action = 'cancelled' })   -- re-shows the rail
                setFocus('panel')
            end

            -- The draft follows you while it has no fixed centre.
            if Builder.mode == 'sphere' and Builder.draft and Builder.draft.followMe then
                local c = GetEntityCoords(PlayerPedId())
                local lift = Builder.draft.centerLift or 0.0
                Builder.draft.center = { x = c.x, y = c.y, z = c.z + lift }
                TenxShapes.computeBounds(Builder.draft)
            end

            Wait(0)
        else
            Wait(200)
        end
    end
end)

--- Marked points get a small pillar each so you can see the shape
--- forming. Only runs while marking a polygon.
CreateThread(function()
    while true do
        if Builder.open and Builder.mode == 'poly' and #Builder.points > 0 then
            local c = Builder.draft and Builder.draft.color or Config.Defaults.solidColor

            for i = 1, #Builder.points do
                local p = Builder.points[i]
                DrawMarker(0, p.x, p.y, p.z + 2.0, 0,0,0, 180.0,0,0, 0.7,0.7,0.7,
                    c.r, c.g, c.b, 180, false, false, 2, nil, nil, false)
                DrawLine(p.x, p.y, p.z, p.x, p.y, p.z + 2.0, c.r, c.g, c.b, 220)
            end

            Wait(0)
        else
            Wait(400)
        end
    end
end)


-- ============================================================
--  OPEN / CLOSE
-- ============================================================

RegisterNetEvent('tenx-zones:openBuilder', function(zones)
    Builder.open      = true
    Builder.mode      = nil
    Builder.draft     = nil
    Builder.points    = {}
    Builder.editingId = nil

    State.building = true   -- never clamp the person building

    SendNUIMessage({
        action = 'open',
        zones  = zones,
        limits = {
            minRadius = Config.Build.minRadius,
            maxRadius = Config.Build.maxRadius,
            minPoints = Config.Build.minPoints,
            maxPoints = Config.Build.maxPoints,
        },
    })

    setFocus('panel')
end)

function TenxZonesBuilder.close()
    if Builder.noclip then setNoclip(false) end

    Builder.open   = false
    Builder.mode   = nil
    Builder.draft  = nil
    Builder.points = {}

    State.building     = false
    State.builderZones = nil
    State.render       = {}

    setFocus(nil)
    SendNUIMessage({ action = 'close' })
    SendNUIMessage({ action = 'keys', show = false })
end

--- Called by nui.lua when the panel asks to start drawing.
function TenxZonesBuilder.beginDraw(mode, existing)
    Builder.editingId = existing and existing.id or nil

    if mode == 'sphere' then
        newSphere()
        if existing then
            Builder.draft.name   = existing.name
            Builder.draft.solid  = existing.solid
            Builder.draft.color  = existing.color
            Builder.draft.radius = existing.radius
            Builder.draft.center = existing.center
            TenxShapes.computeBounds(Builder.draft)
        end
    else
        newPoly()
        if existing then
            Builder.points = {}
            for i = 1, #existing.points do
                local p = existing.points[i]
                Builder.points[i] = { x = p.x, y = p.y, z = existing.minZ }
            end
            rebuildPolyDraft()
            Builder.draft.name  = existing.name
            Builder.draft.solid = existing.solid
            Builder.draft.color = existing.color
            Builder.draft.minZ  = existing.minZ
            Builder.draft.maxZ  = existing.maxZ
        end
    end

    setFocus(nil)

    -- Seed the shape's default tags onto the draft, so they are
    -- visible as chips in the save form rather than applied silently.
    -- Reshaping an existing zone keeps that zone's own tags instead.
    if existing and existing.tags then
        Builder.draft.tags = { table.unpack(existing.tags) }
    else
        local auto = Config.AutoTags and Config.AutoTags[Builder.draft.kind]
        Builder.draft.tags = {}
        if auto then
            for i = 1, #auto do Builder.draft.tags[i] = auto[i] end
        end
    end

    -- Drawing used to force noclip on. Nobody asked for it, and every
    -- fall through the map was the exit transition out of a state the
    -- builder put you in. You now start on foot: the ped never leaves
    -- the ground, collision is never toggled, and there is no exit to
    -- get wrong. F2 still gives you noclip when a large zone needs it.
    SendNUIMessage({ action = 'noclip', on = Builder.noclip })
    SendNUIMessage({ action = 'keys', show = true, mode = mode })
end

function TenxZonesBuilder.getDraft()
    return Builder.draft
end

function TenxZonesBuilder.getEditingId()
    return Builder.editingId
end

function TenxZonesBuilder.clearDraft()
    Builder.mode, Builder.draft, Builder.points = nil, nil, {}
    Builder.editingId  = nil
    State.builderZones = nil
end

function TenxZonesBuilder.patchDraft(patch)
    local d = Builder.draft
    if not d then return end

    if patch.name    ~= nil then d.name    = patch.name    end
    if patch.solid   ~= nil then d.solid   = patch.solid   end
    if patch.color   ~= nil then d.color   = patch.color   end
    if patch.radius  ~= nil then d.radius  = patch.radius + 0.0 end
    if patch.minZ    ~= nil then d.minZ    = patch.minZ + 0.0 end
    if patch.maxZ    ~= nil then d.maxZ    = patch.maxZ + 0.0 end

    TenxShapes.computeBounds(d)
    pushPreview()
end

--- Fly the builder to an existing zone so it can be inspected.
function TenxZonesBuilder.gotoZone(zone)
    local c = zone.kind == 'sphere' and zone.center or zone.centroid
    if not c then return end

    local ped = PlayerPedId()
    local z = (zone.kind == 'sphere') and (c.z + zone.radius * 0.6) or (zone.maxZ or c.z)

    -- Fly here is the one place noclip genuinely helps, since you are
    -- being put in mid air on purpose. Still leaves you able to F2 out
    -- of it, and the settle path handles the landing.
    if not Builder.noclip then
        setNoclip(true)
        SendNUIMessage({ action = 'noclip', on = true })
    end

    SetEntityCoordsNoOffset(ped, c.x, c.y, z + 15.0, false, false, false)

    -- Ask for collision at the destination straight away. Without this
    -- you arrive over unstreamed terrain, and the next noclip exit has
    -- nothing to probe against.
    CreateThread(function()
        local waited = 0
        while waited < 5000 do
            RequestCollisionAtCoord(c.x, c.y, z)
            if HasCollisionLoadedAroundEntity(PlayerPedId()) then return end
            Wait(100)
            waited = waited + 100
        end
    end)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- No yielding allowed here, so restore directly rather than going
    -- through the settle thread. Better to land oddly than to be left
    -- invisible with collision off by a resource that has stopped.
    forceRestore()
    setFocus(nil)
end)
