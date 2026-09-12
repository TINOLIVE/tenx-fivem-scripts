fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-elevators'
author 'Tino'
description 'Naija Elevator Creator - in-game elevator builder with access control, vehicles and travel screen'
version '2.0.0'

shared_script '@ox_lib/init.lua'
shared_script 'config.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

client_script 'client.lua'

ui_page 'html/index.html'
files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

dependencies {
    'ox_lib',
    'oxmysql',
    'ox_inventory',
    'qb-core'
}
