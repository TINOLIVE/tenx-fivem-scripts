# tenx-logoutped

Leaves a faded ped holding a sign where a player disconnected, so a scene can be
resolved fairly instead of ending the moment someone alt-F4s.

> **Early work**, but the more developed take on the idea started in
> [`tenx-exitlog`](../tenx-exitlog) — that one wrote a Discord log line, this one
> leaves something the other players in the scene can actually see and act on.

---

## Requirements

- `qb-core`
- `ox_lib`

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-logoutped` in `server.cfg`.
3. Open `config.lua` and replace `PUT_YOUR_DISCORD_WEBHOOK_HERE` with your own
   webhook, or set it to `''` for console-only logging.

---

## Behaviour

When a player drops, the server spawns a ped at their last position wearing
their model, faded, holding a sign. The ped persists for a configured duration
and is then cleaned up. Anything that happens to it while it stands there is
logged.

The point is that a combat-log no longer removes the player from the scene — the
people they were in a situation with still have something in front of them.

---

## Configuration

See `config.lua`. `Config.Webhook` controls drop logging; leaving it empty logs
to the server console instead of Discord.
