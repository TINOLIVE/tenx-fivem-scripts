# tenx-exitlog

Combat-log catcher. Logs every disconnect to Discord along with a list of who
was standing nearby when it happened.

> **Early work.** Kept here as-is. The idea was later taken further in
> [`tenx-logoutped`](../tenx-logoutped), which leaves a physical ped behind
> instead of only writing a log line.

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-exitlog` in `server.cfg`.
3. Open `config.lua` and replace `PUT_YOUR_DISCORD_WEBHOOK_HERE` with your own
   webhook URL.

> **Keep that Discord channel staff-only.** The log shows who was near whom at
> the moment of a drop, which is exactly the information that lets a player
> argue their way out of a combat-log claim if they can see it.

---

## Configuration

| Setting | Default | What it does |
|---|---|---|
| `Config.Webhook` | placeholder | Discord webhook URL |
| `Config.NearbyRadius` | `30.0` | Metres counted as "nearby" at the moment of the drop |
| `Config.PosInterval` | `5` | Seconds between position cache refreshes |
| `Config.BotName` | `NAIJA 2046 \| Exit Log` | Embed author name |
| `Config.Color` | `15158332` | Embed colour (red) |
| `Config.Avatar` | `''` | Optional embed image URL |

---

## How the nearby list works

A player who has already disconnected cannot be queried for a position, so the
server keeps a cached position per player, refreshed every `Config.PosInterval`
seconds. When the drop fires, the cache is what gets compared.

That interval is the trade-off: lower is more accurate and costs more, higher is
cheaper and can be up to that many seconds stale. Five seconds was the balance
that worked in practice.
