--[[
    tenx-zones :: nui bridge

    The panel can ask for things. It cannot decide anything. Every
    callback here does nothing but forward to the server, which
    re-checks the ACE permission before it acts. A leaked or spoofed
    NUI message gets you exactly as far as a spoofed net event does,
    which is nowhere.
]]

local Builder = TenxZonesBuilder

local function ok(cb, payload)
    cb(payload or { ok = true })
end


RegisterNUICallback('close', function(_, cb)
    Builder.close()
    ok(cb)
end)

--- Start drawing. mode is 'sphere' or 'poly'. If zone is supplied
--- we are re-drawing an existing one.
RegisterNUICallback('draw', function(data, cb)
    Builder.beginDraw(data.mode == 'poly' and 'poly' or 'sphere', data.zone)
    ok(cb)
end)

--- Live edits from the panel while a draft is on screen.
RegisterNUICallback('patch', function(data, cb)
    Builder.patchDraft(data or {})
    ok(cb)
end)

--- Back to flying with the current draft still live.
RegisterNUICallback('resume', function(data, cb)
    local draft = Builder.getDraft()
    if draft then
        Builder.beginDraw(draft.kind == 'poly' and 'poly' or 'sphere', nil)
    end
    ok(cb)
end)

RegisterNUICallback('discard', function(_, cb)
    Builder.clearDraft()
    ok(cb)
end)

RegisterNUICallback('save', function(data, cb)
    local draft = Builder.getDraft()
    if not draft then
        ok(cb, { ok = false, error = 'nothing to save' })
        return
    end

    local payload = {
        name    = tostring(data.name or draft.name or 'Zone'),
        kind    = draft.kind,
        solid   = data.solid ~= false,
        visible = data.visible ~= false,
        color   = data.color or draft.color,
        tags    = type(data.tags) == 'table' and data.tags or draft.tags,
    }

    if draft.kind == 'sphere' then
        payload.center = draft.center
        payload.radius = tonumber(data.radius) or draft.radius
    else
        payload.points = draft.points
        payload.minZ   = tonumber(data.minZ) or draft.minZ
        payload.maxZ   = tonumber(data.maxZ) or draft.maxZ
    end

    local editingId = Builder.getEditingId()
    if editingId then
        TriggerServerEvent('tenx-zones:update', editingId, payload)
    else
        TriggerServerEvent('tenx-zones:create', payload)
    end

    Builder.clearDraft()
    ok(cb)
end)

--- Field level edit on a saved zone, no redraw involved.
RegisterNUICallback('updateZone', function(data, cb)
    local id = tonumber(data.id)
    if not id then ok(cb, { ok = false }) return end

    local patch = {}
    if data.name    ~= nil then patch.name    = tostring(data.name) end
    if data.solid   ~= nil then patch.solid   = data.solid and true or false end
    if data.visible ~= nil then patch.visible = data.visible and true or false end
    if data.color   ~= nil then patch.color   = data.color end
    if data.radius  ~= nil then patch.radius  = tonumber(data.radius) end
    if data.minZ    ~= nil then patch.minZ    = tonumber(data.minZ) end
    if data.maxZ    ~= nil then patch.maxZ    = tonumber(data.maxZ) end
    if type(data.tags) == 'table' then patch.tags = data.tags end

    TriggerServerEvent('tenx-zones:update', id, patch)
    ok(cb)
end)

RegisterNUICallback('delete', function(data, cb)
    local id = tonumber(data.id)
    if id then TriggerServerEvent('tenx-zones:delete', id) end
    ok(cb)
end)

RegisterNUICallback('goto', function(data, cb)
    if data.zone then Builder.gotoZone(data.zone) end
    ok(cb)
end)

RegisterNUICallback('refresh', function(_, cb)
    TriggerServerEvent('tenx-zones:open')
    ok(cb)
end)


-- Server talking back to the panel.
RegisterNetEvent('tenx-zones:result', function(success, message, zone)
    SendNUIMessage({
        action = 'toast',
        ok     = success and true or false,
        text   = message,
        zone   = zone,
    })

    if success then
        TriggerServerEvent('tenx-zones:open')
    end
end)

RegisterNetEvent('tenx-zones:requestOpen', function()
    TriggerServerEvent('tenx-zones:open')
end)
