-- tenx-adminjail/fxmanifest.lua
-- NAIJA 2046 — Admin Punishment System
-- cuff / jail / community service / moon / recovery
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tenx-adminjail'
author 'NAIJA 2046'
description 'Unified admin punishment system (cuff / jail / community service / moon / recovery)'
version '1.2.0'

-- ORDER MATTERS: config.lua defines the Config table; config_moon.lua and
-- config_recovery.lua add onto it with `Config = Config or {}`. config.lua
-- MUST stay first or its `Config = {}` wipes the others.
shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'config_moon.lua',
    'config_recovery.lua',
}

-- ORDER MATTERS:
--   server.lua   declares PunishmentTypes and exposes _G.NaijaPunishmentTypes.
--   moon.lua     registers the 'moon' type — needs the line above.
--   recovery.lua clears/re-pushes punishments (incl. moon) — needs BOTH above,
--                so it loads last.
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/permission.lua',   -- admin allowlist (server-only, never sent to clients)
    'server/server.lua',
    'server/moon.lua',
    'server/recovery.lua',
}

client_scripts {
    'client/client.lua',
    'client/moon.lua',
    'client/recovery.lua',
}

dependencies {
    'qb-core',
    'ox_lib',
    'oxmysql',
    -- ak47_qb_ambulancejob is used for revives but is NOT listed here on
    -- purpose: if the event names ever change, the recovery tools should degrade
    -- (pcall-wrapped) rather than refuse to start the whole resource.
}
