--[[
    SERVER-ONLY CONFIG
    ------------------
    This file is loaded in server_scripts ONLY. It is never sent to clients,
    so the webhooks below stay private.

    DO NOT move anything from this file into config.lua - config.lua is a
    shared_script and every player downloads it into their cache folder.
]]

ConfigServer = {}

ConfigServer.Discord = {
    Enabled = true,

    -- MAIN LOG WEBHOOK (private - server only, never sent to any client)
    -- This is where the full robbery embed goes.
    Webhook = 'PUT_YOUR_DISCORD_WEBHOOK_HERE',

    -- IMAGE WEBHOOK (semi-public - see note below)
    -- screenshot-basic uploads from the CLIENT, so this URL has to be handed to
    -- the robber's game at the moment the shot is taken. It is not stored in any
    -- file the client downloads, but a determined modder could still read it off
    -- the wire.
    --
    -- Point this at a separate, disposable #rob-images channel. If it ever leaks,
    -- the worst anyone can do is post pictures in that one channel. Delete the
    -- webhook, make a new one, paste it here. Your main Webhook above is unaffected.
    --
    -- Leave blank ('') to disable screenshots entirely.
    ScreenshotWebhook = 'PUT_YOUR_DISCORD_WEBHOOK_HERE',

    -- Cosmetics
    BotName = 'NAIJA 2046 | Robbery Log',
    Avatar  = '',           -- optional image URL for the webhook avatar
    Footer  = 'NAIJA 2046',

    ColorRobbed = 15158332, -- red    - hands-up rob
    ColorLooted = 10038562, -- maroon - body loot

    -- Ping the robber/victim's discord account in the log (<@id>).
    -- false = show the raw ID only, no notification.
    MentionDiscordIds = false,

    -- Print to the server console as well as Discord.
    ConsoleLog = false,
}
