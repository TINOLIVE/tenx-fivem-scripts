# tenx-adminjail

Unified admin punishment system for QBCore — cuff, jail, community service,
"moon", and recovery tools, in one resource with one menu.

Built for NAIJA 2046. Punishments are stored in the database and **survive
restarts**: on resource start the server sweeps every online player and
re-applies anything still marked active, resuming from `time_served` rather
than restarting the sentence.

---

## Requirements

- `qb-core`
- `ox_lib`
- `oxmysql`
- `ox_target` (configurable via `Config.TargetResource`)
- `ox_inventory` (configurable via `Config.InventoryResource`)

An ambulance job is used for revives in the recovery tools. It is deliberately
**not** listed in `dependencies` — the calls are `pcall`-wrapped so that if the
event names change, the recovery tools degrade instead of the whole resource
refusing to start.

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-adminjail` in `server.cfg`, after `qb-core` and `oxmysql`.
3. Open `server/permission.lua` and replace the placeholder licence
   identifiers with your own.
4. Restart, then run `/adminjail` in game.

---

## Security model

The admin allowlist lives in **`server/permission.lua`**, which is a
`server_script`. It is never sent to a client. Nothing in `config.lua` or
`config_moon.lua` / `config_recovery.lua` contains a licence, a webhook or any
other secret — those files are shared, so anything in them is readable by every
connected player.

If you add admins, add them in `server/permission.lua`. Do not move the list
into `config.lua` for convenience.

---

## Load order matters

Two orderings in `fxmanifest.lua` are load-bearing and will break the resource
if changed:

**Shared scripts.** `config.lua` declares `Config = {}`. The other two use
`Config = Config or {}` and add onto it. If `config.lua` is not first, it wipes
them.

**Server scripts.** `server.lua` declares the punishment types and exposes
`_G.NaijaPunishmentTypes`. `moon.lua` registers the `moon` type and needs that.
`recovery.lua` clears and re-pushes punishments including moon, so it needs both
and loads last.

---

## Configuration

| File | Covers |
|---|---|
| `config.lua` | Command name, keybind, logging, public broadcast, target/inventory resource names, restart resync delay, location capture |
| `config_moon.lua` | The moon punishment |
| `config_recovery.lua` | Revive / recovery tooling |

Set `Config.Webhook` to your own Discord webhook, or leave it `''` to log to
console only.

`Config.PublicBroadcast` sends punishments to city chat — the public-shaming
layer. Set it to `false` if you'd rather punishments stayed quiet.

---

## Note on naming

The `fxmanifest.lua` declares `name 'tenx-adminjail'` while the folder is
`tenx-adminjail`. FiveM resolves resources by **folder name**, so this works —
but if you rename the folder, update your `server.cfg` and any
`exports[...]` calls to match the folder, not the manifest `name` field.
