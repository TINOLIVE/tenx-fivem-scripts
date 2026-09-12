-- tenx-logoutped/config.lua
-- Shared (client + server).

Config = {}

-- ============================================================
--  LIFETIME
-- ============================================================
Config.Duration = 600      -- seconds the ped stays. 600 = 10 min.

-- The ped stays the FULL duration even if the player reconnects. Someone who
-- logs mid-scene and hops back in still leaves the evidence standing.
-- Their new ped and the logout ped will both exist — that is intentional.
Config.RemoveOnReconnect = false

-- ============================================================
--  APPEARANCE
-- ============================================================
Config.Alpha = 150         -- 0-255. 150 = clearly faded but readable. 255 = solid.

-- How often each client re-sends its appearance to the server (ms).
-- The server can only rebuild a ped from the LAST snapshot it received, so a
-- player who changes clothes and drops 20s later will show the old outfit.
-- Lower = more accurate, more traffic. 60s is a fine trade at 64 players.
Config.SnapshotInterval = 60000

-- ============================================================
--  THE SIGN
-- ============================================================
-- Prop held in the ped's right hand. Validated with IsModelValid before it
-- spawns — a bad name is skipped with a console warning, never a crash.
-- If this prop doesn't exist on your build, the ped still spawns with the
-- floating text, just no sign. Swap the model and restart to try another.
Config.Sign = {
    enabled = true,
    model   = 'prop_cs_protest_sign_01',
    bone    = 28422,   -- PH_R_Hand
    pos     = { x = 0.0,  y = 0.0, z = 0.0 },
    rot     = { x = 0.0,  y = 0.0, z = 0.0 },
}

-- ============================================================
--  FLOATING TEXT
-- ============================================================
Config.Text = {
    distance      = 15.0,   -- metres you must be within to read it
    scale         = 0.4,
    showCountdown = false,  -- add "8:24 left" as a line
    showRawReason = false,  -- add the exact drop string the server received
                            -- (ugly, but useful when you're building a case)
}

-- ============================================================
--  ANIMATION
-- ============================================================
-- Idle the ped plays while standing there. Set enabled = false for a plain
-- T-pose-free static ped.
Config.Anim = {
    enabled = true,
    dict    = 'amb@world_human_bum_freeway@male@base',
    clip    = 'base',
}

-- ============================================================
--  LOGGING
-- ============================================================
Config.LogToConsole = true
Config.Webhook = 'PUT_YOUR_DISCORD_WEBHOOK_HERE'        -- Discord webhook for drop logs. '' = console only.
