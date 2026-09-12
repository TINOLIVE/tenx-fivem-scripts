# FiveM Scripts — by Tino

QBCore / Qbox resources written for **NAIJA 2046** and other FiveM servers.
Fourteen resources, kept in one place, arranged so you can see how the work
progressed rather than just where it landed.

Everything here is built on the `ox` stack — `ox_lib`, `ox_inventory`,
`ox_target`, `oxmysql` — with a strict client/server split: authority,
money, inventory and permission checks live server-side, and the client is
treated as untrusted input.

All resources use the **`tenx-`** prefix and are named consistently — folder,
manifest, event namespace, exports and database tables all match.

**Author:** Valentino Tiamiyu (Tino) — Lagos, Nigeria
**Frameworks:** QBCore (primary), Qbox, ESX

---

## Repository layout

```
/scripts    the current work — full client/server/shared architecture,
            NUI panels, SQL migrations, crash-safe state
/early      the first things I shipped — small, single-purpose, kept on
            purpose so the progression is visible
```

---

## /scripts

| Resource | What it does |
|---|---|
| [`tenx-zones`](scripts/tenx-zones) | Zone engine. In-game shape builder (circle / poly / box), NUI editor, DB-persisted, exported to other resources. Sole owner of zone geometry — nothing else defines its own boundaries. |
| [`tenx-arena`](scripts/tenx-arena) | Bounded team PvP. Routing-bucket isolation, team spawns, parties, queue, matchmaking, ready check, map voting, match hotbar. |
| [`tenx-redzone`](scripts/tenx-redzone) | Always-on free-for-all. Built as its own resource that consumes arena's exports rather than duplicating them, and refuses to start if the arena is too old. |
| [`tenx-rz`](scripts/tenx-rz) | Admin-run arena rounds with full inventory confiscation. Sweeps every inventory in a live zone, issues one weapon, and returns everything on end — including to players who died, disconnected, or were online through a server crash. |
| [`tenx-plates`](scripts/tenx-plates) | Nigerian state licence plates. Per-state prefixes, blocklist, police plate-state changes, master key, job keys, DB cascade so plate changes follow the vehicle everywhere. |
| [`tenx-plates-textures`](scripts/tenx-plates-textures) | Companion to `tenx-plates` — runtime DUI texture replacement mapping one plate image per state onto the native `vehshare` plate slots. |
| [`tenx-adminjail`](scripts/tenx-adminjail) | Unified admin punishment system: cuff, jail, community service, moon, recovery tools. Punishments survive restarts and resume from time served. |
| [`tenx-elevators`](scripts/tenx-elevators) | Multi-floor elevator system with NUI floor select and DB-stored elevator definitions. |
| [`tenx-rob`](scripts/tenx-rob) | Player-to-player robbing over `ox_target` / `ox_inventory`, with server-side validation and Discord logging. |
| [`tenx-spawnmenu`](scripts/tenx-spawnmenu) | Admin spawn menu — vehicles and items, custom labels, imported spawn codes, optional CDN photo hosting. |

## /early

| Resource | What it does |
|---|---|
| [`tenx-cookie`](early/tenx-cookie) | Consumable stamina/armour boost with animation and effect timers. |
| [`tenx-exitlog`](early/tenx-exitlog) | Combat-log catcher — logs disconnects to Discord along with who was nearby. |
| [`tenx-prison`](early/tenx-prison) | Prison medic ped (paid revive / heal) and a prison weapon shop ped. |
| [`tenx-logoutped`](early/tenx-logoutped) | Leaves a faded ped holding a sign where a player dropped, so a scene can be resolved fairly. |

---

## Installing

Full setup — dependencies, SQL, load order and every placeholder to fill in — is
in **[INSTALL.md](INSTALL.md)**. Read the load-order section first: `tenx-zones`,
`tenx-arena` and `tenx-redzone` depend on each other and will not start in the
wrong order.

---

## Before you install anything

Every config in this repo ships with **placeholders, not real values**. Search
for these and fill them in:

| Placeholder | Where | What to put |
|---|---|---|
| `PUT_YOUR_DISCORD_WEBHOOK_HERE` | `tenx-exitlog`, `tenx-logoutped`, `tenx-rob` | Your Discord webhook URL — keep the channel staff-only |
| `PUT_YOUR_LICENSE_IDENTIFIER_HERE` | `tenx-arena`, `tenx-rz`, `tenx-adminjail`, `tenx-elevators`, `tenx-zones` | Your own FiveM licence identifier — each resource has a `/…whoami` command that prints it |
| `PUT_A_SECOND_ADMIN_LICENSE_HERE` | `tenx-adminjail`, `tenx-zones` | A second admin, or delete the line |
| `FIVEMANAGE_TOKEN` (empty) | `tenx-spawnmenu` | Optional — leave `USE_FIVEMANAGE = false` to use local images instead |

No real webhooks, API tokens or licence identifiers are committed to this
repository, and the `.gitignore` is set up to keep it that way.

---

## Requirements

Common to most resources:

- [qb-core](https://github.com/qbcore-framework/qb-core) (or Qbox)
- [ox_lib](https://github.com/overextended/ox_lib)
- [ox_inventory](https://github.com/overextended/ox_inventory)
- [ox_target](https://github.com/overextended/ox_target)
- [oxmysql](https://github.com/overextended/oxmysql)

Each resource lists its own `dependencies` in its `fxmanifest.lua`. Where a
resource ships a `.sql` file, run it before starting the resource — see
[INSTALL.md](INSTALL.md) for the full list and the order to run them in.

---

## Licence

MIT — see [LICENSE](LICENSE).
