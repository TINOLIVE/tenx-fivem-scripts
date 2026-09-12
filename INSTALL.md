# Installation

Every resource here uses the `tenx-` prefix and follows the same shape: drop the
folder in, run its SQL if it has one, add an `ensure` line, fill in the config
placeholders.

Read [Load order](#load-order) before you add `ensure` lines. Three of these
resources depend on each other and will not start in the wrong order.

---

## 1. Dependencies

Install these first. Everything below assumes they're already running.

| Resource | Needed by |
|---|---|
| [qb-core](https://github.com/qbcore-framework/qb-core) (or Qbox) | almost everything |
| [ox_lib](https://github.com/overextended/ox_lib) | almost everything |
| [oxmysql](https://github.com/overextended/oxmysql) | anything with a `.sql` |
| [ox_inventory](https://github.com/overextended/ox_inventory) | tenx-rz, tenx-rob, tenx-prison, tenx-adminjail |
| [ox_target](https://github.com/overextended/ox_target) | tenx-rob, tenx-prison, tenx-adminjail |

Two optional ones, only if you want the features that use them:

- `screenshot-basic` — used by `tenx-rob` and `tenx-spawnmenu`
- an ambulance job — used by `tenx-prison` and `tenx-adminjail` for revives.
  Both call it through `pcall`, so a missing or renamed ambulance job degrades
  that one feature instead of stopping the resource.

---

## 2. Database

Run these once, in this order. Any SQL client works — HeidiSQL, phpMyAdmin,
DBeaver, the `mysql` CLI.

| File | Creates |
|---|---|
| `scripts/tenx-zones/sql/tenx_zones.sql` | `tenx_zones` |
| `scripts/tenx-arena/tenx-arena.sql` | `tenx_arena_zones`, `_matches`, `_stats`, `_ranked`, `_ranked_history`, `_boards`, `_meeting`, `_props` |
| `scripts/tenx-redzone/tenx-redzone.sql` | Red Zone tables |
| `scripts/tenx-rz/tenx-rz.sql` | `tenx_rz_snapshots`, `_log`, `_rounds`, `_spawns`, `_stats` |
| `scripts/tenx-plates/sql/tenx_plates.sql` | `tenx_plates_blocked` |
| `scripts/tenx-elevators/tenx-elevators.sql` | `tenx_elevators` |
| `scripts/tenx-adminjail/` (see its README) | `tenx_admin_punishments`, `tenx_admin_locations` |

`tenx-rz` will start without its SQL and appear to work — until a crash. The
snapshot table is what returns confiscated inventories after an unclean restart.
Do not skip it.

`tenx-spawnmenu`, `tenx-rob`, `tenx-cookie`, `tenx-exitlog`, `tenx-prison`,
`tenx-logoutped` and `tenx-plates-textures` have no database at all.

---

## 3. Load order

Add to `server.cfg` in this order. Anything not listed here is independent and
can go anywhere after `qb-core`.

```cfg
## framework first
ensure qb-core
ensure ox_lib
ensure oxmysql
ensure ox_inventory
ensure ox_target

## zone engine — must load before anything that consumes zones
ensure tenx-zones

## arena, then redzone (redzone reads arena's exports)
ensure tenx-arena
ensure tenx-redzone

## plates — logic and textures, both or neither
ensure tenx-plates
ensure tenx-plates-textures

## independent
ensure tenx-rz
ensure tenx-adminjail
ensure tenx-elevators
ensure tenx-rob
ensure tenx-spawnmenu
```

Three ordering rules that actually matter:

1. **`tenx-zones` before `tenx-arena`.** Zones owns every shape and boundary.
   Arena asks it for geometry rather than defining its own.
2. **`tenx-arena` before `tenx-redzone`.** Red Zone calls arena's exports and
   checks for them on start. If they're missing it refuses to start rather than
   running half-broken — that's deliberate, not a bug.
3. **`tenx-plates` and `tenx-plates-textures` together.** Logic without textures
   gives you correct plate numbers on stock GTA plate images. Textures without
   logic gives you Nigerian plate images with random prefixes.

---

## 4. Fill in the placeholders

Nothing in this repository contains a real secret. Every one has been replaced
with a placeholder you must fill in before the feature works.

### Discord webhooks

Search for `PUT_YOUR_DISCORD_WEBHOOK_HERE` and replace with your own URL, or set
the value to `''` to disable Discord logging and log to console instead.

| Resource | File |
|---|---|
| `tenx-exitlog` | `config.lua` |
| `tenx-logoutped` | `config.lua` |
| `tenx-rob` | `config_server.lua` |

> Keep those Discord channels **staff-only**. The exit log shows who was near
> whom at the moment of a disconnect, which is exactly the evidence a player
> would want to see before arguing about a combat-log.

### Licence identifiers

Search for `PUT_YOUR_LICENSE_IDENTIFIER_HERE` and paste your own FiveM licence,
including the `license:` prefix.

| Resource | File | Command that prints yours |
|---|---|---|
| `tenx-arena` | `config.lua` | `/arenawhoami` |
| `tenx-rz` | `config.lua` | `/ffawhoami` |
| `tenx-zones` | `config.lua` | see its README |
| `tenx-adminjail` | `server/permission.lua` | see its README |
| `tenx-elevators` | `config.lua` | see its README |

Start the resource, join the server, run the command, paste what it prints,
restart the resource.

`PUT_A_SECOND_ADMIN_LICENSE_HERE` appears in `tenx-adminjail` and `tenx-zones`.
Fill it with a second admin, or delete the line.

### API token

`tenx-spawnmenu` ships with `USE_FIVEMANAGE = false` and an empty
`FIVEMANAGE_TOKEN`. Leave it that way to use local images. To use CDN hosting,
set the flag to `true` and paste your token — it lives in `server/main.lua`, a
server script, so clients never receive it.

---

## 5. Verify

After the first start, check the server console for errors from each resource,
then:

| Resource | Check |
|---|---|
| `tenx-zones` | open the builder, create a test zone, restart, confirm it persisted |
| `tenx-arena` | `/arena` opens the panel |
| `tenx-redzone` | `/rz` — if it complains about missing arena exports, your arena is older than this redzone |
| `tenx-rz` | `/ffawhoami` returns your licence |
| `tenx-plates` | spawn a car, confirm the prefix matches the state, and the plate image matches the prefix |
| `tenx-adminjail` | `/adminjail` opens as an admin, returns nothing as a non-admin |
| `tenx-elevators` | interact with a configured elevator |
| `tenx-spawnmenu` | `/spawnmenu` as an admin |

---

## Migrating from the old names

These resources were previously named `naija2046-arena`, `naija2046-redzone`,
`naija2046-rz`, `tx-plates`, `naija-plates`, `naija_adminjail`,
`naija_elevators`, `player_robv2`, `spawn_menu_v2`, `cookie_standalone`,
`n46_exitlog`, `n46_prison` and `naija_logoutped`.

If you're replacing an existing install rather than starting fresh, the folder
names, event names, exports **and database tables** all changed. Rename the
tables before starting the new versions, or they will create empty ones and your
existing data will sit unused:

```sql
RENAME TABLE `naija_arena_zones`          TO `tenx_arena_zones`;
RENAME TABLE `naija_arena_matches`        TO `tenx_arena_matches`;
RENAME TABLE `naija_arena_stats`          TO `tenx_arena_stats`;
RENAME TABLE `naija_arena_ranked`         TO `tenx_arena_ranked`;
RENAME TABLE `naija_arena_ranked_history` TO `tenx_arena_ranked_history`;
RENAME TABLE `naija_arena_boards`         TO `tenx_arena_boards`;
RENAME TABLE `naija_arena_meeting`        TO `tenx_arena_meeting`;
RENAME TABLE `naija_arena_props`          TO `tenx_arena_props`;
RENAME TABLE `naija_arena_rz_inv`         TO `tenx_arena_rz_inv`;
RENAME TABLE `naija_arena_rz_ledger`      TO `tenx_arena_rz_ledger`;

RENAME TABLE `naija_rz_snapshots` TO `tenx_rz_snapshots`;
RENAME TABLE `naija_rz_log`       TO `tenx_rz_log`;
RENAME TABLE `naija_rz_rounds`    TO `tenx_rz_rounds`;
RENAME TABLE `naija_rz_spawns`    TO `tenx_rz_spawns`;
RENAME TABLE `naija_rz_stats`     TO `tenx_rz_stats`;

RENAME TABLE `naija_admin_punishments` TO `tenx_admin_punishments`;
RENAME TABLE `naija_admin_locations`   TO `tenx_admin_locations`;

RENAME TABLE `naija_elevators`   TO `tenx_elevators`;
RENAME TABLE `tx_plates_blocked` TO `tenx_plates_blocked`;
```

The arena's zone mappings are keyed by an `import_key` string that also changed,
from `naija2046:arena:<id>` to `tenx:arena:<id>`. If you already migrated your
arenas onto `tenx-zones`, update those rows too or the next migration run will
create duplicate zones instead of converging onto the existing ones:

```sql
UPDATE `tenx_zones`
SET `import_key` = REPLACE(`import_key`, 'naija2046:arena:', 'tenx:arena:')
WHERE `import_key` LIKE 'naija2046:arena:%';
```

Run that **before** `/arenazonemigrate`.

**Two things deliberately not renamed.** The ox_inventory item `n46_gummies` is
an item in your inventory registry, not a resource — renaming it would orphan
every copy players are holding. And `tenx-spawnmenu`'s KVP keys still begin
`spawn_menu:` so existing captures survive the rename.

Also update your `server.cfg` `ensure` lines, and anything on your server that
calls the old exports or listens for the old event names.

**One thing that does not migrate:** `tenx-spawnmenu` stores its captured photos
and custom labels in resource KVP under keys beginning `spawn_menu:`. Those keys
were deliberately left unchanged so your existing captures still resolve after
the rename. If you'd rather they matched the new name, rename them in
`server/main.lua` and re-run the capture.
