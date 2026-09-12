fx_version 'cerulean'
game 'gta5'

name 'tenx-rob'

lua54 'yes'

author 'Tino'
description 'Player Robbing Script - ox_target, ox_lib, ox_inventory'
version '2.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'client.lua'
}

server_scripts {
    'config_server.lua',
    'server.lua'
}

dependencies {
    'qb-core',
    'ox_target',
    'ox_lib',
    'ox_inventory',
    'screenshot-basic'
}
