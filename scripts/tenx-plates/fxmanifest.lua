fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-plates'
author 'NAIJA 2046'
description 'Nigerian-themed city plates + item-based plate customization'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/plates.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/admin.lua',
    'server/police.lua',
    'server/jobkeys.lua',
    'server/masterkey.lua',
}

client_scripts {
    'client/main.lua',
    'client/traffic.lua',
    'client/police.lua',
    'client/jobkeys.lua',
    'client/masterkey.lua',
}

dependencies {
    'qb-core',
    'ox_lib',
    'oxmysql',
}