-- tenx-adminjail/config_moon.lua
-- SHARED (client + server). Settings for the "Send to Moon" crisis tool.
-- Moon = a parking spot. No cuffs, no timer, no leash — they're just NOT here
-- until you /unmoon them, which drops them back on the exact spot you took them
-- from (same coords, same heading).
--
-- If you'd rather keep everything in one place, paste this whole Config.Moon
-- block into config.lua and delete this file from fxmanifest.

Config = Config or {}

Config.Moon = {
    -- ========================================================
    --  COMMANDS
    -- ========================================================
    command        = 'moon',      -- /moon [id] [reason]
    releaseCommand = 'unmoon',    -- /unmoon [id]
    setPointCommand = 'setmoon',  -- stand where the moon is, run this, press E

    -- ========================================================
    --  TARGET (third-eye)
    -- ========================================================
    -- The eye option is only REGISTERED for players whose license is in
    -- server/permissions.lua — non-staff never even get the option built.
    -- The server re-checks the license anyway, so a spoofed client gets nothing.
    targetLabel    = 'Send to Moon',
    targetIcon     = 'fa-solid fa-rocket',
    targetDistance = 3.0,

    -- true  = pops a reason box on every use
    -- false = fires instantly with defaultReason (faster during a live crisis)
    askReason      = false,
    defaultReason  = 'Crisis resolution',

    -- ========================================================
    --  LOCATION
    -- ========================================================
    -- Set coords here and that's the moon — no /setmoon needed.
    -- Format: vec4(x, y, z, heading). Set to nil to use the DB instead.
    coords = vec4(-3911.59, 292.30, 641.98, 252.72),

    -- Lookup order: this coords field -> newest saved 'moon' location (/setmoon)
    -- -> newest saved ADMIN JAIL location (only if fallbackToJail is true).
    -- So /setmoon still works and OVERRIDES nothing — clear coords above first
    -- if you want the saved point to win.
    fallbackToJail = true,

    -- ========================================================
    --  BEHAVIOUR
    -- ========================================================
    fadeTime       = 500,    -- screen fade each way (ms)
    -- RELOG: a moon stays applied across disconnects and script restarts —
    -- the row sits 'active' in tenx_admin_punishments and gets re-pushed by
    -- the same resync path as jail/cuff. They land back on the moon.
    -- Their return coords are stored in the row, so /unmoon still sends them
    -- to the original spot days later.
    -- (This isn't optional by design: qb-core saves logout position, so a
    -- mooned player would respawn on the moon anyway — better that the script
    -- knows about it and can still pull them back.)

    -- ========================================================
    --  LOGGING
    -- ========================================================
    logToDiscord   = true,   -- uses Config.Webhook from config.lua
    -- Deliberately NEVER broadcast to public chat. This is crisis resolution,
    -- not a punishment — no public shaming layer.
}
