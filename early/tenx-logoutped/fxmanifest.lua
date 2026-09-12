-- tenx-logoutped/fxmanifest.lua
-- NAIJA 2046 — Logout Ped (combat-log catcher)
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-logoutped'
author 'NAIJA 2046'
description 'Leaves a faded ped holding a sign when a player drops, so scenes can be resolved'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    'server.lua',
}

client_scripts {
    'client.lua',
}

dependencies {
    'qb-core',
    'ox_lib',
}
