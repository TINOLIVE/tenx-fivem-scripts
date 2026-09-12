# tenx-rob

Player-to-player robbing for QBCore, built on `ox_target`, `ox_lib` and
`ox_inventory`.

Version 2.1.0. The rewrite that moved every decision that matters — what can be
taken, how much, whether the target is a valid victim — onto the server.

---

## Requirements

- `qb-core`
- `ox_lib`
- `ox_target`
- `ox_inventory`

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-rob` in `server.cfg`.
3. Open **`config_server.lua`** and replace `PUT_YOUR_DISCORD_WEBHOOK_HERE`
   with your own webhook, or set it to `''` to disable Discord logging.

---

## Why there are two config files

| File | Loaded as | Safe to put secrets in |
|---|---|---|
| `config.lua` | `shared_script` | **No** — every connected client can read it |
| `config_server.lua` | `server_script` | Yes |

The webhook and screenshot webhook live in `config_server.lua` for exactly this
reason. Anything you add that a player should not see goes there, not in
`config.lua`.

---

## Server authority

The client's job is limited to showing the `ox_target` option and playing the
animation. It does not decide the outcome.

- The server re-checks distance between robber and victim; a spoofed coordinate
  does not extend reach.
- Item transfer runs through `ox_inventory` server-side. The client never
  names what it receives.
- Each robbery generates a single-use token (`src:time:random`) so a replayed
  event cannot be cashed twice.

---

## Configuration

`config.lua` (shared) holds the timings, animations, cooldowns and which items
are robbable. `config_server.lua` holds the webhooks and anything else that
must stay server-side.
