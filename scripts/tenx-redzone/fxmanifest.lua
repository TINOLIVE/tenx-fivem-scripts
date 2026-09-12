fx_version 'cerulean'
game 'gta5'

name 'tenx-redzone'
author 'TX'
description 'Always-on free-for-all zones for NAIJA 2046. Plugs into tenx-arena.'
version '1.0.0'

lua54 'yes'

-- ox_lib has to be LOADED, not just listed as a dependency.
--
-- `dependencies` only controls start order -- it does not put anything in
-- scope. Without this line `lib` is nil and the first callback registration
-- throws, which is exactly what happened.
shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_script 'client.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',

    -- The tenx-zones handover, kept separate so it can be deleted in one
    -- piece once it stops being optional.
    'zones_server.lua',
}

ui_page 'html/hud.html'

files {
    'html/hud.html'
}

-- This resource does NOT hold inventories, coins or arenas. Those live in
-- tenx-arena and are reached through its exports, so a player carries
-- one bag across both modes rather than two that disagree.
--
-- It has to start AFTER the arena, or its first export call finds nothing.
dependencies {
    'tenx-arena',
    'ox_lib',
    'oxmysql',
}
