fx_version 'cerulean'
game 'gta5'

name 'tenx-spawnmenu'
lua54 'yes'

author 'devtino'
description 'Admin Spawn Menu - QB vehicles (+ addon scan) & ox_inventory items/weapons with images - v2: persistent rename'
version '2.0.0'

shared_script 'shared/vanilla.lua'
client_script 'client/main.lua'
server_script 'server/main.lua'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'images/*.png'
}

dependencies {
    'qb-core',
    'ox_inventory'
}

-- Optional: required only for the "Take Pictures" car-photo feature
-- ensure screenshot-basic is started for that to work.
