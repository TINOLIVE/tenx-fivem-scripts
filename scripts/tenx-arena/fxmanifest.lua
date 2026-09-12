fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-arena'
author 'TX Scripts'
description 'NAIJA 2046 Arena. Bounded PvP arenas with team spawns, isolated routing buckets and an in-game zone builder. Stage 1: zones, boundaries, buckets, admin panel.'
version '0.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',

    -- Zone maths, shared on purpose: the client clamps you inside every frame
    -- and the server checks the same thing on a sweep. Two copies that drifted
    -- apart would have the server shoving players back into a zone their own
    -- client thought they were already in.
    'shared.lua'
}

-- zones_client is loaded AFTER client.lua so the globals it defines exist by
-- the time anything runs. It is a separate file on purpose: the tenx-zones
-- handover is meant to be deleted in one piece once it is no longer optional.
client_scripts {
    'client.lua',
    'zones_client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
    'zones_server.lua',

    -- One-off, run by hand from the console. Kept out of zones_server.lua so
    -- the handover layer and the migration can be deleted independently.
    'zones_migrate.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/logo.png',

    -- Rendered onto the lobby billboard via DUI. Has to be listed here or
    -- the nui:// url will not resolve.
    'html/billboard.html',
    'html/boardinfo.html',

    -- Pictures for items that only exist in this script, so they work
    -- without anyone adding them to ox_inventory.
    -- The wildcard means dropping a new one in the folder is all it takes,
    -- with no manifest edit.
    'html/items/*.png'
}

-- Dispatch suppression needs one line in ps-dispatch. See DISPATCH.md.

dependencies {
    'ox_lib',
    'oxmysql',
    'qb-core'
}
