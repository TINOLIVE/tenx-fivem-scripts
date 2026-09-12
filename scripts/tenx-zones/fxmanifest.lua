fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-zones'
author 'TENX / Tino'
description 'Authoritative zone system and in-game zone creator for NAIJA 2046'
version '2.0.0'

shared_scripts {
    'config.lua',
    'shared/contract.lua',
    'shared/shapes.lua'
}

client_scripts {
    'client/main.lua',
    'client/teleport.lua',
    'client/render.lua',
    'client/builder.lua',
    'client/nui.lua',
    'client/debug.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

dependencies {
    'oxmysql'
}
