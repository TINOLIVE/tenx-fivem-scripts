local positions = {}  -- src -> { x, y, z }

RegisterNetEvent('tenx-exitlog:pos', function(x, y, z)
    positions[source] = { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end)

local function ident(src, kind)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, #kind + 1) == kind .. ':' then return id end
    end
    return 'N/A'
end

-- rough postal-ish label from coords (just distance-free readable coords)
local function nearbyPlayers(src)
    local me = positions[src]
    if not me then return {} end
    local r = Config.NearbyRadius or 30.0
    local out = {}
    for _, other in ipairs(GetPlayers()) do
        other = tonumber(other)
        if other ~= src and positions[other] then
            local o = positions[other]
            local dist = #(vector3(me.x, me.y, me.z) - vector3(o.x, o.y, o.z))
            if dist <= r then
                out[#out + 1] = ('%s [%s] (%.0fm)'):format(GetPlayerName(other) or '?', other, dist)
            end
        end
    end
    return out
end

AddEventHandler('playerDropped', function(reason)
    local src = source
    if not Config.Webhook or Config.Webhook == '' then positions[src] = nil return end

    local name    = GetPlayerName(src) or 'Unknown'
    local license = ident(src, 'license')
    local license2= ident(src, 'license2')
    local discord = ident(src, 'discord'):gsub('discord:', '')
    local ip      = ident(src, 'ip'):gsub('ip:', '')
    local pos     = positions[src]
    local coords  = pos and ('%.1f, %.1f, %.1f'):format(pos.x, pos.y, pos.z) or 'N/A'
    local nearby  = nearbyPlayers(src)
    local nearStr = #nearby > 0 and table.concat(nearby, '\n') or 'Nobody nearby'

    local fields = {
        { name = 'Player',    value = ('%s `[%s]`'):format(name, src), inline = true },
        { name = 'Discord',   value = discord ~= 'N/A' and ('<@%s>'):format(discord) or 'N/A', inline = true },
        { name = 'Reason',    value = '`' .. (reason or 'unknown') .. '`', inline = false },
        { name = 'License',   value = '`' .. license .. '`', inline = false },
        { name = 'License2',  value = '`' .. license2 .. '`', inline = false },
        { name = 'IP',        value = '`' .. ip .. '`', inline = true },
        { name = 'Last Coords', value = '`' .. coords .. '`', inline = true },
        { name = ('Nearby (%dm)'):format(Config.NearbyRadius or 30), value = nearStr, inline = false },
    }

    PerformHttpRequest(Config.Webhook, function() end, 'POST', json.encode({
        username = Config.BotName,
        avatar_url = Config.Avatar ~= '' and Config.Avatar or nil,
        embeds = { {
            title = '🚪 Player Left',
            color = Config.Color,
            fields = fields,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
        } },
    }), { ['Content-Type'] = 'application/json' })

    positions[src] = nil
end)
