# tenx-plates — NAIJA 2046

Nigerian-themed city plates + item-based plate customization for QBCore
(ox_lib + oxmysql + ox_inventory).

Two things this does:
1. **Whole city on Nigerian plates** — AI traffic, new bought cars, and (via a
   one-time command) existing owned cars.
2. **Per-player customization** — a **usable item** lets a player set their own
   plate text + design. The item is **consumed per change** (that is the cost).

---

## Install

1. Drop the `tenx-plates` folder in your resources.
2. `ensure tenx-plates` in your `server.cfg` (after qb-core, ox_lib, oxmysql, ox_inventory).
3. Import `sql/tenx_plates.sql` into your database.
4. Give admins the permission — in `server.cfg`:
   ```
   add_ace group.admin tenx-plates.admin allow
   ```
5. Register the item in **ox_inventory** `data/items.lua`:
   ```lua
   ['plate_kit'] = {
       label = 'Plate Kit',
       weight = 100,
       stack = true,
       close = true,
       description = 'Customize your motor plate — naija style.',
   },
   ```
   (Item name must match `Config.Item`.) Then give it out, or add it to your
   VIP shop / city pass.

---

## DEV WIRING — where things link (read this)

Everything you'll likely need to touch is either in `config.lua` or marked
`>>> DEV WIRING #n <<<` in the code.

- **#1 — Plate cascade tables** → `config.lua > Config.PlateTables`
  The plate is the vehicle's DB identity. List EVERY table on your server that
  stores a plate. A plate change (custom OR migration) updates all of them at
  once, so cars never lose keys/garage links. Only `player_vehicles` is on by
  default — add insurance, garage, boats, etc. to match your server.

- **#2 — Owned-car statebag flag** → `config.lua > Config.Traffic.ownedStateFlag`
  Traffic plates skip AI cars only. If your garage tags owned vehicles with a
  statebag (e.g. `Entity(veh).state.owned = true`), put that key here so a
  parked owned car never gets a random cosmetic plate. If your garage doesn't
  set one, leave it — player-driven cars are already skipped.

- **#3 — Vehicle keys** → `server/main.lua`, inside `cascadePlate()`
  When a plate changes, re-issue keys for the NEW plate with YOUR keys resource.
  A qb-vehiclekeys example is commented in place — uncomment/edit for your setup.

- **#4 — New bought cars** → `exports['tenx-plates']:GenerateNewPlate()`
  In your vehicleshop, when a car is purchased, set its plate with this export
  so every new owned car is born Nigerian:
  ```lua
  local plate = exports['tenx-plates']:GenerateNewPlate()
  ```

- **Custom NAIJA plate texture (the "real deal" look)** → `config.lua > Config.Designs`
  GTA only ships American-style plate designs. To get a true Nigerian plate
  (white/green, flag, FRSC strip) you need a **streamed plate texture** — an
  art asset. Once your dev adds the plate `.ytd` pack and it has a plate index,
  add `{ label = 'NAIJA Green', index = 6 }` (or whatever index) to
  `Config.Designs`. No other code changes needed.

  **Spec to hand whoever makes the texture:** a standard GTA license-plate
  replacement/add-on that registers a new **plate index** (via `carcols` /
  streamed `plate_diffuse` + `plate_normal` `.ytd`). Nigerian civilian style:
  white background, green top strip, black text, national/FRSC branding.
  Deliver as its own streaming resource; give us the resulting plate index.

---

## Admin commands

- `/naijaplates_migrate` — one-time: convert every existing owned car to a
  Nigerian plate (skips cars already in Nigerian format). **Back up your DB
  first**, and make sure `Config.PlateTables` + the keys hook (#3) are set,
  since this rewrites live plates.
- `/plateoverride <oldPlate> <newPlate>` — force-set any plate.
- `/plateblock add <word>` / `/plateblock remove <word>` — manage banned words live.

---

## Config quick-reference (`config.lua`)

- `Config.Item` — the usable item name.
- `Config.AllowSpaces` / `Config.BlockFullyBlank` — balanced rule: spaces inside
  are allowed, a fully-blank plate is rejected.
- `Config.ForceNigerianFormatOnCustom` — `false` = vanity plates allowed;
  `true` = custom plates must match `LLL DDD LL`.
- `Config.Designs` — plate styles shown in the menu.
- `Config.Traffic` — city-wide AI plates on/off + tuning.
- `Config.BannedWords` — starter blocklist (extend in file or via `/plateblock`).
- `Config.Text` — all Pidgin notifications.

---

## Security notes

Server-authoritative throughout: the client only requests; the server verifies
the player exists, owns the car, is holding the item, then validates the text
(length, allowed chars, blank, banned words, uniqueness) before consuming the
item and cascading the change. Parameterized SQL only. Per-player cooldown on
the apply event. No money logic exists — the item is the sole cost, so there's
no cash exploit surface.
