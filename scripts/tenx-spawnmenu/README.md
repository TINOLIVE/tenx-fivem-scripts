# tenx-spawnmenu

Admin spawn menu for QBCore — vehicles and items, with a NUI browser, custom
labels, imported spawn codes and optional CDN photo hosting.

---

## Requirements

- `qb-core`

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-spawnmenu` in `server.cfg`.
3. Open `server/main.lua` and check the config block at the top.
4. Run `/spawnmenu` in game as an admin.

---

## Configuration

At the top of `server/main.lua`:

```lua
local ALLOWED_PERMS  = { 'admin', 'god' }   -- QBCore permission levels
local COMMAND        = 'spawnmenu'          -- chat command
local USE_FIVEMANAGE = false                -- CDN photo hosting, off by default
local FIVEMANAGE_TOKEN = ''
```

`ALLOWED_PERMS` is checked **server-side** against QBCore permissions. The
command is not registered as a client-side convenience — a player without the
permission gets nothing back.

---

## Vehicle photos

Two options.

**Local (default).** Drop images into `images/`. No token, no external calls.

**Fivemanage CDN.** Set `USE_FIVEMANAGE = true` and paste your API token into
`FIVEMANAGE_TOKEN`. The server captures each vehicle once, uploads it, and
stores the returned URL. Subsequent loads pull from the CDN instead of shipping
image files to every client.

> **The token is a secret.** It lives in `server/main.lua`, which is a
> `server_script`, so clients never receive it. Do not move it into a shared
> file, and do not commit a real token to a public repository — the value ships
> here empty on purpose.

---

## Persistence

State is stored with `SetResourceKvp` rather than a database, so there is no
SQL to run:

| Key | Holds |
|---|---|
| `spawn_menu:imports` | User-pasted spawn codes |
| `spawn_menu:captured` | Which models have already had a photo taken |
| `spawn_menu:imageurls` | Model → hosted image URL |
| `spawn_menu:labels` | Model → custom display name |

Capture resumes where it left off, so a restart part-way through a large vehicle
list does not start over.
