--[[
    tenx-zones :: the frozen contract

    This is the agreed v2 export surface, in one place, shared by both
    sides. `GetExports()` returns it directly rather than a hand written
    list, so the answer can never drift from what is actually registered
    -- server/stub.lua walks this table to register, and returns the same
    table when asked what exists.

    v2 keeps this file unchanged. Only the bodies get filled in.
]]

TenxContract = {}

TenxContract.version = '2.0.0'

--- Every server export, grouped only for readability. GetExports()
--- returns them flattened.
TenxContract.server = {

    -- reading zones
    'GetZone',
    'GetZones',
    'ZoneExists',
    'GetVersion',
    'GetZoneCentre',        -- guaranteed INSIDE the shape
    'GetZoneCentroid',      -- raw maths, may fall outside a concave shape
    'GetZoneArea',
    'GetZoneBounds',
    'GetZoneDepth',

    -- membership
    'IsPointInZone',
    'IsPlayerInZone',
    'GetPlayersInZone',

    -- binding
    'BindZoneToBucket',
    'UnbindZoneFromBucket',
    'BindZoneToPlayers',
    'UnbindZoneFromPlayers',
    'RefreshPlayer',
    'ReleaseZone',          -- NOTE: absent from the frozen list you sent,
                            -- but your integration guide calls it on every
                            -- match end. Listed here so a startup check
                            -- against GetExports() actually covers it.
    'GetBindings',
    'GetBindingsFor',

    -- arming
    'RearmZone',
    'DisarmZone',
    'IsZoneArmed',

    -- suspends
    'SuspendZone',
    'ResumeZone',
    'ClearSuspends',
    'GetSuspends',

    -- movement
    'TeleportPlayer',
    'ValidateSpawn',
    'ClampToZone',
    'PushOutsideZone',

    -- writes
    'CreateZone',
    'DeleteZone',
    'SetZoneSolid',
    'SetZoneVisible',

    'GetZoneByImportKey',
    'VerifyZoneMapping',

    -- tags
    'GetZonesByTag',
    'GetZoneTags',
    'ZoneHasTag',
    'SetZoneTags',

    -- introspection
    'GetExports',
    'HasExport',
}

TenxContract.client = {
    'SuspendLocal',
    'ResumeLocal',
    'IsSuspended',
    'GetLocalClaims',
    'IsInZone',
    'GetMyZones',
    'GetZoneDepth',
}

--- Events are not exports and cannot be presence checked, so they are
--- listed here for reference only.
TenxContract.events = {
    client = {
        'tenx-zones:entered',               -- id, zone
        'tenx-zones:left',                  -- id, zone, reason, claim
    },
    server = {
        'tenx-zones:server:ready',          -- version, zoneIds
        'tenx-zones:server:entered',        -- src, zoneId
        'tenx-zones:server:left',           -- src, zoneId, reason, claim
        'tenx-zones:server:zoneDeleted',    -- zoneId
        'tenx-zones:server:zoneUnavailable',-- zoneId, why
    },
}

--- left/displaced reasons.
TenxContract.reasons = {
    'walked',
    'teleported',
    'bucket',
    'unbound',
    'deleted',
    'dropped',
    'displaced',
}

function TenxContract.has(list, name)
    for i = 1, #list do
        if list[i] == name then return true end
    end
    return false
end
