fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-rz'
author 'TX Scripts'
description 'NAIJA 2046 Red Zone. Admin-run arena rounds with a closing ring, ground loot, airdrops and a guaranteed inventory restore. Fully driven from an in-game admin panel.'
version '2.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_script 'client.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/logo.png'
}

dependencies {
    'ox_lib',
    'ox_inventory',
    'oxmysql',
    'qb-core'
}
